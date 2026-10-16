#!/usr/bin/env bash
# Live driver for the treehouse get wait in bin/fm-spawn.sh.
# Runs the given code root's real fm-spawn.sh (and fm-teardown.sh) against a real
# tmux server on a private socket or a real isolated Herdr lab session, with the
# REAL treehouse binary on a throwaway project whose pool lives under this
# world's temp dir (treehouse.toml root). The project's git post-checkout hook,
# which treehouse runs inside `git worktree add` while it holds the pool lock
# (treehouse-state.lock), stands in for a slow copy on a loaded host.
# Time is real: no sleep shim, and FM_TREEHOUSE_GET_* stay at their defaults
# unless the caller exports them.
#
# Usage: live-treehouse-wait.sh <code-root> <tmux|herdr> <scenario> <outdir>
#   slow       one fresh spawn whose hook works visibly for HOOK_SECS seconds
#   fail       one fresh spawn whose hook fails, so treehouse get exits with an error
#   hang       one fresh spawn whose hook hangs with no progress at all
#   queue      N fresh spawns in one home on one pool, each started once the
#              previous one's get is running; every hook works HOOK_SECS seconds
#   queuehang  two fresh spawns; the first get's hook hangs holding the pool
#              lock and the second queues behind it
#   slowfail   one fresh spawn whose hook works HOOK_SECS seconds inside the new
#              worktree and then fails, so treehouse get exits with an error
# SEPARATE_HOMES=1 gives each queued spawn its own home (as firstmate and a
# secondmate share one project pool). WARMUP=1 first runs one quick spawn per
# home, so on Herdr the scenario's spawns are projected next to it.
set -u
CODE_ROOT=$1 BACKEND=$2 SCENARIO=$3 OUT=$4
HEAD_ROOT=${HEAD_ROOT:-$CODE_ROOT}
HOOK_SECS=${HOOK_SECS:-100}
N=${N:-2}
mkdir -p "$OUT"
log() { printf '[%s +%ss] %s\n' "$(date '+%H:%M:%S')" "$((SECONDS - T0))" "$*" | tee -a "$OUT/driver.log"; }
T0=$SECONDS

unset NO_MISTAKES_GATE TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
REAL_PATH=$PATH
W=$(mktemp -d /tmp/fml.XXXXXX)
W=$(cd "$W" && pwd -P)
PROJ="$W/project"
HOMED="$W/home"
FAKEBIN="$W/fakebin"
POOL="$W/pool"
SOCK="fml-$$"
LAB_READY=0
mkdir -p "$FAKEBIN" "$HOMED/data" "$HOMED/projects" "$HOMED/state" "$HOMED/config" "$POOL" "$PROJ"
log "world $W code-root $CODE_ROOT backend $BACKEND scenario $SCENARIO hook_secs $HOOK_SECS n $N"
log "FM_TREEHOUSE_GET_STALL_SECS=${FM_TREEHOUSE_GET_STALL_SECS:-<default>} MAX=${FM_TREEHOUSE_GET_MAX_SECS:-<default>} EXIT_GRACE=${FM_TREEHOUSE_GET_EXIT_GRACE_SECS:-<default>} START=${FM_TREEHOUSE_GET_START_SECS:-<default>}"

cleanup() {
  local pid
  for pid in $(cat "$W/hook-pids" 2>/dev/null); do
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
  done
  if [ "$BACKEND" = tmux ]; then
    tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  elif [ "$LAB_READY" -eq 1 ]; then
    PATH="$REAL_PATH" "$HEAD_ROOT/bin/fm-herdr-lab.sh" teardown "$HERDR_LAB_SESSION" >> "$OUT/driver.log" 2>&1 \
      && log "lab session $HERDR_LAB_SESSION torn down; default fleet session unchanged" \
      || log "LAB TEARDOWN FAILED"
  fi
  for id in $(cat "$W/ids" 2>/dev/null); do rm -rf "/tmp/fm-$id"; done
  rm -rf "$W"
}
trap cleanup EXIT

