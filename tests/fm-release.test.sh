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
count = 0

def check(r, status=0, *args, contains=None):
    global count
    file = temp/'task.md'; file.write_text(body(r) if isinstance(r, dict) else r)
    before = file.read_bytes()
    p = subprocess.run([str(cli), 'check', str(file), '--now', '1000', *args], text=True, capture_output=True)
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
r['progress']['observation']['manual']['instruction']='new silent waiver'; check(r,1,*advance)
# Distinct accurate terminal outcomes and failures.
for disposition in ('released','cancelled','withdrawn'):
    r=copy.deepcopy(base); r['progress'].update(phase='Released' if disposition=='released' else 'Stopped',stage='final')
    r['progress']['observation']['exposure']='all-local'
    r['outcome'].update(disposition=disposition, exposure='all-local' if disposition=='released' else 'none',
                        health='healthy' if disposition=='released' else 'safe', evidence='final state', watches_retired=True)
    check(r,0,'--operation','complete')
    for key,value in [('watches_retired',False),('recovery','failed'),('unresolved_calls',['captain-call'])]:
        bad=copy.deepcopy(r); bad['outcome'][key]=value; check(bad,1,'--operation','complete')
r=copy.deepcopy(base); r['progress']['phase']='Recovering'; r['outcome']['disposition']='failed-recovery'; check(r,1,'--operation','complete')
private=copy.deepcopy(base)
private['identity']['home']='PRIVATE_SENTINEL'; private['readiness'][0]['evidence']='PRIVATE_SENTINEL'
p=temp/'private.md'; p.write_text(body(private))
summary=subprocess.check_output([str(cli),'summary',str(p),'--now','1000'],text=True)
assert 'PRIVATE_SENTINEL' not in summary and 'readiness' in summary
count+=1
print('PASS release body interface: %d observable checks; no mutations' % count)
PY
