#!/usr/bin/env bash
# tests/fm-mkdir-lib.test.sh - fm_mkdir_exclusive, the directory create that
# firstmate's claims and locks rely on. A claim directory must be made by
# exactly one caller, however the host mkdir behaves when it loses a race.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mkdir-lib)
LIB="$ROOT/bin/fm-mkdir-lib.sh"
REAL_MKDIR=$(command -v mkdir)
CALLS="$TMP_ROOT/calls"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# A host mkdir stand-in: --version names it, and every other call is logged and
# either made by the real mkdir or, as uutils mkdir does when another process
# made the path first, reported as a success with no -v line for a directory
# that exists.
cat > "$FAKEBIN/mkdir" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'mkdir (%s) 0.0\n' "$FAKE_MKDIR_IDENTITY"
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_MKDIR_CALLS"
case "$FAKE_MKDIR_BEHAVIOR" in
  real) exec "$FAKE_MKDIR_REAL" "$@" ;;
  lost-race) "$FAKE_MKDIR_REAL" "$@" 2>/dev/null || [ -d "${!#}" ] ;;
esac
SH
chmod +x "$FAKEBIN/mkdir"

# Run fm_mkdir_exclusive under <umask> in a fresh shell that sourced the
# library, with the stand-in as the host mkdir, so each run probes it anew.
with_fake_mkdir() {  # <identity> <behavior> <umask> <dir> [mode]
  local identity=$1 behavior=$2
  shift 2
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  PATH="$FAKEBIN:$PATH" FAKE_MKDIR_IDENTITY=$identity FAKE_MKDIR_BEHAVIOR=$behavior \
    FAKE_MKDIR_CALLS=$CALLS FAKE_MKDIR_REAL=$REAL_MKDIR \
    bash -c '. "$1"; umask "$2"; shift 2; fm_mkdir_exclusive "$@"' _ "$LIB" "$@"
}

has_mode() {  # <dir> <octal-mode>
  [ -n "$(find "$1" -prune -perm "$2" -print 2>/dev/null)" ]
}

test_a_claim_lost_to_another_process_fails_under_a_uutils_mkdir() {
  local dir="$TMP_ROOT/uutils-claim" rc=0
  mkdir "$dir.fixture"
  PATH="$FAKEBIN:$PATH" FAKE_MKDIR_IDENTITY='uutils coreutils' FAKE_MKDIR_BEHAVIOR=lost-race \
    FAKE_MKDIR_CALLS="$TMP_ROOT/fixture-calls" FAKE_MKDIR_REAL=$REAL_MKDIR mkdir "$dir.fixture" \
    || fail "fixture: the uutils stand-in must report success for a directory that exists"
  with_fake_mkdir 'uutils coreutils' lost-race 022 "$dir" \
    || fail "a fresh claim was refused under a uutils mkdir"
  [ -d "$dir" ] || fail "a claim under a uutils mkdir did not make its directory"
  with_fake_mkdir 'uutils coreutils' lost-race 022 "$dir" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "a second claim of one directory succeeded under a uutils mkdir"
  pass "a claim another process already made fails under a uutils mkdir that reports success for it"
}

test_any_other_mkdir_makes_the_claim_itself() {
  local dir="$TMP_ROOT/gnu-claim" rc=0
  : > "$CALLS"
  with_fake_mkdir 'GNU coreutils' real 022 "$dir" \
    || fail "a fresh claim was refused under a GNU mkdir"
  with_fake_mkdir 'GNU coreutils' real 022 "$dir" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "a second claim of one directory succeeded under a GNU mkdir"
  [ "$(grep -c -- "$dir" "$CALLS")" -eq 2 ] \
    || fail "a GNU mkdir did not make both claim attempts itself: $(cat "$CALLS")"
  pass "any mkdir other than uutils makes the claim itself"
}

test_a_mode_is_exact_and_no_mode_follows_the_umask() {
  local identity behavior label dir
  for identity in 'uutils coreutils' 'GNU coreutils'; do
    case "$identity" in uutils*) behavior=lost-race label=uutils ;; *) behavior=real label=GNU ;; esac
    dir="$TMP_ROOT/mode-$label"
    with_fake_mkdir "$identity" "$behavior" 077 "$dir-750" 750 \
      || fail "$label: a claim with a mode was refused"
    has_mode "$dir-750" 0750 || fail "$label: mode 750 under umask 077 was not exact"
    with_fake_mkdir "$identity" "$behavior" 022 "$dir-umask" \
      || fail "$label: a claim without a mode was refused"
    has_mode "$dir-umask" 0755 || fail "$label: a claim without a mode did not follow umask 022"
  done
  pass "a given mode is exact and no mode follows the umask, under uutils and any other mkdir"
}

test_concurrent_claims_of_one_directory_have_one_winner() {
  local round winners
  for round in $(seq 1 25); do
    # shellcheck disable=SC2016 # Expanded by the inner shell.
    bash -c '
      . "$1"
      for racer in 1 2 3 4 5 6 7 8; do
        (fm_mkdir_exclusive "$2" 2>/dev/null && echo "won $racer") &
      done
      wait
    ' _ "$LIB" "$TMP_ROOT/race-$round" > "$TMP_ROOT/race-$round.out"
    winners=$(grep -c '^won ' "$TMP_ROOT/race-$round.out")
    [ "$winners" -eq 1 ] || fail "round $round: $winners concurrent callers claimed one directory"
  done
  pass "concurrent claims of one directory on this host's mkdir have exactly one winner"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_a_claim_lost_to_another_process_fails_under_a_uutils_mkdir
  test_any_other_mkdir_makes_the_claim_itself
  test_a_mode_is_exact_and_no_mode_follows_the_umask
  test_concurrent_claims_of_one_directory_have_one_winner
fi
