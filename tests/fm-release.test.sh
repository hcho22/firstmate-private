#!/usr/bin/env bash
# Behavior of the read-only release task body interface; no live services/models.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-release)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import copy, json, pathlib, subprocess, sys
root, temp = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(root/'tests/fixtures/release'))
from contract import record, body, stamp
cli = root/'bin/fm-release.sh'
base = record(cli)
base_binding = stamp(cli, base)
count = 0

def check(r, status=0, *args, contains=None, now=1000):
    global count
    file = temp/'task.md'; file.write_text(body(r) if isinstance(r, dict) else r)
    before = file.read_bytes()
    p = subprocess.run([str(cli), 'check', str(file), '--now', str(now), *args], text=True, capture_output=True)
    assert p.returncode == status, (p.returncode, status, p.stdout, p.stderr)
    assert file.read_bytes() == before, 'checker mutated task'
    result = json.loads(p.stdout)
    if contains: assert contains in p.stdout, p.stdout
    count += 1
    return result

advance = ('--operation', 'advance', '--target', 'all-local', '--operation-id', 'expand-1')
check(base, 0, *advance)
check('legacy notes only', 1, contains='legacy/unassessed')
check('```firstmate-release\n{}', 2)
check(body(base)+body(base), 2)
check('```firstmate-release\n{"schema":1,"schema":1}\n```', 2)
check('```firstmate-release\n{"schema":NaN}\n```', 2)
# Every unknown/insufficient source blocks progression, preserving honest labels.
for key,value,health in [('observed_at',900,'unknown'), ('environment','wrong','unknown'),
                         ('candidate','old-build','unknown'), ('samples',0,'insufficient'),
                         ('ended_at',995.5,'insufficient'), ('observed_at',1001,'unknown'),
                         ('health','unknown','unknown'), ('health','broken','unknown'),
                         ('samples','two','unknown'), ('stop','false','unknown'),
                         ('stop',True,'unhealthy')]:
    r=copy.deepcopy(base); r['progress']['observation'][key]=value
    result=check(r,1,*advance); assert result['health']==health, result
for ended_at,status in [(200,1),(939.9,1),(940,0),(999,0)]:
    r=copy.deepcopy(base)
    r['progress']['exposure_attempt']['started_at']=100
    r['progress']['completed_actions'][0]['effect_at']=100
    r['progress']['observation'].update(started_at=100,ended_at=ended_at,observed_at=1000)
    result=check(r,status,*advance)
    assert result['health']==('unknown' if status else 'healthy'),result
    assert check(r)['health']==result['health']
r=record(cli,156); r['stages'][0]['window_seconds']=40
r['progress']['exposure_attempt'].update(started_at=100)
r['progress']['completed_actions'][0]['effect_at']=100
r['progress']['observation'].update(started_at=100,ended_at=140,observed_at=140)
stamp(cli,r)
check(r,0,*advance,now=156)
r['progress']['exposure_attempt'].update(id='expose-2',started_at=155)
r['progress']['completed_actions'].append(dict(id='expose-2',operation='expose',target='internal',status='verified',evidence='re-exposure observed',effect_at=155))
assert check(r,1,*advance,now=156)['health']=='unknown'
assert check(r,now=156)['health']=='unknown'
r['progress']['observation']['exposure_attempt']='expose-2'
r['progress']['observation']['effect']='expose-2'
assert check(r,1,*advance,now=156)['health']=='unknown'
r['progress']['observation'].update(started_at=155,ended_at=156,observed_at=156)
assert check(r,1,*advance,now=156)['health']=='insufficient'
r['progress']['observation'].update(ended_at=195,observed_at=195)
check(r,0,*advance,now=195)
saved=temp/'restart.md'; saved.write_text(body(r))
check(saved.read_text(),0,*advance,now=195)
r['progress']['pending_action']=dict(id='expand-1',operation='advance',target='all-local',status='ambiguous')
check(r,1,*advance,now=195,contains='reconcile')
for value in (None,{},'expose-1',dict(id='',target='internal',started_at=995),
              dict(id='expose-1',target='wrong',started_at=995)):
    r=copy.deepcopy(base); r['progress']['exposure_attempt']=value
    assert check(r,1,*advance)['health']=='unknown'
for value in (None,True,'995',-1,1001):
    r=copy.deepcopy(base); r['progress']['exposure_attempt']['started_at']=value
    assert check(r,1,*advance)['health']=='unknown'
for group,key in [('progress','exposure_attempt'),('observation','exposure_attempt'),('observation','effect')]:
    r=copy.deepcopy(base)
    del (r['progress'] if group=='progress' else r['progress']['observation'])[key]
    assert check(r)['health']=='unknown'
    check(r,1,*advance)
