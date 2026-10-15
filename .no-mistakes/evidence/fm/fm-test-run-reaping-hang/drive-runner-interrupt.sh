#!/usr/bin/env bash
# drive-runner-interrupt.sh <runner-checkout> <mode> <jobs> <iterations>
# Stands up a throwaway checkout holding the runner from <runner-checkout> and
# two hanging scripts, runs bin/fm-test-run.sh on them the way a terminal would
# (its own process group, INT at default), waits until every running script has
# started, ends the run per <mode>, and reports how long the runner took to end,
# its exit status, and whether anything it started outlived it.
#   group-term  TERM to the runner's whole process group (CI cancel / kill -- -pgid)
#   group-hup   HUP to the whole group (terminal closed)
#   group-int   INT to the whole group (Ctrl-C)
#   term        TERM to the runner alone
#   stuck-job   SIGSTOP the runner's script job, then TERM to the runner alone
set -u
SRC=$1 MODE=$2 JOBS=$3 N=$4
LIMIT=${LIMIT:-120}
pass=0 failn=0
for i in $(seq 1 "$N"); do
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-int-drive.XXXXXX")
  repo=$tmp/repo caller=$tmp/caller events=$tmp/events
  mkdir -p "$repo/bin" "$repo/tests" "$caller" "$events"
  cp "$SRC/bin/fm-test-run.sh" "$SRC/bin/fm-timeout-lib.sh" "$SRC/bin/fm-test-run-reap.sh" \
    "$SRC/bin/fm-remote-job-lib.sh" "$SRC/bin/fm-remote-job-worker.sh" "$repo/bin/"
  chmod +x "$repo/bin"/*.sh
  printf 'fixture\n' >"$repo/AGENTS.md"
  # Names on the runner's proven-isolated list, so --jobs 2 runs both at once.
  for name in fm-brief fm-crew-state; do
    cat >"$repo/tests/$name.test.sh" <<SH
#!/usr/bin/env bash
echo "ok - $name started"
: >"\$FIXTURE_EVENTS/$name"
sleep 600
SH
    chmod +x "$repo/tests/$name.test.sh"
  done
  (cd "$repo" && TMPDIR="$caller" FIXTURE_EVENTS="$events" \
    exec perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' \
    bin/fm-test-run.sh --jobs "$JOBS" tests/fm-brief.test.sh tests/fm-crew-state.test.sh) >"$tmp/out" 2>"$tmp/err" &
  runner=$!
  want=$JOBS deadline=$((SECONDS + 60))
  while [ "$(find "$events" -type f | wc -l | tr -d ' ')" -lt "$want" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "iter $i: scripts never started"; cat "$tmp/out" "$tmp/err"; exit 2; }
    sleep 0.05
  done
  sleep 0.3
  pgids=$(find "$caller" -name script.pgid -exec cat {} + 2>/dev/null | tr '\n' ' ')
  before=$(ps -A -o pid=,ppid=,pgid=,stat=,command= | awk -v g="$runner" -v s=" $pgids" '$3 == g || index(s, " " $3 " ")' | cut -c1-150)
  job=
  case "$MODE" in
    group-term) kill -TERM -- "-$runner" ;;
    group-hup) kill -HUP -- "-$runner" ;;
    group-int) kill -INT -- "-$runner" ;;
    term) kill -TERM "$runner" ;;
    stuck-job)
      job=$(ps -A -o pid=,ppid=,command= | awk -v r="$runner" '$2 == r && $0 ~ /fm-test-run.sh/ {print $1; exit}')
      kill -STOP "$job"
      kill -TERM "$runner"
      ;;
  esac
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  ended=0
  while [ "$(perl -MTime::HiRes=time -e "print time - $t0 < $LIMIT ? 1 : 0")" = 1 ]; do
    case "$(ps -o stat= -p "$runner" 2>/dev/null)" in '' | Z*) ended=1; break ;; esac
    sleep 0.05
  done
  elapsed=$(perl -MTime::HiRes=time -e "printf '%.2f', time - $t0")
  rc=none
  if [ "$ended" = 1 ]; then rc=0; wait "$runner" 2>/dev/null || rc=$?; fi
  sleep 1
  left=$(ps -A -o pid=,ppid=,pgid=,stat=,command= | awk -v g="$runner" -v s=" $pgids" '$3 == g || index(s, " " $3 " ")' | cut -c1-150)
  root_left=$(find "$caller" -mindepth 1 -maxdepth 1 2>/dev/null)
  echo "=== iter $i mode=$MODE jobs=$JOBS runner=$runner script-pgids=[$pgids] stopped-job=${job:-none}"
  echo "--- processes in the runner's and scripts' groups before the signal:"
  printf '%s\n' "$before"
  echo "--- runner ended=$ended after ${elapsed}s rc=$rc"
  echo "--- runner stderr (last 4 lines):"
  tail -4 "$tmp/err"
  echo "--- processes left in those groups 1s after the runner ended: ${left:-none}"
  echo "--- run root left in the caller's TMPDIR: ${root_left:-none}"
  if [ "$ended" = 1 ] && [ -z "$left" ] && [ -z "$root_left" ]; then pass=$((pass + 1)); else failn=$((failn + 1)); fi
  [ -z "$job" ] || kill -KILL "$job" 2>/dev/null
  if [ "$ended" = 0 ]; then
    kill -KILL -- "-$runner" 2>/dev/null
    for g in $pgids; do kill -KILL -- "-$g" 2>/dev/null; done
    wait "$runner" 2>/dev/null
  fi
  rm -rf "$tmp"
done
echo "SUMMARY mode=$MODE jobs=$JOBS iterations=$N clean=$pass not-clean=$failn"
