#!/usr/bin/env bash
# Live driver: exercise bin/fm-scorebook.sh the way firstmate does, in a
# disposable lab home (bin/fm-lab-home.sh), against the real
# bin/fm-captain-hold.sh and the real tasks-axi on PATH. Prints a transcript of
# every command, its output, and its exit code. Removes the lab on exit.
# Usage: scorebook-live.sh <worktree>
set -u
WT=${1:?worktree}
cd "$WT" || exit 1
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOME; do unset "$v"; done

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
GITLAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-git.XXXXXX")
trap 'rm -rf "$LAB" "$GITLAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
# A real firstmate home carries its tasks-axi config at its root.
cp .tasks.toml "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
export FM_HOME="$LAB"

SB="$WT/bin/fm-scorebook.sh"
CH="$WT/bin/fm-captain-hold.sh"
run() {  # <label> <cmd...>
  local rc=0 out
  printf '\n$ %s\n' "${*:2}" | sed "s#$WT/bin/#bin/#g; s#$LAB#\$LAB#g"
  out=$("${@:2}" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed "s#$LAB#\$LAB#g"
  printf '[exit %s] %s\n' "$rc" "$1"
  LAST_RC=$rc
  LAST_OUT=$out
}
section() { printf '\n==== %s ====\n' "$*"; }
words() { printf '%s\n' "$2" > "$LAB/$1"; printf '%s' "$LAB/$1"; }

printf 'tasks-axi %s, jq %s, lab home %s\n' "$(tasks-axi --version)" "$(jq --version)" "\$LAB (bin/fm-lab-home.sh create)"

section "S0 kinds: which kinds can be handed off"
run "kinds" "$SB" kinds

section "S1 chat question: record, captain picks differently, report"
run "ask chat" "$SB" ask --kind design --recommend "Postgres" --question "Postgres or SQLite for the cache index?" --project sample
CHAT1=$LAST_OUT
run "pending lists it with recommendation" "$SB" pending
run "answer without his words is refused" "$SB" answer "$CHAT1" --matched no
run "answer with his words" "$SB" answer "$CHAT1" --matched no --answer "SQLite, keep it simple."
run "answer twice is refused" "$SB" answer "$CHAT1" --matched yes --answer again
run "report" "$SB" report
printf '\nrecord lines for %s:\n' "$CHAT1"
jq -c "select(.id == \"$CHAT1\")" "$LAB/data/captain-scorebook.jsonl"

section "S2 held question: hold task, ask --held, answer gated on the captain's recorded words"
run "ask --held on a task absent from this home" "$SB" ask --kind finding-design --recommend "keep the queue" --held queue-shape
run "hold the task for the captain" "$CH" hold queue-shape --title "Pick the queue shape" --reason "captain picks the queue shape: FIFO or priority" --repo sample
run "ask --held" "$SB" ask --kind finding-design --recommend "FIFO" --held queue-shape --project sample
run "second open question on same task refused" "$SB" ask --kind finding-design --recommend "x" --held queue-shape
run "further question on the held task as chat" "$SB" ask --kind design --recommend "ship now" --question "Ship now or after the retry work?" --task queue-shape
FURTHER=$LAST_OUT
run "pending shows task and recommendation" "$SB" pending
run "answer before the captain's words are on the task is refused" "$SB" answer queue-shape --matched yes
words decision.txt "FIFO. Ship now." >/dev/null
run "captain answers via fm-captain-hold.sh answer" "$CH" answer queue-shape --decision-file "$LAB/decision.txt"
run "--answer on a held question is refused" "$SB" answer queue-shape --matched yes --answer "FIFO."
run "scorebook answer held question" "$SB" answer queue-shape --matched yes
run "scorebook answer further chat question" "$SB" answer "$FURTHER" --matched yes --answer "Ship now."
run "ask --held on the closed local task says hold it first" "$SB" ask --kind finding-design --recommend r --held queue-shape
run "pending now empty" "$SB" pending
printf '\ncaptain words appear in scorebook record: %s\n' "$(grep -c 'FIFO. Ship now.' "$LAB/data/captain-scorebook.jsonl" || true)"

section "S3 release and re-hold: earlier answer still lands"
run "hold work item" "$CH" hold build-queue --title "Build the queue" --reason "captain picks retry count" --repo sample
run "ask --held" "$SB" ask --kind finding-scope --recommend "retry twice" --held build-queue
words rel.txt "Retry twice." >/dev/null
run "captain answers with --release" "$CH" answer build-queue --decision-file "$LAB/rel.txt" --release
run "re-hold for a new question before scorebook answer" "$CH" hold build-queue --reason "captain picks the backoff"
run "scorebook answer for the first question is accepted" "$SB" answer build-queue --matched yes
run "ask --held second question" "$SB" ask --kind finding-scope --recommend "exponential" --held build-queue
run "second question refused while its call is open" "$SB" answer build-queue --matched no

section "S4 adversarial: expired --until deferral re-held without an answer"
run "hold" "$CH" hold pick-cache --title "Pick the cache" --reason "captain picks the cache" --repo sample
run "ask --held" "$SB" ask --kind finding-design --recommend "no cache" --held pick-cache
run "identity at ask" "$CH" open pick-cache --identity
ID_ASK=$LAST_OUT
sleep 2
run "captain says later (until a past date)" "$CH" hold pick-cache --reason "captain said later" --until 2000-01-01
sleep 2
run "captain says later again on the expired deferral" "$CH" hold pick-cache --reason "captain said later again" --until 2000-01-02
run "identity now" "$CH" open pick-cache --identity
ID_NOW=$LAST_OUT
printf 'identity changed: %s -> %s\n' "$ID_ASK" "$ID_NOW"
run "answer is refused: captain never answered" "$SB" answer pick-cache --matched yes
words cache.txt "No cache." >/dev/null
run "captain answers" "$CH" answer pick-cache --decision-file "$LAB/cache.txt"
run "answer now accepted" "$SB" answer pick-cache --matched yes

section "S5 moot call withdrawn never counts"
run "ask" "$SB" ask --kind finding-scope --recommend r --question "Moot one?"
MOOT=$LAST_OUT
run "withdraw" "$SB" withdraw "$MOOT" --reason "premise was false"

section "S6 threshold, one-time announcement, grant only on the captain's yes"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  id=$("$SB" ask --kind finding-repeat --recommend "fold into one helper" --question "repeat finding $i?")
  out=$("$SB" answer "$id" --matched yes --answer "yes, as you said ($i)" 2>&1); rc=$?
  printf 'answer %2d [exit %s] %s\n' "$i" "$rc" "${out:-(no announcement)}"
done
run "report shows qualifies" "$SB" report
run "granted before the captain's yes" "$SB" granted finding-repeat
run "grant without words is refused" "$SB" grant finding-repeat
: > "$LAB/empty.txt"
run "grant with empty words is refused" "$SB" grant finding-repeat --captain-words-file "$LAB/empty.txt"
words yes.txt "Yes - decide repeated review findings yourself from now on." >/dev/null
run "grant with captain's yes" "$SB" grant finding-repeat --captain-words-file "$LAB/yes.txt"
run "granted after yes" "$SB" granted finding-repeat
run "other hand-off kind not granted by it" "$SB" granted finding-scope
run "report shows granted" "$SB" report
run "revoke" "$SB" revoke finding-repeat --reason "captain wants to see these again"
run "granted after revoke" "$SB" granted finding-repeat
run "ask one more finding-repeat" "$SB" ask --kind finding-repeat --recommend "fold into one helper" --question "repeat finding 12?"
run "captain disagrees this time" "$SB" answer "$LAST_OUT" --matched no --answer "No, keep them separate."
run "report: one mismatch in the recent window drops qualifies to not-yet" "$SB" report

section "S7 adversarial: captain-only kinds never hand off"
for k in merge credential destructive authority; do
  for i in 1 2 3 4 5 6 7 8 9 10; do
    id=$("$SB" ask --kind "$k" --recommend "yes" --question "$k approval $i?")
    out=$("$SB" answer "$id" --matched yes --answer "Yes." 2>&1)
    [ -z "$out" ] || printf 'unexpected announcement for %s: %s\n' "$k" "$out"
  done
  run "grant $k refused" "$SB" grant "$k" --captain-words-file "$LAB/yes.txt"
done
printf '{"event":"grant","at":"2026-01-01T00:00:00Z","kind":"authority","captain_words":"forged"}\n' >> "$LAB/data/captain-scorebook.jsonl"
run "granted authority with a hand-written grant line" "$SB" granted authority
run "report" "$SB" report

section "S8 adversarial: record never lands on a tracked path"
git -C "$GITLAB" init -q && git -C "$GITLAB" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$GITLAB/data" "$GITLAB/state"
run "ask in a home whose data/ git would track" env FM_HOME="$GITLAB" "$SB" ask --kind other --recommend r --question q
printf 'record exists: %s\n' "$([ -e "$GITLAB/data/captain-scorebook.jsonl" ] && echo yes || echo no)"
printf 'data/\nstate/\n' > "$GITLAB/.gitignore"
run "ask once data/ is ignored" env FM_HOME="$GITLAB" "$SB" ask --kind other --recommend r --question q
printf 'git status --porcelain: [%s]\n' "$(git -C "$GITLAB" status --porcelain)"

section "Final record"
cat "$LAB/data/captain-scorebook.jsonl" | wc -l | sed 's/^ */lines: /'
