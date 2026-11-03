#!/usr/bin/env bash
# Live driver: exercises bin/fm-scorebook.sh and bin/fm-captain-hold.sh as a
# firstmate primary would, inside a disposable lab home minted by
# bin/fm-lab-home.sh, against a real tasks-axi markdown backlog and real tmux
# (private socket dir). Prints a transcript; exits non-zero on any failed check.
# Usage: live-scorebook-cli.sh <worktree> <transcript-out>
set -u
WT=$1
OUT=$2
SB="$WT/bin/fm-scorebook.sh"
CH="$WT/bin/fm-captain-hold.sh"
FAILS=0

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rm -rf "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
TMUXDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
cleanup() {
  TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab kill-server 2>/dev/null || true
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB" "$LAB-tracked" "$LAB-ignored"
}
trap cleanup EXIT

# A real home carries its tasks-axi config at the home root.
cp "$WT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"

exec > >(tee "$OUT") 2>&1

run() {  # echo the command as a user would type it, then run it in the lab
  printf '\n$ %s\n' "$*"
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" "$@"
  local rc=$?
  printf '[exit %s]\n' "$rc"
  return "$rc"
}
check() {  # <description> <condition-command...>
  local d=$1
  shift
  if "$@"; then printf 'CHECK ok   - %s\n' "$d"; else printf 'CHECK FAIL - %s\n' "$d"; FAILS=$((FAILS + 1)); fi
}
expect_rc() {  # <want> <got>
  [ "$1" = "$2" ]
}

echo "# lab home: $LAB"
echo "# jq: $(command -v jq) $(jq --version)  tasks-axi: $(tasks-axi --version)"

echo
echo "########## S1 kinds lists every kind, its hand-off status, and definition"
kinds=$(run "$SB" kinds)
printf '%s\n' "$kinds"
check "authority is captain-only" grep -q $'^authority\tcaptain-only\t' <<<"$kinds"
check "merge/credential/destructive captain-only" bash -c '[ "$(grep -cE $'"'"'^(merge|credential|destructive)\tcaptain-only\t'"'"' <<<"$1")" = 3 ]' _ "$kinds"
check "design is hand-off with joined definition" grep -q $'^design\thand-off\ta design or product pick outside a review gate, such as an investigation, visual review, or intake question$' <<<"$kinds"
raw_kinds=$(env FM_HOME="$LAB" "$SB" kinds)
check "all 9 kinds have a non-empty definition column" bash -c '[ "$(awk -F "\t" "NF == 3 && \$3 != \"\"" <<<"$1" | wc -l | tr -d " ")" = 9 ]' _ "$raw_kinds"

echo
echo "########## S2 chat question round-trips: ask -> pending -> answer -> report -> record"
id=$(run "$SB" ask --kind design --recommend "Option A: one column" \
  --question "Which layout for the status board?" --task board-layout --project firstmate | tail -n 2 | head -n 1)
echo "recorded id: $id"
run "$SB" pending
pend=$(env FM_HOME="$LAB" "$SB" pending)
check "pending shows id, kind, chat, task, recommendation" \
  bash -c 'awk -F "\t" -v id="$2" "\$1==id && \$2==\"design\" && \$3==\"chat\" && \$5==\"board-layout\" && \$6==\"Option A: one column\"" <<<"$1" | grep -q .' _ "$pend" "$id"
rc=0; run "$SB" answer "$id" --matched no || rc=$?
check "chat answer without the captain's words refused (exit 1)" expect_rc 1 "$rc"
run "$SB" answer "$id" --matched no --answer "Two columns, please."
run "$SB" pending
run "$SB" report
echo "--- persisted record ---"
cat "$LAB/data/captain-scorebook.jsonl"
rec=$(jq -c "select(.id == \"$id\")" "$LAB/data/captain-scorebook.jsonl" | jq -sc '.')
check "record keeps question, recommendation, task, project" \
  bash -c 'jq -e ".[0] | .question == \"Which layout for the status board?\" and .recommendation == \"Option A: one column\" and .task == \"board-layout\" and .project == \"firstmate\"" <<<"$1" >/dev/null' _ "$rec"
check "record keeps captain's words and matched=false" \
  bash -c 'jq -e ".[1] | .answer == \"Two columns, please.\" and .matched == false" <<<"$1" >/dev/null' _ "$rec"
rc=0; run "$SB" answer "$id" --matched yes --answer again || rc=$?
check "second answer to an answered question refused" expect_rc 1 "$rc"

echo
echo "########## S3 held question on a real captain hold (fm-captain-hold.sh + tasks-axi)"
rc=0; run "$SB" ask --kind finding-design --recommend "keep the queue" --held remote-task || rc=$?
check "ask --held on a task absent from this home refused (exit 1)" expect_rc 1 "$rc"
(cd "$LAB" && tasks-axi add local-task "Queue rework" --repo firstmate --file "$LAB/data/backlog.md" >/dev/null) \
  || { echo "could not add local-task"; FAILS=$((FAILS + 1)); }
