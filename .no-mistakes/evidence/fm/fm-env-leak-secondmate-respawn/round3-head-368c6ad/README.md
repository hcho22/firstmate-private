# Live validation at HEAD 368c6ad (after the launch-prefix drop)

All runs use real tmux 3.6b on a private `TMUX_TMPDIR` socket, or real Herdr 0.7.5 in an isolated `fm-lab-*` session.
Session start, bootstrap, and fm-spawn are the real product; only the agent binary (`pi`) and the network toolchain are stand-ins.
Session start inherits all 14 internal handoff settings, `CLAUDECODE=1`, and an ordinary `RELAUNCH_ORDINARY_SENTINEL=kept`.
Panes run the captain's real login zsh (about 1.9 s startup).

| File | What it shows | Result |
| --- | --- | --- |
| `head-no-server-zsh-run{1,2,3}.txt` | Relaunch starts the tmux server; server and secondmate env are clean; 717-byte launch starts the agent | 0 failed checks x3 |
| `base-no-server-zsh.txt` | Same run on base 7605a4a | 15 failed checks (leak reproduced) |
| `head-clean-server-zsh.txt` | Relaunch into a clean, already-running server | 0 failed checks |
| `base-clean-server-zsh.txt` | Same on base: tmux new-window never passed the client's env | 0 failed checks |
| `head-polluted-server-zsh.txt` | Server an older Firstmate polluted is reused unchanged (documented); agent still starts | agent started; inherited names listed |
| `herdr-server-env-{head,base}.txt` | `fm_backend_herdr_server_ensure` from a polluted env | HEAD 0 failed, base 9 failed |
| `herdr-client-env-head.txt` | Clean Herdr server, pane created from a polluted client | 0 failed checks |
| `regression-test-{head,base}.txt` | Extended regression test alone, HEAD vs base code | HEAD ok, base not ok |
| `regression-test-4171fa5-prefix.txt` | Same test against the earlier prefixed launch | not ok: 1206 typed bytes |
| `tmux-smoke-head.txt` | `tests/fm-backend-tmux-smoke.test.sh` on real tmux | all ok |
