# Project task data validation

This feature-validation summary records retained evidence as of 2026-10-01 for production-code candidate `5d4dccc9287c9692090c3cd636674de321cb7b8e`.
It is a reviewed evidence handoff, not a new passing verdict or a substitute for native validation.
The report is available in the candidate's ordinary source-review diff; its consideration and linkage to validation scenarios require owner review and are not machine-enforced.

## Feature and source

The accepted behavior is per-task documentation under `data/<Project>/<task-id>/`, with fleet-wide records remaining at the `data/` root.
[Configuration](configuration.md) owns the layout; [the task-data resolver](../bin/fm-task-data-lib.sh) and [migration command](../bin/fm-data-migrate.sh) own lookup and migration mechanics.

The isolated CLI observations below recorded the exact candidate, a clean tree, and these source hash prefixes, which were subsequently checked against the complete SHA-256 values:

| Source | SHA-256 |
| --- | --- |
| `bin/fm-brief.sh` | `fbda8bfc74578ca33758729d8cb166d5eb2f45f08025d173a1e6f26a9ea6838a` |
| `bin/fm-data-migrate.sh` | `d6379b1a2bd6fb14fee194457a1c1d4cb2f25dedd482fecad19540073a210118` |
| `bin/fm-task-data-lib.sh` | `0c552f669f5e3f85d5b14657ffe24e5b7bc5bf412d383d766f07f80c9d851bed` |

## Configured Test remains failed

The latest complete configured result was **172 scripts, 16 failures, 28 expected gate skips**, using the unchanged command:

```sh
bin/fm-test-run.sh --changed --exclude-family real-herdr-gated
```

All nine changed test scripts passed, including all 29 assertions in `tests/fm-task-data.test.sh`.
Those passes do not prove that unrelated failures are independent of indirect effects from this feature.
All sixteen failures below remain unresolved; none has an approval or exception.

| Failing script under `tests/` | Baseline disposition |
| --- | --- |
| `fm-watch-arm.test.sh` | Unmatched |
| `fm-wake-queue.test.sh` | Unmatched |
| `fm-pi-watch-extension.test.sh` | Unmatched |
| `fm-watch-triage.test.sh` | Unmatched; configured script bound reached |
| `fm-teardown.test.sh` | Matching first assertion: missing-adapter preflight continued |
| `fm-remote-secondmate-trace-context.test.sh` | Matching first failure: Bash 3.2 empty-array handling |
| `fm-remote-secondmate-lifecycle-e2e.test.sh` | Matching first failure: Bash 3.2 empty-array handling |
| `fm-secondmate-reconcile.test.sh` | Matching first assertion: elapsed-time threshold |
| `fm-on.test.sh` | Unmatched |
| `fm-session-start.test.sh` | Unmatched |
| `fm-procevent.test.sh` | Unmatched |
| `fm-pending-reply.test.sh` | Unmatched |
| `fm-public-followup.test.sh` | Matching first assertion: generated rechain command |
| `fm-extension-binding.test.sh` | Unmatched |
| `fm-bearings-snapshot.test.sh` | Unmatched |
| `fm-backend-cmux.test.sh` | Matching first assertion: send-text-submit failure classification |

The six bounded matches compare retained candidate observations against base `4014148a5c6570b226a032870cddb20035abdf14`; the other ten lack matching baseline attribution.
A matching first failure does not clear a configured failure, prove its cause, or validate assertions that execution never reached.
In particular, the unchanged full-clone reconcile base check reached the same rounded elapsed `5` observation at a `< 5` assertion as the candidate.
This is a threshold observation, not a five-second overrun or proof of host causation.
An earlier archive-base attempt failed sooner at a different warm-ledger assertion and remains an inconclusive comparison.
The full-clone check passed three preceding cases; the remainder of its fourth case and all eighteen subsequent test functions were unexecuted.
Other early-failing comparisons likewise leave their later assertions untested.

Three configured runs on the same production candidate recorded 33, 20 and 16 failures respectively.
Every latest failure also occurred in the first run, but procevent, reconcile and session-start were fail-pass-fail across the three runs.
Control-relaunch passed, then failed, then passed, with four intervening serial comparison passes.
Backlog-atomicity and secondmate-restart also retain mixed configured/comparison outcomes.
These observations do not justify a blanket baseline or environment exemption.

## Direct feature observations and limits

One exact-source product CLI drive used isolated synthetic homes and retained actual resulting state:

- New task placement covered registered projects, case normalization, a project-path argument, an unregistered project and a secondmate charter; duplicate IDs were refused and fleet records stayed at the data root.
- Promotion found the per-project brief and wrote its instructions there; the fleet snapshot found the per-project scout report.
- Migration dry run preserved the tree and reported unresolved assignments; explicit assignments allowed three task-directory moves and three backlog-link rewrites.
- Repeated apply changed nothing; revert restored the original files and links byte-for-byte and removed its manifest; repeated revert changed nothing; forward application converged to the first forward state.
- A true dependency cycle was named and refused twice with exit 4 and unchanged scratch contents.

These are direct CLI observations, separate from automated suite results, baseline comparisons and source inspection.
Earlier same-feature transcripts include a scratch copy of operational data, not migration of the actual home; their headers did not independently pin the tested commit, and that provenance limitation remains.
Live endpoint spawning, actual-home migration and unexecuted failure-path assertions remain uncovered.
The retained private evidence includes complete outputs, timing, source identities and a mapping to this summary; no absent native report is represented as completed.

## Adoption criterion

Moving the two explicitly assigned RepToday task folders is a separate adoption obligation after approved landing and the idle-fleet prerequisite.
Actual-home adoption is not required during this feature's validation, is not authorized by a validation run, and is not a passed live scenario.
Preserve the agreed RepToday assignments for that later operation.
Validation must assess the feature with this sequencing intact while retaining every unresolved Test obligation above.
