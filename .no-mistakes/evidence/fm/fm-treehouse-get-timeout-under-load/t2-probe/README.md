# Test round 2: Herdr early settle and abort-cleanup journal

Code under test: the worktree on top of 4406f06 (uncommitted fix); "pre-fix" runs used `git archive 4406f06`, "base" runs `git archive dd5a411`.

| Evidence | Result |
| --- | --- |
| `slowfail.txt`, `slow.txt` (`herdr-fg-probe.sh`) | Real Herdr 0.7.5 + real treehouse v3.1.0: while the hook runs, `pane get` foreground_cwd is the worktree but the foreground group leader (treehouse) is in the project; after entry the subshell leads the group in the worktree. |
| `../t2-s7-herdr-base-slowfail20-calls` | base dd5a411: launch lines typed into the slow-fail pane w2:p2 9s in while the hook ran; after the hook failed `sleep 600` ran with cwd = primary checkout. |
| `../t2-s7-herdr-fix-slowfail20-calls`, `../t2-s7-herdr-fix-slowfail20` | fix: refused after 37-39s, "treehouse get exited without entering a worktree"; no launch call to the slow-fail pane in the call log; no meta, no journal, no presentation warning. |
| `../t2-s7-tmux-fix-slowfail20` | tmux unchanged: same refusal. |
| `../t2-s9-herdr-fix-slow20-calls` | fix, successful 20s hook: launch typed at 01:34:45 after the hook ended at 01:34:41; worktree recorded; teardown ok. |
| `e2e-treehouse-wait-pre-fix.log` | new hook-fail e2e case red on pre-fix (spawned at the slot while the hook ran). |
| `e2e-treehouse-wait-pre-fix-journal.log` | refused-get warning/journal assertion red on pre-fix ("could not verify the exact pane"). |
| `e2e-treehouse-wait-head.log` | real-Herdr treehouse wait e2e 10/10 on the fix. |
| `herdr-presentation-e2e-fix.log` | real-Herdr presentation e2e 23/23 on the fix (abort fixture now rewrites the process-info leader cwd; journals retired). |
| `tmux-wait-and-herdr-unit.log` | real-tmux treehouse wait suite and portable Herdr adapter suite pass. |
| `targeted-portable-and-smoke.log`, `herdr-real-treehouse-spawn-e2e.log` | worktree-settle, fm-backend, documentation-audiences, real Herdr smoke, workspace-per-home and launcher-workspace e2e pass. |
