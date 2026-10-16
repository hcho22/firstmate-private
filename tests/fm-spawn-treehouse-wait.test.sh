#!/usr/bin/env bash
# Regression test for the wait fm-spawn.sh makes for `treehouse get` to enter a
# worktree (bin/fm-spawn.sh, the loop after the launch lines, and the
# treehouse_wait_seconds comment that owns the rules).
#
# Creating the isolated copy is the one launch step whose duration depends on
# the host, so the wait must not be a fixed poll count: a copy that is slow but
# still advancing completes the launch, a get that exited or is stuck is refused
# with a message naming which, and a get that never settles is refused at a
# ceiling. A get the spawn cannot observe is refused only after the documented
# bound passes without any observation. A get that is only waiting its turn on
# its pool behind another live
# operation is not stuck while that operation advances, and is refused naming
# it when it does not. Because the wait can be long, it holds no lock another
# dispatch in the same home needs. Every case drives the public interface
# (bin/fm-spawn.sh) against a REAL tmux server on a private socket whose pane
# shell is a bare bash, with a `treehouse` stand-in on PATH that behaves as the
# case asks (works for a while, exits with an error, hangs, lands in the wrong
# place, queues on the pool lock, or waits to be released).
#
# Time is compressed rather than slept through: a `sleep` shim turns the spawn's
# one-second poll sleep into a short one, so the original sixty-poll bound is a
# few seconds of real time, shorter than the cases' slow get, and the cases that
# need the original bound to be wrong are red against it. The new limits are
# wall-clock seconds, so each case scales them through the documented
# FM_TREEHOUSE_GET_* variables instead of waiting a real minute.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
REAL_SLEEP=$(command -v sleep)
REAL_PS=$(command -v ps)
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-wait)
RUN_TAG="thw$$"
SOCKETS=()
PEER_PIDS=()
# The pool-lock cases need a way to hold a real flock and a way to find who
# holds it open, which is what the spawn itself uses.
POOL_CASES=1
{ command -v perl >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; } || POOL_CASES=0

cleanup_all() {
  local sock id pid
  for pid in "${PEER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  for sock in "${SOCKETS[@]:-}"; do
    [ -n "$sock" ] || continue
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$sock"
  done
  for id in "${TASK_IDS[@]:-}"; do
    [ -n "$id" ] && rm -rf "/tmp/fm-$id"
  done
  fm_test_cleanup
}
TASK_IDS=()
trap cleanup_all EXIT

# The stand-in treehouse. FMT_MODE picks the behaviour and FMT_SECONDS how long
# it works or hangs:
#   advance  spends FMT_SECONDS starting short-lived children (visible progress),
#            then acquires a worktree and opens a subshell in it
#   hang     one child that sleeps and never changes (no progress at all)
#   fail     prints an error and exits without a worktree
#   subdir   enters a subdirectory of the primary checkout instead of a worktree
#   pool     waits, with no progress of its own, for an exclusive flock on the
#            pool's treehouse-state.lock (as treehouse does), then acquires
#   queue    opens the pool's treehouse-state.lock and then waits, with no
#            progress of its own, without ever contending for it
#   gate     the first get in the world starts short-lived children until
#            the case creates pool/release; every later get acquires at once
#   polls    starts short-lived children until the spawn has read the process
#            table FMT_SECONDS times (counted by the ps stand-in), then acquires
make_treehouse_stub() {
  local dir=$1
  cat > "$dir/treehouse" <<SH
#!/usr/bin/env bash
echo "stand-in treehouse get" >&2
case "\$FMT_MODE" in
  fail) echo "stand-in: fatal: cannot create worktree" >&2; exit 1 ;;
  hang) "$REAL_SLEEP" "\$FMT_SECONDS"; exit 1 ;;
  subdir) mkdir -p "\$FMT_PROJECT/sub"; cd "\$FMT_PROJECT/sub" && exec bash --noprofile --norc -i ;;
  advance)
    end=\$((SECONDS + FMT_SECONDS))
    while [ "\$SECONDS" -lt "\$end" ]; do "$REAL_SLEEP" 0.2; done
    ;;
  pool)
    perl -MFcntl=:flock -e 'open(my \$f, ">>", \$ARGV[0]) or die "open: \$!"; flock(\$f, LOCK_EX) or die "flock: \$!"' \
      "\$FMT_POOL/treehouse-state.lock" || exit 1
    ;;
  polls)
    while [ "\$(cat "\$FMT_PS_COUNT" 2>/dev/null || echo 0)" -lt "\$FMT_SECONDS" ]; do "$REAL_SLEEP" 0.2; done
    ;;
  queue)
    perl -e 'open(my \$f, ">>", \$ARGV[0]) or die "open: \$!"; sleep 3600' "\$FMT_POOL/treehouse-state.lock"
    exit 1
    ;;
  gate)
    if mkdir "\$FMT_POOL/gate" 2>/dev/null; then
      while [ ! -e "\$FMT_POOL/release" ]; do "$REAL_SLEEP" 0.2; done
    fi
    ;;
