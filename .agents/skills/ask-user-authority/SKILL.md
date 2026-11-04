---
name: ask-user-authority
description: >-
  Single owner of ask-user finding and fix-round cap policy.
  Load before deciding any ask-user finding or fix-round cap escalation.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings and for the fix-round cap escalation.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Kinds the captain handed to firstmate

Before escalating a finding, name its kind from `bin/fm-scorebook.sh kinds`.
When `bin/fm-scorebook.sh granted <kind>` exits 0, the captain has said yes to handing that kind to firstmate: decide the finding yourself as you would have recommended, and do not escalate it.
Any other exit means the kind is still the captain's, so escalate it.
Only the captain's own yes to that specific kind may be recorded with `grant`; firstmate never grants itself a kind, and destructive, irreversible, and security-sensitive findings always escalate.
Each home keeps its own scorebook and grants, so a grant given in the main home does not apply in a secondmate home.
In the home that puts the finding to the captain, record it with `bin/fm-scorebook.sh ask` before sending it, passing the recommendation below, `--project <name>` for the reviewed project, and `--held <task-id>` only when a task held for the captain in this home carries it, otherwise `--question` with `--task <task-id>` for the reviewed task, and record whether the captain's answer matched it with `answer` once he gives it, adding his words with `--answer` for a `--question` record.
A secondmate home that escalates through its parent channel does not record the finding; the main home records it with `--question` when it asks the captain, because the task that carries it is held in the secondmate's backlog, never with `--held`.
When `answer` reports that a kind newly qualifies for hand-off, offer the captain that kind once in your next natural reply, citing its count, and record it with `grant` only on his yes.

## Fix-round cap

A `needs-decision` reading `fix-round cap rounds=<n>` means one validation step already took its capped fix rounds in one run, and the worker stopped instead of sending another fix; `bin/fm-nm-rounds.sh` owns what counts as a fix round and the cap's default of 3.
Firstmate never decides it alone, even when every finding in it looks in scope: review that keeps finding something after three fixes is evidence about the approach, not about any one finding.
Ask the captain whether to rethink the approach, approve the step as it stands, or allow more rounds, and name how many.
Lead with the step and the round count, and point at the escalation's rounds file for every round's findings verbatim, then each option's consequence and a recommendation.
The same-theme rule above still applies below the cap: a returning theme that preserves a questionable abstraction escalates at whatever round it appears.
`validation-supervision` owns relaying the captain's answer to the gate.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
