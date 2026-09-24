#!/usr/bin/env python3
"""Read-only release task section interface. Policy: risk-recovery/SKILL.md.

Schema 1 uses JSON inside exactly one firstmate-release fence in an ordinary
backlog task body. No external paths or URLs in the record are opened here.
Identity owns task/project/home/actor; implementations is a many-to-many list of
home/id/revision links. Candidate owns source/artifact/configuration/dependencies.
Target owns environment/resources. Readiness rows use category, requirement,
expected, observed, status, evidence, limitation and a binding (candidate,
configuration, environment, source, dependencies, plan), with observed_at.
The fingerprint command computes the plan digest from candidate, target, stages,
health and recovery. Bind evidence and scoped authority to that exact digest
after assessment, never refresh old evidence by merely copying a new digest. An exception additionally has
criterion/consequence/instruction and the same binding. Six readiness categories
are functional, security/privacy, performance, UX, monitoring and recovery.
Stages name exact target plus window_seconds and min_samples. Health declares
sources, baseline, max_age_seconds and stop_condition. Recovery declares actor,
containment, restoration, limitations and verification. Authority entries bind
operation/target/instruction/expires_at to the same binding; never credentials.
Progress holds phase/stage, deployment, exposure_attempt, observation, pending_action,
completed_actions and last_notified_condition. Deployment includes source,
artifact, binding and evidence. Exposure_attempt is null until exposure is
verified, then contains id (the exposing action identity), target, and
started_at (the verified external exposure start, epoch seconds). Each exposure
or advancement starts a new attempt; restart preserves a reconciled attempt.
Observation includes binding, id, signal_source, exposure_attempt (the attempt id),
effect (latest completed action id),
started_at/ended_at/observed_at epoch seconds, samples, health, stop, exposure and
evidence. Freshness is measured from ended_at, not the reporting time observed_at.
Its measurement window must start at or after the current attempt's started_at;
missing or mismatched attempt evidence is unknown, including in older records.
Optional accepted manual alternative: stage.manual_alternative names
instruction/scenarios; observation.manual has instruction/scenarios/evidence.
Pending/completed actions hold id/operation/target/status/evidence. Pending is
null or planned/ambiguous; only verified actions belong in completed_actions.
Completed actions are in external-effect order and additionally hold effect_at,
the verified external effect time (epoch seconds), not request acknowledgement.
An expose/advance action, or a deploy explicitly targeting a planned cohort,
establishes exposure; a combined deploy must target the initial cohort and have
verified deployment mapping. Its effect_at equals exposure_attempt.started_at.
An unexposed deploy uses a target distinct from every planned cohort.
Retain the most recent
exposure_attempt through containment and restoration; do not clear action history.
Watches lists registered owner references. Outcome includes disposition,
exposure, evidence, health, recovery, watches_retired and unresolved_calls, plus
the same binding, effect (latest completed action id), and observed_at (epoch time
of actual final-state verification, not reporting time). An explicit null effect
records positively verified absence of external effects, requiring empty action
history, null deployment and null exposure_attempt; empty/missing is unassessed.
Health and terminal evidence share applicability checks: current material binding,
latest reconciled effect identity, no ambiguous effect, and measurement/verification
at or after that effect, fresh within max_age_seconds. Cancellation before exposure
needs safe-state evidence but no stage observation; deployed-unexposed cancellation
references the deployment effect. Planned actions do not establish an effect.
Older outcomes remain readable but require verification before completion.

The checker checks recorded consistency only. It cannot prove source truth,
completeness of peer inventory, instruction provenance, or task/lease ownership.
"""
import argparse
import hashlib
import json
import math
import sys
import time
from pathlib import Path

PHASES = {"Preparing", "Ready", "Deployed, unexposed", "Observing",
          "Expansion ready", "Paused", "Recovering", "Released", "Stopped"}
CATEGORIES = {"functional", "security/privacy", "performance", "UX", "monitoring", "recovery"}
OPERATIONS = {"deploy", "expose", "advance", "contain", "restore", "complete"}


