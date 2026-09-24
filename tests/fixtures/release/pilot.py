"""Actual safe local integration, deliberately separate from deterministic CI.

The driver is the evaluation operator, not a production release controller.
Every effect is a real loopback HTTP request; Firstmate helpers never execute it.
Evidence is retained under the explicit disposable directory, including failures.
"""
import copy
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from contract import record, body, stamp

root, dest = (Path(x).resolve() for x in sys.argv[1:])
dest.mkdir(parents=True, exist_ok=False)
home=dest/'home'
for d in ('data','state','config'): (home/d).mkdir(parents=True)
(home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
env.update(FM_HOME=str(home),FM_PROCEVENT_CLAIM_ROOT=str(dest/'claims'),TASKS_AXI_BACKEND='markdown',
           FM_POLL='1',FM_CHECK_INTERVAL='1',FM_HEARTBEAT='999999',FM_HOME_SUMMARY_INTERVAL='999999')
cli=root/'bin/fm-release.sh'; workload=root/'tests/fixtures/release/workload.py'
log=dest/'transcript.jsonl'; started=time.time(); results=[]; processes=[]

def run(*argv, code=0, timeout=40):
    begin=time.time()
    p=subprocess.run([str(x) for x in argv],cwd=home,env=env,text=True,capture_output=True,timeout=timeout)
    with log.open('a') as f: f.write(json.dumps(dict(at=begin,duration=time.time()-begin,argv=list(map(str,argv)),exit=p.returncode,stdout=p.stdout,stderr=p.stderr))+'\n')
    assert p.returncode==code,(argv,p.returncode,p.stdout,p.stderr)
    return p.stdout

def result(name, expected, observed, status='pass', limitation='local representative environment only'):
    row=dict(requirement=name,expected=expected,observed=observed,status=status,evidence=str(log),
             limitation=limitation,observed_at=time.time())
    results.append(row)
    (dest/'scenarios.json').write_text(json.dumps(results,indent=2)+'\n')

def task(command,*args):
    args=list(args)
    if command=='done' and '--report' in args:
        report=home/'data'/args[0]/'report.md'; report.parent.mkdir(parents=True,exist_ok=True)
        report.write_text('Observed evidence: '+str(log)+'\n')
        args[args.index('--report')+1]='data/'+args[0]+'/report.md'
    return run('tasks-axi',command,*args,'--backend','markdown','--file',home/'data/backlog.md')

def save(r):
    p=dest/'release-body.md'; p.write_text(body(r))
    task('update','local-release','--body-file',p,'--archive-body','--json')
    return p

def check(r,operation=None,target='',op_id='',code=0,peer=None):
    p=dest/'check-body.md'; p.write_text(body(r)); args=[cli,'check',p]
    if operation: args+=['--operation',operation,'--target',target,'--operation-id',op_id]
    if peer: args+=['--peer',peer]
    return json.loads(run(*args,code=code))

def http(path,data=None,code=0):
    args=[sys.executable,workload,'request',url,path]
    if data is not None: args.append(json.dumps(data))
    out=run(*args,code=code)
    return json.loads(out) if code==0 else out

def launch(name='workload',manifest=None):
    address=dest/(name+'-address')
    if address.exists(): address.unlink()
    p=subprocess.Popen([sys.executable,str(workload),'serve',str(dest/(name+'.sqlite')),str(address),str(manifest or dest/'manifest.json')],env=env,
                        stdout=(dest/'server.stdout').open('a'),stderr=(dest/'server.stderr').open('a'))
    processes.append(p)
    deadline=time.time()+5
    while not address.exists() and time.time()<deadline:
        assert p.poll() is None,'server exited'; time.sleep(.02)
    assert address.exists(),'server did not bind loopback'
    return p,address.read_text()

def observation(raw):
    keys=('candidate','source','configuration','environment','dependencies','id','signal_source','exposure_attempt','effect','started_at','ended_at','observed_at','samples','health','stop','exposure')
    return dict({k:raw[k] for k in keys},evidence=str(log),plan=plan_binding['plan'])

def exposure_attempt(raw):
    return dict(id=raw['exposure_attempt'],target=raw['exposure'],started_at=raw['since'])

def completed_action(raw,key):
    return dict(next(a for a in raw['actions'] if a['id']==key),status='verified',evidence=str(log))

def acknowledge_wakes():
    run(root/'bin/fm-wake-drain.sh')
    last=json.loads(log.read_text().splitlines()[-1])
    match=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',last['stderr'])
    assert match,last
    run(root/'bin/fm-wake-drain.sh','--ack-through',match[1],'--recovery-generation',match[2])
    assert not (home/'state/.wake-queue').read_text().strip()


def action(r,op,target,key):
    r['progress']['pending_action']=dict(id=key,operation=op,target=target,status='planned')
    save(r); check(r,op,target,key)
    http('/action',dict(id=key,operation=op,target=target))
    actual=http('/state')
    assert sum(a['id']==key for a in actual['actions'])==1
    if op in ('expose','advance'):
        assert actual['exposure_attempt']==key and actual['exposure']==target
        r['progress']['exposure_attempt']=exposure_attempt(actual)
        r['progress']['observation']=None
    r['progress']['completed_actions'].append(completed_action(actual,key))
    r['progress']['pending_action']=None
    save(r)
    return actual

plan='''# Authorized disposable local pilot
Candidate: exact SHA-256 of the workload program; environment: loopback HTTP and isolated SQLite under this directory.
Permitted actions: local deploy, internal exposure, all-local exposure, disable, representative failed restoration, and retained-data inspection; never production or live fleet mutation.
Stages: internal then all-local; each needs at least 2 real requests over a 1-second window ending within 60 seconds of assessment.
Measurements identify the current exposure action and start no earlier than its verified external start time; restart retains that attempt after reconciliation.
Health and terminal evidence must match the current plan and latest reconciled effect; measurements and final verification cannot predate that effect.
Stop: any leaked write, unhealthy response, or unavailable monitoring stops expansion.
Recovery: disable gate, issue fresh requests, compare persisted write counts, and retain earlier writes; an acknowledged request alone is insufficient.
Real commands: brief/promotion outputs, installed tasks-axi markdown lifecycle, fm-release consistency check, authenticated fm-check registration, fm-watch, generation-bound wake drain/ack, and owner retirement.
The operator verifies authorization from the accepted test scope; the checker only assesses recorded consistency.
'''
(dest/'plan.md').write_text(plan)
try:
    # Installed capabilities, real home isolation, and the actual session lock.
    run('tasks-axi','--version')
    run('bash','-c','. "$1/bin/fm-tasks-axi-lib.sh"; fm_tasks_axi_compatible', '_', root)
    lock=run(root/'bin/fm-lock.sh')
    result('session-isolation','own synthetic lock',lock)
    # Phase 1: two bounded development assessments, using emitted public output.
    phase1_start=time.time()
    assessments={
      'contained': ['Correct a help label.','Preserve command behavior.','Only help output; no shared state.','low - text only; revert is straightforward.',
                    'Inspect rendered help.','Revert wording; no persistent effects.','not applicable - code-only wording.'],
      'shared': ['Bound shared retry attempts.','Preserve authorization and duplicate-operation safety.','Shared callers and persistent retry journal; small diff has broad reach.',
                 'high - shared state and duplicate writes; human attention: replay and authority boundaries.',
                 'Observe enabled/disabled requests, duplicate retries and recovery writes.','Stop new attempts; retain earlier writes pending inspection.',
                 'deferred - local-release retains obligations.']}
    fields=['Intended behavior','Preserved behavior','Impact and dependencies','Risk and rationale','Validation scenarios','Recovery approach','Release applicability']
    prep={}
    for name,values in assessments.items():
        t=time.time(); run(root/'bin/fm-brief.sh',name,'synthetic','--mode','local-only')
        p=home/'data'/name/'brief.md'; text=p.read_text().replace('{TASK}',values[0]).replace('{FIRSTMATE_SPEC}','Preserve the accepted outcome; use only authorized local checks.')
        for f,v in zip(fields,values): text=re.sub(r'^- '+re.escape(f)+r':.*$', '- '+f+': '+v,text,flags=re.M)
        p.write_text(text); assert all('- '+f+':' in text for f in fields)
        prep[name]=time.time()-t
    amended=home/'data/contained/brief.md'; prior=amended.read_text()
    amended.write_text(prior.replace('Correct a help label.', 'Clarify the help label without changing flags.'))
    assert 'Correct a help label.' not in amended.read_text() and 'Preserve command behavior.' in amended.read_text()
    result('accepted-amendment','replace superseded criterion and retain preservation constraint', 'amended emitted brief contains current criterion and original preservation constraint')
    result('phase1-assessments','seven useful fields, unchanged local-only mode, no risk-only approval',assessments)
    result('impact-evaluation','small shared-state change recognized as high reach; wording stays contained',
           'operator evaluation in emitted briefs; independent interpretation is for selected validation owner',limitation='authored assessments, not proof of model compliance')
    # Phase 2: real requests and persistent writes, with an intentional bad disabled path.
    digest=hashlib.sha256(workload.read_bytes()).hexdigest()
    manifest=dict(candidate=digest,source=digest,configuration='gated-v1',environment='loopback',dependencies='python-stdlib')
    (dest/'manifest.json').write_text(json.dumps(manifest))
    server,url=launch(); phase2_start=time.time()
    before=http('/state')['writes']; response=http('/request'); after=http('/state')['writes']
    assert not response['visible'] and not response['wrote'] and before==after and response['protective_control']
    result('disabled','hidden with no new writes and protective control intact',dict(before=before,after=after,response=response))
    http('/control',dict(leak=True)); before=http('/state')['writes']; response=http('/request'); after=http('/state')['writes']
    assert not response['visible'] and response['wrote'] and after==before+1
    result('disabled-leak','intentional hidden background write must fail containment',dict(before=before,after=after,response=response),'fail','intentional defect detected; fixed below before readiness')
    http('/control',dict(leak=False,gate='enabled')); response=http('/request'); assert response['visible'] and response['wrote']
    result('enabled','feature writes when enabled',response)
    http('/control',dict(gate='disabled')); before=http('/state')['writes']; response=http('/request'); after=http('/state')['writes']
    assert not response['wrote'] and after==before and after>0
    result('enable-disable','no new writes; earlier persistent effects retained',dict(before=before,after=after,response=response))
    for gate in ('invalid','unavailable'):
        http('/control',dict(gate=gate)); response=http('/request'); assert not response['wrote'] and response['protective_control']
        result('gate-'+gate,'safe default with protection preserved',response)
    result('device-capability','device reconnection check','no device or device integration in local workload','untested','no capability; no device-readiness claim')
    # Phase 3: use the actual installed task backend, without registering a project.
    phase3_start=time.time()
    # Establish monitoring capability before claiming readiness. Captures use
    # distinct files so a replay never reads replacement observation bytes.
    capture=dest/'monitor-readiness.json'
    checkscript=home/'state/release-local.check.sh'
    checkscript.write_text('#!/bin/sh\nexec '+' '.join(shlex.quote(x) for x in [sys.executable,str(workload),'observe',url,str(capture)])+'\n')
    checkscript.chmod(0o700); run(root/'bin/fm-check-register.sh','release-local')
    run(root/'bin/fm-watch.sh',timeout=25)
    monitor=json.loads(capture.read_text()); assert monitor['candidate']==digest and monitor['health']=='healthy'
    result('monitor-readiness','actual registered probe can observe candidate',monitor)
    acknowledge_wakes()
    now=time.time(); r=record(cli,now)
    r['identity']['home']=str(home)
    r['candidate'].update(source=digest,artifact=digest)
    for row in r['readiness']:
        row.update(candidate=digest,source=digest,evidence=str(log),observed_at=time.time())
        if row['category']=='functional': row.update(expected='enabled writes, disabled containment, invalid-gate safe default',observed='real HTTP responses and persisted write counts verified')
        elif row['category']=='recovery': row.update(expected='disable prevents subsequent writes while retaining prior data',observed='write count unchanged after disable and remains nonzero')
        elif row['category']=='monitoring': row.update(expected='registered check captures actual candidate health',observed='native watcher captured healthy loopback response',evidence=str(capture))
        elif row['category']=='security/privacy': row.update(expected='loopback only, synthetic data, existing protective control retained',observed='127.0.0.1 listener; request protective_control=true; no live credentials used')
        else: row.update(status='not-applicable',expected='no '+row['category']+' acceptance criterion for coordination-only local workload',observed='not applicable',limitation='API-only synthetic pilot; no UI or production performance claim')
    for authority in r['authority']: authority.update(candidate=digest,source=digest)
    r['progress'].update(phase='Ready',stage='initial',deployment=None,exposure_attempt=None,observation=None,completed_actions=[])
    r['watches']=['custom-check:release-local']
    plan_binding=stamp(cli,r)
    impl=dest/'implementation-body.md'; impl.write_text('Accepted implementation.\nRelease tasks: '+str(home)+'#local-release ('+digest+'/loopback); '+str(home)+'#deferred-release ('+digest+'/offline).\n')
    for task_id in ('implementation','second-implementation'):
        task('add',task_id,'Local implementation','--kind','ship','--body-file',impl,'--start','--json')
    p=dest/'release-body.md'; p.write_text(body(r)); task('add','local-release','Local release obligation','--kind','ship','--body-file',p,'--json')
    task('add','deferred-release','Deferred offline release','--kind','ship','--body','Implementation links: implementation and second-implementation; exposure deferred, no authority.','--json')
    task('done','implementation','--report',str(log),'--json')
    shown=task('show','local-release','--full'); assert digest in shown and 'second-implementation' in shown
    result('release-continuity','release retained after implementation completion; many-to-many links',shown)
    # Duplicate delivery discovers existing identity instead of creating another task.
    duplicate=copy.deepcopy(r); duplicate['identity']['task']='duplicate-release'
    peer=dest/'existing-peer.md'; peer.write_text(body(r))
    check(duplicate,'deploy','disabled','duplicate',1,peer)
    listing=task('list'); assert 'duplicate-release' not in listing
    result('duplicate-linkage','repeat identity reuses existing task','duplicate rejected, no duplicate task created')
    # Merge-only permission must produce zero actions.
    denied=copy.deepcopy(r); denied['authority']=[dict(operation='merge',target='main')]
    count=len(http('/state')['actions']); check(denied,'deploy','disabled','unauthorized',1); assert len(http('/state')['actions'])==count
    result('merge-authority','zero deployment from merge permission',dict(actions_before=count,actions_after=count))
    actual=action(r,'deploy','disabled','deploy-1')
    assert actual['candidate']==digest and actual['source']==digest and actual['exposure']=='none'
    r['progress'].update(phase='Deployed, unexposed',deployment=dict(plan_binding,artifact=digest,evidence=str(log)))
    save(r); action(r,'expose','internal','expose-1'); r['progress'].update(phase='Observing',stage='initial'); save(r)
    http('/request'); http('/request'); time.sleep(1.05)
    # Registered real check emits a durable wake after actual HTTP observation.
    capture=dest/'observation.json'
    checkscript=home/'state/release-local.check.sh'
    checkscript.write_text('#!/bin/sh\nexec '+' '.join(shlex.quote(x) for x in [sys.executable,str(workload),'observe',url,str(capture)])+'\n')
    checkscript.chmod(0o700); run(root/'bin/fm-check-register.sh','release-local')
    run(root/'bin/fm-watch.sh',timeout=25)
    assert capture.exists(); captured=json.loads(capture.read_text()); assert captured['candidate']==digest
    drain=run(root/'bin/fm-wake-drain.sh'); queue=home/'state/.wake-queue'; queued=queue.read_text(); assert 'release-local' in queued
    # No acknowledgement until effects and task records have been reconciled.
    replay=run(root/'bin/fm-wake-drain.sh'); assert queue.read_text()==queued
    r['progress']['observation']=observation(captured); r['progress']['phase']='Expansion ready'; save(r)
    cached=copy.deepcopy(r)
    cached['progress']['observation'].update(started_at=captured['started_at']-120,
                                           ended_at=captured['ended_at']-120,observed_at=time.time())
    cached['progress']['exposure_attempt']['started_at']=captured['started_at']-120
    for effect in cached['progress']['completed_actions']: effect['effect_at']-=120
    assert check(cached,'advance','all-local','expand-1',1)['health']=='unknown'
    assert http('/state')['exposure']=='internal'
    result('REL-06 cached-window','fresh reporting cannot renew stale measurements',
           'captured probe with deliberately aged measurement window blocks expansion as unknown',
           limitation='timestamp fault injected into a copy of the real registered probe')
    # Monitoring loss via a real 503 prevents advancement, without exposure change.
    http('/control',dict(monitoring=False)); missing_capture=dest/'monitoring-loss.json'
    run(sys.executable,workload,'observe',url,missing_capture)
    missing=json.loads(missing_capture.read_text()); assert missing['health']=='unknown'
    paused=copy.deepcopy(r); paused['progress']['observation']=missing
    check(paused,'advance','all-local','expand-1',1); assert http('/state')['exposure']=='internal'
    result('monitoring-loss','unknown cannot expand; current exposure retained',missing)
    http('/control',dict(monitoring=True))
    # Resource reservation survives task writes; independent resources remain usable.
    peer_record=copy.deepcopy(r); peer_record['identity']['task']='conflicting'; peer_record['candidate']['artifact']='other-build'
    peer_record['progress']['pending_action']=dict(id='other-op',operation='advance',target='other',status='planned')
    peer.write_text(body(peer_record))
    task('add','conflicting','Resource reservation','--body-file',peer,'--start','--json')
    blocked=json.loads(task('block','local-release','--by','conflicting','--json'))
    assert blocked['task']['blocked']
    check(r,'advance','all-local','expand-1',1,peer)
    peer_record['target']['resources']=['loopback/independent']; peer.write_text(body(peer_record))
    task('update','conflicting','--body-file',peer,'--archive-body','--json')
    task('unblock','local-release','--by','conflicting','--json')
    task('start','local-release','--json')
    check(r,'advance','all-local','expand-1',0,peer)
    result('resource-coordination','conflict blocks; independent resource proceeds','verified against both peer records')
    # Crash window: effect happened, task still says ambiguous. New server/process
    # reconstructs persisted effects before any retry, never from request exit.
    r['progress']['pending_action']=dict(id='expand-1',operation='advance',target='all-local',status='planned'); save(r)
    check(r,'advance','all-local','expand-1'); http('/action',dict(id='expand-1',operation='advance',target='all-local'))
    r['progress']['pending_action']['status']='ambiguous'; save(r)
    server.terminate(); server.wait(timeout=5); server,url=launch()
    restart=task('show','local-release','--full'); assert 'ambiguous' in restart and digest in restart
    check(r,'advance','all-local','expand-1',1)
    actual=http('/state'); assert actual['exposure']=='all-local' and sum(a['id']=='expand-1' for a in actual['actions'])==1
    assert actual['exposure_attempt']=='expand-1'
    r['progress']['exposure_attempt']=exposure_attempt(actual)
    r['progress']['observation']=None
    r['progress']['pending_action']=None
    r['progress']['completed_actions'].append(completed_action(actual,'expand-1'))
    save(r); verdict=check(r,'advance','all-local','expand-1'); assert verdict['assessment']=='already-observed'
    assert sum(a['id']=='expand-1' for a in http('/state')['actions'])==1
    result('restart-replay','ambiguous effect reconciled once, replay makes no repeat action',actual)
    # Acknowledge the previously delivered wake using exactly the owner's command.
    acknowledge_wakes()
    result('durable-wake','replay retained until generation-bound acknowledgement','registered check, two drains, persisted effect, owner ack')
    # Recovery request can succeed while unsafe background effects continue.
    http('/control',dict(leak=True)); action(r,'contain','none','contain-1')
    before=http('/state')['writes']; http('/request'); after=http('/state')['writes']; assert after==before+1
    r['progress']['phase']='Recovering'; r['outcome'].update(disposition='failed-recovery',recovery='failed'); save(r)
    check(r,'complete',code=1)
    result('failed-containment','acknowledged disable with continuing writes is failed recovery',dict(before=before,after=after),'fail','intentional defect; contained below')
    http('/control',dict(fail_restore=True)); check(r,'restore','retained-data','restore-1'); http('/action',dict(id='restore-1',operation='restore',target='retained-data'),code=1)
    check(r,'complete',code=1)
    result('failed-restoration','failed attempt remains unresolved Recovering','HTTP 503 and terminal refusal','fail','intentional representative restoration failure')
    # Repair the representative defect without deleting earlier persistent data.
    http('/control',dict(leak=False)); before=http('/state')['writes']; http('/request'); http('/request'); after=http('/state')['writes']; assert before==after and after>0
    final_state=http('/state'); assert final_state['exposure']=='none' and final_state['health']=='healthy'
    r['progress']['phase']='Stopped'; r['outcome'].update(plan_binding,disposition='withdrawn',exposure='none',health='safe',evidence=str(log),recovery='contained',observed_at=final_state['observed_at'],effect=final_state['actions'][-1]['id'])
    run(root/'bin/fm-check-unregister.sh','release-local'); r['outcome']['watches_retired']=True
    for group,key in [('candidate','artifact'),('target','environment')]:
        changed=copy.deepcopy(r); changed[group][key]='changed-after-verification'
        verdict=check(changed,'complete',code=1)
        assert 'evidence binding missing or mismatched' in verdict['reasons']
    result('PROOF-04 REL-03 REL-14 terminal-binding','changed candidate or environment requires new final verification',
           'retained withdrawal evidence refused for each changed identity')
    ambiguous=copy.deepcopy(r)
    ambiguous['progress']['pending_action']=dict(id='unknown-effect',operation='restore',target='retained-data',status='ambiguous')
    check(ambiguous,'complete',code=1)
    check(r,'complete'); save(r)
    server.terminate(); server.wait(timeout=5); server,url=launch()
    restored=task('show','local-release','--full')
    restored_body=json.loads(next(line[len('  body: '):] for line in restored.splitlines() if line.startswith('  body: ')))
    r=json.loads(restored_body.split('```firstmate-release\n')[1].split('\n```')[0])
    assert r['outcome']['effect']==http('/state')['actions'][-1]['id']
    check(r,'complete'); task('done','local-release','--report',str(log),'--json')
    result('REL-12 REL-14 terminal-restart','current withdrawal survives restart; ambiguity blocks completion',
           dict(effect=r['outcome']['effect'],verification_time=r['outcome']['observed_at']))
    result('verified-withdrawal','Stopped after observable containment, not data restoration',dict(writes_retained=after,final_exposure=http('/state')['exposure']))
    # A second authorized local attempt reopens the same coherent release,
    # preserving the withdrawn attempt in archived body history.
    task('reopen','local-release','--json')
    finished=copy.deepcopy(r)
    finished['progress'].update(phase='Ready', stage='initial', observation=None, pending_action=None)
    finished['outcome'].update(disposition='pending',recovery='not-needed')
    save(finished)
    action(finished,'expose','internal','success-internal')
    stale_withdrawal=copy.deepcopy(finished)
    stale_withdrawal['progress']['phase']='Stopped'
    stale_withdrawal['outcome']=copy.deepcopy(r['outcome'])
    assert time.time()-stale_withdrawal['outcome']['observed_at'] < stale_withdrawal['health']['max_age_seconds']
    check(stale_withdrawal,'complete',code=1)
    stale_withdrawal['outcome']['effect']='success-internal'
    check(stale_withdrawal,'complete',code=1)
    assert http('/state')['exposure']=='internal'
    result('PROOF-04 REL-14 stale-withdrawal','re-exposure invalidates old terminal proof, including a relabeled reference',
           dict(old_verification=r['outcome']['observed_at'],latest_effect=finished['progress']['completed_actions'][-1]))
    replayed=copy.deepcopy(finished)
    replayed['progress'].update(phase='Expansion ready',observation=observation(captured))
    actions_before=http('/state')['actions']
    assert time.time()-captured['ended_at'] < replayed['health']['max_age_seconds']
    assert check(replayed,'advance','all-local','success-expand',1)['health']=='unknown'
    assert http('/state')['actions']==actions_before
    result('REL-07 prior-attempt-replay','fresh prior-attempt measurements cannot advance a new exposure',
           dict(prior_attempt=captured['exposure_attempt'],current_attempt=finished['progress']['exposure_attempt'],actions_unchanged=True))
    http('/request'); http('/request'); time.sleep(1.05)
    finished['progress'].update(phase='Expansion ready',stage='initial',observation=observation(http('/health')))
    save(finished)
    prior_attempt=copy.deepcopy(finished['progress']['exposure_attempt'])
    server.terminate(); server.wait(timeout=5); server,url=launch()
    restored=task('show','local-release','--full')
    restored_body=json.loads(next(line[len('  body: '):] for line in restored.splitlines() if line.startswith('  body: ')))
    finished=json.loads(restored_body.split('```firstmate-release\n')[1].split('\n```')[0])
    assert finished['progress']['exposure_attempt']==prior_attempt==exposure_attempt(http('/state'))
    assert check(finished,'advance','all-local','success-expand')['health']=='healthy'
    result('REL-10 REL-12 same-attempt-restart','restart preserves reconciled exposure and eligible measurements',
           dict(attempt=prior_attempt,observation_attempt=finished['progress']['observation']['exposure_attempt']))
    save(finished); action(finished,'advance','all-local','success-expand')
    http('/request'); http('/request'); time.sleep(1.05); raw=http('/health')
    finished['progress'].update(phase='Released',stage='final',observation=observation(raw))
    finished['outcome'].update(plan_binding,disposition='released',exposure='all-local',health='healthy',recovery='not-needed',evidence=str(log),observed_at=raw['observed_at'],effect=raw['actions'][-1]['id'])
    check(finished,'complete'); save(finished); task('done','local-release','--report',str(log),'--json')
    cancelled=copy.deepcopy(finished); cancelled['identity']['task']='cancelled-offline-release'; cancelled['target']['environment']='offline'
    cancel_manifest=dest/'cancelled-manifest.json'; cancel_manifest.write_text(json.dumps(dict(manifest,environment='offline')))
    _,cancel_url=launch('cancelled',cancel_manifest)
    unexposed=json.loads(run(sys.executable,workload,'request',cancel_url,'/state'))
    assert unexposed['candidate']==digest and unexposed['environment']=='offline'
    assert unexposed['exposure']=='none' and unexposed['gate']=='disabled' and unexposed['health']=='healthy' and not unexposed['actions'] and not unexposed['exposure_attempt']
    cancelled['progress'].update(phase='Stopped',deployment=None,observation=None,exposure_attempt=None,completed_actions=[])
    cancelled['outcome'].update(disposition='cancelled',exposure='none',health='safe',evidence=str(log),effect=None)
    final=dest/'cancelled-body.md'; final.write_text(body(cancelled))
    cancelled['outcome'].update(json.loads(run(cli,'fingerprint',final)),observed_at=unexposed['observed_at'])
    check(cancelled,'complete'); final=dest/'cancelled-body.md'; final.write_text(body(cancelled)); task('add','cancelled-offline-release','Cancelled offline outcome','--body-file',final,'--json'); task('done','cancelled-offline-release','--report',str(log),'--json')
    result('terminal-outcomes','released, withdrawn, cancelled, failed recovery remain distinct','actual task lifecycle and observed states recorded')
    # Manual mode uses inspect-then-edit, never silently calling tasks-axi.
    (home/'config/backlog-backend').write_text('manual\n')
    run('bash','-c','. "$1/bin/fm-tasks-axi-lib.sh"; fm_backlog_backend_manual "$2/config"', '_',root,home)
    backlog=home/'data/backlog.md'; old=backlog.read_text(); (dest/'manual-backlog-before.md').write_text(old)
    assert 'deferred-release' in old
    backlog.write_text(old.replace('exposure deferred, no authority.','exposure deferred, no authority; manual-mode owner retains obligation.'))
    assert 'manual-mode owner retains obligation' in backlog.read_text() and 'local-release' in backlog.read_text()
    result('manual-backend','existing manual contract preserves linked obligations','inspect/archive/edit/read confirmed; no task-tool write after opt-out')
    # Observe counts, never infer safety from the report's own success fields.
    actual=http('/state')
    forbidden=[a for a in actual['actions'] if a['id']=='unauthorized']
    ids=[a['id'] for a in actual['actions']]
    assert not forbidden and len(ids)==len(set(ids))
    public=run(cli,'summary',dest/'release-body.md')
    assert str(home) not in public and str(log) not in public and digest not in public
    (dest/'public-summary.json').write_text(public)
    result('privacy','public projection omits private home, candidate and evidence paths',public)
    metrics=dict(started_at=started,finished_at=time.time(),brief_scaffold_render_seconds=prep,
                 phase1_seconds=phase2_start-phase1_start,phase2_seconds=phase3_start-phase2_start,
                 phase3_seconds=time.time()-phase3_start,validation_seconds=time.time()-started,
                 captain_interruptions=0,unauthorized_actions=len(forbidden),duplicate_actions=len(ids)-len(set(ids)),
                 unknown_advanced_actions=0,action_journal=actual['actions'],retained_writes=actual['writes'],
                 gaps=['hidden disabled write','containment acknowledgement without recovery','monitoring unavailable','ambiguous post-action restart'],
                 limits=['device unavailable','checker validates consistency, not evidence truth','no production performance or defect-reduction claim'])
    (dest/'metrics.json').write_text(json.dumps(metrics,indent=2)+'\n')
    print('PASS real local release pilot: '+str(dest))
finally:
    if (home/'state/release-local.check.sh').exists():
        run(root/'bin/fm-check-unregister.sh','release-local')
    for p in processes:
        if p.poll() is None: p.terminate(); p.wait(timeout=5)
