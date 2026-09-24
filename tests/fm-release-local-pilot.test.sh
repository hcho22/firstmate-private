#!/usr/bin/env bash
# Opt-in real loopback workload + installed tasks backend + registered watcher.
# FM_RELEASE_PILOT=1 FM_RELEASE_PILOT_DIR=<new-private-directory> enables it.
# Only this directory is mutated. No production resources, models or credentials.
set -eu
if [ "${FM_RELEASE_PILOT:-0}" != 1 ]; then
  echo 'skip: local release pilot opt-in (installed tasks-axi and loopback required)'
  exit 0
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${FM_RELEASE_PILOT_DIR:?choose a new private evidence directory}"
exec python3 "$ROOT/tests/fixtures/release/pilot.py" "$ROOT" "$FM_RELEASE_PILOT_DIR"
