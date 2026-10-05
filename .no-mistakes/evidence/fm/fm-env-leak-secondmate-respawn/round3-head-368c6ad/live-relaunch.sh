#!/usr/bin/env bash
# live-relaunch.sh <bin-dir> <no-server|clean-server|polluted-server> <label> [pane-shell]
#
# Drives the real bin/fm-session-start.sh against a REAL tmux server on a
# private TMUX_TMPDIR socket, with a throwaway Firstmate home whose recorded
# tmux secondmate endpoint is missing (a home after a reboot), so the deferred
# network stage relaunches that secondmate through bootstrap -> fm-spawn.
# Session start runs from an environment that carries every Firstmate internal
# handoff setting (as from a pane of an older, polluted server), plus the Claude
# harness marker and an ordinary sentinel. Only the agent binary (`pi`) and the
# network toolchain are stand-ins; tmux, session start, bootstrap, and fm-spawn
# are the real product. Windows run the captain's real login shell unless
# pane-shell is given.
#
# Modes:
#   no-server       no tmux server yet; the relaunch is what starts it.
#   clean-server    a server already running, started from a clean environment
#                   (the captain already in tmux); the relaunch only adds a window.
#   polluted-server a server an older Firstmate started from a polluted
#                   environment; reused untouched by design.
set -u
BIN=$1 MODE=$2 LABEL=$3 PANE_SHELL=${4:-}
[ -z "$PANE_SHELL" ] || export SHELL="$PANE_SHELL"
W=$(mktemp -d /tmp/fmlv.XXXXXX)
export TMUX_TMPDIR="$W/t"
mkdir -p "$TMUX_TMPDIR"
unset TMUX
unset NO_MISTAKES_GATE
cd "$W" || exit 2
root="$W/root" home="$W/home" fakebin="$W/fakebin" stale="$W/stale"
id="fmlive-sm-${W##*.}"
mate="$W/secondmate-$id"
pi_env="$W/pi.env"
mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin" "$stale"
mkdir -p "$mate/bin" "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
git init -q -b main "$root"
git -C "$root" -c user.name=fmlive -c user.email=fmlive@example.invalid commit -q --allow-empty -m init
ln -s "$BIN" "$root/bin"
printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
printf '# Firstmate\n' > "$mate/AGENTS.md"
printf 'Second mate charter.\n' > "$mate/data/charter.md"
printf '%s\n' pi > "$home/config/secondmate-harness"
printf '%s\n' manual > "$home/config/backlog-backend"
touch "$home/state/.last-watcher-beat"
{
  printf 'window=firstmate:fm-%s\n' "$id"
  printf 'kind=secondmate\n'
  printf 'harness=pi\n'
  printf 'home=%s\n' "$mate"
} > "$home/state/$id.meta"

stub() { cat > "$fakebin/$1"; chmod +x "$fakebin/$1"; }
for t in node chrome-devtools-axi gh; do printf '#!/usr/bin/env bash\nexit 0\n' | stub "$t"; done
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.46\nexit 0\n' | stub lavish-axi
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.29\nexit 0\n' | stub gh-axi
printf '#!/usr/bin/env bash\n[ "${1:-}" = get ] && [ "${2:-}" = --help ] && echo "Usage: treehouse get [--lease]"\nexit 0\n' | stub treehouse
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z"\nexit 0\n' | stub no-mistakes
# A pass-through tmux: every call reaches the real tmux unchanged; literal text
# typed into a pane (send-keys -l) also has its byte length logged.
REAL_TMUX=$(command -v tmux)
stub tmux <<SH
#!/usr/bin/env bash
prev=
for a in "\$@"; do
  if [ "\$prev" = -l ]; then printf '%s\t%s\n' "\$(printf '%s' "\$a" | wc -c | tr -d ' ')" "\${a:0:70}" >> '$W/typed.log'; fi
  prev=\$a
done
exec '$REAL_TMUX' "\$@"
SH
# The stand-in agent: record the environment the secondmate actually starts
# with, then stay alive so the window keeps its agent process.
stub pi <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --help|-h) echo 'usage: pi [options]'; exit 0 ;;
  --version|-v) echo 'pi 0.0.0-live-stand-in'; exit 0 ;;
esac
env | sort > '$pi_env'
exec sleep 86400
SH

inherited=(
  FM_SESSION_START_STAGE_FILE="$stale/stage"
  FM_CREW_STATE_META_OVERRIDE="$stale/alpha.meta"
  FM_CREW_STATE_STATUS_OVERRIDE="$stale/alpha.status"
  FM_HOME_SUMMARY_IF_IDLE=0
  FM_HOME_SUMMARY_WORKER_BEST_EFFORT=1
  FM_TASKS_AXI_COMPATIBLE=1
  FM_BOOTSTRAP_NETWORK=only
  FM_BOOTSTRAP_NETWORK_LOCK_PID=1
  FM_BOOTSTRAP_LOCKED=1
  FM_BOOTSTRAP_VERBOSE_FACTS=1
  FM_BOOTSTRAP_PARALLEL_DIR="$stale/parallel"
  FM_SPAWN_NO_GUARD=1
  FM_TIMING_LOG="$stale/timings"
  FM_TIMING_EPOCH_MS=1
)
internal=()
for kv in "${inherited[@]}"; do internal+=("${kv%%=*}"); done
PATHV="$fakebin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
names_re="^(FM_[A-Za-z0-9_]*|CLAUDECODE|RELAUNCH_ORDINARY_SENTINEL)="