esac
wt="\$FMT_POOL/slot-\$\$"
git worktree add -q --detach "\$wt" >&2 || exit 1
cd "\$wt" && exec bash --noprofile --norc -i
SH
  chmod +x "$dir/treehouse"
}

# make_world <name>: a case's own project, home, private tmux socket, and fakebin
# under $TMP_ROOT/<name>, which every spawn of that case shares.
make_world() {
  local name=$1 case_dir proj home fakebin sock
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  sock="$RUN_TAG-$name"
  mkdir -p "$fakebin" "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/pool"
  fm_git_identity
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$case_dir/project.origin.git"
  printf 'set -g default-command "bash --noprofile --norc"\n' > "$case_dir/tmux.conf"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$sock" -f "$case_dir/tmux.conf" "\$@"
SH
  cat > "$fakebin/sleep" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = 1 ]; then exec "$REAL_SLEEP" 0.05; fi
exec "$REAL_SLEEP" "\$@"
SH
  # FMT_PS_FAIL_EVERY=<n> makes every n-th read of the process table the wait
  # uses fail, as a fork failure or a failing ps on a loaded host would.
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
if [ -n "\${FMT_PS_FAIL_EVERY:-}" ] && [ "\$*" = "-A -o pid=,ppid=,time=,command=" ]; then
  n=\$((\$(cat "\$FMT_PS_COUNT" 2>/dev/null || echo 0) + 1))
  printf '%s\n' "\$n" > "\$FMT_PS_COUNT"
  [ \$((n % FMT_PS_FAIL_EVERY)) -ne 0 ] || exit 1
fi
exec "$REAL_PS" "\$@"
SH
  # Every scan for the processes holding a file open is logged to FMT_LSOF_LOG.
  if [ "$POOL_CASES" -eq 1 ]; then
    cat > "$fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in *" -t "*) printf 'scan\n' >> "\$FMT_LSOF_LOG" ;; esac
exec "$(command -v lsof)" "\$@"
SH
    chmod +x "$fakebin/lsof"
  fi
  printf '#!/usr/bin/env bash\nexec "%s" 600\n' "$REAL_SLEEP" > "$fakebin/codex"
  make_treehouse_stub "$fakebin"
  chmod +x "$fakebin/tmux" "$fakebin/sleep" "$fakebin/ps" "$fakebin/codex"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
}

# spawn_in <name> <id> <out-dir> <mode> <seconds> [VAR=value ...]: run one spawn
# of task <id> in world <name> and leave its output, exit code, and elapsed
# seconds under <out-dir>.
spawn_in() {
  local name=$1 id=$2 out_dir=$3 mode=$4 seconds=$5 case_dir proj home start rc kv
  shift 5
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  home="$case_dir/home"
  mkdir -p "$out_dir" "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the treehouse get wait for $name.

## Firstmate spec
Record the worktree the get settled in.
EOF
  start=$SECONDS
  (
    cd "$proj" || exit 1
    for kv in "$@"; do export "${kv?}"; done
    # An ambient Herdr or tmux runtime must never steer the spawn: it is pinned to
    # tmux, on the private socket above, inside this case's own home.
    env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID \
      -u HERDR_WORKSPACE_ID -u HERDR_SESSION \
      FMT_MODE="$mode" FMT_SECONDS="$seconds" FMT_POOL="$case_dir/pool" FMT_PROJECT="$proj" \
      FMT_PS_COUNT="$out_dir/ps.count" FMT_LSOF_LOG="$out_dir/lsof-scans" \
      FM_BACKEND=tmux FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 PATH="$case_dir/fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off --backend tmux
  ) > "$out_dir/spawn.out" 2>&1
  rc=$?
  printf '%s\n' "$rc" > "$out_dir/rc"
  printf '%s\n' "$((SECONDS - start))" > "$out_dir/elapsed"
}

