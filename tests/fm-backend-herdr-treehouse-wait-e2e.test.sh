#!/usr/bin/env bash
# Isolated real-Herdr E2E for the wait bin/fm-spawn.sh makes for `treehouse get`
# to enter a worktree (tests/fm-spawn-treehouse-wait.test.sh owns the rules and
# covers them on tmux; this proves the shared wait on the Herdr backend, whose
# pane exposes the foreground cwd the wait settles on).
# A stand-in `treehouse` that spends longer than the original sixty-poll bound
# while visibly working must complete the launch and record its worktree, and
# one that errors out must be refused promptly, saying it exited. One that fails
# after running a hook inside its new worktree, which moves the pane's newest
# foreground process there, must be refused the same way with no launch line
# ever typed into the pane.
# While a projected spawn's get is still running, neither the session-wide
# presentation lock nor the home's task-set lock may be held, so a teardown on
# the same Herdr session gets past its lock preflight and a second fresh
# dispatch in the same home completes, projected, before that get settles. The
# teardown's `treehouse return` then waits behind the get's pool lock without
# holding the presentation lock either. After its get, a projected spawn waits
# for a busy presentation lock instead of launching without it, and refuses,
# naming the holder and the projection it leaves, only at the get ceiling. A
# refused get's abort cleanup waits for a busy lock the same way and removes
# its projection and journal under it, without a warning.
# Every Herdr call goes through the guarded named-session lab helper, and lab
# teardown verifies that the default fleet session is unchanged.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
REAL_SLEEP=$(command -v sleep)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-treehouse-wait.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
PANEBIN="$TMP_ROOT/panebin"
mkdir -p "$FAKEBIN" "$PANEBIN"
export REAL_HERDR HERDR_ORIGINAL_PATH HERDR_LAB_HELPER

# Route every production-adapter call through the lab helper, which appends the
# one trailing session flag; the adapter's session-independent version read goes
# straight to the real binary with the same explicit lab session.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) echo "test wrapper: unexpected caller-supplied session flag" >&2; exit 1 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
# A `sleep` shim compresses the spawn's one-second poll sleep (as the tmux test
# does), so the original sixty polls are a few seconds, shorter than the slow get.
cat > "$FAKEBIN/sleep" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = 1 ]; then exec "$REAL_SLEEP" 0.05; fi
exec "$REAL_SLEEP" "\$@"
SH
# The pane shell must see the stand-in: the lab server is provisioned with a bare
# bash (no startup files that could put the real treehouse first) and a PATH that
# leads with $PANEBIN, which holds only the stand-in so it never shadows herdr.
printf '#!/bin/bash\nexec /bin/bash --noprofile --norc "$@"\n' > "$TMP_ROOT/bash-norc"
# The pane's environment is fixed when the lab server starts, so the stand-in
# reads each case's behaviour from control files instead of the environment.
CONTROL="$TMP_ROOT/control"
mkdir -p "$CONTROL"
# In gate mode the first get to start holds the pool's treehouse-state.lock, as
# treehouse does across its copy, while it starts short-lived children until the
# case creates control/release; every later get acquires at once. In gatefail
# mode that first get then exits with an error instead of acquiring. In hookfail
# mode the get creates its worktree, runs a hook-like child inside it for the
# case's seconds, and then exits with an error instead of entering. Teardown's
# `treehouse return` has nothing to give back, but it takes that same pool lock
# first, as treehouse does, so it waits behind a gated get.
cat > "$PANEBIN/treehouse" <<SH
#!/usr/bin/env bash
FMT_POOL=\$(cat "$CONTROL/pool")
if [ "\${1:-}" = return ]; then
  : > "$CONTROL/return-started"
  exec perl -MFcntl=:flock -e 'open(my \$f, ">>", \$ARGV[0]) or die "open: \$!"; flock(\$f, LOCK_EX) or die "flock: \$!"' \
    "\$FMT_POOL/treehouse-state.lock"