echo "=== live relaunch: $LABEL (mode=$MODE) ==="
echo "bin: $BIN"
echo "tmux: $(tmux -V), private socket dir: $TMUX_TMPDIR, pane shell: $SHELL"
case "$MODE" in
  polluted-server)
    env -u TMUX "${inherited[@]}" CLAUDECODE=1 FM_HOME=/tmp/wrong-home FM_STATE_OVERRIDE=/tmp/wrong-state \
      RELAUNCH_ORDINARY_SENTINEL=kept PATH="$PATHV" tmux new-session -d -s firstmate
    echo "pre-existing server started by an older Firstmate from a polluted environment; global env:"
    tmux show-environment -g | grep -E "$names_re" | sed 's/^/  /'
    ;;
  clean-server)
    # The captain's own tmux, started from an ordinary login environment.
    env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" SHELL="$SHELL" TERM="${TERM:-xterm-256color}" \
      TMUX_TMPDIR="$TMUX_TMPDIR" PATH="$PATHV" RELAUNCH_ORDINARY_SENTINEL=kept \
      tmux new-session -d -s firstmate
    echo "pre-existing server started from a clean environment; global env:"
    tmux show-environment -g | grep -E "$names_re" | sed 's/^/  /'
    ;;
  no-server)
    tmux ls >/dev/null 2>&1 && { echo "unexpected: a tmux server is already running on the private socket"; exit 2; }
    echo "no tmux server running before session start"
    ;;
esac

echo
echo "--- session start (inherits all internal settings + CLAUDECODE=1 + RELAUNCH_ORDINARY_SENTINEL=kept) ---"
env -u TMUX -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$PATHV" \
  "${inherited[@]}" CLAUDECODE=1 RELAUNCH_ORDINARY_SENTINEL=kept \
  "$root/bin/fm-session-start.sh" > "$W/digest.txt" 2>&1
echo "session start exit: $?"
FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$PATHV" "$root/bin/fm-startup-network.sh" wait 120 >/dev/null 2>&1
echo "deferred network stage report:"
FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$PATHV" "$root/bin/fm-startup-network.sh" report 2>&1 \
  | grep -E 'relaunch|SECONDMATE|secondmate' | sed 's/^/  /'
deadline=$((SECONDS + 60))
while [ ! -s "$pi_env" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done

fails=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }
echo
echo "--- real tmux after session start ---"
tmux list-windows -t firstmate -F '  window #{window_name}: pane_current_command=#{pane_current_command}' 2>&1
echo "tmux server global environment (Firstmate-relevant names):"
global=$(tmux show-environment -g 2>/dev/null)
printf '%s\n' "$global" | grep -E "$names_re" | sed 's/^/  /'
echo "secondmate window pane (what the captain would see):"
tmux capture-pane -p -J -t "firstmate:fm-$id" 2>/dev/null | sed '/^$/d' | fold -w 160 | sed 's/^/  | /'
echo "literal text typed into the secondmate pane (bytes, first 70 chars):"
sed 's/^/  /' "$W/typed.log" 2>/dev/null
echo "relaunched secondmate process environment (Firstmate-relevant names):"
[ -s "$pi_env" ] && grep -E "$names_re" "$pi_env" | sed 's/^/  /'
echo
max_typed=$(cut -f1 "$W/typed.log" 2>/dev/null | sort -n | tail -1)
check "the deferred stage relaunched the dead secondmate into window fm-$id" \
  "tmux list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -qx 'fm-$id'"
check "every line typed into the pane stays under the ~1 KB pty typeahead limit (max ${max_typed:-none} bytes)" \
  "[ -n '${max_typed:-}' ] && [ '${max_typed:-0}' -lt 1024 ]"
check "the typed launch command started the secondmate agent (it recorded its environment)" "[ -s '$pi_env' ]"
if [ "$MODE" != polluted-server ]; then
  for n in "${internal[@]}" FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE CLAUDECODE; do
    check "server global env has no $n" "[ -n \"\$global\" ] && ! printf '%s\n' \"\$global\" | grep -q '^$n='"
  done
  check "server global env keeps ordinary RELAUNCH_ORDINARY_SENTINEL=kept" \
    "printf '%s\n' \"\$global\" | grep -qx RELAUNCH_ORDINARY_SENTINEL=kept"
  for n in "${internal[@]}" CLAUDECODE; do
    check "relaunched secondmate process has no $n" "[ -s '$pi_env' ] && ! grep -q '^$n=' '$pi_env'"
  done
  check "relaunched secondmate keeps ordinary RELAUNCH_ORDINARY_SENTINEL=kept" \
    "grep -qx RELAUNCH_ORDINARY_SENTINEL=kept '$pi_env'"
fi
if [ "$MODE" = no-server ]; then
  check "server global env keeps explicit FM_BACKEND=tmux" "printf '%s\n' \"\$global\" | grep -qx FM_BACKEND=tmux"
fi
check "relaunched secondmate runs in its own home (FM_HOME=$mate)" "grep -Eqx 'FM_HOME=(/private)?$mate' '$pi_env'"
check "secondmate meta still records harness=pi and its home" \
  "grep -qx harness=pi '$home/state/$id.meta' && grep -Eqx 'home=(/private)?$mate' '$home/state/$id.meta'"
if [ "$MODE" = polluted-server ]; then
  echo "observed (documented limitation, not checked): internal names the relaunched secondmate got from the pre-existing polluted server:"
  [ -s "$pi_env" ] && for n in "${internal[@]}" CLAUDECODE; do grep "^$n=" "$pi_env" | sed 's/^/  /'; done
fi
echo
echo "RESULT ($LABEL, $MODE): $fails failed check(s)"

tmux kill-server >/dev/null 2>&1 || true
rm -rf "$W" "/tmp/fm-$id"
exit "$fails"