# run_case <name> <mode> <seconds> [VAR=value ...]: build a world and run its one
# spawn, leaving the results and recorded state under $TMP_ROOT/<name>. Cases are
# independent, so the caller runs them together.
run_case() {
  local name=$1
  shift
  make_world "$name"
  spawn_in "$name" "$(case_id "$name")" "$TMP_ROOT/$name" "$@"
}

# start_peer <name> <progress|stall> <seconds>: stand in for another live
# treehouse operation on the case's pool (a get from another home, or
# `treehouse return`) that holds the pool lock for <seconds>, either starting
# short-lived children all along or doing nothing at all. Returns once it holds
# the lock, and records its pid in $TMP_ROOT/<name>/peer.pid.
start_peer() {
  local case_dir="$TMP_ROOT/$1" deadline
  perl -MFcntl=:flock -e '
    my ($lock, $marker, $mode, $seconds, $sleep) = @ARGV;
    open(my $f, ">>", $lock) or die "open: $!";
    flock($f, LOCK_EX) or die "flock: $!";
    open(my $m, ">", $marker) or die "marker: $!";
    close($m);
    my $end = time + $seconds;
    if ($mode eq "progress") { system($sleep, "0.2") while time < $end }
    else { sleep $seconds }
  ' "$case_dir/pool/treehouse-state.lock" "$case_dir/peer.holding" "$2" "$3" "$REAL_SLEEP" \
    </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$case_dir/peer.pid"
  deadline=$((SECONDS + 30))
  while [ ! -e "$case_dir/peer.holding" ] && [ "$SECONDS" -lt "$deadline" ]; do "$REAL_SLEEP" 0.1; done
}

# run_pool_case <name> <progress|stall> <peer-seconds> [VAR=value ...]: a get that
# queues behind a peer holding the pool lock.
run_pool_case() {
  local name=$1 peer_mode=$2 peer_seconds=$3
  shift 3
  make_world "$name"
  start_peer "$name" "$peer_mode" "$peer_seconds"
  spawn_in "$name" "$(case_id "$name")" "$TMP_ROOT/$name" pool 0 "$@"
}

# run_handoff_case: a get queued on the pool while the lock passes from one
# peer to another. The first peer holds the lock while working, then, once the
# get has found both peers, closes it and keeps working, as a get whose copy is
# done keeps running under the worker it launched. The second peer, queued
# behind it, takes the lock and does nothing. Their pids are recorded in
# first.pid and second.pid.
run_handoff_case() {
  local case_dir="$TMP_ROOT/peerhandoff" spawn_pid deadline
  make_world peerhandoff
  perl -MFcntl=:flock -e '
    my ($lock, $marker, $release, $sleep) = @ARGV;
    open(my $f, ">>", $lock) or die "open: $!";
    flock($f, LOCK_EX) or die "flock: $!";
    open(my $m, ">", $marker) or die "marker: $!";
    close($m);
    system($sleep, "0.2") until -e $release;
    close($f);
    system($sleep, "0.2") while 1;
  ' "$case_dir/pool/treehouse-state.lock" "$case_dir/first.holding" "$case_dir/pool/release-first" "$REAL_SLEEP" \
    </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$case_dir/first.pid"
  deadline=$((SECONDS + 30))
  while [ ! -e "$case_dir/first.holding" ] && [ "$SECONDS" -lt "$deadline" ]; do "$REAL_SLEEP" 0.1; done
  perl -MFcntl=:flock -e '
    my ($lock, $marker) = @ARGV;
    open(my $f, ">>", $lock) or die "open: $!";
    flock($f, LOCK_EX) or die "flock: $!";
    open(my $m, ">", $marker) or die "marker: $!";
    close($m);
    sleep 3600;
  ' "$case_dir/pool/treehouse-state.lock" "$case_dir/second.holding" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$case_dir/second.pid"
  spawn_in peerhandoff "$(case_id peerhandoff)" "$case_dir" queue 0 \
    FM_TREEHOUSE_GET_STALL_SECS=4 FM_TREEHOUSE_GET_MAX_SECS=60 &
  spawn_pid=$!
  deadline=$((SECONDS + 60))
  while [ ! -s "$case_dir/lsof-scans" ] && kill -0 "$spawn_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    "$REAL_SLEEP" 0.1
  done
  "$REAL_SLEEP" 1
  touch "$case_dir/pool/release-first"
  wait "$spawn_pid"
}

