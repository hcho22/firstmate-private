#!/usr/bin/env bash
# Regression test for the wait fm-spawn.sh makes for `treehouse get` to enter a
# worktree (bin/fm-spawn.sh, the loop after the launch lines, and the
# treehouse_get_tree comment that owns the rules).
#
# Creating the isolated copy is the one launch step whose duration depends on
# the host, so the wait must not be a fixed poll count: a copy that is slow but
# still advancing completes the launch, a get that exited or is stuck is refused
# with a message naming which, and a get that never settles is refused at a
# ceiling. Every case drives the public interface (bin/fm-spawn.sh) against a
# REAL tmux server on a private socket whose pane shell is a bare bash, with a
# `treehouse` stand-in on PATH that behaves as the case asks (works for a while,
# exits with an error, hangs, or lands in the wrong place).
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
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-wait)
RUN_TAG="thw$$"
SOCKETS=()

cleanup_all() {
  local sock id
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
esac
wt="\$FMT_POOL/slot-\$\$"
git worktree add -q --detach "\$wt" >&2 || exit 1
cd "\$wt" && exec bash --noprofile --norc -i
SH
  chmod +x "$dir/treehouse"
}

# run_case <name> <mode> <seconds> [VAR=value ...]: build a world, run the spawn
# and leave its output, exit code, elapsed seconds, and recorded state under
# $TMP_ROOT/<name>. Cases are independent, so the caller runs them together.
run_case() {
  local name=$1 mode=$2 seconds=$3 case_dir proj home fakebin sock id start rc kv
  shift 3
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  sock="$RUN_TAG-$name"
  id="thw-$name-$$"
  mkdir -p "$fakebin" "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$case_dir/pool"
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
  printf '#!/usr/bin/env bash\nexec "%s" 600\n' "$REAL_SLEEP" > "$fakebin/codex"
  make_treehouse_stub "$fakebin"
  chmod +x "$fakebin/tmux" "$fakebin/sleep" "$fakebin/codex"
  printf 'codex\n' > "$home/config/crew-harness"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the treehouse get wait for $name.

## Firstmate spec
Record the worktree the get settled in.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n%s\n' "$sock" "$id" > "$case_dir/ids"
  start=$SECONDS
  (
    cd "$proj" || exit 1
    for kv in "$@"; do export "${kv?}"; done
    # An ambient Herdr or tmux runtime must never steer the spawn: it is pinned to
    # tmux, on the private socket above, inside this case's own home.
    env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID \
      -u HERDR_WORKSPACE_ID -u HERDR_SESSION \
      FMT_MODE="$mode" FMT_SECONDS="$seconds" FMT_POOL="$case_dir/pool" FMT_PROJECT="$proj" \
      FM_BACKEND=tmux FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off --backend tmux
  ) > "$case_dir/spawn.out" 2>&1
  rc=$?
  printf '%s\n' "$rc" > "$case_dir/rc"
  printf '%s\n' "$((SECONDS - start))" > "$case_dir/elapsed"
}

declare_case() {  # <name>: register the case's socket and task id for cleanup
  SOCKETS+=("$RUN_TAG-$1")
  TASK_IDS+=("thw-$1-$$")
}

case_out() { cat "$TMP_ROOT/$1/spawn.out"; }
case_rc() { cat "$TMP_ROOT/$1/rc"; }
case_elapsed() { cat "$TMP_ROOT/$1/elapsed"; }
case_id() { printf 'thw-%s-%s' "$1" "$$"; }

for c in slow stuck ceiling failed wrongplace; do declare_case "$c"; done

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
wait "$PID_SLOW" "$PID_STUCK" "$PID_CEILING" "$PID_FAILED" "$PID_WRONG"

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

test_the_wait_strands_no_temp_root() {
  local c
  assert_absent "/tmp/fm-$(case_id slow)/treehouse-get.shell-pid" "the wait left its pid record behind after a successful launch"
  # A refused launch has made no task, so nothing may be left for teardown to miss.
  for c in stuck ceiling failed wrongplace; do
    assert_absent "/tmp/fm-$(case_id $c)" "a refused launch stranded a temp root ($c)"
  done
  pass "the wait's pid record is removed on success and a refusal strands no temp root"
}

test_slow_but_advancing_get_completes_the_launch
test_stuck_get_is_refused_at_the_stall_window
test_endless_get_is_refused_at_the_ceiling
test_failed_get_is_refused_promptly
test_isolation_assertion_still_refuses_a_primary_checkout
test_the_wait_strands_no_temp_root

echo "# all fm-spawn-treehouse-wait tests passed"
