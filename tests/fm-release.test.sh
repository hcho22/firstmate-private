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
    r['progress']['observation'].update(started_at=100,ended_at=ended_at,observed_at=1000)
    result=check(r,status,*advance)
    assert result['health']==('unknown' if status else 'healthy'),result
    assert check(r)['health']==result['health']
r=record(cli,156); r['stages'][0]['window_seconds']=40
r['progress']['exposure_attempt'].update(started_at=100)
r['progress']['observation'].update(started_at=100,ended_at=140,observed_at=140)
stamp(cli,r)
check(r,0,*advance,now=156)
r['progress']['exposure_attempt'].update(id='expose-2',started_at=155)
assert check(r,1,*advance,now=156)['health']=='unknown'
assert check(r,now=156)['health']=='unknown'
r['progress']['observation']['exposure_attempt']='expose-2'
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
for group,key in [('progress','exposure_attempt'),('observation','exposure_attempt')]:
    r=copy.deepcopy(base)
    del (r['progress'] if group=='progress' else r['progress']['observation'])[key]
    assert check(r)['health']=='unknown'
    check(r,1,*advance)
r=copy.deepcopy(base); r['progress'].update(phase='Ready',exposure_attempt=None,observation=None)
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
r['progress']['completed_actions'][0]['target']='different'; check(r,1,*advance)
# Resource conflicts block, independent resources remain concurrent.
peer=copy.deepcopy(base); peer['identity']['task']='other'; peer['candidate']['artifact']='other-build'
peer['progress']['pending_action']=dict(id='other',status='planned')
f=temp/'peer.md'; f.write_text(body(peer)); check(base,1,*advance,'--peer',str(f),contains='reserved')
peer['target']['resources']=['loopback/independent']; f.write_text(body(peer)); check(base,0,*advance,'--peer',str(f))
peer['candidate']['artifact']=base['candidate']['artifact']; f.write_text(body(peer)); check(base,1,*advance,'--peer',str(f),contains='duplicate release')
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
assert check(r,1,*advance)['health']=='unknown'
r=manual
r['progress']['observation']['manual']['instruction']='new silent waiver'; check(r,1,*advance)
# Distinct accurate terminal outcomes and failures.
for disposition in ('released','cancelled','withdrawn'):
    r=copy.deepcopy(base); r['progress'].update(phase='Released' if disposition=='released' else 'Stopped',stage='final')
    r['progress']['exposure_attempt'].update(id='final-1',target='all-local')
    r['progress']['observation']['exposure_attempt']='final-1'
    r['progress']['observation']['exposure']='all-local'
    r['outcome'].update(disposition=disposition, exposure='all-local' if disposition=='released' else 'none',
                        health='healthy' if disposition=='released' else 'safe', evidence='final state', watches_retired=True,
                        observed_at=999, **base_binding)
    if disposition!='released':
        r['progress']['observation']=None
        r['outcome']['recovery']='contained' if disposition=='withdrawn' else 'not-needed'
    if disposition=='cancelled': r['progress'].update(stage='',deployment=None,exposure_attempt=None)
    check(r,0,'--operation','complete')
    for key,value in [('watches_retired',False),('recovery','failed'),('unresolved_calls',['captain-call']),
                      ('evidence',''),('health','unknown'),('observed_at',900),('observed_at',1001),
                      ('observed_at',None),('observed_at',True),('observed_at','999'),('observed_at',0)]:
        bad=copy.deepcopy(r); bad['outcome'][key]=value; check(bad,1,'--operation','complete')
    for group,key in [('candidate','artifact'),('candidate','source'),('candidate','configuration'),
                      ('candidate','dependencies'),('target','environment'),('health','baseline')]:
        bad=copy.deepcopy(r); bad[group][key]='changed'
        check(bad,1,'--operation','complete',contains='outcome binding')
    for key in (*base_binding,'observed_at'):
        bad=copy.deepcopy(r); del bad['outcome'][key]
        check(bad)
        check(bad,1,'--operation','complete')
    if disposition=='released':
        bad=copy.deepcopy(r); bad['progress']['observation'].update(started_at=100,ended_at=200,observed_at=1000)
        bad['progress']['exposure_attempt']['started_at']=100
        assert check(bad,1,'--operation','complete')['health']=='unknown'
        bad=copy.deepcopy(r); bad['progress']['exposure_attempt'].update(id='final-2',started_at=999)
        assert check(bad,1,'--operation','complete')['health']=='unknown'
        bad['progress']['observation']['exposure_attempt']='final-2'
        assert check(bad,1,'--operation','complete')['health']=='unknown'
r=copy.deepcopy(base); r['progress']['phase']='Recovering'; r['outcome']['disposition']='failed-recovery'; check(r,1,'--operation','complete')
private=copy.deepcopy(base)
private['identity']['home']='PRIVATE_SENTINEL'; private['readiness'][0]['evidence']='PRIVATE_SENTINEL'
p=temp/'private.md'; p.write_text(body(private))
summary=subprocess.check_output([str(cli),'summary',str(p),'--now','1000'],text=True)
assert 'PRIVATE_SENTINEL' not in summary and 'readiness' in summary
count+=1
print('PASS release body interface: %d observable checks; no mutations' % count)
PY
