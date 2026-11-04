#!/bin/bash
# Test write-guard for live validation against real GitHub: every read passes
# through to the real gh unchanged and its exit code is preserved; every write
# (pr merge/close/edit/..., REST calls with fields or a method, GraphQL
# mutations) is refused, so no real pull request can change during the run.
REAL=/usr/local/bin/gh
LOG=${FM_LIVE_GH_LOG:?FM_LIVE_GH_LOG must name the call log}
block() {
  printf 'BLOCKED-WRITE gh %s\n' "$*" >> "$LOG"
  echo "test write-guard: refused 'gh $*'; this validation never changes a real pull request" >&2
  exit 1
}
case "${1-}" in
  pr) case "${2-}" in view|list|checks|diff|status) ;; *) block "$@" ;; esac ;;
  api)
    graphql=false
    [ "${2-}" = graphql ] && graphql=true
    for a in "$@"; do
      case "$a" in
        -X|-X*|--method|--method=*|--input|--input=*) block "$@" ;;
        *mutation*) block "$@" ;;
      esac
    done
    if ! $graphql; then
      for a in "$@"; do
        case "$a" in -f|-F|-f*|-F*|--field|--field=*|--raw-field|--raw-field=*) block "$@" ;; esac
      done
    fi
    ;;
  auth) [ "${2-}" = status ] || block "$@" ;;
  *) block "$@" ;;
esac
printf 'read gh %s\n' "$*" | cut -c1-400 >> "$LOG"
rc=0
out=$("$REAL" "$@") || rc=$?
printf '  -> rc=%s out=%s\n' "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" >> "$LOG"
[ -z "$out" ] || printf '%s\n' "$out"
exit "$rc"
