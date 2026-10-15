#!/usr/bin/env bash
# drive-interrupt.sh <runner-src> <mode> <jobs> <iterations> [limit-secs]
#
# Drives the real bin/fm-test-run.sh (copied from <runner-src>, a checkout's bin
# directory) against hanging test scripts in a scratch repo, then interrupts it
# the way a user or CI does and records how the run ends.
#
# modes:
#   int-group   Ctrl-C: INT to the runner's whole process group
#   term-group  TERM to the runner's whole process group (CI cancel / kill -- -pgid)
#   hup-group   HUP to the runner's whole process group (terminal closed)
#   term-runner TERM to the runner process alone
#   stopped-job SIGSTOP the runner's script job(s), then TERM the runner alone:
#               a job that never reports its end to the runner
#
# jobs: 1 = serial path (ACTIVE_SCRIPT_GUARD), 2 = concurrent workers (WORKER_PIDS)
set -u
src=$1 mode=$2 jobs=$3 iterations=$4 limit=${5:-150}
out_dir=${OUT_DIR:-$(dirname "$0")}
fails=0

new_repo() { # <tmp>
  local tmp=$1 repo=$1/repo name
  mkdir -p "$repo/bin" "$repo/tests" "$tmp/fake-bin" "$tmp/events" "$tmp/caller"
  for name in fm-test-run.sh fm-timeout-lib.sh fm-test-run-reap.sh fm-remote-job-lib.sh fm-remote-job-worker.sh; do
    cp "$src/$name" "$repo/bin/$name"
  done
  chmod +x "$repo/bin"/*.sh
  printf 'fixture\n' >"$repo/AGENTS.md"
  # The concurrent path's 0700 check uses GNU stat; emulate it on macOS as the
  # repository's own jobs-scheduler test does.
  cat >"$tmp/fake-bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then printf '700\n'; exit 0; fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"; exit 0; fi
exit 1
SH
  chmod +x "$tmp/fake-bin/stat"
  for name in fm-brief fm-composer-lib; do
    cat >"$repo/tests/$name.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - hang fixture $(basename "$0") started"
sleep 600 &
printf '%s\n' "$TMPDIR" >"$HANG_EVENTS/started.$(basename "$0")"
sleep 600
SH
    chmod +x "$repo/tests/$name.test.sh"
  done
}

for i in $(seq 1 "$iterations"); do
  tmp=$(mktemp -d /tmp/fmdrv.XXXXXX)
  new_repo "$tmp"
  if [ "$jobs" -eq 1 ]; then scripts=(tests/fm-brief.test.sh); else scripts=(tests/fm-brief.test.sh tests/fm-composer-lib.test.sh); fi
  (cd "$tmp/repo" && PATH="$tmp/fake-bin:$PATH" TMPDIR="$tmp/caller" HANG_EVENTS="$tmp/events" \
    exec perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' \
    bin/fm-test-run.sh --jobs "$jobs" "${scripts[@]}") >"$tmp/out" 2>"$tmp/err" &
  runner=$!
  deadline=$((SECONDS + 60))
  while [ "$(ls "$tmp/events" | wc -l | tr -d ' ')" -lt "${#scripts[@]}" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "iter $i: fixtures never started"; cat "$tmp/out" "$tmp/err"; break; }
    sleep 0.05
  done
  sandboxes=$(cat "$tmp/events"/started.* 2>/dev/null)
  stopped=
  case "$mode" in
    int-group) kill -INT -- "-$runner" ;;
    term-group) kill -TERM -- "-$runner" ;;
    hup-group) kill -HUP -- "-$runner" ;;
    term-runner) kill -TERM "$runner" ;;
    stopped-job)
      # The runner's script jobs are its long-lived children in its own group
      # (the sentinel has a group of its own) that have children themselves
      # (the guard or the job's script subshell). The concurrent path's polling
      # loop also forks short-lived foreground children (sleep, ps); stopping
      # one of those would block the runner's trap rather than test the job wait,
      # so only children present in two snapshots 0.3s apart qualify.
      snap1=$(pgrep -P "$runner" | sort)
      sleep 0.3
      for c in $(comm -12 <(printf '%s\n' "$snap1") <(pgrep -P "$runner" | sort)); do
        [ "$(ps -o pgid= -p "$c" | tr -d ' ')" = "$runner" ] || continue
        [ -n "$(pgrep -P "$c")" ] || continue
        kill -STOP "$c" && stopped="$stopped $c"
      done
      echo "stopped script job(s):$stopped of runner $runner"
      sleep 0.3
      kill -TERM "$runner"
      ;;
  esac
  t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  ended=0
  while :; do
    case "$(ps -o stat= -p "$runner" 2>/dev/null)" in '' | Z*) ended=1; break ;; esac
    now=$(perl -MTime::HiRes=time -e 'printf "%.0f", time')
    [ "$((now - ${t0%.*}))" -lt "$limit" ] || break
    sleep 0.05
  done
  t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  elapsed=$(perl -e "printf '%.2f', $t1 - $t0")
  if [ "$ended" -eq 1 ]; then
    wait "$runner"; rc=$?
  else
    rc=HUNG
  fi
  sleep 0.5
  left=$(ps -A -o pid=,pgid=,stat=,command= | grep -F "$tmp" | grep -v grep)
  sandbox_left=
  for s in $sandboxes; do [ ! -e "$s" ] || sandbox_left="$sandbox_left $s"; done
  caller_left=$(find "$tmp/caller" -mindepth 1 -maxdepth 1 2>/dev/null)
  msg=$(grep -E 'interrupted|still running 30s' "$tmp/err" | tr '\n' '|')
  status=ok
  case "$mode" in int-group) want=130 ;; hup-group) want=129 ;; *) want=143 ;; esac
  [ "$rc" = "$want" ] || status=FAIL
  [ -z "$left$sandbox_left$caller_left" ] || status=FAIL
  [ "$status" = ok ] || fails=$((fails + 1))
  printf 'iter=%s mode=%s jobs=%s rc=%s want=%s ended_in=%ss leftover_procs=%s sandbox_left=%s run_root_left=%s stderr=[%s] %s\n' \
    "$i" "$mode" "$jobs" "$rc" "$want" "$elapsed" "$(printf '%s' "$left" | grep -c .)" \
    "${sandbox_left:-none}" "${caller_left:-none}" "$msg" "$status"
  if [ "$status" != ok ]; then
    { echo "--- out"; cat "$tmp/out"; echo "--- err"; cat "$tmp/err"; echo "--- left"; printf '%s\n' "$left"; } | sed 's/^/    /'
  fi
  # Release anything this iteration left behind.
  [ -z "$stopped" ] || kill -CONT $stopped 2>/dev/null
  [ "$ended" -eq 1 ] || { kill -KILL -- "-$runner" 2>/dev/null; wait "$runner" 2>/dev/null; }
  for p in $(ps -A -o pid=,command= | grep -F "$tmp" | grep -v grep | awk '{print $1}'); do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$tmp"
done
echo "SUMMARY mode=$mode jobs=$jobs iterations=$iterations failures=$fails"
[ "$fails" -eq 0 ]
