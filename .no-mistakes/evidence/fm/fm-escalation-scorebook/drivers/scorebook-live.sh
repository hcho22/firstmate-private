#!/usr/bin/env bash
# Live CLI drive of bin/fm-scorebook.sh in disposable marked lab homes minted
# by bin/fm-lab-home.sh, with a real tasks-axi markdown backlog behind
# bin/fm-captain-hold.sh. Usage: scorebook-live.sh <worktree> <transcript>
set -u
WT=$1
OUT=$2
cd "$WT" || exit 1
: > "$OUT"
# mklab runs in $(...) subshells, so lab paths go to a file the EXIT trap reads.
LABLIST=$(mktemp "${TMPDIR:-/tmp}/fm-scorebook-labs.XXXXXX")
cleanup() {
  local l
  while IFS= read -r l; do [ -n "$l" ] && [ -f "$l/.fm-lab-home" ] && rm -rf "$l"; done < "$LABLIST"
  rm -f "$LABLIST"
}
trap cleanup EXIT

mklab() {
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  rmdir "$lab"
  bin/fm-lab-home.sh create "$lab" >/dev/null || { echo "lab create failed" >&2; exit 1; }
  mkdir -p "$lab/tmux"
  cat > "$lab/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$lab/data/backlog.md"
  printf '%s\n' "$lab" >> "$LABLIST"
  printf '%s\n' "$lab"
}