fi
echo "stand-in treehouse get" >&2
FMT_MODE=\$(cat "$CONTROL/mode"); FMT_SECONDS=\$(cat "$CONTROL/seconds")
case "\$FMT_MODE" in
  fail) echo "stand-in: fatal: cannot create worktree" >&2; exit 1 ;;
  advance)
    end=\$((SECONDS + FMT_SECONDS))
    while [ "\$SECONDS" -lt "\$end" ]; do "$REAL_SLEEP" 0.2; done
    ;;
  gate|gatefail)
    if mkdir "$CONTROL/gate" 2>/dev/null; then
      perl -MFcntl=:flock -e '
        my (\$lock, \$held, \$release, \$sleep) = @ARGV;
        open(my \$f, ">>", \$lock) or die "open: \$!";
        flock(\$f, LOCK_EX) or die "flock: \$!";
        open(my \$m, ">", \$held) or die "held: \$!";
        close(\$m);
        system(\$sleep, "0.2") until -e \$release;
      ' "\$FMT_POOL/treehouse-state.lock" "$CONTROL/gate/held" "$CONTROL/release" "$REAL_SLEEP" || exit 1
      [ "\$FMT_MODE" != gatefail ] || { echo "stand-in: fatal: cannot create worktree" >&2; exit 1; }
    fi
    ;;
esac
wt="\$FMT_POOL/slot-\$\$"
git worktree add -q --detach "\$wt" >&2 || exit 1
if [ "\$FMT_MODE" = hookfail ]; then
  (cd "\$wt" && "$REAL_SLEEP" "\$FMT_SECONDS")
  echo "stand-in: fatal: setup failed inside the new worktree" >&2
  exit 1
fi
cd "\$wt" && exec bash --noprofile --norc -i
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/sleep" "$PANEBIN/treehouse" "$TMP_ROOT/bash-norc"
export PATH="$FAKEBIN:$PANEBIN:$PATH"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# The lab is isolated, so a Herdr pane inherited from the launching terminal must
# not follow the spawn into it as a cross-session parent identity.
herdr_forget_inherited_pane

HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" name fm-herdr-treehouse-wait)
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION
LAB_READY=0
LOCK_HOLDER_PID=
cleanup_all() {
  local status=$?
  [ -z "$LOCK_HOLDER_PID" ] || kill "$LOCK_HOLDER_PID" 2>/dev/null || true
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || status=1
    LAB_READY=0
  fi
  rm -rf "/tmp/fm-hthw-slow-$$" "/tmp/fm-hthw-fail-$$" "/tmp/fm-hthw-hookfail-$$" "/tmp/fm-hthw-gated-$$" "/tmp/fm-hthw-second-$$" \
    "/tmp/fm-hthw-held-$$" "/tmp/fm-hthw-refused-$$" "/tmp/fm-hthw-ceiling-$$" "$TMP_ROOT"
  exit "$status"
}
trap cleanup_all EXIT
SHELL="$TMP_ROOT/bash-norc" PATH="$PANEBIN:$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
POOL_DIR="$TMP_ROOT/pool"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$POOL_DIR" "$PROJECT_DIR"
git -C "$PROJECT_DIR" init -q
printf '# treehouse wait fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJECT_DIR" "$PROJECT_DIR.origin.git"
git -C "$PROJECT_DIR" remote add origin "file://$PROJECT_DIR.origin.git"
touch "$HOME_DIR/state/.last-watcher-beat"

spawn_case() {  # <id> <mode> <seconds> [VAR=value ...]
  local id=$1 mode=$2 seconds=$3 kv
  shift 3
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the treehouse get wait on Herdr for $id.

## Firstmate spec
Record the worktree the get settled in.
EOF
  (
    cd "$PROJECT_DIR" || exit 1
    for kv in "$@"; do export "${kv?}"; done
    printf '%s\n' "$mode" > "$CONTROL/mode"
    printf '%s\n' "$seconds" > "$CONTROL/seconds"
    printf '%s\n' "$POOL_DIR" > "$CONTROL/pool"
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT_DIR" "sh -c 'sleep 120'" --mode no-mistakes --yolo off --backend herdr
  ) 2>&1
}

SLOW_ID="hthw-slow-$$"
out=$(spawn_case "$SLOW_ID" advance 10 FM_TREEHOUSE_GET_STALL_SECS=4) \
  || fail "a slow but advancing treehouse get was refused on Herdr: $out"
