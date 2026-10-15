#!/usr/bin/env bash
# Isolated real-Herdr E2E for the wait bin/fm-spawn.sh makes for `treehouse get`
# to enter a worktree (tests/fm-spawn-treehouse-wait.test.sh owns the rules and
# covers them on tmux; this proves the shared wait on the Herdr backend, whose
# pane exposes the foreground cwd the wait settles on).
# A stand-in `treehouse` that spends longer than the original sixty-poll bound
# while visibly working must complete the launch and record its worktree, and
# one that errors out must be refused promptly, saying it exited.
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
cat > "$PANEBIN/treehouse" <<SH
#!/usr/bin/env bash
echo "stand-in treehouse get" >&2
FMT_MODE=\$(cat "$CONTROL/mode"); FMT_SECONDS=\$(cat "$CONTROL/seconds"); FMT_POOL=\$(cat "$CONTROL/pool")
case "\$FMT_MODE" in
  fail) echo "stand-in: fatal: cannot create worktree" >&2; exit 1 ;;
  advance)
    end=\$((SECONDS + FMT_SECONDS))
    while [ "\$SECONDS" -lt "\$end" ]; do "$REAL_SLEEP" 0.2; done
    ;;
esac
wt="\$FMT_POOL/slot-\$\$"
git worktree add -q --detach "\$wt" >&2 || exit 1
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
cleanup_all() {
  local status=$?
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || status=1
    LAB_READY=0
  fi
  rm -rf "/tmp/fm-hthw-slow-$$" "/tmp/fm-hthw-fail-$$" "$TMP_ROOT"
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

echo "# all fm-backend-herdr-treehouse-wait-e2e tests passed"