# Project: one commit plus a treehouse.toml that keeps the pool in this world.
git -C "$PROJ" init -q
printf '# live treehouse wait fixture\n' > "$PROJ/README.md"
printf 'root = "%s"\n' "$POOL" > "$PROJ/treehouse.toml"
git -C "$PROJ" add README.md treehouse.toml
git -C "$PROJ" -c user.name='Firstmate Live' -c user.email='live@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$W/project.origin.git"
git -C "$PROJ" remote add origin "file://$W/project.origin.git"
# The hook reads its behaviour per run from $W/hook-mode (the first line is
# consumed by the first get to reach it, later gets use the last line).
cat > "$PROJ/.git/hooks/post-checkout" <<SH
#!/bin/bash
echo \$\$ >> "$W/hook-pids"
mode=\$(head -n 1 "$W/hook-mode")
[ "\$(wc -l < "$W/hook-mode")" -le 1 ] || { tail -n +2 "$W/hook-mode" > "$W/hook-mode.next"; mv "$W/hook-mode.next" "$W/hook-mode"; }
echo "\$(date +%s) \$(date +%H:%M:%S) hook start mode=\$mode pid=\$\$ cwd=\$PWD" >> "$W/hook.log"
case "\$mode" in
  slow:*) n=\${mode#slow:}; i=0; while [ \$i -lt \$n ]; do sleep 1; i=\$((i + 1)); done ;;
  hang) sleep 86400 ;;
  slowfail:*) n=\${mode#slowfail:}; i=0; while [ \$i -lt \$n ]; do sleep 1; i=\$((i + 1)); done; echo "hook: fatal: setup failed after \$n s" >&2; echo "\$(date +%s) \$(date +%H:%M:%S) hook fail pid=\$\$" >> "$W/hook.log"; exit 1 ;;
  fail) echo "hook: fatal: cannot prepare worktree" >&2; echo "\$(date +%s) \$(date +%H:%M:%S) hook fail pid=\$\$" >> "$W/hook.log"; exit 1 ;;
esac
echo "\$(date +%s) \$(date +%H:%M:%S) hook end mode=\$mode pid=\$\$" >> "$W/hook.log"
SH
chmod +x "$PROJ/.git/hooks/post-checkout"
touch "$HOMED/state/.last-watcher-beat"

if [ "$BACKEND" = tmux ]; then
  printf 'set -g default-command "bash --noprofile --norc"\n' > "$W/tmux.conf"
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$(command -v tmux)" -L "$SOCK" -f "$W/tmux.conf" "\$@"
SH
  chmod +x "$FAKEBIN/tmux"
else
  export REAL_HERDR HERDR_ORIGINAL_PATH HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_SESSION
  REAL_HERDR=$(command -v herdr)
  HERDR_ORIGINAL_PATH=$REAL_PATH
  HERDR_LAB_HELPER="$HEAD_ROOT/bin/fm-herdr-lab.sh"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) echo "live wrapper: unexpected caller-supplied session flag" >&2; exit 1 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
if [ -n "${HERDR_CALL_LOG:-}" ]; then
  out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@" 2>"$HERDR_CALL_LOG.err.$$"); rc=$?
  { printf '%s pid=%s ppid=%s rc=%s: herdr %s\n' "$(date +%H:%M:%S)" "$$" "$PPID" "$rc" "$*"; printf '  out: %s\n' "$(printf '%s' "$out" | head -c 600)"; printf '  err: %s\n' "$(head -c 400 "$HERDR_CALL_LOG.err.$$")"; } >> "$HERDR_CALL_LOG"
  cat "$HERDR_CALL_LOG.err.$$" >&2; rm -f "$HERDR_CALL_LOG.err.$$"
  [ -z "$out" ] || printf '%s\n' "$out"
  exit "$rc"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
  chmod +x "$FAKEBIN/herdr"
  printf '#!/bin/bash\nexec /bin/bash --noprofile --norc "$@"\n' > "$W/bash-norc"
  chmod +x "$W/bash-norc"
  HERDR_LAB_SESSION=$(PATH="$REAL_PATH" "$HERDR_LAB_HELPER" name fm-live-thw)
  HERDR_SESSION=$HERDR_LAB_SESSION
  SHELL="$W/bash-norc" PATH="$REAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >> "$OUT/driver.log" 2>&1 \
    || { log "could not provision the Herdr lab"; exit 2; }
  LAB_READY=1
  printf 'on\n' > "$HOMED/config/herdr-presentation-spaces"
  log "provisioned isolated Herdr lab session $HERDR_LAB_SESSION (projected presentation on)"
fi
export PATH="$FAKEBIN:$REAL_PATH"

# home_for <id>: the home a spawn uses (one per queued spawn with SEPARATE_HOMES=1).
home_for() {
  local n
  if [ "${SEPARATE_HOMES:-0}" = 1 ]; then
    n=$(printf '%s\n' "$1" | sed -n 's/^fml-[a-z]*\([0-9]*\)-.*/\1/p')
    [ -n "$n" ] || n=0
    printf '%s/home%s\n' "$W" "$n"
  else
    printf '%s\n' "$W/home"
  fi
}
make_home() {
  mkdir -p "$1/data" "$1/projects" "$1/state" "$1/config"
  touch "$1/state/.last-watcher-beat"
  [ "$BACKEND" != herdr ] || printf 'on\n' > "$1/config/herdr-presentation-spaces"
}

