#!/usr/bin/env bash
# Live reproduction of the reported bug against a REAL Herdr server.
#
# Runs the real Claude SessionStart hook entry point (bin/fm-sessionstart-run.sh)
# for an isolated firstmate home whose two tasks live on a Herdr session whose
# server is NOT running yet, so startup's own fleet snapshot is what launches the
# server. Then opens a fresh pane in that server - the pane a later captain
# session would run in - and, inside it, records the FM_ environment and runs
# bin/fm-crew-state.sh for each task.
#
# Isolation: HOME points at a throwaway directory, so Herdr resolves every socket
# under it and can never reach the captain's real Herdr sessions. The whole run
# uses `env -i`, so nothing from the invoking shell leaks in. Network tools are
# exit-0 fakes so no real GitHub/no-mistakes calls happen.
#
# Usage: live-herdr-session-env.sh <source-tree> <label> <evidence-dir>
set -u
SRC=${1:?source tree containing bin/}
LABEL=${2:?label}
OUT=${3:?evidence dir}
JQ_DIR=$(dirname "$(command -v jq)")
HERDR_BIN=$(command -v herdr)

W=$(mktemp -d /tmp/fmlv.XXXX)
H=$W/h root=$W/r home=$W/m fb=$W/fb sess=lv
mkdir -p "$H" "$home/state" "$home/data" "$home/config" "$fb"
git init -q -b main "$root"
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
ln -s "$SRC/bin" "$root/bin"
printf '# Firstmate\n' > "$root/AGENTS.md"

for t in tmux node chrome-devtools-axi gh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/$t"
done
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.46\nexit 0\n' > "$fb/lavish-axi"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.29\nexit 0\n' > "$fb/gh-axi"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z"\nexit 0\n' > "$fb/no-mistakes"
printf '#!/usr/bin/env bash\n[ "${1:-} ${2:-}" = "get --help" ] && echo "Usage: treehouse get [--lease]"\nexit 0\n' > "$fb/treehouse"
chmod +x "$fb"/*

for task in alpha beta; do
  mkdir -p "$W/wt-$task"
  {
    printf 'kind=ship\nproject=demo\nmode=direct-PR\nyolo=0\nbackend=herdr\n'
    printf 'window=%s:p-%s\nherdr_session=%s\nworktree=%s\nspawn_gen=g1\nharness=claude\n' \
      "$sess" "$task" "$sess" "$W/wt-$task"
  } > "$home/state/$task.meta"
  printf 'working: %s\n' "$task" > "$home/state/$task.status"
done

CLEAN_PATH="$fb:$(dirname "$HERDR_BIN"):$JQ_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
clean_env() {
  env -i HOME="$H" USER="$USER" LOGNAME="$USER" SHELL=/bin/bash TERM=xterm-256color \
    LANG=en_US.UTF-8 TMPDIR="${TMPDIR:-/tmp}" PATH="$CLEAN_PATH" "$@"
}
herdr_iso() { clean_env "$HERDR_BIN" "$@" --session "$sess"; }

log=$OUT/live-herdr-$LABEL.txt
{
  echo "# live herdr session-env check: $LABEL"
  echo "# source tree: $SRC ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo exported))"
  echo "# isolated HOME: $H (herdr sockets resolve under it)"
  echo
  echo "## before startup: isolated herdr server running?"
  herdr_iso status --json 2>&1 | jq -c '{running: .server.running, socket: .server.socket}'

  echo
  echo "## run the Claude SessionStart hook entry point: bin/fm-sessionstart-run.sh"
  printf '{"source":"startup"}' | clean_env CLAUDECODE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$root/bin/fm-sessionstart-run.sh" > "$W/session-start.out" 2>&1
  echo "exit=$? (digest saved to session-start.out; first lines:)"
  head -5 "$W/session-start.out"

  echo
  echo "## after startup: did startup launch the isolated herdr server?"
  herdr_iso status --json 2>&1 | jq -c '{running: .server.running, socket: .server.socket}'
  server_pid=
  for p in $(pgrep -f "herdr server --session $sess"); do
    ps eww -p "$p" -o command= 2>/dev/null | grep -Fq "HOME=$H " && { server_pid=$p; break; }
  done
  echo "server pid: ${server_pid:-<none>}"
  if [ -n "$server_pid" ]; then
    echo "server process environment, FM_* names (ps eww):"
    ps eww -p "$server_pid" -o command= | tr ' ' '\n' | grep '^FM_' | sed 's/=.*//' | sort | sed 's/^/  /'
    echo "  (end)"
  fi

  echo
  echo "## open a fresh pane in that server (what a later captain session gets)"
  ws=$(herdr_iso workspace create --cwd "$W" --label probe --no-focus 2>&1)
  pane=$(printf '%s' "$ws" | jq -r '.. | .pane_id? // empty' 2>/dev/null | head -1)
  echo "pane: ${pane:-<none>}"
  [ -n "$pane" ] || echo "workspace create said: $ws"
  if [ -n "$pane" ]; then
    sleep 1
    herdr_iso pane run "$pane" "clear; echo '--- FM_ vars in this pane ---'; env | grep '^FM_' | sort; echo '--- end ---'; for t in alpha beta; do echo \"\$ fm-crew-state.sh \$t\"; FM_HOME=$home FM_ROOT_OVERRIDE=$root $root/bin/fm-crew-state.sh \$t 2>&1; done; echo PANE-DONE" >/dev/null 2>&1
    for _ in $(seq 1 60); do
      herdr_iso pane read "$pane" --source recent --lines 80 2>/dev/null | grep -q '^PANE-DONE' && break
      sleep 0.5
    done
    echo "pane transcript (herdr pane read):"
    herdr_iso pane read "$pane" --source recent --lines 80 2>&1 | sed '/^[[:space:]]*$/d' | sed 's/^/  | /'
  fi

  echo
  echo "## teardown: stop only the isolated session"
  herdr_iso session stop "$sess" 2>&1 | head -2 || true
  [ -z "${server_pid:-}" ] || { sleep 1; kill "$server_pid" 2>/dev/null || true; }
} 2>&1 | tee "$log"
cp "$W/session-start.out" "$OUT/live-herdr-$LABEL-session-start-digest.txt" 2>/dev/null || true
pkill -f "$W/" 2>/dev/null || true
echo "workdir: $W"
