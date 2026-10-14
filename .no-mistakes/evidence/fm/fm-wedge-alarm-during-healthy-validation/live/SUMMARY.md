# Live wedge-alarm runs: fm/fm-wedge-alarm-during-healthy-validation

Each run starts the real `bin/fm-watch.sh` in a temporary firstmate home against one crew window in a private tmux server.
The real `bin/fm-crew-state.sh` reads the run state, and the busy record is written with the real `bin/fm-busy-event.sh`.
Every wake is drained and acknowledged with the real `bin/fm-wake-drain.sh`, and then the watcher is re-armed, as firstmate's handling turn does.
The only stand-in is the external `no-mistakes` CLI (`nm-standin.sh`), which replays the v1.79.0 `axi status` TOON shapes, because a gate test phase may not start a pipeline.
The driver is `drive.sh`, and the real-harness variant is `drive-self-harness.sh`.
`after-*` runs use the change (d8fe03d), and `before-*` runs use the base commit (7516a6f).
The window is `FM_STALE_ESCALATE_SECS=30` unless noted.

| Run | Crew situation | Stale / possible-wedge wakes | Result |
| --- | --- | --- | --- |
| before-sync-wait | idle pane, `paused:` status, run's test step producing output every 5s | 3 in 140s (3rd demands deep inspection) | false alarms reproduced |
| after-sync-wait | same, pipeline agent output stops at t+131s | 0 while active, then 1 at t+181s | deferred while active ("its validation step test was active Ns ago"), escalated within two windows of the last activity |
| before-ci-wait | ci step waiting on pending checks, last log line ~30 min old | 3 in 140s | false alarms reproduced |
| after-ci-wait | same | 0 in 140s | deferred ("its validation run is waiting on CI checks") |
| after-ci-red | ci step whose latest marker is `issues detected: ... auto-fixing` | 3 in 140s (3rd demands deep inspection) | real stall still escalates |
| after-stalled-step | working run, step silent 900s+, crew writing its worktree | 3 in 140s (3rd demands deep inspection) | crew writes do not outvote a stalled pipeline |
| before-fg-tests | busy pane past the turn bound, real `bin/fm-test-run.sh` in the pane | 3 in 140s | false alarms reproduced |
| after-fg-tests-240s | same, default 240s window, 15 min of fm-watch-triage, fm-crew-state, fm-daemon, fm-teardown suites | 0 in 900s | deferred every window ("starting new processes in its worktree") |
| after-fg-tests | same at a 30s window | 2 in 170s | deferred twice, then escalated during a ~35s phase where the running test file blocked in one subprocess (see diag-fg-probe-crew-state.txt) |
| after-fg-hung-harness | busy pane, harness in the worktree restarting a real `caffeinate -t 8` while its foreground child hangs | 3 in 140s (3rd demands deep inspection) | housekeeping restarts are not progress |
| after-parked-writes | busy pane, run parked at a gate, crew writing its worktree | 0 in 140s | deferred ("writing its worktree") |
| after-parked-hung | busy pane, run parked at a gate, crew hung | 3 in 140s (3rd demands deep inspection) | real wedge still escalates |
| self-harness | this session's own Claude Code harness, blocked on one tool call in the recorded worktree, 260s window | 1 at t+268s | real harness with nothing new running still escalates |