wt=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$SLOW_ID.meta")
case "$wt" in "$POOL_DIR/slot-"*) ;; *) fail "meta recorded '$wt', not the worktree the get settled in" ;; esac
pass "a slow but advancing treehouse get completes the launch on Herdr and records its worktree"

FAIL_ID="hthw-fail-$$"
start=$SECONDS
if out=$(spawn_case "$FAIL_ID" fail 0 FM_TREEHOUSE_GET_EXIT_GRACE_SECS=1); then
  fail "a treehouse get that exited with an error was not refused on Herdr: $out"
fi
case "$out" in *"treehouse get exited without entering a worktree"*) ;; *) fail "the refusal does not say the get exited: $out" ;; esac
[ $((SECONDS - start)) -lt 40 ] || fail "the exited get was not refused promptly on Herdr"
[ ! -e "$HOME_DIR/state/$FAIL_ID.meta" ] || fail "a refused launch recorded a task"
pass "a get that exits without a worktree is refused promptly on Herdr and says so"

HOOKFAIL_ID="hthw-hookfail-$$"
if out=$(spawn_case "$HOOKFAIL_ID" hookfail 5 FM_TREEHOUSE_GET_EXIT_GRACE_SECS=1); then
  fail "a treehouse get that failed after a hook ran inside its new worktree launched on Herdr: $out"
fi
case "$out" in *"treehouse get exited without entering a worktree"*) ;; *) fail "the hook-failed get was not refused for exiting without a worktree: $out" ;; esac
[ ! -e "$HOME_DIR/state/$HOOKFAIL_ID.meta" ] || fail "a refused launch recorded a task"
hookfail_target=$(printf '%s\n' "$out" | sed -n 's/.*; inspect window \([^ ]*\)$/\1/p' | tail -n 1)
[ -n "$hookfail_target" ] || fail "the refusal did not name the pane it left: $out"
hookfail_screen=$(herdr pane read "${hookfail_target#*:}" --source recent --lines 200) \
  || fail "could not read the refused get's pane ${hookfail_target#*:}"
case "$hookfail_screen" in
  *"stand-in: fatal: setup failed inside the new worktree"*) ;;
  *) fail "the refused get's pane does not show the hook failure, so it proves nothing: $hookfail_screen" ;;
esac
case "$hookfail_screen" in
  *GOTMPDIR*|*"sleep 120"*) fail "a launch line was typed into the pane while treehouse get was still running its hook: $hookfail_screen" ;;
esac
pass "a get that fails after a hook ran inside its new worktree is refused on Herdr with no launch line typed"

# wait_for <path> <pid> <what>: until <path> exists, while <pid> still runs.
wait_for() {
  local deadline=$((SECONDS + 120))
  while [ ! -e "$1" ] && kill -0 "$2" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    "$REAL_SLEEP" 0.1
  done
  [ -e "$1" ] || fail "$3"
}

# start_gated <id> <out> <gate|gatefail> [VAR=value ...]: a projected spawn whose
# get holds the pool lock until control/release exists; returns once that get
# holds it.
start_gated() {
  local id=$1 out=$2 mode=$3
  shift 3
  rm -rf "$CONTROL/gate" "$CONTROL/release"
  spawn_case "$id" "$mode" 0 "$@" > "$out" 2>&1 &
  GATED_PID=$!
  wait_for "$CONTROL/gate/held" "$GATED_PID" "the gated spawn $id never started its treehouse get: $(cat "$out")"
  [ -e "$HOME_DIR/state/$id.herdr-presentation" ] \
    || fail "the gated spawn $id was not projected, so it does not exercise the presentation lock"
}

