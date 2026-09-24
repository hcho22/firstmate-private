"""Synthetic task bodies consumed through the public release interface."""
import json
import subprocess
import tempfile
from pathlib import Path


def record(cli, now=1000):
    body = subprocess.check_output([str(cli), 'template', 'local-release'], text=True)
    r = json.loads(body.split('```firstmate-release\n')[1].split('\n```')[0])
    r['identity'].update(project='synthetic', home='local-pilot', actor='local-pilot-owner')
    r['implementations'] = [{'home': 'local-pilot', 'id': 'implementation', 'revision': 'source-v1'},
                            {'home': 'local-pilot', 'id': 'second-implementation', 'revision': 'source-v1'}]
    r['candidate'].update(source='source-v1', artifact='local-build-v1', configuration='gated-v1', dependencies='python-stdlib')
    r['target'].update(environment='loopback', resources=['loopback/gate'])
    b = dict(candidate='local-build-v1', configuration='gated-v1', environment='loopback', source='source-v1', dependencies='python-stdlib')
    for row in r['readiness']:
        row.update(b, expected='observable criterion', observed='criterion met in isolated pilot', status='pass',
                   evidence='synthetic-log', limitation='local only', observed_at=now-10)
    r['stages'] = [dict(name='initial', target='internal', window_seconds=1, min_samples=2),
                   dict(name='final', target='all-local', window_seconds=1, min_samples=2)]
    r['health'].update(sources=['loopback-http'], baseline='no errors', max_age_seconds=60, stop_condition='any error or leaked write')
    r['recovery'].update(actor='local-pilot-owner', containment='disable gate', restoration='no deletion; retain writes for investigation',
                         limitations='disable preserves existing data', verification='new requests produce zero writes')
    r['authority'] = [dict(b, operation=op, target=target, instruction='accepted disposable local pilot', expires_at=now+600)
                      for op, target in [('deploy', 'disabled'), ('expose', 'internal'), ('advance', 'all-local'),
                                         ('contain', 'none'), ('restore', 'retained-data')]]
    r['progress'].update(phase='Expansion ready', stage='initial',
                         exposure_attempt=dict(id='expose-1',target='internal',started_at=now-5),
                         deployment=dict(b, artifact='local-build-v1', evidence='observed HTTP deployment'),
                         observation=dict(b, id='observation-1', exposure_attempt='expose-1', signal_source='loopback-http', started_at=now-5,
                                          ended_at=now-1, observed_at=now-1, samples=2, health='healthy',
                                          stop=False, exposure='internal', evidence='observed HTTP response'))
    r['outcome']['recovery'] = 'not-needed'
    stamp(cli, r)
    return r


def body(r):
    return 'Preserved ordinary task notes.\n\n## Release readiness\n\n```firstmate-release\n' + json.dumps(r, indent=2) + '\n```\n'


def stamp(cli, r):
    # Only for freshly assessed synthetic fixtures, never to refresh old proof.
    with tempfile.TemporaryDirectory() as tmp:
        p=Path(tmp)/'body.md'; p.write_text(body(r))
        b=json.loads(subprocess.check_output([str(cli),'fingerprint',str(p)],text=True))
    for row in r['readiness']+r['authority']:
        row.update(b)
    for key in ('deployment','observation'):
        if r['progress'].get(key): r['progress'][key].update(b)
    return b