# run_concurrent_case: two fresh dispatches in one home. The first one's get is
# held open until the second has finished, and whether the first was still inside
# its get at that point (no record yet, spawn still running) is recorded.
run_concurrent_case() {
  local case_dir="$TMP_ROOT/concurrent" first second first_pid deadline
  first=$(case_id concurrent-a)
  second=$(case_id concurrent-b)
  make_world concurrent
  spawn_in concurrent "$first" "$case_dir/a" gate 0 &
  first_pid=$!
  deadline=$((SECONDS + 60))
  while [ ! -d "$case_dir/pool/gate" ] && [ "$SECONDS" -lt "$deadline" ]; do "$REAL_SLEEP" 0.1; done
  spawn_in concurrent "$second" "$case_dir/b" gate 0
  if [ ! -e "$case_dir/home/state/$first.meta" ] && kill -0 "$first_pid" 2>/dev/null; then
    touch "$case_dir/first-was-waiting"
  fi
  touch "$case_dir/pool/release"
  wait "$first_pid"
}

declare_case() {  # <name>: register the case's socket and task id for cleanup
  SOCKETS+=("$RUN_TAG-$1")
  TASK_IDS+=("$(case_id "$1")")
}

case_out() { cat "$TMP_ROOT/$1/spawn.out"; }
case_rc() { cat "$TMP_ROOT/$1/rc"; }
case_elapsed() { cat "$TMP_ROOT/$1/elapsed"; }
case_id() { printf 'thw-%s-%s' "$1" "$$"; }

for c in slow stuck ceiling failed wrongplace blindslow blindflicker blind peerprogress peerstalled peerhandoff concurrent; do declare_case "$c"; done
TASK_IDS+=("$(case_id concurrent-a)" "$(case_id concurrent-b)")

