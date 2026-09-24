# Local release evidence

Candidate commit: `28d2b382c929c75ef1acc4aa7dc2dee2e6db0f40`.
Actual installed task backend, registered monitoring, durable notification acknowledgement, loopback HTTP requests and SQLite persistence were exercised in a disposable home. No production resource was used.

## Observed behavior

| Scenario | Observation |
|---|---|
| disabled (pass) | {"after": 0, "before": 0, "response": {"protective_control": true, "visible": false, "wrote": false}} |
| disabled-leak (fail) | {"after": 1, "before": 0, "response": {"protective_control": true, "visible": false, "wrote": true}} |
| enabled (pass) | {"protective_control": true, "visible": true, "wrote": true} |
| enable-disable (pass) | {"after": 2, "before": 2, "response": {"protective_control": true, "visible": false, "wrote": false}} |
| gate-invalid (pass) | {"protective_control": true, "visible": false, "wrote": false} |
| gate-unavailable (pass) | {"protective_control": true, "visible": false, "wrote": false} |
| monitoring-loss (pass) | {"health": "unknown", "observed_at": 1790228414.214271, "reason": "HTTP Error 503: Service Unavailable"} |
| merge-authority (pass) | {"actions_after": 0, "actions_before": 0} |
| failed-containment (fail) | {"after": 5, "before": 4} |
| failed-restoration (fail) | HTTP 503 and terminal refusal |
| verified-withdrawal (pass) | {"final_exposure": "none", "writes_retained": 5} |
| REL-07 prior-attempt-replay (pass) | {"actions_unchanged": true, "current_attempt": {"id": "success-internal", "started_at": 1790228421.568929, "target": "internal"}, "prior_attempt": "expose-1"} |
| REL-10 REL-12 same-attempt-restart (pass) | {"attempt": {"id": "success-internal", "started_at": 1790228421.568929, "target": "internal"}, "observation_attempt": "success-internal"} |
| PROOF-04 REL-14 stale-withdrawal (pass) | {"latest_effect": {"effect_at": 1790228421.568929, "evidence": "[synthetic evidence directory]/transcript.jsonl", "id": "success-internal", "operation": "expose", "status": "verified", "target": "internal"}, "old_verification": 1790228419.794048} |
| REL-12 REL-14 terminal-restart (pass) | {"effect": "contain-1", "verification_time": 1790228419.794048} |
| device-capability (untested) | no device or device integration in local workload |

The three failed observations above are deliberately injected defects that the pilot must detect. They were not relabeled as passing criteria. The absent device demonstrates honest capability reporting; no device-readiness claim is made.

## Persisted results

Independent read-only SQLite verification found six distinct authorized actions, 15 requests and nine retained writes. Verified withdrawal retained five existing writes; the later successful rollout produced four more. Cancellation had zero actions and disabled exposure. The deferred release obligation remained in the ordinary backlog after implementation completion. Registered checks were retired and the durable notification queue was empty.

The exact action journal and real checker responses are in [verified-results.json](verified-results.json). The user-facing safe projection is in [public-summary.json](public-summary.json). Full synthetic observations are in [scenarios.json](scenarios.json), with command responses in [transcript.jsonl](transcript.jsonl).

## Validation and limits

The supplied outer baseline `bin/fm-test-run.sh --changed --exclude-family real-herdr-gated` had already passed. This phase additionally ran the release interface, actual local pilot, brief generation, task delivery/promotion and test-runner behavior checks through the normal runner; all passed without skips.
The pilot took 26.02 seconds. Brief scaffold/render timing was 0.065 seconds for contained work and 0.061 seconds for shared work; these are rendering measurements, not impact-assessment or preparation overhead. No new preparation-overhead estimate or production benefit claim is made.
Evidence covers a CLI/API workflow; there is no changed rendered UI to screenshot. The checker assesses consistency of recorded evidence and does not independently authenticate external truth.
