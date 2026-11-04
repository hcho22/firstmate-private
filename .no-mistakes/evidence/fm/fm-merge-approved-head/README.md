# Live validation: an attended merge is bound to the head the captain approved

## Round 2 (target 0f59e9ce): everything below in round2/

Round 2 re-drove every round-1 scenario at the new target, which wraps the merge card's head under the PR link and fixes the count plurals.
Every live run used a disposable marked lab home (bin/fm-lab-home.sh), removed at the end of its run.
`gh` was drivers/gh-write-guard.sh throughout: reads reach real GitHub, writes are refused and logged as BLOCKED-WRITE.

### The fixed round-1 failure: the merge card keeps the PR number legible (round2/board/)
- b02: Lavish at a 1440px window with the conversation panel open, so the board iframe is 1080px wide, the width that clipped the link in round 1.
  The card now shows the full `https://github.com/hcho22/firstmate-private/pull/24`, with `head 9182211` on the line below.
- b03: measured in headless Chrome at board widths 1440, 1080, 768 and 500.
  The link needs 398px and gets 398px at every width (never clipped).
  The head sits beside the link when both fit (1440, 768) and wraps under it otherwise (1080, 500).
- b04: screenshots of the one-line (1440) and wrapped (500) layouts.

### The board's answer path, driven in a real browser against real lavish-axi (isolated state dir, port 4792, no auto-open)
- b01: build reads each merge card's live head from GitHub, drops the card whose PR has no task record, and records no approved head.
- b05-b08: the captain selects Merge now and queues and sends the answer.
  The board's real listener captures it, `fm-procevent-lavish.sh heads` prints the card's full head, the handler records it, and the real fm-pr-merge.sh hands `gh pr merge --match-head-commit 91822114...` to the forge (blocked by the guard).
- b09: a chat ask records an older head for PR #22, then the board is rebuilt.
  The rebuild leaves approved_head unchanged, and the merge refuses: "1 commit between the heads, 1 not on main" (singular now).
- b10: the captain then clicks the PR #22 card, which shows the live head.
  The click's head replaces the chat-recorded head, and the merge proceeds at the card's head.

### Real git catch-up rules (round2/catchup/, drivers/live-catchup.sh and drivers/live-catchup-singular.sh)
- Pass: c01 unchanged, c02 "(2 commits from main, 1 clean merge commit)", c03 "(2 commits from main, 2 clean merge commits)", c11 "(1 commit from main, 1 clean merge commit)".
- Refuse: c04 CI-fix commit ("1 commit between the heads, 1 not on main"), c05 hand-resolved conflict, c06 evil merge, c07 rebase plus force-push, c08 octopus, c09 head moved while verifying, c10 task worktree gone.

### Real GitHub (round2/github/) and secondmate parent channel (round2/secondmate/)
Same drivers and outcomes as round 1, re-run at 0f59e9ce: g01-g10 and s01-s06 (see round2/github-run.txt and round2/secondmate-run.txt).

### Supporting automated tests (not live)
round2/automated-approved-head-cases.txt: tests/fm-pr-merge.test.sh exit 0, including the singular-count assertions this commit added.
It also includes tests/fm-bearings-board-render.test.sh, which exits 0 with jq 1.7.1.
With the host's anaconda jq 1.6 first on PATH, one charted-order case prints `not ok - the board did not build` and then a vacuous ok; that is a pre-existing host issue unrelated to this change.

### Real PRs
round2/zz-real-prs-unchanged.txt: PR #24 is unchanged.
PR #22 was merged at 00:41:35Z by the operator's own fleet (task fm-review-round-cap), after this validation's guarded and refused attempt and after its lab was torn down.

## Round 1 (target a71801c8)

Change: fm/fm-merge-approved-head (base 30a79894, target a71801c8).
Every live run used a disposable marked lab home (bin/fm-lab-home.sh), removed at the end of its run.

### Real GitHub (github/)
Driver: drivers/live-github.sh.
The real bin/fm-pr-check.sh, bin/fm-approved-head.sh and bin/fm-pr-merge.sh ran against https://github.com/hcho22/firstmate-private/pull/24 (green CI), and the task worktree was a real clone.
`gh` was drivers/gh-write-guard.sh: every read goes to real GitHub, and every write is refused, so no PR was ever merged or changed (see zz-real-prs-unchanged.txt).
A run that reached `gh pr merge` shows a BLOCKED-WRITE line where the real merge would have happened.

- g01 registers the PR; g02 records the head the presentation shows (approved_head is written before pr=).
- g03 merges at the approved head: verify passes, the GraphQL isMergeQueueEnabled read (owner/repo sent as raw strings) is false, and the merge is handed to `gh pr merge --match-head-commit`.
- g04: a head-bound merge with --auto is refused before any forge write.
- g05: the head the captain saw was 617baf6f, and two commits were pushed after it. The merge is refused, naming each commit and giving the record command. The clean merge-from-main commit 1975388c is not flagged.
- g06: after the PR is presented again at the refused head, the merge proceeds.
- g07: an approved head that is not an ancestor (rewritten history) is refused.
- g08: no recorded head is refused. g09: a head recorded for a different PR counts as none and is refused.
- g10: a yolo task with no recorded head proceeds unbound.

### Real git catch-up rules (catchup/)
Driver: drivers/live-catchup.sh.
These cases use a real origin that serves refs/pull/7/head, a cloned task worktree, and the real `fm-approved-head.sh record` and `verify`.
Pass: c01 unchanged head, c02 an automatic catch-up merge with main, and c03 two catch-ups in a row.
Refuse: c04 a CI-fix commit, c05 a hand-resolved conflict merge, c06 a catch-up merge amended with an extra file, c07 a rebase plus force-push, c08 an octopus merge, c09 a head that moved while being verified, and c10 a missing task worktree.

### Secondmate parent channel (secondmate/)
Driver: drivers/live-secondmate.sh.
This uses real GitHub with the write-guard: a parent lab home, plus mate homes bound to it with route=local.
- s01: the child's ready line carries head=.
- s02/s03: a relayed word at that head reaches the forge, and the channel gains no new line.
- s04-s06: a relayed older head is refused, and only that refusal publishes the ready line at the live head.

### Bearings board in a real browser (board/)
This used the real fm-bearings-board.sh build, real lavish-axi (isolated state dir, port 4791, no auto-open), and an isolated headless Chrome (chrome-devtools-axi session fm-lab-board).
- b01: the build reads each merge card's live head, drops the card whose PR has no task record (dropped-unbound-merge-card), and records no approved head.
- b02: screenshot of the card showing "head 9182211". b03: screenshot of "Merge now" selected. b04: screenshot of the queued answer carrying the full head.
- b05: the board's real listener captured the click. `fm-procevent-lavish.sh heads` prints merge.bd-24 with 91822114..., recording it binds the merge, and verify passes.
- b06: a chat ask recorded be1c87da for PR #22, and the board was then rebuilt. The rebuild left approved_head unchanged, and the merge refused, naming the commit pushed after the chat ask.
- b07: before/after at 1080px, the board's width in Lavish with the conversation panel open. The base template shows ".../pull/24". With this change the head label clips the link to ".../pu...", hiding the PR number.

### Automated tests run as supporting evidence (not live)
- automated-fm-pr-merge-approved-head-cases.txt: 32 approved-head and queue cases from tests/fm-pr-merge.test.sh, all ok. They cover the GitLab/Forgejo binding, the classic-protection queue, and queued-outcome refusals with a stubbed forge.
- automated-bearings-board-tests.txt: tests/fm-bearings-board.test.sh and tests/fm-bearings-board-render.test.sh, exit 0.
