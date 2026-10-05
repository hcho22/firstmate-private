#!/usr/bin/env bash
# live-relaunch.sh <bin-dir> <no-server|polluted-server> <label> [pane-shell]
# pane-shell (optional) becomes SHELL for the session, so tmux starts every
# window with it instead of the captain's own login shell.
# Drives the real bin/fm-session-start.sh against a REAL tmux server on a
# private TMUX_TMPDIR socket, with a throwaway Firstmate home whose recorded
# tmux secondmate endpoint is missing (a home after a reboot). Session start
# runs from an environment that carries every Firstmate internal handoff
# setting (as a pane of an older, polluted server would), plus the Claude
# harness marker and an ordinary sentinel. Only the agent binary (`pi`) and the
# network toolchain are stand-ins; tmux, session start, bootstrap, and fm-spawn
# are the real product.
set -u
BIN=$1 MODE=$2 LABEL=$3 PANE_SHELL=${4:-}
[ -z "$PANE_SHELL" ] || export SHELL="$PANE_SHELL"
W=$(mktemp -d /tmp/fmlv.XXXXXX)
export TMUX_TMPDIR="$W/t"
mkdir -p "$TMUX_TMPDIR"
unset TMUX
# A captain's own session, not a no-mistakes gate agent: run from outside the
# gate worktree and without the gate marker, so the fleet guard lets the
# isolated home's lifecycle run as it would for an end user.
unset NO_MISTAKES_GATE
cd "$W" || exit 2
root="$W/root" home="$W/home" fakebin="$W/fakebin" agentbin="$W/agentbin" stale="$W/stale"
id="fmlive-sm-${W##*.}"
mate="$W/secondmate-$id"
pi_env="$W/pi.env"
mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin" "$agentbin" "$stale"
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
  if [ "\$prev" = -l ]; then printf '%s\t%s\n' "\$(printf '%s' "\$a" | wc -c | tr -d ' ')" "\${a:0:60}" >> '$W/typed.log'; fi
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

echo "=== live relaunch: $LABEL (mode=$MODE) ==="
echo "bin: $BIN"
echo "tmux: $(tmux -V), private socket dir: $TMUX_TMPDIR, pane shell: $SHELL"
if [ "$MODE" = polluted-server ]; then
  # A server an older Firstmate started from a polluted environment: its global
  # environment carries every internal setting, a wrong home, and the marker.
  env -u TMUX "${inherited[@]}" CLAUDECODE=1 FM_HOME=/tmp/wrong-home FM_STATE_OVERRIDE=/tmp/wrong-state \
    RELAUNCH_ORDINARY_SENTINEL=kept PATH="$PATHV" tmux new-session -d -s firstmate
  echo "pre-existing polluted server global env (internal names):"
  tmux show-environment -g | grep -E "^($(IFS='|'; echo "${internal[*]}")|CLAUDECODE|FM_HOME|FM_STATE_OVERRIDE)=" | sed 's/^/  /'
else
  tmux ls >/dev/null 2>&1 && { echo "unexpected: a tmux server is already running on the private socket"; exit 2; }
  echo "no tmux server running before session start"
fi

echo
echo "--- session start (inherits all internal settings + CLAUDECODE=1 + RELAUNCH_ORDINARY_SENTINEL=kept) ---"
env -u TMUX -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$PATHV" \
  "${inherited[@]}" CLAUDECODE=1 RELAUNCH_ORDINARY_SENTINEL=kept \
  "$root/bin/fm-session-start.sh" > "$W/digest.txt" 2>&1
echo "session start exit: $?"
FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$PATHV" "$root/bin/fm-startup-network.sh" wait 120 >/dev/null 2>&1
echo "deferred network stage report:"
FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$PATHV" "$root/bin/fm-startup-network.sh" report 2>&1 | grep -E 'relaunch|SECONDMATE|secondmate' | sed 's/^/  /'
deadline=$((SECONDS + 60))
while [ ! -s "$pi_env" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done

fails=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }
echo
echo "--- real tmux after session start ---"
tmux list-windows -t firstmate -F '  window #{window_name}: pane_current_command=#{pane_current_command}' 2>&1
echo "tmux server global environment (Firstmate-relevant names):"
global=$(tmux show-environment -g 2>/dev/null)
printf '%s\n' "$global" | grep -E '^(FM_[A-Za-z0-9_]*|CLAUDECODE|RELAUNCH_ORDINARY_SENTINEL)=' | sed 's/^/  /'
echo "secondmate window pane (typed launch command, wrapped):"
tmux capture-pane -p -J -t "firstmate:fm-$id" 2>/dev/null | sed '/^$/d' | fold -w 160 | sed 's/^/  | /'
echo "literal text typed into panes (bytes, first 60 chars):"
sed 's/^/  /' "$W/typed.log" 2>/dev/null
echo "relaunched secondmate process environment (Firstmate-relevant names):"
[ -s "$pi_env" ] && grep -E '^(FM_[A-Za-z0-9_]*|CLAUDECODE|RELAUNCH_ORDINARY_SENTINEL)=' "$pi_env" | sed 's/^/  /'
echo
check "the deferred stage relaunched the dead secondmate into window fm-$id" \
  "tmux list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -qx 'fm-$id'"
check "the typed launch command started the secondmate agent (it recorded its environment)" "[ -s '$pi_env' ]"
if [ "$MODE" = no-server ]; then
  for n in "${internal[@]}" FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE CLAUDECODE; do
    check "server global env has no $n" "[ -n \"\$global\" ] && ! printf '%s\n' \"\$global\" | grep -q '^$n='"
  done
  check "server global env keeps ordinary RELAUNCH_ORDINARY_SENTINEL=kept" "printf '%s\n' \"\$global\" | grep -qx RELAUNCH_ORDINARY_SENTINEL=kept"
  check "server global env keeps explicit FM_BACKEND=tmux" "printf '%s\n' \"\$global\" | grep -qx FM_BACKEND=tmux"
fi
for n in "${internal[@]}"; do
  check "relaunched secondmate process has no $n" "[ -s '$pi_env' ] && ! grep -q '^$n=' '$pi_env'"
done
check "relaunched secondmate runs in its own home (FM_HOME=$mate)" "grep -Eqx 'FM_HOME=(/private)?$mate' '$pi_env'"
check "relaunched secondmate keeps ordinary RELAUNCH_ORDINARY_SENTINEL=kept" "grep -qx RELAUNCH_ORDINARY_SENTINEL=kept '$pi_env'"
check "secondmate meta still records harness=pi and its home" "grep -qx harness=pi '$home/state/$id.meta' && grep -Eqx 'home=(/private)?$mate' '$home/state/$id.meta'"
echo
echo "RESULT ($LABEL, $MODE): $fails failed check(s)"

tmux kill-server >/dev/null 2>&1 || true
rm -rf "$W" "/tmp/fm-$id"
exit "$fails"
