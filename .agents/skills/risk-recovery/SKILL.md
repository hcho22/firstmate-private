---
name: risk-recovery
description: >-
  Assess new or revised ship briefs and promoted scouts, hand off behavioral
  validation, and coordinate release obligations before implementation completion
  and on release observations or restart. Owns risk, evidence, and release policy.
user-invocable: false
metadata:
  internal: true
---

# Risk, recovery, and release

This is the single interpretation owner for the seven-field interface rendered by `bin/fm-dod-lib.sh` and the ordinary release task section rendered and checked by `bin/fm-release.sh`.
It extends the existing selected delivery owner, backlog, captain-call, and observation owners; it is neither a second review pipeline nor a deployment controller.

## Assessment and accepted scope

Fill the generated fields with concrete task facts before dispatch or promotion; a short sentence per field can suffice.
Intended behavior names the outcome; preserved behavior names existing guarantees and explicitly accepted changes; impact identifies users, callers, shared state, dependencies, data, and environments.
Validation names observable success and failure cases; recovery distinguishes containment from restoration and names limitations and success observations; release applicability states planned, deferred, or not applicable with a reason.
Use stable requirement names when several evidence items refer to a requirement, without imposing numbering or length on simple work.
A justified non-applicable field is valid; an unfilled or absent assessment is unassessed, never a low-risk verdict.

Classify low when effects are contained, sensitive shared state is absent, and recovery is straightforward; focus on concise behavioral evidence.
Classify medium for bounded integrations or understood state changes; examine affected callers and failure paths.
Classify high for shared infrastructure, permissions, sensitive data, broad effects, difficult recovery, or material uncertainty; name dependency and side-effect analysis, recovery limits, and the particular human judgment needed.
Neither diff size nor a new file establishes isolation, and a flag reduces risk only after containment is demonstrated.
Unknown impact is provisionally high; resolve it through bounded discovery inside accepted scope.
A risk label does not change delivery mode, authorize another reviewer, require a flag, or create a captain approval gate.
An isolated wording correction needs no runtime experiment or ceremonial release task.

The worker reports material planned-versus-actual impact discrepancies before dependent consequential work; unaffected authorized work can continue.
Use existing decision routing only when uncertainty could change whether or what to build or exceeds authority.
Reconcile accepted amendments into the current assessment and criteria, replacing superseded criteria and retaining unrelated constraints.
Preserve provenance: captain-authorized requirements go into captain intent through `bin/fm-dod-lib.sh`; Firstmate specification stays specification.
Promotion preserves accepted scout requirements and any existing assessment, then verifies it against the ship scope.
Never bulk-rewrite active briefs or reopen completed or landed work merely to adopt this convention.

## Selected validation owner

Establish the installed no-mistakes version and supported interfaces with its current help before handoff; do not infer local support from upstream documentation or install an upgrade.
Pass accepted captain requirements, including the substance of referenced requirements and current amendments, through the existing intent owner.
Supply the remaining accepted specification, scenarios, and evidence through supported pipeline configuration or a task-owned report that the pipeline can actually read.
When structured evidence input is unsupported, use the smallest report-based handoff and explicitly disclose that scenario linkage is reviewed by the selected owner, not machine-enforced by Firstmate.
Include public-safe accepted criteria directly in intent when authorized; a private report pointer inaccessible to the pipeline is not a completed handoff.
Never use evidence-import work as an implicit dependency or add an evidence database.
The no-mistakes worker keeps the same run and routes every ask-user finding through Firstmate; the pipeline owns subsequent fixes and reruns.
For direct-PR and local-only, the authorized task work supplies evidence and the mode remains unchanged; stronger review needs the existing mode decision.

For gated changes cover disabled, enabled, enable-then-disable, invalid/unavailable gate, and recovery behavior, explaining irrelevant categories rather than inventing tests.
Disabled means preserved control behavior and absence of unauthorized new requests, writes, jobs, telemetry, or other effects, including background activity behind a hidden interface.
Enable-then-disable must consider in-flight work, cached decisions, persisted state, and existing sessions.
An unavailable gate uses the established safe default without disabling an existing protective control.
A non-gated risky change instead verifies preservation and its applicable recovery method; do not introduce a flag solely for this contract.
A temporary flag names its responsible owner and a review/removal condition as follow-up work, never an automatic production action.

