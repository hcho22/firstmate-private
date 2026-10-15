# Live evidence: wedge alarm vs a validation step's own long command (f3ec246)

Setup for every live watcher run: the real `bin/fm-watch.sh` in normal blocking mode, a real private tmux server with one static idle worker pane, the real `bin/fm-crew-state.sh`, and the real no-mistakes v1.79.0 daemon.
The fixture crew worktree is a temp clone at the run's head, so `drivers/no-mistakes-forwarder.sh` pins `axi status` to the live run with `--run <id>`; every answer comes from the real CLI.
The run's copy resolves through the real `~/.no-mistakes/worktrees/<repo>/<run-id>`.

- `live-crew-state-read.txt`, `live-real-quiet-run-crew-state-read.txt`: the new `active <secs>s in run <id>` segment, read live from this run and from a real run in its quiet configured-command phase (`5h14m` read as its upper bound, 18899s).
- `live-A-window6-fixed.txt`: this change, with `bin/fm-test-run.sh` running in this run's copy. 20 of 22 consecutive deferrals named "its validation step test is starting new processes in its run"; the next window after the command exited escalated.
- `live-C-window6-base-reproduces-alarm.txt`: base fbd3c9b, same setup, long command running the whole time. Escalation 1, 2, 3 (demand-deep-inspection), 4, 5.
- `live-B-window6-fixed-step-starts-nothing.txt`: this change, run still working, long command gone. Escalation 1, 2, 3 with demand-deep-inspection.
- `live-B2-window6-fixed-crew-own-work-does-not-outvote-run.txt`: this change, the crew's own worktree starting a new process tree every second. Still escalates 1, 2, 3.
- `live-A-window60-fixed.txt`: 60s window. This agent-driven step's `last_activity` stays fresh (the daemon refreshes "claude producing output"), so the earlier PR #14 branch deferred; that is why the runs above use a 6s window.
- `live-D0-real-run-command-ended-before-first-window.txt`: an attempt against a real configured-command phase. The command ended before the first window, so it shows no difference between the two versions.
- `long-command-fm-test-run.log`: the changed suites (`fm-crew-state`, `fm-watch-triage`) passing in isolation; this run was also scenario A's long command.
- `wake-queue-flake-repro.txt`, `crew-state-flake-and-shared-stub-fix.txt`: the two unrelated flakes seen in this step.
- `drivers/`: the scripts that produced the above.