# spawn_one <id>: one fresh dispatch of task <id>, its transcript in $OUT/<id>.out.
spawn_one() {
  local id=$1 start rc HOMED
  HOMED=$(home_for "$id")
  make_home "$HOMED"
  echo "$id" >> "$W/ids"
  mkdir -p "$HOMED/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLive check of the treehouse get wait for %s.\n\n## Firstmate spec\nRecord the worktree the get settled in.\n' "$id" > "$HOMED/data/$id/brief.md"
  start=$SECONDS
  log "spawn $id: start"
  ( cd "$PROJ" && FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOMED" FM_ROOT_OVERRIDE="$CODE_ROOT" \
      ${SPAWN_TRACE:+bash -x} "$CODE_ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "sh -c 'sleep 600'" --mode no-mistakes --yolo off --backend "$BACKEND" ) \
    > "$OUT/$id.out" 2>&1
  rc=$?
  printf 'rc=%s elapsed=%ss\n' "$rc" "$((SECONDS - start))" > "$OUT/$id.result"
  log "spawn $id: exit $rc after $((SECONDS - start))s: $(grep -E '^(spawned|error:|warning:)' "$OUT/$id.out" | tr '\n' ' ' | cut -c1-400)"
}

# record <id>: meta, pane state, and where the agent runs.
record() {
  local id=$1 HOMED meta win pane wt
  HOMED=$(home_for "$id")
  meta="$HOMED/state/$id.meta"
  {
    echo "### $id"
    cat "$OUT/$id.result"
    echo "--- spawn transcript"
    cat "$OUT/$id.out"
    if [ -e "$meta" ]; then
      echo "--- state/$id.meta (worktree and endpoint)"
      grep -E '^(worktree|window|backend|herdr_pane_id|project)=' "$meta"
      wt=$(sed -n 's/^worktree=//p' "$meta")
      echo "--- git worktree toplevel of recorded worktree"
      git -C "$wt" rev-parse --show-toplevel
      win=$(sed -n 's/^window=//p' "$meta")
      if [ "$BACKEND" = tmux ]; then
        echo "--- tmux pane_current_path / pane_current_command for $win"
        tmux display -p -t "$win" '#{pane_current_path} #{pane_current_command}'
        echo "--- tmux capture-pane $win"
        tmux capture-pane -p -t "$win" | sed '/^$/d' | tail -n 15
      else
        pane=$(sed -n 's/^herdr_pane_id=//p' "$meta"); [ -n "$pane" ] || pane=$win
        echo "--- herdr pane process-info $pane"
        herdr pane process-info "$pane" 2>&1 | head -c 1500; echo
        echo "--- herdr pane read $pane"
        herdr pane read "$pane" --source recent --lines 15 2>&1 | sed '/^$/d' | tail -n 15
      fi
    else
      echo "--- no state/$id.meta (no task recorded)"
      [ -e "$HOMED/state/$id.herdr-presentation" ] && echo "--- presentation journal state/$id.herdr-presentation still present" || true
    fi
    echo
  } >> "$OUT/record.txt" 2>&1
}

teardown_one() {
  local id=$1 start rc HOMED
  HOMED=$(home_for "$id")
  [ -e "$HOMED/state/$id.meta" ] || return 0
  # treehouse return resets the slot, which runs the hook again; keep it quick.
  echo fast > "$W/hook-mode"
  start=$SECONDS
  ( cd "$PROJ" && FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOMED" FM_ROOT_OVERRIDE="$CODE_ROOT" \
      "$CODE_ROOT/bin/fm-teardown.sh" "$id" --force ) > "$OUT/$id.teardown.out" 2>&1
  rc=$?
  log "teardown $id: exit $rc after $((SECONDS - start))s; meta left: $([ -e "$HOMED/state/$id.meta" ] && echo yes || echo no); worktrees: $(git -C "$PROJ" worktree list | wc -l | tr -d ' ')"
}

# wait_get_running <id>: until that spawn's pane shell has reported its pid for
# the get (written right before `treehouse get` runs) or its hook started.
wait_get_running() {
  local id=$1 deadline=$((SECONDS + 120)) n
  n=$(wc -l < "$W/hook.log" 2>/dev/null || echo 0)
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -e "/tmp/fm-$id/treehouse-get.shell-pid" ] && return 0
    [ "$(wc -l < "$W/hook.log" 2>/dev/null || echo 0)" -gt "$n" ] && return 0
    sleep 0.5
  done
  return 1
}

