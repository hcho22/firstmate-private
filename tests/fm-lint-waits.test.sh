#!/usr/bin/env bash
# Contract tests for bin/fm-lint-waits.sh, the owner of the counted-wait rule:
# a test that waits for an event by counting a fixed number of short sleeps
# fails on a loaded host, so the lint flags that form and accepts a clock
# deadline, a count of 60 seconds or more, and a window that names its reason.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINTW="$ROOT/bin/fm-lint-waits.sh"

# write_case <dir> <name>: the case body from stdin, as a test file. Fixtures
# spell -lt, -le, -ge and -gt as -LT, -LE, -GE and -GT, and a line-leading for or
# until as FOR or UNTIL, so this file's own text is not a finding of the
# repository-wide check below.
write_case() {
  sed -e 's/ -LT / -lt /g' -e 's/ -LE / -le /g' -e 's/ -GE / -ge /g' -e 's/ -GT / -gt /g' \
    -e 's/^\( *\)FOR /\1for /' -e 's/^\( *\)UNTIL /\1until /' >"$1/$2"
}

test_flags_a_counted_short_wait() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-lint-waits-flag)
  write_case "$tmp" counted.test.sh <<'SH'
#!/usr/bin/env bash
i=0
while [ ! -e "$marker" ] && [ "$i" -LT 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
SH
  out=$("$LINTW" "$tmp/counted.test.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a counted 5 s wait was not flagged (rc=$rc): $out"
  assert_contains "$out" "$tmp/counted.test.sh:3: counted wait of 50 x 0.1 s (5 s)" \
    "the finding does not name the loop's line and budget"
  # shellcheck disable=SC2016 # The literal clock-deadline form the finding names.
  assert_contains "$out" 'deadline=$((SECONDS + 60))' "the finding does not name the clock-deadline form"
  pass "fm-lint-waits flags a counted short wait with its line and budget"
}

test_accepts_clock_deadlines_long_counts_and_variable_bounds() {
  local tmp out
  tmp=$(fm_test_tmproot fm-lint-waits-accept)
  write_case "$tmp" accepted.test.sh <<'SH'
#!/usr/bin/env bash
deadline=$((SECONDS + 60))
while [ ! -e "$marker" ] && [ "$SECONDS" -lt "$deadline" ]; do
  sleep 0.05
done
i=0
while [ "$i" -LT 600 ]; do
  [ -e "$marker" ] && break
  sleep 0.1
  i=$((i + 1))
done
i=0
while [ "$i" -lt "$limit" ]; do
  sleep 0.1
  i=$((i + 1))
done
seen=0
while [ "$seen" -LT 3 ] && [ "$SECONDS" -lt "$deadline" ]; do
  sleep 0.1
  seen=$((seen + 1))
done
SH
  out=$("$LINTW" "$tmp/accepted.test.sh" 2>&1) \
    || fail "an accepted wait form was flagged: $out"
  pass "fm-lint-waits accepts clock deadlines, counts of 60 s or more, and variable bounds"
}

test_named_windows_pass_and_bare_markers_do_not() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-lint-waits-marker)
  write_case "$tmp" named.test.sh <<'SH'
#!/usr/bin/env bash
reap=0
# fm-lint-waits: allow a reap grace before the forced kill below
while kill -0 "$pid" 2>/dev/null && [ "$reap" -LT 20 ]; do
  sleep 0.1
  reap=$((reap + 1))
done
# fm-lint-waits: allow a detection window the case reads either way
tries=0
while [ "$tries" -LT 5 ] && [ ! -e "$marker" ]; do sleep 0.01; tries=$((tries + 1)); done
SH
  out=$("$LINTW" "$tmp/named.test.sh" 2>&1) || fail "a named deliberate window was flagged: $out"
  write_case "$tmp" bare.test.sh <<'SH'
#!/usr/bin/env bash
reap=0
# fm-lint-waits: allow
while kill -0 "$pid" 2>/dev/null && [ "$reap" -LT 20 ]; do
  sleep 0.1
  reap=$((reap + 1))
done
SH
  out=$("$LINTW" "$tmp/bare.test.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a marker without a reason exempted the loop (rc=$rc): $out"
  pass "fm-lint-waits accepts a window that names its reason and rejects a bare marker"
}

test_finds_multi_line_and_single_line_loops() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-lint-waits-shapes)
  write_case "$tmp" shapes.test.sh <<'SH'
