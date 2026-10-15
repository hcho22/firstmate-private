# Round 2 live evidence (target 267c59f)

Every watcher run used the real `bin/fm-watch.sh` in normal blocking mode (re-armed after each wake by `drivers/watch-loop.sh`), the real `bin/fm-crew-state.sh`, a private tmux server with one static idle worker pane, and the real no-mistakes v1.79.0 daemon answering for live run `01M4Z2NDNVFJXVP6PM2K4SF305`.
The run's copy is this worktree, resolved through the real `~/.no-mistakes/worktrees/<repo>/<run-id>`.
The fixture crew is a temp clone at the run's head on the run's branch, so `drivers/forwarder.sh` pins `axi status` to the live run with `--run`.
The long command is the real `bin/fm-test-run.sh` running the two changed suites inside the run's copy.
Base is a `git archive` of fbd3c9b, run side by side at the same time.

## 60s window (`live-quiet-*`, `diag-quiet-*`)

This agent-driven test step's real `last_activity` is refreshed every 15-30s by its agent, which a configured-command phase never does.
These runs pass the real CLI answer through `drivers/forwarder-quiet.sh`, which rewrites only the active step's `last_activity`/`agent_pid` cells to the quiet configured-command rendering (`"quiet <m>m<s>s ago: running tests",""`).
Run id, branch, head, status, and `active_for` stay real.

- `live-quiet-A-60s-window-fixed-vs-base.txt`: this change escalated once, in the first window, then deferred 3 windows naming "its validation step test is starting new processes in its run". Base escalated 1, 2, then 3 with demand-deep-inspection.
- `diag-quiet-A-60s-instrumented-run1.txt`, `diag-quiet-A-60s-instrumented-run2-with-base.txt`: the same scenario using a temp copy of this change's `bin/` that adds DIAG log lines only. This change deferred 3 of 3 and then 5 of 5 windows, with zero escalations. Base, at the same time, escalated 1, 2, 3, 4 with demand-deep-inspection from the third. DIAG shows each escalation-time read and the process-tree roots whose cwd is the run's copy.
- `live-quiet-B-*`, `live-quiet-C-*`, `live-quiet-D-*` (20s window, this change): with the run working and its step quiet, every window escalated, with no deferral on process evidence, in each of three cases. B: the long command is gone. C: the crew's own worktree starts a new process tree every second. D: another real run's copy does the same.

## 6s window, unmodified daemon answers (`live-A-*`, `live-B/C/D-*`)

- `live-A-long-command-fixed-vs-base.txt`: this change escalated twice early, while a single test case paused longer than 6s, then deferred 16 consecutive windows. Base escalated 10 times (demand-deep-inspection from the third).
- `live-B/C/D-*`: escalations only, with no process-evidence deferral.
- `live-crew-state-read.txt`: the new `active <secs>s in run <id>` segment, read from the real daemon. The rendering `2h26m` is read as its upper bound, 8819s. Base omits the segment.

## Wake lock (`live-wake-lock-between-holders.txt`)

The real `bin/fm-wake-drain.sh` faces a queue lock that is mid-handover when its 1s bounded wait gives up.
This change skips (exit 0) when a live holder appears, and drains (exit 0) when the lock frees.
A lock that never shows an owner is still reported unsafe (exit 1).
Pre-fix f3ec246 reports all three as unsafe (exit 1).
The natural 40-appender race did not reproduce for either version this time (20 reps each).

## Flake (`flake-new-crew-state-case.txt`)

The new `test_run_step_process_evidence_over_real_helper` failed once under host load, out of about 58 executions.

`drivers/` holds every script that produced the files above.