# warmup <id>...: one quick spawn in each of those spawns' homes.
WARM_IDS=()
warmup() {
  local id wid
  [ "${WARMUP:-0}" = 1 ] || return 0
  for id in "$@"; do
    if [ "${SEPARATE_HOMES:-0}" = 1 ]; then
      wid="fml-w$(printf '%s\n' "$id" | sed -n 's/^fml-[a-z]*\([0-9]*\)-.*/\1/p')-$$"
    else
      wid="fml-w-$$"
    fi
    case " ${WARM_IDS[*]:-} " in *" $wid "*) continue ;; esac
    echo fast > "$W/hook-mode"
    spawn_one "$wid"
    WARM_IDS+=("$wid")
  done
}

case "$SCENARIO" in
  slow|fail|hang|slowfail)
    warmup "fml-$SCENARIO-$$"
    case "$SCENARIO" in slow|slowfail) echo "$SCENARIO:$HOOK_SECS" ;; *) echo "$SCENARIO" ;; esac > "$W/hook-mode"
    id="fml-$SCENARIO-$$"
    spawn_one "$id"
    record "$id"
    if [ "$SCENARIO" = slowfail ] && [ -e "$(home_for "$id")/state/$id.meta" ]; then
      # The launch reported success; see where its agent ends up once the get fails.
      deadline=$((SECONDS + HOOK_SECS + 60))
      until grep -q 'hook fail' "$W/hook.log" 2>/dev/null || [ "$SECONDS" -ge "$deadline" ]; do sleep 1; done
      log "hook failed; treehouse get exited; probing the launched endpoint"
      sleep 5
      pane=$(sed -n 's/^herdr_pane_id=//p' "$(home_for "$id")/state/$id.meta")
      win=$(sed -n 's/^window=//p' "$(home_for "$id")/state/$id.meta")
      {
        echo "### $id after treehouse get failed (recorded worktree=$(sed -n 's/^worktree=//p' "$(home_for "$id")/state/$id.meta"))"
        echo "primary checkout: $PROJ"
        if [ "$BACKEND" = herdr ]; then
          echo "--- herdr pane process-info --pane $pane"
          herdr pane process-info --pane "$pane" 2>&1
          echo "--- herdr pane read $pane"
          herdr pane read "$pane" --source recent --lines 25 2>&1 | sed '/^$/d' | tail -n 25
        else
          echo "--- tmux pane_current_path / command"
          tmux display -p -t "$win" '#{pane_current_path} #{pane_current_command}'
          tmux capture-pane -p -t "$win" | sed '/^$/d' | tail -n 25
        fi
        echo "--- processes running 'sleep 600' and their cwd"
        for p in $(pgrep -f "^sleep 600$"); do printf 'pid %s cwd %s\n' "$p" "$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"; done
      } >> "$OUT/record.txt" 2>&1
    fi
    teardown_one "$id"
    ;;
  queue)
    qids=(); for i in $(seq 1 "$N"); do qids+=("fml-q$i-$$"); done
    warmup "${qids[@]}"
    echo "slow:$HOOK_SECS" > "$W/hook-mode"
    pids=()
    for i in $(seq 1 "$N"); do
      id="fml-q$i-$$"
      spawn_one "$id" &
      pids+=("$!")
      [ "$i" -eq "$N" ] || wait_get_running "$id" || log "spawn $id never started its get"
      sleep 2
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    for i in $(seq 1 "$N"); do record "fml-q$i-$$"; done
    for i in $(seq 1 "$N"); do teardown_one "fml-q$i-$$"; done
    ;;
  queuehang)
    id1="fml-qh1-$$" id2="fml-qh2-$$"
    warmup "$id1" "$id2"
    printf 'hang\nslow:5\n' > "$W/hook-mode"
    spawn_one "$id1" & p1=$!
    wait_get_running "$id1" || log "first spawn never started its get"
    sleep 3
    spawn_one "$id2" & p2=$!
    wait "$p1"; wait "$p2"
    record "$id1"; record "$id2"
    ;;
esac
for id in "${WARM_IDS[@]:-}"; do [ -z "$id" ] || teardown_one "$id"; done
echo "--- hook.log" >> "$OUT/record.txt"
cat "$W/hook.log" >> "$OUT/record.txt" 2>/dev/null
log "done"