# A copy that takes longer than the original bound but is still advancing: the
# stand-in works for ten seconds (the original loop gives up after sixty
# compressed polls, a few seconds), and the stall window is shorter than that, so
# only watching for progress can tell this get from a stuck one.
run_case slow advance 10 FM_TREEHOUSE_GET_STALL_SECS=4 &
PID_SLOW=$!
# A get that hangs with nothing changing: refused at the stall window.
run_case stuck hang 120 FM_TREEHOUSE_GET_STALL_SECS=3 &
PID_STUCK=$!
# A get that keeps advancing past the ceiling: refused at the ceiling.
run_case ceiling advance 120 FM_TREEHOUSE_GET_STALL_SECS=30 FM_TREEHOUSE_GET_MAX_SECS=6 &
PID_CEILING=$!
# A get that errors out immediately: refused promptly, saying it exited.
run_case failed fail 0 FM_TREEHOUSE_GET_EXIT_GRACE_SECS=1 &
PID_FAILED=$!
# A get that lands in the primary checkout's subdirectory: the isolation
# assertion still refuses it.
run_case wrongplace subdir 0 &
PID_WRONG=$!
PIDS=("$PID_SLOW" "$PID_STUCK" "$PID_CEILING" "$PID_FAILED" "$PID_WRONG")
# A slow get the spawn can never observe, with a generous unobservable bound:
# it settles only after a hundred polls, so a bound that is still a fixed sixty
# polls refuses it.
run_case blindslow polls 100 FMT_PS_FAIL_EVERY=1 FM_TREEHOUSE_GET_START_SECS=400 &
PIDS+=("$!")
# A slow get whose process table read fails once every twenty polls: a failed
# read after the first sixty polls must not refuse a get that is still advancing.
run_case blindflicker polls 100 FMT_PS_FAIL_EVERY=20 &
PIDS+=("$!")
# A get the spawn can never observe that never settles: refused at the
# unobservable bound, saying why.
run_case blind hang 120 FMT_PS_FAIL_EVERY=1 FM_TREEHOUSE_GET_START_SECS=3 &
PIDS+=("$!")
if [ "$POOL_CASES" -eq 1 ]; then
  # A get queued behind a peer that holds the pool lock for ten seconds while
  # working: the get itself shows nothing for longer than the stall window.
  run_pool_case peerprogress progress 10 FM_TREEHOUSE_GET_STALL_SECS=4 &
  PIDS+=("$!")
  # The same queue behind a peer that holds the lock and does nothing.
  run_pool_case peerstalled stall 120 FM_TREEHOUSE_GET_STALL_SECS=3 &
  PIDS+=("$!")
  # A queue behind a peer that hands the lock to another and keeps working.
  run_handoff_case &
  PIDS+=("$!")
fi
run_concurrent_case &
PIDS+=("$!")
wait "${PIDS[@]}"
for f in peerprogress/peer.pid peerstalled/peer.pid peerhandoff/first.pid peerhandoff/second.pid; do
  [ -r "$TMP_ROOT/$f" ] || continue
  PEER_PIDS+=("$(cat "$TMP_ROOT/$f")")
done

test_slow_but_advancing_get_completes_the_launch() {
  local c=slow out rc meta wt
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 0 "$rc" "a slow but advancing treehouse get must not be refused: $out"
  assert_contains "$out" "spawned $(case_id $c)" "the spawn did not report success: $out"
  meta="$TMP_ROOT/$c/home/state/$(case_id $c).meta"
  wt=$(sed -n 's/^worktree=//p' "$meta")
  case "$wt" in "$TMP_ROOT/$c/pool/slot-"*) ;; *) fail "meta recorded '$wt', not the worktree the get settled in" ;; esac
  [ "$(git -C "$wt" rev-parse --show-toplevel)" != "$TMP_ROOT/$c/project" ] \
    || fail "the recorded worktree is the primary checkout"
  pass "a slow but advancing treehouse get completes the launch and records its worktree"
}

test_stuck_get_is_refused_at_the_stall_window() {
  local c=stuck out rc
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 1 "$rc" "a hung treehouse get must be refused"
  assert_contains "$out" "treehouse get made no progress for 3s" "the refusal does not say the get stalled: $out"
  assert_contains "$out" "waiting on: " "the refusal does not name what the get was waiting on: $out"
  [ "$(case_elapsed $c)" -lt 40 ] || fail "the stalled get was not refused within the stall window"
  assert_absent "$TMP_ROOT/$c/home/state/$(case_id $c).meta" "a refused launch recorded a task"
  pass "a get whose processes stop changing is refused at the stall window, naming what it waits on"
}

test_endless_get_is_refused_at_the_ceiling() {
  local c=ceiling out rc
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 1 "$rc" "a get that never settles must be refused at the ceiling"
  assert_contains "$out" "still not settled in a worktree after 6s" "the refusal does not name the ceiling: $out"
  [ "$(case_elapsed $c)" -lt 40 ] || fail "the ceiling did not bound the wait"
  pass "a get that keeps advancing but never settles is refused at the ceiling"
}