Each required scenario records requirement/name, expected and observed behavior, pass/fail/untested, evidence reference, and limitations, bound to revision/artifact, dependency and material configuration, environment, and observation time.
Screenshots support appearance; requests, interactions, recordings, logs, or state observations support behavior.
An absent device, permission, environment, or executable capability stays untested with its reason.
A failed required criterion remains failed; an approved exception names the exact criterion, candidate, environment, consequence, and approving instruction without converting failure to pass or authorizing a red merge.
Candidate, dependency, configuration, or environment changes require reviewing affected evidence and exceptions and rerunning only what no longer applies.
Successful containment does not restore earlier writes, queued work, or migrations; successful recovery needs an observed safe state, not an exit code or accepted request.
State irreversible and destructive restoration limits explicitly and preserve their existing approval boundary.
Validation authorization alone never grants production traffic changes or destructive experiments; prefer safe representative environments.
Keep sensitive evidence in authorized private storage; use synthetic data, redaction, or safe references that retain enough context to assess the claim.
PR and local landing summaries state material impact, evidence gaps, recovery, and specific human judgment proportionately, omitting private operational facts.

## Ordinary release tasks

Before closing implementation whose accepted scope includes production release, create or link the ordinary release task for its coherent candidate and environment, even when exposure is deferred.
Add relevant records before newly authorized exposure on older work.
Inspect existing tasks, including retained completed task references, before creating a task; reuse the same release identity on replay.
A release body contains all included implementation links; each implementation body records all participating release links as `home + task ID + candidate/environment`, not just a one-to-one blocker.
Keep links in the durable task bodies and completion history; they survive implementation teardown and archive pruning independently of a live worker.
Code-only work without a release obligation gets no release task.

Use `bin/fm-release.sh template` for the body section and `check` for a read-only consistency assessment; its help owns fields and command syntax.
Firstmate remains responsible for interpreting evidence and verifying authorization against the actual captain instruction or policy: strings, a checker verdict, and observations cannot confer authority.
The ordinary task body is authoritative; reports, summaries, and checker output are projections.
Read it before every update, archive a replaced considered body when needed, and preserve unrelated body content.
Use the configured backlog backend through `AGENTS.md` section 10 and `bin/fm-tasks-axi-lib.sh`: compatible tasks-axi uses its current add/update/hold/done interfaces; manual mode uses the existing inspect-then-edit backlog contract, not a hidden tasks-axi call.
Do not introduce new global states, a second task database, or automatic writes from the checker.
Session locks and task leases still govern all fleet mutations; this skill cannot override a refusal.

The section carries identity/ownership; included source revisions and actual artifact mapping; target environment and shared mutable resources; applicable functional, security/privacy, performance, UX, monitoring, and recovery checks; exposure stages; health sources, baseline, freshness/window/sample and stop criteria; containment/restoration and limitations; exact authority references; progress and pending action; and outcome.
A merged PR alone does not identify what runs; verify the deployed artifact or source-to-artifact mapping before exposure.
Resource names must be canonical within the target environment and shared across projects when the actual flag/service/migration is shared.
Use one authoritative coordinating home for each shared resource; route other-home release work there and use existing task dependencies to serialize conflicting work.
Within that home reserve affected resources in the task's pending action before acting, under the existing session/task-lease discipline, and inspect all open peer tasks for conflicts.
Independent resources can progress concurrently; a release-wide global mutex is unnecessary.
If a conflicting actor cannot be coordinated, pause instead of asserting exclusivity.

## Progress and actions

Phases are facts inside the body, separate from the ordinary queued/in-flight/blocked/held/done lifecycle:

| Phase | Meaning |
| --- | --- |
| Preparing | Gather candidate, readiness, plan, evidence, and authority. |
| Ready | Applicable readiness criteria satisfied or explicitly excepted; wait for any missing action authority. |
| Deployed, unexposed | Optional verified deployment with disabled exposure. |
| Observing | Verify current stage exposure and collect its specified observations. |
| Expansion ready | Prior stage criteria passed; the next action still needs scoped authority. |
| Paused | Advancement stopped; record the reason, retained exposure, and next action. |
| Recovering | Authorized containment/restoration in progress; verify its actual result. |
| Released | Final planned exposure verified and final observation criteria met. |
| Stopped | Cancelled or withdrawn with verified final condition and accurate disposition. |