# hold_presentation_lock: hold this lab session's presentation lock from a live
# process (LOCK_HOLDER_PID) until control/lock-release exists.
hold_presentation_lock() {
  local lock
  lock=$(HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_presentation_session_lock_path "$1"
  ' "$ROOT" "$HERDR_LAB_SESSION") || fail "could not resolve the lab session presentation lock"
  rm -f "$CONTROL/lock-held" "$CONTROL/lock-release"
  ROOT="$ROOT" LOCK="$lock" CONTROL="$CONTROL" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$CONTROL/lock-held"
    while [ ! -e "$CONTROL/lock-release" ]; do sleep 0.05; done
    fm_lock_release "$LOCK"
  ' &
  LOCK_HOLDER_PID=$!
  wait_for "$CONTROL/lock-held" "$LOCK_HOLDER_PID" "could not hold the lab session presentation lock"
}

release_presentation_lock() {
  : > "$CONTROL/lock-release"
  wait "$LOCK_HOLDER_PID" || fail "the presentation lock holder failed"
  LOCK_HOLDER_PID=
}

# From here on spawns are projected, so each one holds the session-wide
# presentation lock from its workspace create to just before its get.
printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
GATED_ID="hthw-gated-$$"
SECOND_ID="hthw-second-$$"
start_gated "$GATED_ID" "$TMP_ROOT/gated.out" gate
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-teardown.sh" "$SLOW_ID" --force > "$TMP_ROOT/teardown.out" 2>&1 &
TEARDOWN_PID=$!
wait_for "$CONTROL/return-started" "$TEARDOWN_PID" \
  "a teardown on the same Herdr session did not reach its treehouse return while a projected get was running: $(cat "$TMP_ROOT/teardown.out")"
pass "a teardown on the same Herdr session gets past its presentation lock preflight while a projected spawn's get is still running"

out=$(spawn_case "$SECOND_ID" gate 0) \
  || fail "a second fresh dispatch in the same home did not proceed while a get was running: $out"
[ -e "$HOME_DIR/state/$SECOND_ID.meta" ] || fail "the second dispatch recorded no task"
case "$out" in
  *"presentation focus lock unavailable"*) fail "the second dispatch could not take the presentation lock while a teardown waited in treehouse return: $out" ;;
esac
[ -e "$HOME_DIR/state/$SECOND_ID.herdr-presentation" ] \
  || fail "the second dispatch was not projected while a teardown waited in treehouse return: $out"
pass "a second dispatch in the same home completes, projected, while a get runs and a teardown waits in treehouse return behind it"

if ! { kill -0 "$GATED_PID" 2>/dev/null && [ ! -e "$HOME_DIR/state/$GATED_ID.meta" ] && kill -0 "$TEARDOWN_PID" 2>/dev/null; }; then
  fail "the gated get or the teardown waiting behind it was already over, so the cases above proved nothing: $(cat "$TMP_ROOT/gated.out" "$TMP_ROOT/teardown.out")"
fi
: > "$CONTROL/release"
if wait "$TEARDOWN_PID"; then :; else fail "the teardown failed once the pool lock freed: $(cat "$TMP_ROOT/teardown.out")"; fi
[ ! -e "$HOME_DIR/state/$SLOW_ID.meta" ] || fail "the teardown left its task record behind"
pass "the teardown completes its pane close under the presentation lock once its treehouse return gets the pool lock"
if wait "$GATED_PID"; then :; else fail "the gated spawn failed once its get settled: $(cat "$TMP_ROOT/gated.out")"; fi
wt=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$GATED_ID.meta")
case "$wt" in "$POOL_DIR/slot-"*) ;; *) fail "meta recorded '$wt', not the worktree the gated get settled in" ;; esac
pass "the projected spawn whose get was held open completes once the get settles"

# A presentation lock that is busy when the get settles, for longer than one
# bounded attempt, is waited for: the spawn neither launches without it nor fails.
HELD_ID="hthw-held-$$"
start_gated "$HELD_ID" "$TMP_ROOT/held.out" gate
hold_presentation_lock
: > "$CONTROL/release"
"$REAL_SLEEP" 20
if ! { kill -0 "$GATED_PID" 2>/dev/null && [ ! -e "$HOME_DIR/state/$HELD_ID.meta" ]; }; then
  fail "the spawn did not wait for the busy presentation lock after its get: $(cat "$TMP_ROOT/held.out")"
fi
release_presentation_lock
if wait "$GATED_PID"; then :; else fail "the spawn failed after waiting for the presentation lock: $(cat "$TMP_ROOT/held.out")"; fi
grep -E "presentation focus lock unavailable|presentation lock stayed held" "$TMP_ROOT/held.out" >/dev/null 2>&1 \
  && fail "the spawn did not launch under the presentation lock: $(cat "$TMP_ROOT/held.out")"