#!/usr/bin/env bash
check() {
  local i=0
  while ! grep -Fq ready "$log" 2>/dev/null \
    && [ "$i" -LT 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  i=0
  while [ "$i" -LT 500 ] && [ ! -f "$dir/done" ]; do sleep 0.01; i=$((i + 1)); done
}
SH
  out=$("$LINTW" "$tmp/shapes.test.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "multi-line and single-line counted waits were not flagged (rc=$rc): $out"
  assert_contains "$out" "shapes.test.sh:4: counted wait of 100 x 0.1 s (10 s)" "the multi-line condition was missed"
  assert_contains "$out" "shapes.test.sh:10: counted wait of 500 x 0.01 s (5 s)" "the single-line loop was missed"
  pass "fm-lint-waits finds counted waits with multi-line conditions and on one line"
}

test_flags_counted_for_loops_that_leave_early() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-lint-waits-for)
  write_case "$tmp" for.test.sh <<'SH'
#!/usr/bin/env bash
FOR _ in $(seq 1 50); do [ -e "$m" ] && break; sleep 0.1; done
FOR _ in {1..20}; do
  [ -e "$m" ] && break
  sleep 0.2
done
FOR _ in 1 2 3 4 5; do [ -e "$m" ] && return 0; sleep 1; done
FOR ((n = 0; n < 20; n++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
FOR _ in $(seq 1 100); do
  FOR job in "$dir"/*; do
    [ -e "$job" ] && break 2
  done
  sleep 0.05
done
FOR _ in $(seq 1 6); do probe; sleep 0.3; done
SH
  out=$("$LINTW" "$tmp/for.test.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "counted for loops were not flagged (rc=$rc): $out"
  assert_contains "$out" "for.test.sh:2: counted wait of 50 x 0.1 s (5 s)" "a for over seq was missed"
  assert_contains "$out" "for.test.sh:3: counted wait of 20 x 0.2 s (4 s)" "a for over a brace range was missed"
  assert_contains "$out" "for.test.sh:7: counted wait of 5 x 1 s (5 s)" "a for over a list of integers was missed"
  assert_contains "$out" "for.test.sh:8: counted wait of 20 x 0.05 s (1 s)" "an arithmetic for was missed"
  assert_contains "$out" "for.test.sh:9: counted wait of 100 x 0.05 s (5 s)" "a for left by break 2 was missed"
  assert_not_contains "$out" "for.test.sh:15:" "a paced for with no early exit was flagged as a wait"
  pass "fm-lint-waits flags counted for loops that leave early, and not paced ones"
}

test_flags_until_loops_body_guards_and_bin_sleep() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-lint-waits-guards)
  write_case "$tmp" guards.test.sh <<'SH'
#!/usr/bin/env bash
UNTIL [ -e "$m" ] || [ "$i" -GE 40 ]; do sleep 0.1; i=$((i + 1)); done
while ! probe; do
  [ "$i" -LT 30 ] || fail "never ready"
  sleep 0.1
  i=$((i + 1))
done
while ! probe; do
  attempts=$((attempts + 1))
  if [ "$attempts" -GE 100 ]; then
    fail "never ready"
  fi
  sleep 0.01
done
while [ ! -e "$m" ] && [ "$i" -LT 100 ]; do /bin/sleep 0.01; i=$((i + 1)); done
stable=0
while :; do
  if probe; then stable=$((stable + 1)); else stable=0; fi
  [ "$stable" -GE 4 ] && break
  sleep 0.1
done
SH
  out=$("$LINTW" "$tmp/guards.test.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "counted until loops and body guards were not flagged (rc=$rc): $out"
  assert_contains "$out" "guards.test.sh:2: counted wait of 40 x 0.1 s (4 s)" "an until counter was missed"
  assert_contains "$out" "guards.test.sh:3: counted wait of 30 x 0.1 s (3 s)" "a || guard in the body was missed"
  assert_contains "$out" "guards.test.sh:8: counted wait of 100 x 0.01 s (1 s)" "an if guard in the body was missed"
  assert_contains "$out" "guards.test.sh:15: counted wait of 100 x 0.01 s (1 s)" "a /bin/sleep wait was missed"
  assert_not_contains "$out" "guards.test.sh:17:" "a run of observations the body resets was flagged as a bound"
  pass "fm-lint-waits flags until counters, body guards and /bin/sleep, and not a reset run"
}

test_reads_heredoc_stubs_and_literal_default_bounds() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-lint-waits-stubs)
  write_case "$tmp" stubs.test.sh <<'SH'
#!/usr/bin/env bash
install_stub() {
  cat > "$1/git" <<STUB
#!/usr/bin/env bash
waited=0
while ! grep -q START '$log' && [ "\$waited" -LT 500 ]; do
  sleep 0.01
  waited=\$((waited + 1))
done
STUB
}
wait_wake() {
  local home=$1 limit=${2:-50} waited=0
  while ! grep -q ready "$home/q" && [ "$waited" -LT "$limit" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
}
wait_raised() {
  local pid=$1 limit=${2:-50} i=0
  [ "$limit" -GE "$GUARD" ] || limit=$GUARD
  while [ "$i" -LT "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
}
wait_given() {
  local pid=$1 limit=$2 i=0
  while [ "$i" -LT "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
}
SH
  out=$("$LINTW" "$tmp/stubs.test.sh" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "an escaped stub and a literal default bound were not flagged (rc=$rc): $out"
  assert_contains "$out" "stubs.test.sh:6: counted wait of 500 x 0.01 s (5 s)" "the escaped here-document stub was missed"
  assert_contains "$out" "stubs.test.sh:14: counted wait of 50 x 0.1 s (5 s)" "the literal default bound was missed"
  [ "$(printf '%s\n' "$out" | grep -c 'counted wait of')" -eq 2 ] \
    || fail "a bound the caller or a later assignment sets was flagged: $out"
  pass "fm-lint-waits reads escaped here-document stubs and literal default bounds, not caller-set ones"
}

test_counts_only_the_loops_own_sleeps() {
  local tmp out
  tmp=$(fm_test_tmproot fm-lint-waits-own)
  write_case "$tmp" launch.test.sh <<'SH'
#!/usr/bin/env bash
i=1
while [ "$i" -LE 40 ]; do
  bash -c '
    if try_lock; then
      sleep 1
    fi
  ' _ "$lock" &
  i=$((i + 1))
done
n=1
while [ "$n" -LE 3 ]; do
  cat > "$dir/fake" <<STUB
#!/usr/bin/env bash
sleep 0.02
STUB
  (
    while [ ! -e "$ready" ]; do
      sleep 0.01
    done
  ) &
  deadline=$((SECONDS + 60))
  while [ ! -e "$staged" ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.02
  done
  n=$((n + 1))
done
SH
  out=$("$LINTW" "$tmp/launch.test.sh" 2>&1) \
    || fail "sleeps in a quoted script, here-document, subshell, or nested loop were counted as the outer loop's: $out"
  pass "fm-lint-waits counts only the sleeps at the loop's own level"
}

test_repository_tests_are_clean() {
  local out
  out=$("$LINTW" 2>&1) || fail "the repository's tests have counted short waits:"$'\n'"$out"
  pass "the repository's tests have no counted short waits"
}

# bin/fm-lint.sh's default path runs this owner, so CI and commands.lint fail
# on a counted short wait.
test_default_lint_runs_the_waits_check() {
  local tmp fakebin out rc=0
  tmp=$(fm_test_tmproot fm-lint-waits-default)
  mkdir -p "$tmp/repo/bin" "$tmp/repo/tests"
  fakebin=$(fm_fakebin "$tmp")
  cp "$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-lint-waits.sh" "$tmp/repo/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/repo/bin/fm-lint-workflows.sh"
  chmod +x "$tmp/repo/bin/"*.sh
  cat >"$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { printf 'version: %s\n' '$("$ROOT/bin/fm-lint.sh" --required-version)'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  write_case "$tmp/repo/tests" counted.test.sh <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -LT 20 ]; do
  [ -e "$marker" ] && break
  sleep 0.1
  i=$((i + 1))
done
SH
  out=$(PATH="$fakebin:$PATH" CI=true FM_LINT_JOBS=1 "$tmp/repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the default lint passed a counted short wait: $out"
  assert_contains "$out" "tests/counted.test.sh:3: counted wait of 20 x 0.1 s (2 s)" \
    "the default lint did not report the counted wait"
  pass "bin/fm-lint.sh's default path fails on a counted short wait"
}

test_flags_a_counted_short_wait
test_accepts_clock_deadlines_long_counts_and_variable_bounds
test_named_windows_pass_and_bare_markers_do_not
test_finds_multi_line_and_single_line_loops
test_flags_counted_for_loops_that_leave_early
test_flags_until_loops_body_guards_and_bin_sleep
test_reads_heredoc_stubs_and_literal_default_bounds
test_counts_only_the_loops_own_sleeps
test_repository_tests_are_clean
test_default_lint_runs_the_waits_check
