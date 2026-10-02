#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving the continuity changes preserve
# Codex's bounded foreground-checkpoint supervision path, and that a Codex Stop
# hook resolves the same session-lock harness as a Codex shell tool call: the
# turn-end guard stands down for a session only when the lock holder is not one of
# its own ancestors, so a hook resolving a different harness than the tool call
# that took the lock would silence the guard for the real lock holder.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"

LAB="$ROOT/.codex-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.jsonl"
CODEX_VERSION=$(codex --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After the checkpoint returns, reply briefly.'

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi

# Session-lock identity: record the harness pid the real lock library resolves
# from inside a real Codex shell tool call and from inside the real Stop hook of
# the same turn. They must be the same non-empty pid.
ANCESTRY_PROJECT="$LAB/ancestry-project"
ANCESTRY_OUT="$LAB/ancestry.txt"
# Its own git root, so Codex loads this project's hooks rather than the enclosing
# worktree's.
mkdir -p "$ANCESTRY_PROJECT/.codex"
git init -q "$ANCESTRY_PROJECT"
cat > "$LAB/ancestry-probe.sh" <<SH
#!/usr/bin/env bash
. "$ROOT/bin/fm-session-lock-lib.sh"
printf '%s %s\n' "\$1" "\$(fm_harness_ancestry_pid 2>/dev/null)" >> "$ANCESTRY_OUT"
SH
chmod +x "$LAB/ancestry-probe.sh"
cat > "$ANCESTRY_PROJECT/.codex/hooks.json" <<JSON
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cat >/dev/null; $LAB/ancestry-probe.sh hook","timeout":30}]}]}}
JSON
(
  cd "$ANCESTRY_PROJECT" || exit 1
  codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "Run exactly this shell command once, then reply DONE: $LAB/ancestry-probe.sh tool" </dev/null
) > "$LAB/codex-ancestry.jsonl" 2>&1 || fail "Codex credentialed ancestry turn failed: $(tail -20 "$LAB/codex-ancestry.jsonl")"
TOOL_HARNESS=$(sed -n 's/^tool \([0-9][0-9]*\)$/\1/p' "$ANCESTRY_OUT" | head -n 1)
HOOK_HARNESS=$(sed -n 's/^hook \([0-9][0-9]*\)$/\1/p' "$ANCESTRY_OUT" | head -n 1)
[ -n "$TOOL_HARNESS" ] || fail "the Codex shell tool call resolved no session-lock harness: $(cat "$ANCESTRY_OUT" 2>/dev/null)"
[ -n "$HOOK_HARNESS" ] || fail "the Codex Stop hook never ran or resolved no session-lock harness: $(cat "$ANCESTRY_OUT" 2>/dev/null)"
[ "$TOOL_HARNESS" = "$HOOK_HARNESS" ] \
  || fail "the Codex Stop hook resolved harness $HOOK_HARNESS but the tool call that takes the lock resolves $TOOL_HARNESS"

printf 'ok - %s live E2E preserved the one-second foreground checkpoint path and resolved one session-lock harness for both its shell tool call and its Stop hook\n' "$CODEX_VERSION"
