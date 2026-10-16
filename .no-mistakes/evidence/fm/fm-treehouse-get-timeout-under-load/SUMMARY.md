# Live validation: treehouse get wait under load

Driver: `live-treehouse-wait.sh` runs the real `bin/fm-spawn.sh` and `bin/fm-teardown.sh` against a real tmux server on a private socket or a real isolated Herdr lab session (Herdr 0.7.5).
It uses the REAL `treehouse` binary (v3.1.0) on a throwaway project whose pool lives in a temp dir.
The project's git post-checkout hook, which treehouse runs inside `git worktree add` while it holds the pool lock, stands in for slow copy work.
Time is real: no sleep shim, and FM_TREEHOUSE_GET_* stay at their defaults unless a run name says otherwise.
Base runs use the tree of dd5a411 extracted with `git archive`.

## Reproduction and fix

| Run | Code | Result |
| --- | --- | --- |
| `s1-tmux-base-slow100` | base | refused after 69s: `treehouse get did not enter a worktree within 60s` while the copy was still working |
| `s1-tmux-head-slow100` | head | launched after 116s (the 100s hook took 110s of wall time); agent runs in the recorded worktree; teardown returns it |
| `s2-herdr-base-queue2-sephomes` | base | projected spawn queued on the pool lock refused after 78s with the same 60s message |
| `s2-herdr-head-queue2-sephomes` | head | same spawn launched, projected, after 111s; the other home's teardown then waited 108s behind the get in `treehouse return` and completed |

## Concurrency at default bounds (same home, one pool)

| Run | Result |
| --- | --- |
| `s5-tmux-head-queue3-samehome` | 3 of 3 launched at 84s, 157s, 230s; the third sat queued about 150s with no progress of its own (stall default 120s) |
| `s5-herdr-head-queue3-samehome` | 3 of 3 launched, projected, at 13s, 82s, 153s |
| `s8-tmux-head-queue8-samehome` | 8 of 8 launched; q6 to q8 queued 107s to 145s with no progress of its own, across 7 pool-lock handoffs |
| `s8-herdr-head-queue8-samehome` | 8 of 8 launched, projected; every teardown succeeded |

## Refusals

| Run | Result |
| --- | --- |
| `s3-tmux-head-fail` | refused after 13s: `treehouse get exited without entering a worktree` |
| `s3-herdr-head-fail-projected` | refused after 17s with the same message; the projected workspace was removed (see the call log) |
| `s3-herdr-base-fail-projected` | base waited 74s and refused with the 60s message |
| `s4-tmux-head-hang-stall30` | stall 30s: refused after 35s, `made no progress for 30s (waiting on: sleep 86400)`; Go runtime noise in the real treehouse did not mask the stall |
| `s6-tmux-head-queuehang-stall30` | the holder was refused as stuck; the queued get was refused naming the stuck holder: `pid 8812 (treehouse get)` |

## Pre-existing issues seen (same at base)

`s7-herdr-head-slowfail20` and `s7-herdr-base-slowfail20`: on Herdr, `foreground_cwd` follows a hook running in the new worktree, so the settle rule accepts the worktree while `treehouse get` is still running.
The spawn reports `spawned ... worktree=<slot>`, then the hook fails, and the typed-ahead agent command runs in the PRIMARY checkout (`sleep 600` with cwd at the project).
`s7-tmux-head-slowfail20` refuses the same case correctly.

`s3-herdr-*-fail-projected`: abort cleanup removes the projected task pane and workspace, then reads the seeded default pane that creation already pruned, warns `could not verify the exact pane`, and leaves `state/<id>.herdr-presentation` behind.

## Existing suites driven

- `herdr-treehouse-wait-e2e.log`: 9 of 9 on real Herdr (skipped by the baseline's real-herdr-gated exclusion).
- `herdr-presentation-e2e.log`: all cases on real Herdr, including the changed concurrent-abort assertion (skipped by the baseline too).
- `spawn-treehouse-wait-tmux.log`: 13 of 13 on real tmux.
- `secondmate-safety.log`: includes the forced-teardown refusal while a spawn is in flight.
