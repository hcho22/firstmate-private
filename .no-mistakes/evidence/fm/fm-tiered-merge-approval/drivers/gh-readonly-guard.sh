#!/bin/bash
# Live-test safety interlock: forwards every read-only gh call to the real gh
# and refuses anything that could change GitHub state (pr merge, mutating api
# calls, graphql mutations). Every call is logged to $FM_LIVE_GH_LOG.
REAL_GH=${FM_LIVE_REAL_GH:?}
LOG=${FM_LIVE_GH_LOG:-/dev/null}
printf 'gh %s\n' "$*" >> "$LOG"
deny() {
  printf '  -> BLOCKED by live-test guard (no GitHub mutation allowed)\n' >> "$LOG"
  echo "live-test guard: blocked mutating call: gh $*" >&2
  exit 1
}
case "${1:-}" in
  api)
    if [[ " $* " == *" graphql "* ]]; then
      [[ "$*" == *mutation* ]] && deny "$@"
    else
      for a in "$@"; do
        case "$a" in -X|-X*|--method|--method=*|-f|-F|--field|--field=*|--raw-field|--raw-field=*|--input|--input=*) deny "$@" ;; esac
      done
    fi
    ;;
  pr) case "${2:-}" in view|checks|list|diff) ;; *) deny "$@" ;; esac ;;
  repo) case "${2:-}" in view) ;; *) deny "$@" ;; esac ;;
  auth) case "${2:-}" in status|token) ;; *) deny "$@" ;; esac ;;
  *) deny "$@" ;;
esac
exec "$REAL_GH" "$@"