def template(task):
    binding = {"candidate": "", "configuration": "", "environment": "", "source": "", "dependencies": "", "plan": ""}
    return {
        "schema": 1,
        "identity": {"task": task, "project": "", "home": "", "actor": ""},
        "implementations": [],
        "candidate": {"source": "", "artifact": "", "configuration": "", "dependencies": ""},
        "target": {"environment": "", "resources": []},
        "readiness": [dict(category=c, requirement=c, expected="", observed="",
                           status="untested", evidence="", limitation="unassessed",
                           observed_at=0, **binding) for c in sorted(CATEGORIES)],
        "stages": [],
        "health": {"sources": [], "baseline": "", "max_age_seconds": 0, "stop_condition": ""},
        "recovery": {"actor": "", "containment": "", "restoration": "", "limitations": "", "verification": ""},
        "authority": [],
        "progress": {"phase": "Preparing", "stage": "", "deployment": None,
                     "exposure_attempt": None, "observation": None, "pending_action": None,
                     "completed_actions": [], "last_notified_condition": ""},
        "watches": [],
        "outcome": {"disposition": "pending", "exposure": "", "evidence": "",
                    "health": "unknown", "recovery": "unresolved", "watches_retired": False,
                    "unresolved_calls": [], "observed_at": 0, "effect": "", **binding},
    }


def read_body(path):
    lines = Path(path).read_text().splitlines()
    blocks, body, active = [], [], False
    fence = None
    for line in lines:
        text = line.strip()
        if active:
            if text == '```':
                blocks.append('\n'.join(body)); active = False; body = []
            else:
                body.append(line)
        elif fence:
            if text.startswith(fence[0] * fence[1]) and not text.lstrip(fence[0]):
                fence = None
        elif text == '```firstmate-release':
            active = True
        elif text.startswith(('```', '~~~')):
            marker = text[0]
            fence = (marker, len(text) - len(text.lstrip(marker)))
    if active or len(blocks) > 1:
        raise ValueError('expected one closed firstmate-release fence')
    if not blocks:
        return None
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValueError('duplicate JSON key: ' + key)
            obj[key] = value
        return obj
    return json.loads(blocks[0], object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('non-finite JSON number')))


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def shape(r):
    if not isinstance(r, dict) or type(r.get('schema')) is not int or r['schema'] != 1:
        raise ValueError('unsupported release schema')
    groups = {'identity': ('task', 'project', 'home', 'actor'),
              'candidate': ('source', 'artifact', 'configuration', 'dependencies'),
              'target': ('environment',), 'health': ('baseline', 'stop_condition'),
              'recovery': ('actor', 'containment', 'restoration', 'limitations', 'verification'),
              'progress': ('phase', 'stage', 'last_notified_condition'),
              'outcome': ('disposition', 'exposure', 'evidence', 'health', 'recovery')}
    for group, fields in groups.items():
        if not isinstance(r.get(group), dict):
            raise ValueError('missing object: ' + group)
        for key in fields:
            if not isinstance(r[group].get(key), str):
                raise ValueError('expected string: ' + group + '.' + key)
    for value, name in ((r.get('implementations'), 'implementations'),
                        (r.get('readiness'), 'readiness'), (r.get('stages'), 'stages'),
                        (r.get('authority'), 'authority'), (r.get('watches'), 'watches'),
                        (r['target'].get('resources'), 'resources'),
                        (r['health'].get('sources'), 'sources'),
                        (r['progress'].get('completed_actions'), 'completed_actions'),
                        (r['outcome'].get('unresolved_calls'), 'unresolved_calls')):
        if not isinstance(value, list):
            raise ValueError('expected list: ' + name)
    for key in ('deployment', 'observation', 'pending_action'):
        if key not in r['progress'] or (r['progress'][key] is not None and not isinstance(r['progress'][key], dict)):
            raise ValueError('expected object or null: ' + key)
    for key in ('implementations', 'readiness', 'stages', 'authority'):
        if not all(isinstance(x, dict) for x in r[key]):
            raise ValueError('expected object entries: ' + key)
    if not all(isinstance(x, dict) for x in r['progress']['completed_actions']):
        raise ValueError('expected object entries: completed_actions')
    for name, value in [('resources', r['target']['resources']), ('sources', r['health']['sources']),
                        ('watches', r['watches']), ('unresolved_calls', r['outcome']['unresolved_calls'])]:
        if not all(nonempty(x) for x in value) or len(value) != len(set(value)):
            raise ValueError('expected unique nonempty strings: ' + name)
    if r['progress']['phase'] not in PHASES:
        raise ValueError('unknown phase')
    if type(r['outcome'].get('watches_retired')) is not bool:
        raise ValueError('expected boolean: watches_retired')