r=copy.deepcopy(base); r['progress'].update(phase='Ready',exposure_attempt=None,observation=None,completed_actions=[])
check(r,0,'--operation','deploy','--target','disabled','--operation-id','deploy-1')
for group,key in [('candidate','artifact'), ('candidate','configuration'), ('candidate','source'), ('candidate','dependencies'), ('target','environment')]:
    r=copy.deepcopy(base); r[group][key]='changed'; check(r,1,*advance)
r=copy.deepcopy(base); r['stages'][0]['min_samples']=1; check(r,1,*advance,contains='stale')
r=copy.deepcopy(base); r['health']['baseline']='silently changed'; check(r,1,*advance)
r=copy.deepcopy(base); r['progress']['observation']=None; check(r,1,*advance)
r=copy.deepcopy(base); r['authority']=[dict(operation='merge', target='main')]; check(r,1,*advance,contains='authority')
r=copy.deepcopy(base); r['authority'][2]['expires_at']=999; check(r,1,*advance)
r=copy.deepcopy(base); r['readiness'][0]['status']='untested'; check(r,1,*advance,contains='untested')
r=copy.deepcopy(base); r['readiness'][0]['status']='fail'; check(r,1,*advance,contains='fail')
r=copy.deepcopy(base); r['progress']['pending_action']=dict(id='expand-1',operation='advance',target='all-local',status='ambiguous'); check(r,1,*advance,contains='reconcile')
r['progress']['pending_action']['status']='planned'; check(r,0,*advance)
r['progress']['pending_action']['id']='other'; check(r,1,*advance)
r=copy.deepcopy(base); r['progress']['completed_actions']=[dict(id='expand-1',operation='advance',target='all-local',status='verified',evidence='external state read')]
assert check(r,0,*advance)['assessment']=='already-observed'
r['progress']['pending_action']=dict(id='expand-1',operation='advance',target='all-local',status='ambiguous')
check(r,1,*advance,contains='reconcile')
r['progress']['pending_action']=None
r['progress']['completed_actions'][0]['target']='different'; check(r,1,*advance)
# Resource conflicts block, independent resources remain concurrent.
peer=copy.deepcopy(base); peer['identity']['task']='other'; peer['candidate']['artifact']='other-build'
peer['progress']['pending_action']=dict(id='other',status='planned')
f=temp/'peer.md'; f.write_text(body(peer)); check(base,1,*advance,'--peer',str(f),contains='reserved')
peer['target']['resources']=['loopback/independent']; f.write_text(body(peer)); check(base,0,*advance,'--peer',str(f))
peer['candidate']['artifact']=base['candidate']['artifact']; f.write_text(body(peer)); check(base,1,*advance,'--peer',str(f),contains='duplicate release')
for field in ('configuration','source','dependencies','artifact'):
    independent=copy.deepcopy(peer); independent['candidate'][field]='distinct-material-value'
    f.write_text(body(independent)); check(base,0,*advance,'--peer',str(f))
    independent['target']['resources']=base['target']['resources']
    f.write_text(body(independent)); check(base,1,*advance,'--peer',str(f),contains='reserved')
for group,field,value in [('identity','project','other-project'),('target','environment','other-environment')]:
    independent=copy.deepcopy(peer); independent[group][field]=value
    f.write_text(body(independent)); check(base,0,*advance,'--peer',str(f))
for group,field,value in [('progress','phase','Stopped'),('progress','observation',None),
                         ('health','baseline','different-plan'),('candidate','extra_note','not-material')]:
    duplicate=copy.deepcopy(peer); duplicate[group][field]=value
    duplicate['progress']['pending_action']=None
    f.write_text(body(duplicate)); check(base,1,*advance,'--peer',str(f),contains='duplicate release')
