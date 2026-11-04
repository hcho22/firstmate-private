#!/bin/bash
# Only gh-axi's read-only pr view is let through to the real gh-axi.
LOG=${FM_LIVE_GH_LOG:?}
case "${1-} ${2-}" in
  "pr view") printf 'read gh-axi %s\n' "$*" >> "$LOG"; exec /Users/hcho/.nvm/versions/node/v20.19.5/bin/gh-axi "$@" ;;
  *) printf 'BLOCKED-WRITE gh-axi %s\n' "$*" >> "$LOG"; echo "test write-guard: refused gh-axi $*" >&2; exit 1 ;;
esac