Platforms that deploy and expose together go from Ready to Observing after the authorized action.
Merge authority, including yolo, never grants deployment, expansion, destructive recovery, or irreversible data operations.
A bounded approved plan can cover several stages without asking again, but its candidate, environment, actions, targets, expiration/conditions, and limitations must still match.
Before an external action record a stable operation identity, intended target, resource reservation, and pending outcome in the ordinary body.
Then use project-owned commands/providers; this checker executes nothing and cannot authenticate external evidence.
After the action, observe actual external state and durably record the result before releasing the reservation or acknowledging the wake.
On restart reconstruct candidate, configuration, phase, authority, current exposure attempt, last observation, and pending action from the body and reverify volatile external facts.
If the command result is ambiguous, keep the reservation and reconcile actual state before any retry; retry only when provider semantics establish idempotency or observation proves the action never occurred.
Duplicate observations/wakes and completed operation identities are no-ops for effects; do not mistake wake acknowledgement for exactly-once external execution.

Use existing registered checks or process-event sources for observation; load `process-event-sources` before arming or handling them and preserve its durable acknowledgement and retirement contract.
Register the source under the release obligation rather than the implementation worker, so teardown cannot remove its monitor.
A bounded observation has a deadline; arrange an existing registered check to surface silence/monitoring loss as unknown by that deadline.
Missing, stale, wrong-candidate/environment/configuration, future-dated, or malformed observations are unknown and prevent advancement, never automatically authorize destructive rollback.
Measure freshness from the end of the measurement window; reporting cached measurements again does not renew their validity.
Bind each health observation to the verified exposure attempt recorded in the task using the fields owned by `bin/fm-release.py`.
Every exposure or stage advancement starts a distinct attempt identified by its action and verified external start time, even when the candidate and cohort repeat.
Measurements must cover only that attempt; never relabel a prior observation to renew its applicability.
Restart alone preserves the reconciled attempt and its eligible observations; an uncertain action result still requires external-state reconciliation before continuation.
An incomplete window or insufficient usage cannot pass; an accepted manual-scenario alternative must be recorded before use and cannot lower criteria mid-release.
Stop conditions halt expansion and notify the changed condition, consequence, and needed action; execute containment only if that exact action is authorized and safe under existing boundaries.
Unchanged healthy observations stay quiet unless periodic reporting was requested; record the last notified condition in the body for restart/replay suppression.

Before terminal completion verify final exposure, final health evidence (or the observed safe withdrawn/cancelled state), recovery disposition, and watch retirement through its owner.
Bind final-state evidence to the current candidate and material plan, including the environment, and record the actual verification time using the outcome fields owned by `bin/fm-release.py`.
Cancellation before exposure needs current safe-state verification but does not require a rollout-stage observation; older outcomes remain readable and need verification before completion.
A failed recovery remains Recovering or Paused; attempted rollback is not Stopped or Released.
Distinguish successful release, cancellation before exposure, and verified withdrawal explicitly in the outcome.
Load `captain-hold-lifecycle` for genuine unresolved captain calls; preserve them through completion, never close them merely because implementation finished.
Use existing holds and supervision for observation waits; the implementation worker need not remain idle and live.
Retiring or reverting this convention retains active obligations and evidence and explicitly hands ownership off through ordinary tasks; a code revert does not restore persistent data.

## Development evaluation

Keep deterministic CI independent of live credentials, production, and model calls; emitted briefs are an interface test, not proof of agent understanding.
Before adoption evaluate a contained and a shared-state change, then observable gated behavior with intentional leakage, persistent effects and missing capability, then a bounded local rollout with actual installed task and registered observation commands.
Exercise monitoring loss, duplicate delivery, restart with ambiguous effects, resource conflicts, and failed recovery before relying on stage autonomy.
Keep the plan and transcripts in the private task report with candidate/environment, permitted actions, stage/window/freshness/sample criteria, stop/recovery verification, and requirement-to-evidence mapping.
Record all applicable brief fields, every scenario result or untested reason, surviving release links, out-of-authority and duplicate action counts, unknown-as-healthy count, preparation/validation duration, captain interruptions, and specific gaps caught.
Compare contained and shared-impact overhead before setting a numeric budget; small pilots do not establish production defect reduction.