for final_in_deploy in (False,True):
    combined=copy.deepcopy(base)
    if final_in_deploy: combined['stages']=combined['stages'][:1]
    combined['authority'].append(dict(base_binding,operation='deploy',target='internal',
                                     instruction='combined deployment to internal cohort',expires_at=1600))
    combined_binding=stamp(cli,combined)
    combined['progress'].update(phase='Ready',stage='initial',deployment=None,exposure_attempt=None,
                                observation=None,completed_actions=[])
    deploy=('--operation','deploy','--target','internal','--operation-id','combined-1')
    check(combined,0,*deploy)
    denied=copy.deepcopy(combined); denied['authority']=denied['authority'][:-1]
    check(denied,1,*deploy,contains='authority')
    denied=copy.deepcopy(combined); denied['authority'][-1]['expires_at']=999
    check(denied,1,*deploy,contains='authority')
    denied=copy.deepcopy(combined); denied['authority'][-1]['target']='disabled'
    check(denied,1,*deploy,contains='authority')
    check(combined,1,'--operation','expose','--target','internal','--operation-id','expose-1',contains='mapping')
    combined['progress'].update(phase='Observing',
        deployment=dict(combined_binding,artifact=combined['candidate']['artifact'],evidence='verified combined deployment'),
        exposure_attempt=dict(id='combined-1',target='internal',started_at=995),
        completed_actions=[dict(id='combined-1',operation='deploy',target='internal',status='verified',effect_at=995,evidence='observed combined effect')],
        observation=dict(base['progress']['observation'],**combined_binding))
    combined['progress']['observation'].update(exposure_attempt='combined-1',effect='combined-1')
    assert check(combined)['health']=='healthy'
    assert check(combined,0,*deploy)['assessment']=='already-observed'
    if final_in_deploy:
        combined['progress']['phase']='Released'
        combined['outcome'].update(combined_binding,disposition='released',exposure='internal',health='healthy',
                                  evidence='final combined state',effect='combined-1',observed_at=999,watches_retired=True)
        operation=('--operation','complete')
    else:
        combined['progress']['phase']='Expansion ready'
        operation=advance
    check(combined,0,*operation)
    saved.write_text(body(combined)); check(saved.read_text(),0,*operation)
    for key,value,verdict in [('samples',0,'insufficient'),('ended_at',995.5,'insufficient'),
                             ('started_at',994,'unknown'),('exposure_attempt','earlier','unknown'),
                             ('effect','earlier','unknown'),('environment','elsewhere','unknown')]:
        bad=copy.deepcopy(combined); bad['progress']['observation'][key]=value
        assert check(bad,1,*operation)['health']==verdict
    bad=copy.deepcopy(combined)
    bad['progress']['exposure_attempt']['started_at']=100
    bad['progress']['completed_actions'][0]['effect_at']=100
    bad['progress']['observation'].update(started_at=100,ended_at=200,observed_at=1000)
    assert check(bad,1,*operation)['health']=='unknown'
    for field,value in [('deployment',None),('exposure_attempt',None),
                        ('pending_action',dict(id='combined-1',operation='deploy',target='internal',status='ambiguous'))]:
        bad=copy.deepcopy(combined); bad['progress'][field]=value
        check(bad,1,*operation)
    bad=copy.deepcopy(combined); bad['progress']['deployment']['artifact']='wrong-build'
    check(bad,1,*operation,contains='mapping')
    bad=copy.deepcopy(combined); bad['progress']['completed_actions'][0]['target']='disabled'
    check(bad,1,*operation)
    withdrawn=copy.deepcopy(combined)
    withdrawn['progress'].update(phase='Stopped',observation=None)
    withdrawn['progress']['completed_actions'].append(dict(id='combined-contain',operation='contain',target='none',status='verified',effect_at=999,evidence='safe state'))
    withdrawn['outcome'].update(combined_binding,disposition='withdrawn',exposure='none',health='safe',recovery='contained',
                               evidence='verified withdrawal',effect='combined-contain',observed_at=999,watches_retired=True)
    check(withdrawn,0,'--operation','complete')
    withdrawn['progress']['exposure_attempt'].update(id='combined-2',started_at=1000)
    withdrawn['progress']['completed_actions'].append(dict(id='combined-2',operation='deploy',target='internal',status='verified',effect_at=1000,evidence='new combined deployment'))
    check(withdrawn,1,'--operation','complete',contains='latest external effect')
    withdrawn['outcome']['effect']='combined-2'
    check(withdrawn,1,'--operation','complete',contains='predates')
r=copy.deepcopy(base); r['progress'].update(phase='Ready',deployment=None,exposure_attempt=None,observation=None,completed_actions=[])
r['authority'].append(dict(base_binding,operation='deploy',target='all-local',instruction='deployment',expires_at=1600))
check(r,1,'--operation','deploy','--target','all-local','--operation-id','skip-stage',contains='initial cohort')
r['progress'].update(phase='Deployed, unexposed',deployment=copy.deepcopy(base['progress']['deployment']),
                     completed_actions=[dict(id='unexposed',operation='deploy',target='disabled',status='verified',effect_at=995,evidence='unexposed state')])