test_failed_get_is_refused_promptly() {
  local c=failed out rc
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 1 "$rc" "a treehouse get that exited with an error must be refused"
  assert_contains "$out" "treehouse get exited without entering a worktree" "the refusal does not say the get exited: $out"
  [ "$(case_elapsed $c)" -lt 30 ] || fail "the exited get was not refused promptly"
  assert_absent "$TMP_ROOT/$c/home/state/$(case_id $c).meta" "a refused launch recorded a task"
  pass "a get that exits without a worktree is refused promptly and says so"
}

test_isolation_assertion_still_refuses_a_primary_checkout() {
  local c=wrongplace out rc
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 1 "$rc" "a get that lands inside the primary checkout must be refused"
  assert_contains "$out" "did not yield an isolated worktree" "the isolation refusal did not fire: $out"
  assert_absent "$TMP_ROOT/$c/home/state/$(case_id $c).meta" "a refused launch recorded a task"
  pass "a get that lands in the primary checkout is still refused by the isolation assertion"
}

test_unobservable_slow_get_honours_the_start_bound() {
  local c=blindslow out rc
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 0 "$rc" "a slow get must not be refused before FM_TREEHOUSE_GET_START_SECS passes unobserved: $out"
  assert_contains "$out" "spawned $(case_id $c)" "the spawn did not report success: $out"
  pass "an unobservable get is waited on for FM_TREEHOUSE_GET_START_SECS, not a fixed sixty polls"
}

test_one_failed_process_read_does_not_refuse_an_advancing_get() {
  local c=blindflicker out rc
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 0 "$rc" "an advancing get must not be refused because one process-table read failed: $out"
  assert_contains "$out" "spawned $(case_id $c)" "the spawn did not report success: $out"
  pass "a failed process-table read restarts nothing and refuses nothing while the get keeps advancing"
}

test_unobservable_get_is_refused_at_the_start_bound() {
  local c=blind out rc
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 1 "$rc" "a get that can never be observed must still be refused"
  assert_contains "$out" "treehouse get could not be observed for 3s" "the refusal does not say the get could not be observed: $out"
  [ "$(case_elapsed $c)" -lt 40 ] || fail "the unobservable get was not refused at its bound"
  assert_absent "$TMP_ROOT/$c/home/state/$(case_id $c).meta" "a refused launch recorded a task"
  pass "a get that can never be observed is refused at FM_TREEHOUSE_GET_START_SECS, saying why"
}

test_get_queued_behind_a_working_peer_completes_the_launch() {
  local c=peerprogress out rc meta wt scans
  if [ "$POOL_CASES" -ne 1 ]; then echo "skip: perl or lsof not found"; return 0; fi
  out=$(case_out $c)
  rc=$(case_rc $c)
  expect_code 0 "$rc" "a get waiting its turn behind a working peer on its pool must not be refused: $out"
  assert_contains "$out" "spawned $(case_id $c)" "the spawn did not report success: $out"
  meta="$TMP_ROOT/$c/home/state/$(case_id $c).meta"
  wt=$(sed -n 's/^worktree=//p' "$meta")
  case "$wt" in "$TMP_ROOT/$c/pool/slot-"*) ;; *) fail "meta recorded '$wt', not the worktree the get settled in" ;; esac
  scans=$(cat "$TMP_ROOT/$c/lsof-scans" 2>/dev/null | wc -l | tr -d ' ')
  [ "$scans" -le 2 ] \
    || fail "the wait rescanned every process's open files on each poll while the same peer kept working: $scans scans"
  pass "a get queued on the pool lock behind a peer that keeps working completes the launch, finding that peer once"
}

test_get_queued_behind_a_stalled_peer_is_refused_naming_it() {
  local c=peerstalled out rc peer
  if [ "$POOL_CASES" -ne 1 ]; then echo "skip: perl or lsof not found"; return 0; fi
  out=$(case_out $c)
  rc=$(case_rc $c)
  peer=$(cat "$TMP_ROOT/$c/peer.pid")
  expect_code 1 "$rc" "a get queued behind a stalled peer must be refused"
  assert_contains "$out" "made no progress for 3s (waiting on: " "the refusal does not name what the get was waiting on: $out"
  assert_contains "$out" "and nothing else holding its pool lock (treehouse-state.lock) open advanced either: pid $peer (" \
    "the refusal does not name the stalled peer holding the pool lock: $out"
  [ "$(case_elapsed $c)" -lt 40 ] || fail "the get queued behind a stalled peer was not refused within the stall window"
  assert_absent "$TMP_ROOT/$c/home/state/$(case_id $c).meta" "a refused launch recorded a task"
  pass "a get queued on the pool lock behind a peer that does nothing is refused, naming that peer"
}

