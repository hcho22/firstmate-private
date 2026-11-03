#!/bin/bash
printf 'gh-axi %s\n' "$*" >> "${FM_LIVE_GH_LOG:-/dev/null}"
case "${1:-} ${2:-}" in "pr view") exec "${FM_LIVE_REAL_GH_AXI:?}" "$@" ;; esac
printf '  -> BLOCKED by live-test guard\n' >> "${FM_LIVE_GH_LOG:-/dev/null}"
exit 1
