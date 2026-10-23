# Test phase evidence: upstream firstmate merge at c2afff2a

Base 9463297b (private main), target c2afff2a, driven 2026-10-22 on the captain's Mac (macOS, GNU bash 3.2.57, host jq 1.6, host tasks-axi 0.2.6, codex CLI 0.160.0 with a managed app-server daemon 0.164.0, tmux, treehouse 3.1.0, no `timeout` or `gtimeout`).
This run's review rounds net to two runtime changes against 3fec102e, which the previous run (01M5HD7288YPXE51BV6TY7KPX9) drove live: `bin/fm-watch-checkpoint.sh` now reports a watcher's signal death as 128+n on its perl fallback, and a comment in `bin/fm-session-lock-lib.sh`.
`bin/fm-lock.sh`, `bin/fm-turnend-guard.sh` and `bin/fm-turnend-guard-cursor.sh` are byte-identical to 3fec102e after c2afff2a reverted 2bf2fc6e/60d20341's displaced-session refusal.
Every lab was a throwaway directory under /tmp with a private tmux socket and was torn down; no global tool or config was changed.

## Configured command (exit 1)

265 scripts selected, 1 failed: `tests/fm-composer-codex-idle-live-e2e.test.sh` (`s-gate-run-attribution.txt`).
codex 0.160.0 on PATH disagrees with the running managed daemon 0.164.0 and opens "Background server has incompatible feature settings" before any composer is drawn.
`s-codex-idle-guard-c2afff2a.txt` reproduces that, then runs the same guard on a /tmp copy of c2afff2a with the daemon's own codex 0.164.0, that folder trusted and hooks off via `-c` for the invocation only: it passes in 3 s, starfield and placeholder observed, `empty` on both reads.

## Files

| File | What it shows |
| --- | --- |
| `s-gate-run-attribution.txt` | The gate run's summary, the one failing script with codex's modal, and this round's focused suites passing |
| `s-codex-idle-guard-c2afff2a.txt` | The codex idle guard against the host CLI (host modal) and the daemon's own binary (pass) |
| `s-lock-dead-taker-head-c2afff2a.txt` | Two Claude-shaped stand-in sessions: A locks; B is refused; B's captain-confirmed takeover moves the lock (pid, sidecar S2, one takeover record); A is refused while B lives; A's turn-end guard prints the displaced notice once (exit 2) then exits 0; B's process exits; A's session start reclaims the dead taker's lock automatically (pid A, sidecar S1, still one takeover record) |
| `s-lock-dead-taker-before-60d20341.txt` | The same driver on the pre-revert round: step 7 leaves A read-only behind B's dead pid, which c2afff2a removed |
| `s-checkpoint-term-stop-head-c2afff2a.txt` | Real `fm-watch-checkpoint.sh --seconds 120` stopped by the real `fm-watch-arm.sh --stop`: exit 143, watch lock released |
| `s-checkpoint-term-stop-before-3fec102e.txt` | The same before the fix: exit 0 with no wake line, which the checkpoint contract reads as an actionable wake |
| `upgrade/s-upgrade-1..4-*.txt` | Old code 9463297b spawns a ship task through real treehouse and tmux; its own `fm-update.sh` fast-forwards to c2afff2a; merged session start acquires the lock and lists the task alive (bootstrap reports quota-axi missing and lavish-axi below 0.1.77 on this host); merged teardown reaps the agent, returns the worktree, closes the backlog row and keeps the task folder |

## Drivers

`drivers/lock-dead-taker.sh <commit> <out>`, `drivers/checkpoint-term-stop.sh <commit> <out>`, `drivers/codex-idle-guard.sh <commit> <out>`, `drivers/upgrade-path.sh <outdir>`.
