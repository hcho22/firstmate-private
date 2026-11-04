---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A `forge=external` task reports `done [at=<epoch>]: review <url> uploaded for review` instead: run `bin/fm-review-check.sh <id> <review url>` rather than `bin/fm-pr-check.sh`, which arms no merge watch, then always escalate the review URL to the captain whatever the yolo setting, because firstmate can neither observe nor perform its approval or merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` and a project's low-risk merge tier are the only standing routine merge authority.
When neither a captain instruction nor `yolo` covers a green, in-scope PR, run `bin/fm-pr-merge.sh <id> <PR url> --low-risk` once, unless the captain asked to see that change or it is destructive, irreversible, or security-sensitive.
It merges only when the project declares a tier and every file the PR changes is low risk; a tier refusal names its cause, such as the files outside the tier, and turns the ready PR into the usual merge ask, with those files named for the captain.
When the message to the captain asks for the merge word, first run `bin/fm-approved-head.sh record <id> <PR url>` and name the short head it prints in the message, because the word covers only the head it was given at.
An attended `bin/fm-pr-merge.sh` merges only that head or a clean catch-up of it with the base branch; when it refuses because the head changed, tell the captain what changed, record the head the refusal names with the command it prints, and ask again at that head.
That merge must land at once, so `bin/fm-pr-merge.sh` refuses `--auto`, a merge queue, and GitLab auto-merge for it; wait until the checks are green and merge then.
When it refuses because no head is recorded, present the PR to the captain again and record the head you show; never record a head the captain was not shown.
A secondmate child's PR has no task record in the main home: present it at the head its `child <id> PR ready:` line carries in `head=`, and relay the captain's merge word to that secondmate together with the full head shown in the presentation the captain answered, never simply the newest `head=` on the channel.
A newer ready line for the same child means presenting the PR again at its head before relaying any merge word.
Known limitation for secondmate children: the main home records no head for a child's PR, so a word given while a newer head is still unpresented binds to the right head only because the main firstmate reads which head its own presentation showed.
In a secondmate home, a relayed merge word names the head the captain was shown, so record exactly that head with `bin/fm-approved-head.sh record <id> <PR url> <head>` before merging; a later push then still refuses, and that refusal publishes a new ready line with the live head, which is what the main firstmate presents again.
The merge's own registration publishes no ready line, so a merge that proceeds tells the parent only that it merged.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
