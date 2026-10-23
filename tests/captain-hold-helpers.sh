#!/usr/bin/env bash
# tests/captain-hold-helpers.sh - the shared fixture for the captain-held task
# suites, tests/fm-captain-hold-lifecycle.test.sh and
# tests/fm-captain-hold-records.test.sh: isolated homes, the wrappers that run
# the real scripts against them, the merge-entrypoint fixtures, and the skip
# when jq or tasks-axi is missing. Generic reporters and assertions come from
# lib.sh, pulled in below; the Beads migration fixtures live with their cases
# in the records suite, so only that suite pays for the Beads probe.

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_shared_stub_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

# The generic process-event runner, run against this suite's isolated home and
# its own claim root, so a review armed here can never contend with a real one.
run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_bearings() {  # <home> [extra args]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json "$@"
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# Completes <id>'s captain-call inventory through a separate held task, because
# the origin task is never accepted as its own inventory entry.
complete_through_sibling() {  # <home> <origin-id>
  local home=$1 id=$2
  run_captain "$home" hold "$id-call" --title "Sibling captain call for $id" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    && run_captain "$home" complete "$id" "$id-call"
}

request_reconciles() {  # <home> <source-id> <task-id>...
  local home=$1 source_id=$2 id
  shift 2
  run_captain "$home" bind "$source_id" >/dev/null || return 1
  for id in "$@"; do printf '%s\n' "$id"; done \
    | run_captain "$home" reconcile-requests --source-id "$source_id" \
        --source "captured board result" >/dev/null
}

configure_merged_github() {  # <home>
  local home=$1
  fm_shared_stub "$home/fakebin" "gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"1111111111111111111111111111111111111111","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
        ;;
      *headRefOid*) printf '%s\n' 1111111111111111111111111111111111111111 ;;
    esac
    ;;
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "api graphql")
    printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main'
    ;;
  "api --paginate")
    case " $* " in
      *merge_queue*) ;;
      *) printf '%s\n' '[]' ;;
    esac
    ;;
  "api repos/"*) printf '%s\n' '{"name":"main","protected":false}' ;;
esac
SH
  fm_shared_stub "$home/fakebin" "gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
esac
SH
  : > "$home/gh.log"
  : > "$home/gh-axi.log"
}

run_pr_merge() {  # <home> <id> <url>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_GH_AXI_LOG="$home/gh-axi.log" "$ROOT/bin/fm-pr-merge.sh" "$@"
}

# wait_for_test_file <path> <pid> succeeds once <path> exists, and fails once
# <pid> has exited without creating it. The 60-second clock deadline only
# bounds a real hang, so a loaded host cannot turn a slow start into a failure.
wait_for_test_file() {  # <path> <pid>
  local path=$1 pid=$2 deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -e "$path" ] && return 0
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.01
  done
  [ -e "$path" ]
}

install_reused_task_barriers() {  # <home>
  local home=$1
  fm_shared_stub "$home/fakebin" "perl" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_REUSE_TEARDOWN:-}" = 1 ] \
    && [ ! -e "${FM_TEST_REUSE_TEARDOWN_ONCE:-}" ]; then
  : > "$FM_TEST_REUSE_TEARDOWN_ONCE"
  : > "$FM_TEST_REUSE_TEARDOWN_READY"
  while [ ! -e "$FM_TEST_REUSE_TEARDOWN_RELEASE" ]; do
    "$FM_TEST_REAL_SLEEP" 0.01
  done
fi
exec "$FM_TEST_REAL_PERL" "$@"
SH
  fm_shared_stub "$home/fakebin" "sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_REUSE_MERGE:-}" = 1 ] && [ "${1:-}" = 0.1 ] \
    && [ ! -e "${FM_TEST_REUSE_MERGE_ONCE:-}" ]; then
  : > "$FM_TEST_REUSE_MERGE_ONCE"
  : > "$FM_TEST_REUSE_MERGE_READY"
  while [ ! -e "$FM_TEST_REUSE_MERGE_RELEASE" ]; do
    "$FM_TEST_REAL_SLEEP" 0.01
  done
fi
exec "$FM_TEST_REAL_SLEEP" "$@"
SH
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}