# run <lab> <label> <cmd...>: show the command, its stdout+stderr and exit code
run() {
  local lab=$1 label=$2 rc=0 o
  shift 2
  o=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE \
      FM_HOME="$lab" "$@" 2>&1) || rc=$?
  {
    printf '$ %s\n' "$*" | sed "s#$WT/##g; s#$lab#\$LAB#g"
    [ -z "$o" ] || printf '%s\n' "$o" | sed "s#$lab#\$LAB#g"
    printf '[exit %s]%s\n' "$rc" "${label:+  <- $label}"
  } >> "$OUT"
  LAST_OUT=$o
  LAST_RC=$rc
}
section() { printf '\n==== %s ====\n' "$*" >> "$OUT"; }
check() {  # <desc> <condition-cmd...>
  local desc=$1
  shift
  if "$@"; then printf 'CHECK PASS: %s\n' "$desc" >> "$OUT"; else printf 'CHECK FAIL: %s\n' "$desc" >> "$OUT"; FAILS=$((FAILS + 1)); fi
}
FAILS=0
SB=bin/fm-scorebook.sh
CH=bin/fm-captain-hold.sh
eq() { [ "$1" = "$2" ]; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
field() {  # <lab> <kind> <col>
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$1" $SB report | awk -v k="$2" -v c="$3" '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next } $1 == k { print $col[c] }'
}

printf 'fm-scorebook live drive at %s (HEAD %s), host jq %s, tasks-axi %s\n' \
  "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD)" "$(jq --version)" "$(tasks-axi --version)" >> "$OUT"

A=$(mklab)

section "S1 kinds lists each kind, hand-off or captain-only, and its definition"
run "$A" "" $SB kinds
check "authority is captain-only and names the fix-round cap" has "$LAST_OUT" $'authority\tcaptain-only\tany other decision AGENTS.md\'s hard rules, captain-instruction precedence, or a policy-owning skill reserve for his own concrete word, such as a direct project write under hard rule 1 or a fix-round cap escalation under ask-user-authority'
check "other excludes skill-reserved decisions" has "$LAST_OUT" $'other\thand-off\tany other question no AGENTS.md rule or policy-owning skill reserves for his own word'
check "merge credential destructive authority are the captain-only set" eq "$(printf '%s\n' "$LAST_OUT" | awk -F '\t' '$2=="captain-only"{printf "%s ", $1}')" "merge credential destructive authority "

section "S2 a chat question round-trips: ask, pending, answer, report, persisted record"
run "$A" "record a design question asked in chat" $SB ask --kind design --recommend "option A: board on the left" --question "Which layout for the Bearings board?" --task fm-board --project firstmate
CHAT=$LAST_OUT
check "chat question gets a chat- id" has "$CHAT" chat-
run "$A" "" $SB pending
check "pending shows id, kind, chat, at, task, recommendation" eq "$(printf '%s' "$LAST_OUT" | awk -F '\t' '{print $1"|"$2"|"$3"|"$5"|"$6}')" "$CHAT|design|chat|fm-board|option A: board on the left"
run "$A" "chat answer without his words is refused" $SB answer "$CHAT" --matched yes
check "answer without --answer refused (exit 1)" eq "$LAST_RC" 1
run "$A" "captain picked something else" $SB answer "$CHAT" --matched no --answer "Option B, board on the right."
check "answer accepted" eq "$LAST_RC" 0
run "$A" "" $SB pending
check "nothing pending after the answer" eq "$LAST_OUT" ""
run "$A" "" $SB report
check "design row counts 1 asked, 1 answered, 0 matched, not-yet" eq "$(field "$A" design asked)/$(field "$A" design answered)/$(field "$A" design matched)/$(field "$A" design status)" "1/1/0/not-yet"
printf '$ cat $LAB/data/captain-scorebook.jsonl\n' >> "$OUT"
sed "s#$A#\$LAB#g" "$A/data/captain-scorebook.jsonl" >> "$OUT"
check "record keeps question, recommendation, task, project, matched and answer" \
  eq "$(jq -sc '[.[0] | .question, .recommendation, .task, .project], [.[1] | .matched, .answer]' "$A/data/captain-scorebook.jsonl" | tr '\n' ' ')" \
  '["Which layout for the Bearings board?","option A: board on the left","fm-board","firstmate"] [false,"Option B, board on the right."] '
run "$A" "withdraw a moot question" $SB ask --kind design --recommend r --question "moot one" --project firstmate
MOOT=$LAST_OUT
run "$A" "" $SB withdraw "$MOOT" --reason "premise was false"
check "withdrawn question never counts as answered" eq "$(field "$A" design answered)/$(field "$A" design withdrawn)" "1/1"

section "S3 a hand-off kind qualifies at 10 matching answers, announced once"
B=$(mklab)
ann=''
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  id=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$B" $SB ask --kind finding-scope --recommend "out of scope: decline" --question "finding $i widens the contract?" --task t$i --project sample)
  run "$B" "answer $i as recommended" $SB answer "$id" --matched yes --answer "Decline, out of scope."
  [ -z "$LAST_OUT" ] || ann="$ann$i:$LAST_OUT;"
done
check "only answer 10 printed an announcement citing the count" eq "$ann" "10:finding-scope newly qualifies for hand-off: its 10 most recent answers all matched the recommendation (10 answered, 10 matched);"
run "$B" "" $SB report
check "finding-scope qualifies" eq "$(field "$B" finding-scope status)" qualifies
run "$B" "qualifying is not granted" $SB granted finding-scope
check "granted exits 1 before the captain's yes" eq "$LAST_RC" 1
id=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$B" $SB ask --kind finding-scope --recommend "decline" --question "finding 12")
run "$B" "one mismatch" $SB answer "$id" --matched no --answer "Fix it after all."
check "a mismatch in the recent 10 drops it to not-yet, 9/10" eq "$(field "$B" finding-scope status) $(field "$B" finding-scope recent)" "not-yet 9/10"

section "S4 a qualifying kind is firstmate's only after the captain's recorded yes; revoke takes it back"
C=$(mklab)
for i in 1 2 3 4 5 6 7 8 9 10; do
  id=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$C" $SB ask --kind finding-repeat --recommend "rethink the abstraction" --question "repeat $i")
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$C" $SB answer "$id" --matched yes --answer ok >/dev/null
done
: > "$C/empty.txt"
run "$C" "grant with empty captain words" $SB grant finding-repeat --captain-words-file "$C/empty.txt"
check "empty words refused" eq "$LAST_RC" 1
head -c 8193 /dev/zero | tr '\0' a > "$C/big.txt"
run "$C" "grant with 8193-byte captain words" $SB grant finding-repeat --captain-words-file "$C/big.txt"
check "oversized words refused" eq "$LAST_RC" 1
run "$C" "" $SB granted finding-repeat
check "still not granted" eq "$LAST_RC" 1
printf 'Yes, decide repeated findings yourself from now on.\n' > "$C/yes.txt"
run "$C" "captain's yes" $SB grant finding-repeat --captain-words-file "$C/yes.txt"
run "$C" "" $SB granted finding-repeat
check "granted exits 0 after the yes" eq "$LAST_RC" 0
run "$C" "" $SB report
check "report shows granted" eq "$(field "$C" finding-repeat status)" granted
run "$C" "a grant for one kind does not leak to another" $SB granted finding-scope
check "finding-scope not granted" eq "$LAST_RC" 1
D=$(mklab)
run "$D" "another home never reads the first home's grant" $SB granted finding-repeat
check "second lab home not granted" eq "$LAST_RC" 1
run "$C" "" $SB revoke finding-repeat --reason "captain wants to see these again"
run "$C" "" $SB granted finding-repeat
check "revoked kind not granted" eq "$LAST_RC" 1

section "S5 adversarial: fix-round cap escalation recorded as authority never becomes firstmate's"
E=$(mklab)
ann=''
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  id=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$E" $SB ask --kind authority --recommend "allow 2 more rounds" --question "Review on sample-work hit fix-round cap rounds=3: rethink, approve as is, or allow more rounds?" --task sample-work --project sample)
  run "$E" "cap escalation $i answered as recommended" $SB answer "$id" --matched yes --answer "Allow 2 more rounds."
  [ -z "$LAST_OUT" ] || ann="$ann$i:$LAST_OUT;"
done
check "no hand-off announcement after 12 matching cap answers" eq "$ann" ""
run "$E" "" $SB report
check "authority 12/12 matched yet captain-only" eq "$(field "$E" authority matched) $(field "$E" authority status)" "12 captain-only"
printf 'Yes, decide fix-round caps yourself.\n' > "$E/yes.txt"
run "$E" "even with the captain's words, grant refuses authority" $SB grant authority --captain-words-file "$E/yes.txt"
check "grant authority refused (exit 1)" eq "$LAST_RC" 1
printf '{"event":"grant","at":"2026-01-01T00:00:00Z","kind":"authority","captain_words":"forged"}\n' >> "$E/data/captain-scorebook.jsonl"
run "$E" "hand-forged grant line appended to the record" $SB granted authority
check "granted authority still exits 1 with a forged grant" eq "$LAST_RC" 1
for k in merge credential destructive; do
  run "$E" "captain-only $k" $SB grant "$k" --captain-words-file "$E/yes.txt"
  check "grant $k refused" eq "$LAST_RC" 1
done
run "$E" "the cap escalation cannot be filed under a hand-off kind by typo" $SB ask --kind fix-round-cap --recommend r --question q
check "unknown kind is bad usage (exit 2)" eq "$LAST_RC" 2

section "S6 adversarial: project-write approvals recorded as authority stay captain-only"
F=$(mklab)
for i in 1 2 3 4 5 6 7 8 9 10; do
  id=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$F" $SB ask --kind authority --recommend "yes, fix it directly" --question "May I fix the typo in projects/x/README directly?" --project x)
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$F" $SB answer "$id" --matched yes --answer "Yes, fix it." >> "$OUT" 2>&1
done
run "$F" "" $SB report
check "authority 10/10 matched, captain-only" eq "$(field "$F" authority matched) $(field "$F" authority status)" "10 captain-only"

section "S7 held questions against a real backlog through fm-captain-hold.sh"
G=$(mklab)
run "$G" "task absent from this home (e.g. held in a secondmate home)" $SB ask --kind finding-design --recommend "keep the queue" --held remote-call --project sample
check "absent task refused, routed to --question" eval '[ "$LAST_RC" = 1 ] && has "$LAST_OUT" "not in this home'"'"'s backlog" && has "$LAST_OUT" "--question"'
run "$G" "create a local task that is not held" sh -c 'cd "$0" && exec tasks-axi "$@"' "$G" add queue-call "Pick the queue shape" --repo sample
run "$G" "local task not yet held" $SB ask --kind finding-design --recommend "keep the queue" --held queue-call --project sample
check "local unheld task refused with hold it first" eval '[ "$LAST_RC" = 1 ] && has "$LAST_OUT" "hold it first"'
run "$G" "hold it for the captain" $CH hold queue-call --reason "captain picks the queue shape: keep the queue or switch to a stack"
run "$G" "record the held question" $SB ask --kind finding-design --recommend "keep the queue" --held queue-call --project sample
check "held question id is the task id" eq "$LAST_OUT" queue-call
run "$G" "a further question on the same held task" $SB ask --kind design --recommend "ship now" --question "Ship now or after X?" --task queue-call --project sample
FURTHER=$LAST_OUT
run "$G" "" $SB pending
check "pending shows both with task and recommendation" eq "$(printf '%s\n' "$LAST_OUT" | awk -F '\t' '{print $1"|"$2"|"$3"|"$5"|"$6}' | tr '\n' ';')" "queue-call|finding-design|held|queue-call|keep the queue;$FURTHER|design|chat|queue-call|ship now;"
run "$G" "answer before the captain's words are on the task" $SB answer queue-call --matched yes
check "refused while still an open captain call" eval '[ "$LAST_RC" = 1 ] && has "$LAST_OUT" "still an open captain call"'
printf 'Keep the queue.\n' > "$G/decision.txt"
run "$G" "captain's words recorded on the task" $CH answer queue-call --decision-file "$G/decision.txt"
run "$G" "held answer must not copy his words" $SB answer queue-call --matched yes --answer "Keep the queue."
check "--answer refused for a held question" eq "$LAST_RC" 1
run "$G" "" $SB answer queue-call --matched yes
check "held answer accepted after the captain answered" eq "$LAST_RC" 0
run "$G" "" $SB answer "$FURTHER" --matched no --answer "After X."
run "$G" "" $SB report
check "finding-design 1 matched, design 0 matched" eq "$(field "$G" finding-design matched)/$(field "$G" design answered)/$(field "$G" design matched)" "1/1/0"
check "captain's words stored once (on the task, not in the scorebook)" eval '! grep -q "Keep the queue." "$G/data/captain-scorebook.jsonl"'
printf '$ cat $LAB/data/captain-scorebook.jsonl\n' >> "$OUT"
sed "s#$G#\$LAB#g" "$G/data/captain-scorebook.jsonl" >> "$OUT"

section "S8 release and re-hold: a new question on a re-held task needs a new answer"
run "$G" "" sh -c 'cd "$0" && exec tasks-axi "$@"' "$G" add work-call "Gate the release" --repo sample
run "$G" "" $CH hold work-call --reason "approve the release plan?"
run "$G" "" $SB ask --kind design --recommend "plan A" --held work-call --project sample
printf 'Plan A, go.\n' > "$G/d2.txt"
run "$G" "captain answers with --release" $CH answer work-call --decision-file "$G/d2.txt" --release
run "$G" "" $SB answer work-call --matched yes
check "first held question answered" eq "$LAST_RC" 0
run "$G" "held again for a new question" $CH hold work-call --reason "approve the rollout window?"
run "$G" "" $SB ask --kind design --recommend "Friday" --held work-call --project sample
check "re-held task accepts a new question" eq "$LAST_RC 
$LAST_OUT" "0 
work-call"
run "$G" "answer to the new question before his new words" $SB answer work-call --matched yes
check "refused until a new resolution lands" eq "$LAST_RC" 1
printf 'Monday instead.\n' > "$G/d3.txt"
run "$G" "" $CH answer work-call --decision-file "$G/d3.txt" --release
run "$G" "" $SB answer work-call --matched no
check "accepted after the new resolution" eq "$LAST_RC" 0

section "S9 the record never lands on a git-tracked path"
H=$(mklab)
git init -q "$H/repo" && git -C "$H/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$H/repo/data"
run "$H" "FM_DATA_OVERRIDE inside a git work tree that does not ignore it" env FM_DATA_OVERRIDE="$H/repo/data" $SB ask --kind other --recommend r --question q
check "write refused (exit 1) and no file left" eval '[ "$LAST_RC" = 1 ] && [ ! -e "$H/repo/data/captain-scorebook.jsonl" ] && has "$LAST_OUT" "not ignored"'
printf 'data/\n' > "$H/repo/.gitignore"
run "$H" "same path once ignored" env FM_DATA_OVERRIDE="$H/repo/data" $SB ask --kind other --recommend r --question q
check "write accepted where git ignores it" eval '[ "$LAST_RC" = 0 ] && [ -s "$H/repo/data/captain-scorebook.jsonl" ]'

printf '\nRESULT: %s check(s) failed\n' "$FAILS" >> "$OUT"
exit "$FAILS"
