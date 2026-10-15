# Round 3 live evidence (target 6273c67)

Each watcher run used the real `bin/fm-watch.sh` in its normal blocking mode, re-armed after each wake by `drivers/watch-loop.sh`.
Each also used the real `bin/fm-crew-state.sh`, a private tmux server with one static idle worker pane, and the real no-mistakes v1.79.0 daemon answering for live run `01M4Z2NDNVFJXVP6PM2K4SF305`.
The run's copy is this worktree, resolved through the real `~/.no-mistakes/worktrees/<repo>/<run-id>`.
The fixture crew is a temp clone at the run's head on the run's branch, so the forwarders pin `axi status` to the live run with `--run`.
The long command is the real `bin/fm-test-run.sh --jobs 1` running the three affected suites inside the run's copy.
Base is a `git archive` of fbd3c9b, run side by side at the same time.
The step agent's own tool calls also run in the run's copy and count as the step's work, so the agent stayed blocked on one call through every watcher phase, and each direct probe opens its window after the driver started.

## Long command running in the run's copy

- `live-A-60s-window-fixed-vs-base.txt`: 60s window, `axi status` through `drivers/forwarder-quiet.sh`, which rewrites only the active step's `last_activity`/`agent_pid` cells to the configured-command rendering.
  This change deferred all 5 windows, each naming "its validation step test is starting new processes in its run", with zero escalations while host load reached about 268.
  Base escalated 1, 2, then 3 and 4 with demand-deep-inspection.
- `live-A6-6s-window-unmodified-fixed-vs-base.txt`: 6s window, nothing rewritten.
  This change escalated 0 times in 15 windows: 9 deferrals on the run-step process evidence, 6 on the step's own fresh activity.
  Base escalated 6 times, with demand-deep-inspection from the third.
- `live-A-progress-evidence-probe.txt`: `crew_progress_evidence` called directly mid-run: this change names the evidence (rc=0), base finds none (rc=1).
- `live-crew-state-read.txt`: the new `active <secs>s in run <id>` segment from the real daemon, for both renderings.
  The `4h16m` active_for reads as its upper bound, 15419s.
  Base omits the segment.
  The run id resolves to this worktree, and an unknown id resolves to nothing.
  With no long command running yet, the probe finds no evidence (rc=1).

## Guards (20s window, step quiet, this change)

Every window escalated, with no deferral, and each direct probe returned rc=1:
- `live-B-step-command-stopped.txt`: the long command is gone.
- `live-C-crew-own-work-does-not-outvote-run.txt`: the crew's own worktree starts a new process tree every second.
- `live-D-other-run-copy-does-not-count.txt`: another real run's copy does the same.

## Wake lock (`live-wake-lock-between-holders.txt`)

Here the real `bin/fm-wake-drain.sh` faces a queue lock that is mid-handover when its 1s bounded wait gives up.
This change skips (exit 0) when a live holder appears, drains all 3 queued records (exit 0) when the lock frees, and still reports a lock that never shows an owner as unsafe (exit 1).
Pre-fix f3ec246 reports all three as unsafe (exit 1).

## The revised run-step test (6273c67)

- `test-discriminates-missing-behavior.txt`: `tests/fm-crew-state.test.sh` through each tree's own `bin/fm-test-run.sh`, in a private TMPDIR.
  Unmodified HEAD passes.
  HEAD's test with base's `bin/fm-classify-lib.sh` fails at the run-step case's first positive read ("new work under the active step's command in the run's own copy was not progress evidence"), and the runner returns within 2s with no leaked runner.
  The 267c59f test fails at the same point, but `fm-test-run.sh` was still blocked 90s later because its `while :` runner had outlived the case, with ppid 1 and its cwd in the deleted fixture.
- `stress-run-step-case-8-concurrent.txt`, `stress-run-step-case-16-concurrent.txt`: 8 and then 16 concurrent copies of the suite at HEAD.
  All 24 passed, including the run-step case, at host load up to about 123, and no runner was left behind.
- `long-command-fm-test-run.log`: the long command's own log; `fm-crew-state.test.sh` passed in the run's copy (the later suites were stopped when the phase ended).

`drivers/` holds every script that produced the files above.