[ -e "$HOME_DIR/state/$HELD_ID.meta" ] || fail "the spawn that waited for the presentation lock recorded no task"
pass "a projected spawn waits for a presentation lock still busy after its get and then launches under it"

# A get refused while the presentation lock is busy for longer than one bounded
# attempt: abort cleanup waits for the lock and removes the projection under it.
workspace_count() {
  herdr workspace list | jq '.result.workspaces | length'
}
REFUSED_ID="hthw-refused-$$"
workspaces_before=$(workspace_count) || fail "could not count the lab session's workspaces"
start_gated "$REFUSED_ID" "$TMP_ROOT/refused.out" gatefail FM_TREEHOUSE_GET_EXIT_GRACE_SECS=1
[ "$(workspace_count)" = $((workspaces_before + 1)) ] \
  || fail "the refused-get fixture did not add exactly one projected workspace"
hold_presentation_lock
: > "$CONTROL/release"
"$REAL_SLEEP" 20
if ! { kill -0 "$GATED_PID" 2>/dev/null && [ "$(workspace_count)" = $((workspaces_before + 1)) ]; }; then
  fail "abort cleanup of the refused get did not wait for the busy presentation lock: $(cat "$TMP_ROOT/refused.out")"
fi
release_presentation_lock
if wait "$GATED_PID"; then fail "a get that exited without a worktree launched: $(cat "$TMP_ROOT/refused.out")"; fi
out=$(cat "$TMP_ROOT/refused.out")
case "$out" in
  *"treehouse get exited without entering a worktree"*) ;;
  *) fail "the refused get was not refused for exiting without a worktree: $out" ;;
esac
case "$out" in
  *"leaving projected task pane"*) fail "abort cleanup left the refused get's projection behind: $out" ;;
  *"warning: herdr presentation"*) fail "abort cleanup of the refused get warned: $out" ;;
esac
[ "$(workspace_count)" = "$workspaces_before" ] \
  || fail "abort cleanup did not remove the refused get's projected workspace: $out"
[ ! -e "$HOME_DIR/state/$REFUSED_ID.herdr-presentation" ] \
  || fail "abort cleanup removed the refused get's projection but left its presentation journal: $out"
[ ! -e "$HOME_DIR/state/$REFUSED_ID.meta" ] || fail "a refused launch recorded a task"
pass "a refused get's abort cleanup waits out a busy presentation lock and removes its projection and journal under it"

# Past the get ceiling the spawn refuses, naming the holder, and abort cleanup,
# unable to take the lock either, leaves the projection for inspection and says so.
CEILING_ID="hthw-ceiling-$$"
start_gated "$CEILING_ID" "$TMP_ROOT/ceiling.out" gate FM_TREEHOUSE_GET_MAX_SECS=30
hold_presentation_lock
: > "$CONTROL/release"
if wait "$GATED_PID"; then fail "the spawn launched although the presentation lock stayed busy past the ceiling: $(cat "$TMP_ROOT/ceiling.out")"; fi
out=$(cat "$TMP_ROOT/ceiling.out")
case "$out" in
  *"presentation lock stayed held by pid $LOCK_HOLDER_PID ("*"for 30s after treehouse get settled"*) ;;
  *) fail "the refusal does not name the presentation lock holder and the ceiling: $out" ;;
esac
ceiling_pane=$(printf '%s\n' "$out" | sed -n 's/.*leaving projected task pane \([^ ]*\) and its presentation journal in place.*/\1/p')
[ -n "$ceiling_pane" ] || fail "abort cleanup did not report the projection it left behind: $out"
herdr pane get "$ceiling_pane" >/dev/null 2>&1 || fail "the reported projected pane $ceiling_pane is not what remains"
[ -e "$HOME_DIR/state/$CEILING_ID.herdr-presentation" ] || fail "the presentation journal the refusal reported was not left in place"
[ ! -e "$HOME_DIR/state/$CEILING_ID.meta" ] || fail "a refused launch recorded a task"
release_presentation_lock
pass "a presentation lock still busy at the get ceiling refuses the launch, naming its holder and the projection left behind"

echo "# all fm-backend-herdr-treehouse-wait-e2e tests passed"
