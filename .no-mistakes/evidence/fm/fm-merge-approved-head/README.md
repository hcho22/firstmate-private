# Live validation: a merge is bound to the head the captain approved, attended and away (target 0ced86d6)

This round re-drives the change at the target that adds the three review commits since the last validated round (0f59e9ce):
- 3d27b5cf binds an away-posture merge to a head recorded for the pull request.
- 86f2f0b9 gives an away refusal a hold-for-return remedy.
- 0ced86d6 makes a failed read ask for a retry instead of asking for the captain.

Every live run used a disposable marked lab home (bin/fm-lab-home.sh), and each was removed at the end of its run.
The away posture was always entered with the real `bin/fm-afk-contract.sh enter --words ...`, and the captain's return used the real `archive`.
`gh` was drivers/gh-write-guard.sh throughout, so every read reached real GitHub and every write was refused and logged as BLOCKED-WRITE.
The real fixture PR was https://github.com/hcho22/nodebase/pull/2 (open, CLEAN, MERGEABLE, head fcabedcb, one commit on top of main 4d2a6261).
Recording 4d2a6261 as the approved head stands in for "the captain was shown the PR before the worker pushed fcabedcb".
This branch's own PR #25 is CONFLICTING, so a merge of it would refuse at the mergeability check before reaching the head binding.
zz-real-prs-unchanged.txt shows that both PRs were unchanged afterwards.

## Away posture against real GitHub (away-github/, drivers/live-away-github.sh)
- a01: away, no head recorded: "merging under away authority, bound to no head", and the merge reaches `gh pr merge --match-head-commit fcabedcb` (blocked).
- a02: away, with a head recorded only for another PR (pull/1): this counts as none, so the result is the same as a01.
- a03: away, with the captain-approved head 4d2a6261 recorded: refused, naming the pushed commit, with "the captain is away, so hold the merge for the captain's return ... record that head now ... only when the captain's away words explicitly cover it". There was no forge write.
- a04: away, with the verify fetch failing (origin unreachable): "nothing between the heads was judged, so the merge can be retried once that read succeeds". There was no hold-for-return text and no forge write.
- a05: the captain's away words are replaced with "merge nodebase PR 2 once the worker's fix lands, at whatever head it is then". The away session records the head the a03 refusal named, and the away merge then proceeds bound to it ("is the captain-approved head", blocked at the forge).
- q01/q02: after the captain's return (archive), the same older head refuses with the attended "present the pull request to the captain again" remedy, and a fetch failure gives the retry remedy.
- q03/q04: quiet mode is a present captain. A PR with no recorded head refuses as an attended merge does, and the older head refuses with the attended remedy.

## Captain returns in the middle of an away merge (return-mid-merge/, drivers/live-return-mid-merge.sh)
- r01: drivers/gh-return-mid-merge.sh runs the real `fm-afk-contract.sh archive` at the merge's base-branch read, which is just before the first approved-head verify.
  The pre-lock verify ran away ("bound to no head").
  The verify under the lock then ran attended and refused: "no captain-approved head is recorded".
  There was no forge write.

## Real git catch-up rules under --away (away-catchup/, drivers/live-away-catchup.sh)
- c01: an away clean catch-up with main passes (exit 0).
- c02 (CI fix), c03 (rebase plus force-push) and c04 (hand-resolved conflict) refuse with exit 1 and the hold-for-return remedy.
- c05 (head moved while verifying) and c06 (origin unreachable) return exit 4 with the retry remedy; c06b is the same verify passing once origin is back.
- c07: the task worktree is gone, which is not transient, so it keeps the hold-for-return remedy (exit 1).
- c08 to c10 are the attended contrasts: a moved head gives exit 4 with the retry remedy, a CI fix gives exit 1 with the re-present remedy, and a clean catch-up gives exit 0.

## Secondmate parent channel (secondmate/, drivers/live-secondmate-retry.sh)
Each child home registered its PR before it was bound to the parent, so its channel started empty.
- s03/s08: a retry-only refusal (failed fetch), attended and away, publishes nothing (0 -> 0).
- s04/s09: a refusal that needs the captain again, attended and away, publishes the child's PR-ready line at head=fcabedcb (0 -> 1).

## Bearings board in a real browser, then an away merge (board/, drivers/live-board-away.sh, drivers/board-handler-away-merge.sh)
These steps used the real fm-bearings-board.sh build, a real lavish-axi isolated by its state dir and port 4793, and an isolated headless Chrome (session fm-lab-board-r3) at a 1440px window (board iframe 1080px).
- b01: the build records no approved head.
- b02: the merge card shows "head fcabedc" beside the full PR link.
- b03/b04/b05: the captain selects Merge now, queues the answer, and sends it to the agent.
- b06: the real listener captured the answer, `fm-procevent-lavish.sh heads` prints merge.bd-nb with fcabedcb..., and the handler records it.
  The captain then goes away, and the away merge is verified at the captain-approved head and handed to `gh pr merge --match-head-commit fcabedcb` (blocked).
- Cosmetic, outside this repo: Lavish's own conversation panel does not wrap the answer's 40-character "head" value, so it runs past the bubble's right edge (b04, b05). Round 2's b06 showed the same.

## Supporting automated tests (not live)
automated-approved-head-and-away-cases.txt: these are the 23 approved-head, away and quiet cases from tests/fm-pr-merge.test.sh, run from a temporary copy that lists only those cases. The run exited 0.