rc=0; run "$SB" ask --kind finding-design --recommend "keep the queue" --held local-task || rc=$?
check "ask --held on a local task not yet held refused (exit 1)" expect_rc 1 "$rc"
run "$CH" hold local-task --reason "Captain picks the queue shape: keep the queue or replace with a stream?" --repo firstmate
run "$CH" open local-task --identity
hid=$(env FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" "$SB" ask --kind finding-design --recommend "keep the queue" --held local-task --project firstmate)
printf '\n$ %s ask --kind finding-design --recommend "keep the queue" --held local-task --project firstmate\n%s\n' "$SB" "$hid"
check "held question id is the task id" expect_rc local-task "$hid"
rc=0; run "$SB" ask --kind finding-design --recommend again --held local-task || rc=$?
check "second open question on the same held task refused" expect_rc 1 "$rc"
further=$(env FM_HOME="$LAB" "$SB" ask --kind design --recommend "ship now" --question "Ship now or after the stream lands?" --task local-task --project firstmate)
printf '\n$ %s ask --kind design --recommend "ship now" --question "Ship now or after the stream lands?" --task local-task --project firstmate\n%s\n' "$SB" "$further"
run "$SB" pending
pend=$(env FM_HOME="$LAB" "$SB" pending)
check "pending shows held question with task and recommendation" \
  bash -c 'awk -F "\t" "\$1==\"local-task\" && \$3==\"held\" && \$5==\"local-task\" && \$6==\"keep the queue\"" <<<"$1" | grep -q .' _ "$pend"
check "pending shows the further chat question linked to the held task" \
  bash -c 'awk -F "\t" -v id="$2" "\$1==id && \$3==\"chat\" && \$5==\"local-task\" && \$6==\"ship now\"" <<<"$1" | grep -q .' _ "$pend" "$further"
rc=0; run "$SB" answer local-task --matched yes || rc=$?
check "held answer refused before the captain's words are on the task" expect_rc 1 "$rc"
printf 'Keep the queue.\n' > "$LAB/decision.txt"
run "$CH" answer local-task --decision-file "$LAB/decision.txt"
rc=0; run "$SB" answer local-task --matched yes --answer "Keep the queue." || rc=$?
check "held answer refuses copied --answer words" expect_rc 1 "$rc"
rc=0; run "$SB" answer local-task --matched yes || rc=$?
check "held answer accepted once the captain answered the call" expect_rc 0 "$rc"
run "$SB" answer "$further" --matched yes --answer "Ship now."
run "$SB" pending
run "$SB" report
check "captain's held words not copied into the scorebook" \
  bash -c '! grep -q "Keep the queue\." "$1"' _ "$LAB/data/captain-scorebook.jsonl"
echo "--- backlog after the call ---"
cat "$LAB/data/backlog.md"

echo
echo "########## S4 threshold: a kind answered as recommended 10 times newly qualifies, announced once"
i=1
ann=''
while [ "$i" -le 11 ]; do
  q=$(env FM_HOME="$LAB" "$SB" ask --kind finding-repeat --recommend "fold into one helper" --question "repeat finding $i" --project firstmate)
  a=$(env FM_HOME="$LAB" "$SB" answer "$q" --matched yes --answer "agreed $i")
  printf 'answer %2d (%s) -> %s\n' "$i" "$q" "${a:-<no output>}"
  [ "$i" != 10 ] || ann=$a
  [ "$i" = 10 ] || [ -z "$a" ] || { echo "unexpected announcement on answer $i"; FAILS=$((FAILS + 1)); }
  i=$((i + 1))
done
check "the 10th matching answer announced the kind" bash -c 'grep -q "finding-repeat newly qualifies for hand-off: its 10 most recent answers all matched the recommendation (10 answered, 10 matched)" <<<"$1"' _ "$ann"
run "$SB" report

echo
echo "########## S5 grant: a qualifying kind stays the captain's until he says yes"
rc=0; run "$SB" granted finding-repeat || rc=$?
check "qualifying but ungranted kind is not granted (exit 1)" expect_rc 1 "$rc"
rc=0; run "$SB" grant finding-repeat || rc=$?
check "grant without captain words refused (exit 2)" expect_rc 2 "$rc"
: > "$LAB/empty.txt"
rc=0; run "$SB" grant finding-repeat --captain-words-file "$LAB/empty.txt" || rc=$?
check "grant with empty captain words refused (exit 1)" expect_rc 1 "$rc"
printf 'Yes - decide repeated same-theme findings yourself from now on.\n' > "$LAB/yes.txt"
run "$SB" grant finding-repeat --captain-words-file "$LAB/yes.txt"
rc=0; run "$SB" granted finding-repeat || rc=$?
check "granted kind passes the check (exit 0)" expect_rc 0 "$rc"
rc=0; run "$SB" granted finding-scope || rc=$?
check "a grant for one kind does not grant another" expect_rc 1 "$rc"
run "$SB" report
run "$SB" revoke finding-repeat --reason "captain wants to see these again"
rc=0; run "$SB" granted finding-repeat || rc=$?
check "revoked kind no longer granted" expect_rc 1 "$rc"

echo
echo "########## S6 adversarial: captain-only kinds can never be handed off"
i=1
out=''
while [ "$i" -le 10 ]; do
  q=$(env FM_HOME="$LAB" "$SB" ask --kind authority --recommend "yes, write directly" --question "May I fix the README typo in projects/x directly? ($i)")
  out=$out$(env FM_HOME="$LAB" "$SB" answer "$q" --matched yes --answer "Yes, fix it.")
  i=$((i + 1))
done
check "10 matching authority answers announced nothing" expect_rc "" "$out"
printf 'Yes, approve all of these yourself.\n' > "$LAB/blanket.txt"
for k in authority merge credential destructive; do
  rc=0; run "$SB" grant "$k" --captain-words-file "$LAB/blanket.txt" || rc=$?
  check "grant $k refused (exit 1)" expect_rc 1 "$rc"
done
printf '{"event":"grant","at":"2026-01-01T00:00:00Z","kind":"merge","captain_words":"x"}\n{"event":"grant","at":"2026-01-01T00:00:00Z","kind":"authority","captain_words":"x"}\n' >> "$LAB/data/captain-scorebook.jsonl"
echo "(hand-appended grant events for merge and authority to the record)"
for k in merge authority; do
  rc=0; run "$SB" granted "$k" || rc=$?
  check "hand-written grant for $k does not make it granted" expect_rc 1 "$rc"
done
run "$SB" report

echo
echo "########## S7 adversarial: concurrent writers serialize; one question answered once"
pids=''
for n in 1 2 3 4 5 6 7 8; do
  (env FM_HOME="$LAB" "$SB" ask --kind other --recommend "r$n" --question "parallel $n" > "$LAB/par.$n") &
  pids="$pids $!"
done
wait $pids
before=$(wc -l < "$LAB/data/captain-scorebook.jsonl" | tr -d ' ')
check "every concurrent ask produced a distinct id" bash -c '[ "$(cat "$1"/par.* | sort -u | wc -l | tr -d " ")" = 8 ]' _ "$LAB"
check "record is still valid JSON lines" bash -c 'jq -cs "length" "$1" >/dev/null' _ "$LAB/data/captain-scorebook.jsonl"
target=$(cat "$LAB/par.1")
okc=0
for n in 1 2 3 4 5 6; do
  (env FM_HOME="$LAB" "$SB" answer "$target" --matched yes --answer "racer $n" >/dev/null 2>&1; echo $? > "$LAB/race.$n") &
done
wait
okc=$(cat "$LAB"/race.* | grep -c '^0$')
echo "racing answers to $target: $okc of 6 accepted"
check "exactly one of six racing answers to one question accepted" expect_rc 1 "$okc"
check "exactly one answer event recorded for it" bash -c '[ "$(jq -c "select(.event==\"answer\" and .id==\"$2\")" "$1" | wc -l | tr -d " ")" = 1 ]' _ "$LAB/data/captain-scorebook.jsonl" "$target"

echo
echo "########## S8 adversarial: the record never lands on a git-tracked path"
mkdir -p "$LAB-tracked/data" "$LAB-tracked/state"
git -C "$LAB-tracked" init -q && git -C "$LAB-tracked" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
rc=0
printf '\n$ FM_HOME=<tracked repo> %s ask --kind other --recommend r --question q\n' "$SB"
env FM_HOME="$LAB-tracked" "$SB" ask --kind other --recommend r --question q || rc=$?
printf '[exit %s]\n' "$rc"
check "ask into a tracked data dir refused" expect_rc 1 "$rc"
check "no record written there" test ! -e "$LAB-tracked/data/captain-scorebook.jsonl"
mkdir -p "$LAB-ignored/data" "$LAB-ignored/state"
git -C "$LAB-ignored" init -q && printf 'data/\nstate/\n' > "$LAB-ignored/.gitignore"
git -C "$LAB-ignored" add .gitignore && git -C "$LAB-ignored" -c user.name=t -c user.email=t@t commit -q -m ignore
printf '\n$ FM_HOME=<repo ignoring data/> %s ask --kind other --recommend r --question q\n' "$SB"
env FM_HOME="$LAB-ignored" "$SB" ask --kind other --recommend r --question q
check "ask into an ignored data dir writes the record and leaves git clean" \
  bash -c 'test -s "$1/data/captain-scorebook.jsonl" && [ -z "$(git -C "$1" status --porcelain)" ]' _ "$LAB-ignored"

echo
echo "########## RESULT: $FAILS failed checks"
exit "$FAILS"
