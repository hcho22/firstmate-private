#!/usr/bin/env bash
# Stand-in forwarder for the configured-command phase: every `axi status` answer
# is the real no-mistakes CLI's answer for the live run (real run id, branch,
# head, status, active_for), with only the active step's last_activity and
# agent_pid cells rewritten to how the daemon renders a step running its own
# configured command: `"quiet <m>m<s>s ago: running tests",""`, quiet since
# FM_QUIET_SINCE. This agent-driven test step's real last_activity is refreshed
# every few seconds by its agent, which no configured-command phase does.
if [ "${1:-} ${2:-}" = "axi status" ]; then
  out=$(/usr/local/bin/no-mistakes axi status --run "$FM_LIVE_RUN_ID" 2>/dev/null) || exit $?
  q=$(( $(date +%s) - ${FM_QUIET_SINCE:?} )); m=$(( q / 60 )); s=$(( q % 60 ))
  printf '%s\n' "$out" | sed -E "/active_steps/{n;s/,\"[^\"]*\",\"[0-9]*\",/,\"quiet ${m}m${s}s ago: running tests\",\"\",/;}"
  exit 0
fi
exec /usr/local/bin/no-mistakes "$@"
