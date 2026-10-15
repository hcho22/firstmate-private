#!/usr/bin/env bash
# Stand-in forwarder: the fixture crew worktree is not registered with the gate,
# so the branch-scoped `axi status` is pinned to the real live run by id. Every
# answer still comes from the real no-mistakes CLI and daemon.
if [ "${1:-} ${2:-}" = "axi status" ]; then
  printf '%s %s\n' "$(date +%s)" "$PWD" >> "${FM_LIVE_NM_LOG:-/dev/null}"
  exec /usr/local/bin/no-mistakes axi status --run "$FM_LIVE_RUN_ID"
fi
exec /usr/local/bin/no-mistakes "$@"
