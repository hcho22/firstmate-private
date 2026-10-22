#!/usr/bin/env bash
# Opt-in real loopback workload + installed tasks backend + registered watcher.
# FM_RELEASE_PILOT=1 FM_RELEASE_PILOT_DIR=<new-private-directory> enables it.
# Only this directory is mutated. No production resources, models or credentials.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Opt-in: it needs the installed tasks-axi and a loopback workload.
fm_live_gate opt-in FM_RELEASE_PILOT tasks-axi python3
set -e
: "${FM_RELEASE_PILOT_DIR:?choose a new private evidence directory}"
exec python3 "$ROOT/tests/fixtures/release/pilot.py" "$ROOT" "$FM_RELEASE_PILOT_DIR"
