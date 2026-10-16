# Test round 3: committed head be2e771, real tmux and real Herdr, real treehouse

Code under test: the committed head be2e771 (the worktree, clean).
"base" runs used the tree of dd5a411 extracted with `git archive` into a temp dir that is now removed.
Driver: `live-treehouse-wait.sh` (copied from round 1) runs the real `bin/fm-spawn.sh` and `bin/fm-teardown.sh` with the REAL treehouse v3.1.0 against a private tmux server or an isolated Herdr 0.7.5 lab session.
A git post-checkout hook, which treehouse runs inside `git worktree add` while it holds the pool lock, stands in for a slow copy.
Time is real: no sleep shim, and `FM_TREEHOUSE_GET_*` stay at their defaults unless a run name says otherwise.
Variants: `live-treehouse-wait-busy.sh` adds a fork-free CPU-busy hook, `live-treehouse-wait-side.sh` adds side work during a slow get, `live-treehouse-wait-order.sh` is the teardown-order control.

## The reported failure: a copy slower than 60s

| Run | Code | Result |
| --- | --- | --- |
| `s1-tmux-base-slow100` | base | refused after 69s: `treehouse get did not enter a worktree within 60s` while the copy was still working |
| `s1-tmux-head-slow100` | head | launched after 116s (hook 02:00:49-02:02:39); `pane_current_path` is the recorded worktree and runs the agent; teardown ok |
| `s2-herdr-base-slow100-projected` | base | reported `spawned` after 7s while the copy was still running: the pane shows `Setting up worktree...` followed by the typed-ahead launch lines |
| `s2-herdr-head-slow100-projected` | head | launched, projected (w2), after 118s, 5s after the hook ended; the pane shows `Entered worktree` before the launch lines |
| `s11-herdr-base-queue2-sephomes` | base | the projected spawn queued on the pool lock was refused after 77s with the 60s message plus `herdr presentation cleanup could not verify` |
| `s11-herdr-head-queue2-sephomes` | head | both queued projected spawns launched, at 117s and 221s |

## Eight-way concurrency on one pool (the intent's shape)

| Run | Code | Result |
| --- | --- | --- |
| `s3-herdr-head-queue8-samehome` | head | 8 of 8 launched, projected (w2-w9), at 33s to 149s; every teardown ok |
| `s3-herdr-base-queue8-samehome` | base | q4 refused at 0s (`this home's task set is locked by another operation`); the rest reported `spawned` within 8-27s of starting |
| `presentation-*` | head and base | concurrent copies of the real-Herdr presentation e2e (real treehouse), the suite where the original 60s refusal was seen; see the next section |

## Refusals stay bounded and truthful (head)

| Run | Result |
| --- | --- |
| `s5-tmux-head-hang-stall30` | refused after 33s: `made no progress for 30s (waiting on: sleep 86400)` |
| `s6-tmux-head-queuehang-stall30` | holder refused after 33s; the get queued behind it refused after 33s naming the holder: `pid 14738 (treehouse get)` |
| `s7-tmux-head-ceiling45-slow100` | still-advancing copy refused at the ceiling: `still not settled in a worktree after 45s (last running: sleep 1)` |
| `s8-herdr-head-fail-projected` | refused after 16s: `exited without entering a worktree`; its projected workspace w2 is gone, no meta, no journal, no warning, focus stayed on w1 (call log) |
| `s9-tmux-head-cpuonly75-stall20` | a copy that only spends CPU (no new process) for 75s launched after 80s under a 20s stall bound |
| `s10-herdr-head-slowfail20` | refused after 38s; the call log shows no `export`/launch call to the failing pane w2:p2; no meta, no journal |
| `s10-herdr-base-slowfail20` | base typed the launch into w2:p2 5s in while the hook ran; after the hook failed `sleep 600` ran with cwd = the primary checkout |
| `s10-tmux-head-slowfail20` | refused after 36s, same message |

## Side work during a slow get (head)

`s4-herdr-head-side90`: while a projected get worked for about 98s, a fresh dispatch of another project in the same home and Herdr session launched in 10s, and a teardown on the same session got past its presentation lock and waited 87s in `treehouse return` behind the get's pool lock, then completed.
The slow spawn then launched at 111s.

Its final teardown of the slow task exited 1 with `herdr presentation cleanup target is the captain's active tab; refusing a close that cannot preserve focus`.
That is pre-existing and comes from the driver's order, not this change: `x1-herdr-base-teardown-order` and `x1-herdr-head-teardown-order` (no concurrency) refuse identically on base and head once the warm-up task, the only pane of the lab's `firstmate` workspace, is torn down first and focus moves to the next task's workspace.
In a real fleet the captain's own pane keeps that workspace alive.
The `s11-*` runs end with the same refusal for the same reason, on base and head alike.

## Concurrent real-Herdr presentation e2e (the suite named in the intent)

| Folder | Copies at once | Result |
| --- | --- | --- |
| `presentation-8way/` | 8 head (be2e771 as committed) | 6 passed; `copy-5` failed `fm-hibit-resume-r1 reclaim flattened into a different workspace`, `copy-7` failed `flat cross-home contention fixture teardown failed`; neither assertion printed the stderr it had captured, and the test removes its temp root, so the cause was lost |
| `presentation-4v4/` | 4 head + 4 base, both with the stderr diagnostics added | 8 of 8 passed (load average up to about 40) |
| `presentation-8way-r2/` | 8 head with diagnostics | 8 of 8 passed (load average up to about 50) |
| `presentation-8v8/` | 8 head + 8 base with diagnostics | 16 of 16 passed (load average up to about 290) |

No copy, head or base, was refused by the treehouse get wait.
Head passed 26 of 28 copies and base 12 of 12; the two round-one failures did not recur in 20 later head copies.
The six teardown and reclaim assertions that dropped their captured stderr now print it, so the next occurrence names its cause.

## Suites

- `e2e-herdr-treehouse-wait.log`: real-Herdr treehouse wait e2e 10/10 on be2e771, run while the live drivers loaded the host (skipped by the baseline's real-herdr-gated exclusion).