test_get_follows_the_pool_lock_to_its_current_holder() {
  local c=peerhandoff out rc first second
  if [ "$POOL_CASES" -ne 1 ]; then echo "skip: perl or lsof not found"; return 0; fi
  out=$(case_out $c)
  rc=$(case_rc $c)
  first=$(cat "$TMP_ROOT/$c/first.pid")
  second=$(cat "$TMP_ROOT/$c/second.pid")
  expect_code 1 "$rc" "a get queued behind a stalled holder must be refused"
  assert_present "$TMP_ROOT/$c/second.holding" "the second peer never took the pool lock, so the case proved nothing"
  assert_contains "$out" "advanced either: pid $second (" \
    "the refusal does not name the operation that now holds the pool lock: $out"
  assert_not_contains "$out" "pid $first (" \
    "the refusal counts or blames an operation that already closed the pool lock: $out"
  [ "$(case_elapsed $c)" -lt 40 ] \
    || fail "a peer that closed the pool lock but kept working still counted as progress"
  pass "a get follows the pool lock from a peer that closed it but kept working to the peer that holds it now"
}

test_second_dispatch_proceeds_while_a_slow_get_runs() {
  local dir="$TMP_ROOT/concurrent" first second out
  first=$(case_id concurrent-a)
  second=$(case_id concurrent-b)
  out=$(cat "$dir/b/spawn.out")
  expect_code 0 "$(cat "$dir/b/rc")" "a second fresh dispatch in the same home must not be refused while another get runs: $out"
  assert_contains "$out" "spawned $second" "the second dispatch did not report success: $out"
  assert_present "$dir/first-was-waiting" "the second dispatch did not finish while the first was still inside its get"
  out=$(cat "$dir/a/spawn.out")
  expect_code 0 "$(cat "$dir/a/rc")" "the first dispatch must complete once its get settles: $out"
  assert_contains "$out" "spawned $first" "the first dispatch did not report success: $out"
  assert_present "$dir/home/state/$first.meta" "the first dispatch recorded no task"
  assert_present "$dir/home/state/$second.meta" "the second dispatch recorded no task"
  pass "a second fresh dispatch in the same home proceeds while the first one's get is still running"
}

test_the_wait_strands_no_temp_root() {
  local c
  for c in slow blindslow blindflicker peerprogress; do
    assert_absent "/tmp/fm-$(case_id $c)/treehouse-get.shell-pid" "the wait left its pid record behind after a successful launch ($c)"
  done
  # A refused launch has made no task, so nothing may be left for teardown to miss.
  for c in stuck ceiling failed wrongplace blind peerstalled peerhandoff; do
    assert_absent "/tmp/fm-$(case_id $c)" "a refused launch stranded a temp root ($c)"
  done
  pass "the wait's pid record is removed on success and a refusal strands no temp root"
}

test_slow_but_advancing_get_completes_the_launch
test_stuck_get_is_refused_at_the_stall_window
test_endless_get_is_refused_at_the_ceiling
test_failed_get_is_refused_promptly
test_isolation_assertion_still_refuses_a_primary_checkout
test_unobservable_slow_get_honours_the_start_bound
test_one_failed_process_read_does_not_refuse_an_advancing_get
test_unobservable_get_is_refused_at_the_start_bound
test_get_queued_behind_a_working_peer_completes_the_launch
test_get_queued_behind_a_stalled_peer_is_refused_naming_it
test_get_follows_the_pool_lock_to_its_current_holder
test_second_dispatch_proceeds_while_a_slow_get_runs
test_the_wait_strands_no_temp_root

echo "# all fm-spawn-treehouse-wait tests passed"