def plan_fingerprint(r):
    material = {key: r[key] for key in ('candidate', 'target', 'stages', 'health', 'recovery')}
    return hashlib.sha256(json.dumps(material, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def candidate_identity(r):
    return {'candidate': r['candidate']['artifact'], 'configuration': r['candidate']['configuration'],
            'source': r['candidate']['source'], 'dependencies': r['candidate']['dependencies']}


def binding(r):
    return dict(candidate_identity(r), environment=r['target']['environment'], plan=plan_fingerprint(r))


def bound(row, r):
    return all(nonempty(v) and row.get(k) == v for k, v in binding(r).items())


def exposes(r, operation, target):
    return operation in ('expose', 'advance') or (
        operation == 'deploy' and any(target == s.get('target') for s in r['stages']))


def deployment_verified(r):
    d = r['progress']['deployment']
    return (isinstance(d, dict) and bound(d, r) and d.get('source') == r['candidate']['source']
            and d.get('artifact') == r['candidate']['artifact'] and nonempty(d.get('evidence')))


def evidence_applicability(row, r, now, start, end):
    errors = []
    if not bound(row, r):
        errors.append('evidence binding missing or mismatched')
    if not nonempty(row.get('evidence')):
        errors.append('evidence reference missing')
    observed = row.get('observed_at')
    age = r['health'].get('max_age_seconds')
    if (not all(number(t) for t in (start, end, observed, age)) or
            not 0 <= start <= end <= observed <= now or observed <= 0 or
            age <= 0 or now - end > age):
        errors.append('evidence times stale, future, unordered, or missing')
    pending = r['progress']['pending_action']
    if pending and pending.get('status') != 'planned':
        errors.append('unreconciled effect: reconcile actual external state before continuation')
    effects = r['progress']['completed_actions']
    effect_id = row.get('effect', '')
    if any(not nonempty(a.get('id')) or a.get('operation') not in ('deploy', 'expose', 'advance', 'contain', 'restore') or
           not nonempty(a.get('target')) or a.get('status') != 'verified' or
           not nonempty(a.get('evidence')) or not number(a.get('effect_at')) or
           not 0 <= a['effect_at'] <= now for a in effects):
        return errors + ['external effect history missing verified identity/time']
    if (len({a['id'] for a in effects}) != len(effects) or
            any(a['effect_at'] > b['effect_at'] for a, b in zip(effects, effects[1:]))):
        return errors + ['external effect history duplicated or unordered']
    exposure = next((a for a in reversed(effects) if exposes(r, a['operation'], a['target'])), None)
    attempt = r['progress'].get('exposure_attempt')
    if exposure:
        if not deployment_verified(r):
            errors.append('actual deployed artifact/source mapping unverified')
        if exposure['operation'] == 'deploy' and exposure['target'] != r['stages'][0].get('target'):
            errors.append('combined deployment must target initial cohort')
        if (not isinstance(attempt, dict) or attempt.get('id') != exposure['id'] or
                attempt.get('target') != exposure['target'] or
                not number(attempt.get('started_at')) or attempt['started_at'] != exposure['effect_at']):
            errors.append('exposure attempt does not match reconciled effect history')
    elif 'exposure_attempt' not in r['progress'] or attempt is not None:
        errors.append('absence of exposure not established by effect history')
    if effects:
        latest = effects[-1]
        if effect_id != latest['id']:
            errors.append('evidence does not reference latest external effect')
        if not number(start) or start < latest['effect_at']:
            errors.append('evidence predates latest external effect')
    elif effect_id is not None or r['progress']['deployment'] is not None:
        errors.append('absence of external effects not verified')
    return errors


def health(r, now):
    o = r['progress']['observation']
    stages = [s for s in r['stages'] if s.get('name') == r['progress']['stage']]
    if not isinstance(o, dict) or len(stages) != 1:
        return 'unknown', ['observation or unique current stage missing']
    s, h = stages[0], r['health']
    attempt = r['progress'].get('exposure_attempt')
    errors = evidence_applicability(o, r, now, o.get('started_at'), o.get('ended_at'))
    if (not isinstance(attempt, dict) or not nonempty(attempt.get('id')) or
            attempt.get('target') != s.get('target') or
            o.get('exposure_attempt') != attempt['id']):
        errors.append('current exposure attempt missing, malformed, or mismatched')
    if o.get('signal_source') not in h['sources']:
        errors.append('observation source mismatch')
    if not nonempty(o.get('id')) or o.get('exposure') != s.get('target'):
        errors.append('observation identity/exposure missing or mismatched')
    if not number(o.get('samples')) or o['samples'] < 0:
        errors.append('invalid observation samples')
    for key, value in [('window_seconds', s.get('window_seconds')), ('min_samples', s.get('min_samples'))]:
        if not number(value) or value <= 0:
            errors.append('invalid health criterion ' + key)
    if errors:
        return 'unknown', errors
    if type(o.get('stop')) is not bool or o.get('health') not in ('healthy', 'unhealthy', 'unknown'):
        return 'unknown', ['malformed health/stop verdict']
    if o['stop'] or o['health'] == 'unhealthy':
        return 'unhealthy', ['stop condition or unhealthy observation']
    if o['health'] != 'healthy':
        return 'unknown', ['monitoring unavailable']
    if o['ended_at'] - o['started_at'] < s['window_seconds']:
        return 'insufficient', ['observation window incomplete']
    if o['samples'] < s['min_samples']:
        a, m = s.get('manual_alternative'), o.get('manual')
        if not (isinstance(a, dict) and isinstance(m, dict) and nonempty(a.get('instruction'))
                and nonempty(a.get('scenarios')) and all(m.get(k) == a[k] for k in ('instruction', 'scenarios'))
                and nonempty(m.get('evidence'))):
            return 'insufficient', ['insufficient samples; no previously accepted manual alternative evidenced']
    return 'healthy', []


def assess(r, operation, target, op_id, peers, now):
    shape(r)
    verdict, observations = health(r, now)
    errors = []
    if not operation:
        return {'assessment': 'record-only', 'phase': r['progress']['phase'], 'health': verdict,
                'limitations': observations + ['Recorded facts are not authenticated evidence or authority.']}
    for group in ('identity', 'candidate', 'recovery'):
        if not all(nonempty(v) for v in r[group].values()):
            errors.append('unassessed ' + group)
    if not nonempty(r['target']['environment']) or not r['target']['resources']:
        errors.append('target/environment resources missing')
    if not r['implementations'] or not all(all(nonempty(i.get(k)) for k in ('home', 'id', 'revision')) for i in r['implementations']):
        errors.append('durable implementation links missing')
    if not number(r['health'].get('max_age_seconds')) or r['health']['max_age_seconds'] <= 0:
        errors.append('health freshness criterion missing')
    if not r['health']['sources'] or not nonempty(r['health']['baseline']) or not nonempty(r['health']['stop_condition']):
        errors.append('health contract incomplete')
    if not r['stages'] or any(not nonempty(s.get('name')) or not nonempty(s.get('target')) or
                            not all(number(s.get(k)) and s[k] > 0 for k in ('window_seconds', 'min_samples'))
                            for s in r['stages']):
        errors.append('exposure stages incomplete')
    if len({s.get('name') for s in r['stages']}) != len(r['stages']):
        errors.append('duplicate stage names')
    pending = r['progress']['pending_action']
    if pending and pending.get('status') == 'ambiguous':
        errors.append('ambiguous action: reconcile actual external state before continuation')
    elif pending and (pending.get('status') != 'planned' or pending.get('id') != op_id
                      or pending.get('operation') != operation or pending.get('target') != target):
        errors.append('different or malformed pending action retains resource reservation')
    # Only the caller can supply a complete peer inventory and hold the existing
    # fleet lock/lease while reserving resources. This is deliberately not a lock.
    for peer in peers:
        shape(peer)
        if (peer['identity']['home'], peer['identity']['task']) == (r['identity']['home'], r['identity']['task']):
            continue
        if (peer['identity']['project'], candidate_identity(peer), peer['target']['environment']) == (r['identity']['project'], candidate_identity(r), r['target']['environment']):
            errors.append('duplicate release identity: reuse ' + peer['identity']['task'])
        if peer['target']['environment'] == r['target']['environment'] and peer['progress']['pending_action']:
            if set(peer['target']['resources']) & set(r['target']['resources']):
                errors.append('resource reserved by ' + peer['identity']['task'])
    completed = [a for a in r['progress']['completed_actions'] if a.get('id') == op_id and op_id]
    if completed:
        if not errors and len(completed) == 1 and completed[0].get('operation') == operation and completed[0].get('target') == target and completed[0].get('status') == 'verified' and nonempty(completed[0].get('evidence')):
            return {'assessment': 'already-observed', 'health': verdict, 'reasons': ['Do not repeat the external action; reverify volatile state.']}
        errors.append('operation identity reused or unverified')
    if operation in ('deploy', 'expose', 'advance'):
        if {row.get('category') for row in r['readiness']} != CATEGORIES:
            errors.append('readiness categories incomplete')
        for row in r['readiness']:
            label = str(row.get('requirement', 'unnamed'))
            if not nonempty(row.get('requirement')) or not nonempty(row.get('expected')) or not bound(row, r):
                errors.append('missing/stale readiness identity: ' + label)
                continue
            status = row.get('status')
            if status == 'not-applicable' and nonempty(row.get('limitation')):
                continue
            if not nonempty(row.get('observed')) or not nonempty(row.get('evidence')) or not number(row.get('observed_at')) or not 0 < row['observed_at'] <= now:
                errors.append('readiness evidence missing: ' + label)
            if status != 'pass':
                ex = row.get('exception')
                if not (status in ('fail', 'untested') and isinstance(ex, dict) and bound(ex, r)
                        and all(nonempty(ex.get(k)) for k in ('criterion', 'consequence', 'instruction'))
                        and ex['criterion'] == row.get('requirement')):
                    errors.append('required criterion ' + str(status) + ': ' + label)
        if operation == 'deploy' and r['progress']['phase'] != 'Ready':
            errors.append('deployment requires Ready assessment')
        if operation == 'deploy' and exposes(r, operation, target) and target != r['stages'][0].get('target'):
            errors.append('combined deployment must target initial cohort')
        if operation in ('expose', 'advance'):
            if not deployment_verified(r):
                errors.append('actual deployed artifact/source mapping unverified')
            names = [s.get('name') for s in r['stages']]
            if operation == 'expose':
                if r['progress']['phase'] not in ('Ready', 'Deployed, unexposed') or target != (r['stages'][0].get('target') if r['stages'] else None):
                    errors.append('initial exposure phase/target mismatch')
            else:
                stage = r['progress']['stage']
                index = names.index(stage) if stage in names else -1
                if (r['progress']['phase'] != 'Expansion ready' or index < 0 or index + 1 >= len(names)
                        or target != r['stages'][index + 1].get('target')):
                    errors.append('next stage phase/target mismatch')
                if verdict != 'healthy':
                    errors.extend(observations)
    if operation in ('deploy', 'expose', 'advance', 'contain', 'restore'):
        if not nonempty(op_id) or not nonempty(target):
            errors.append('operation identity and exact target required')
        if not any(bound(a, r) and a.get('operation') == operation and a.get('target') == target
                   and nonempty(a.get('instruction')) and number(a.get('expires_at')) and a['expires_at'] >= now
                   for a in r['authority']):
            errors.append('no matching unexpired recorded action authority; merge permission is insufficient')
    if operation == 'complete':
        o = r['outcome']
        if pending:
            errors.append('pending action remains unresolved')
        if o['recovery'] not in ('not-needed', 'contained', 'restored'):
            errors.append('recovery disposition unresolved or failed')
        if not o['watches_retired'] or o['unresolved_calls']:
            errors.append('watch retirement or captain-call disposition unresolved')
        if not nonempty(o['exposure']):
            errors.append('final exposure missing')
        errors.extend(evidence_applicability(o, r, now, o.get('observed_at'), o.get('observed_at')))
        if o['disposition'] == 'released':
            if (r['progress']['phase'] != 'Released' or not r['stages'] or
                    r['progress']['stage'] != r['stages'][-1].get('name') or
                    o['exposure'] != r['stages'][-1].get('target') or o['health'] != 'healthy' or verdict != 'healthy'):
                errors.append('final planned exposure and healthy observation not verified')
        elif o['disposition'] in ('cancelled', 'withdrawn'):
            if r['progress']['phase'] != 'Stopped' or o['health'] != 'safe' or o['exposure'] != 'none':
                errors.append('cancelled/withdrawn final safe state not verified')
        else:
            errors.append('nonterminal or failed recovery disposition')
    return {'assessment': 'blocked' if errors else 'consistent', 'health': verdict,
            'reasons': errors, 'limitations': ['Consistency only; verify evidence, instruction provenance, complete peer inventory and existing locks/leases before any action.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    t = sub.add_parser('template'); t.add_argument('task')
    f = sub.add_parser('fingerprint'); f.add_argument('body')
    s = sub.add_parser('summary'); s.add_argument('body'); s.add_argument('--now', type=float)
    c = sub.add_parser('check'); c.add_argument('body'); c.add_argument('--operation', choices=sorted(OPERATIONS))
    c.add_argument('--target', default=''); c.add_argument('--operation-id', default='')
    c.add_argument('--peer', action='append', default=[]); c.add_argument('--now', type=float)
    args = parser.parse_args()
    if args.command == 'template':
        print('## Release readiness\n\n```firstmate-release\n' + json.dumps(template(args.task), indent=2) + '\n```')
        return 0
    try:
        if args.command == 'fingerprint':
            r = read_body(args.body); shape(r)
            print(json.dumps(binding(r), sort_keys=True)); return 0
        now = time.time() if args.now is None else args.now
        if not number(now) or now <= 0:
            raise ValueError('invalid current time')
        r = read_body(args.body)
        if r is None:
            print(json.dumps({'assessment': 'legacy/unassessed', 'health': 'unknown'})); return 1
        if args.command == 'summary':
            shape(r)
            counts = {status: sum(row.get('status') == status for row in r['readiness'])
                      for status in ('pass', 'fail', 'untested', 'not-applicable')}
            print(json.dumps({'phase': r['progress']['phase'], 'recorded_health': health(r, now)[0],
                              'readiness': counts, 'evidence': 'See the approved validation summary; private references omitted.'}, sort_keys=True))
            return 0
        peers = [read_body(p) for p in args.peer]
        result = assess(r, args.operation, args.target, args.operation_id, peers, now)
        print(json.dumps(result, sort_keys=True))
        return 1 if result['assessment'] == 'blocked' else 0
    except (ValueError, OSError, TypeError, KeyError) as exc:
        print(json.dumps({'assessment': 'malformed', 'health': 'unknown', 'reason': 'invalid private release record' if args.command == 'summary' else str(exc)}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