assert check(r)['health']=='unknown'
check(r,0,'--operation','expose','--target','internal','--operation-id','expose-after-deploy')
# The previously accepted manual alternative can satisfy usage, never time.
r=copy.deepcopy(base); r['progress']['observation']['samples']=0
r['stages'][0]['manual_alternative']=dict(instruction='accepted before exposure', scenarios='two named interactions')
r['progress']['observation']['manual']=dict(r['stages'][0]['manual_alternative'],evidence='interaction-log')
stamp(cli,r)
check(r,0,*advance)
manual=copy.deepcopy(r)
r['progress']['observation'].update(started_at=999,ended_at=999.5,observed_at=1000)
assert check(r,1,*advance)['health']=='insufficient'
r['progress']['observation'].update(started_at=100,ended_at=200,observed_at=1000)
r['progress']['exposure_attempt']['started_at']=100
r['progress']['completed_actions'][0]['effect_at']=100
assert check(r,1,*advance)['health']=='unknown'
r=manual
r['progress']['observation']['manual']['instruction']='new silent waiver'; check(r,1,*advance)
# Distinct accurate terminal outcomes and failures.
for disposition in ('released','cancelled','withdrawn'):
    r=copy.deepcopy(base); r['progress'].update(phase='Released' if disposition=='released' else 'Stopped',stage='final')
    r['progress']['exposure_attempt'].update(id='final-1',target='all-local')
    r['progress']['completed_actions'][0].update(id='final-1',operation='advance',target='all-local')
    r['progress']['observation']['exposure_attempt']='final-1'
    r['progress']['observation']['effect']='final-1'
    r['progress']['observation']['exposure']='all-local'
    r['outcome'].update(disposition=disposition, exposure='all-local' if disposition=='released' else 'none',
                        health='healthy' if disposition=='released' else 'safe', evidence='final state', watches_retired=True,
                        observed_at=999, effect='final-1', **base_binding)
    if disposition!='released':
        r['progress']['observation']=None
        r['outcome']['recovery']='contained' if disposition=='withdrawn' else 'not-needed'
    if disposition=='cancelled':
        r['progress'].update(stage='',deployment=None,exposure_attempt=None,completed_actions=[])
        r['outcome']['effect']=None
    if disposition=='withdrawn':
        r['progress']['completed_actions'].append(dict(id='contain-1',operation='contain',target='none',status='verified',evidence='disabled state',effect_at=998))
        r['outcome']['effect']='contain-1'
    check(r,0,'--operation','complete')
    for key,value in [('watches_retired',False),('recovery','failed'),('unresolved_calls',['captain-call']),
                      ('evidence',''),('health','unknown'),('observed_at',900),('observed_at',1001),
                      ('observed_at',None),('observed_at',True),('observed_at','999'),('observed_at',0)]:
        bad=copy.deepcopy(r); bad['outcome'][key]=value; check(bad,1,'--operation','complete')
    for group,key in [('candidate','artifact'),('candidate','source'),('candidate','configuration'),
                      ('candidate','dependencies'),('target','environment'),('health','baseline')]:
        bad=copy.deepcopy(r); bad[group][key]='changed'
        check(bad,1,'--operation','complete',contains='evidence binding')
    for key in (*base_binding,'observed_at','effect'):
        bad=copy.deepcopy(r); del bad['outcome'][key]
        check(bad)
        check(bad,1,'--operation','complete')
    if disposition=='released':
        bad=copy.deepcopy(r); bad['progress']['observation'].update(started_at=100,ended_at=200,observed_at=1000)
        bad['progress']['exposure_attempt']['started_at']=100
        bad['progress']['completed_actions'][0]['effect_at']=100
        assert check(bad,1,'--operation','complete')['health']=='unknown'
        bad=copy.deepcopy(r); bad['progress']['exposure_attempt'].update(id='final-2',started_at=999)
        bad['progress']['completed_actions'].append(dict(id='final-2',operation='advance',target='all-local',status='verified',evidence='new final exposure',effect_at=999))
        assert check(bad,1,'--operation','complete')['health']=='unknown'
        bad['progress']['observation']['exposure_attempt']='final-2'
        bad['progress']['observation']['effect']='final-2'
        assert check(bad,1,'--operation','complete')['health']=='unknown'
    if disposition=='withdrawn':
        current_withdrawal=copy.deepcopy(r)
    for pending_status in ('planned','ambiguous'):
        bad=copy.deepcopy(r); bad['progress']['pending_action']=dict(id='new-effect',operation='contain',target='none',status=pending_status)
        check(bad,1,'--operation','complete')
r=copy.deepcopy(current_withdrawal)
r['outcome']['observed_at']=1000
check(r,0,'--operation','complete',now=1011)
r['progress']['exposure_attempt'].update(id='expose-new',target='internal',started_at=1010)
r['progress']['completed_actions'].append(dict(id='expose-new',operation='expose',target='internal',status='verified',evidence='new exposure',effect_at=1010))
check(r,1,'--operation','complete',now=1011,contains='latest external effect')
r['outcome']['observed_at']=1011
check(r,1,'--operation','complete',now=1011,contains='latest external effect')
r['outcome'].update(effect='expose-new',observed_at=1000)
check(r,1,'--operation','complete',now=1011,contains='predates')
r['progress']['completed_actions'].append(dict(id='contain-new',operation='contain',target='none',status='verified',evidence='current safe state',effect_at=1011))
r['outcome'].update(effect='contain-new',observed_at=1011)
check(r,0,'--operation','complete',now=1011)
saved.write_text(body(r)); check(saved.read_text(),0,'--operation','complete',now=1012)
r['progress']['completed_actions'].append(dict(id='restore-new',operation='restore',target='retained-data',status='verified',evidence='repair verified',effect_at=1012))
check(r,1,'--operation','complete',now=1012,contains='latest external effect')
for consumer in ('health','terminal'):
    original=base if consumer=='health' else current_withdrawal
    args=advance if consumer=='health' else ('--operation','complete')
    for field,value in [('effect_at',None),('effect_at',True),('effect_at','998'),('effect_at',1001),
                        ('status','ambiguous'),('evidence',''),('id','')]:
        bad=copy.deepcopy(original); bad['progress']['completed_actions'][-1][field]=value
        check(bad,1,*args)
    bad=copy.deepcopy(original); del bad['progress']['completed_actions'][-1]['effect_at']
    check(bad); check(bad,1,*args)
    bad=copy.deepcopy(original); bad['progress']['completed_actions'].append(copy.deepcopy(bad['progress']['completed_actions'][-1]))
    check(bad,1,*args)
    bad=copy.deepcopy(original)
    bad['progress']['completed_actions'].append(dict(id='earlier',operation='restore',target='retained-data',status='verified',evidence='state',effect_at=990))
    check(bad,1,*args,contains='unordered')
r=copy.deepcopy(base)
r['progress']['completed_actions'].append(dict(id='contain-latest',operation='contain',target='none',status='verified',evidence='containment',effect_at=999.5))
assert check(r,1,*advance)['health']=='unknown'
r=copy.deepcopy(base)
r['progress']['completed_actions'].append(dict(id='repair-latest',operation='restore',target='retained-data',status='verified',evidence='repair',effect_at=998))
assert check(r,1,*advance)['health']=='unknown'
r['progress']['observation'].update(effect='repair-latest')
assert check(r,1,*advance)['health']=='unknown'
r['progress']['observation'].update(started_at=998,ended_at=999,observed_at=999)
check(r,0,*advance)
r=copy.deepcopy(base); r['progress'].update(phase='Stopped',deployment=None,observation=None,exposure_attempt=None,completed_actions=[])
r['outcome'].update(base_binding,disposition='cancelled',exposure='none',health='safe',recovery='not-needed',effect=None,observed_at=999,evidence='environment inspected, no effects',watches_retired=True)
check(r,0,'--operation','complete')
for value in ('', 'old-effect'):
    bad=copy.deepcopy(r); bad['outcome']['effect']=value; check(bad,1,'--operation','complete')
bad=copy.deepcopy(r); bad['progress']['completed_actions']=copy.deepcopy(base['progress']['completed_actions'])
check(bad,1,'--operation','complete')
r['progress']['deployment']=copy.deepcopy(base['progress']['deployment'])
check(r,1,'--operation','complete')
r['progress']['completed_actions']=[dict(id='deploy-only',operation='deploy',target='disabled',status='verified',evidence='disabled deployment',effect_at=998)]
r['outcome']['effect']='deploy-only'
check(r,0,'--operation','complete')
r=copy.deepcopy(base); r['progress']['phase']='Recovering'; r['outcome']['disposition']='failed-recovery'; check(r,1,'--operation','complete')
private=copy.deepcopy(base)
private['identity']['home']='PRIVATE_SENTINEL'; private['readiness'][0]['evidence']='PRIVATE_SENTINEL'
p=temp/'private.md'; p.write_text(body(private))
summary=subprocess.check_output([str(cli),'summary',str(p),'--now','1000'],text=True)
assert 'PRIVATE_SENTINEL' not in summary and 'readiness' in summary
count+=1
print('PASS release body interface: %d observable checks; no mutations' % count)
PY
