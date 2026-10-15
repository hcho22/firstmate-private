#!/usr/bin/env bash
# Round 2 live fixture (target 267c59f): prints the fixture root.
#   base/     git archive of fbd3c9b (watcher and crew-state reader before this change)
#   prefix/   git archive of f3ec246 bin/ (wake lock before the 267c59f re-observe fix)
#   wt2/      a fixture crew worktree: a clone at this run's head on this run's branch
#   pane.sh   the static idle worker pane
#   forwarder the stand-in `no-mistakes` that pins `axi status` to the live run id;
#             every answer still comes from the real no-mistakes CLI and daemon
set -eu
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
EVD=/Users/hcho/.no-mistakes/evidence/01M4Z2NDNVFJXVP6PM2K4SF305/round2/drivers
L=$(mktemp -d /tmp/fmr2.XXXX)
L=$(cd "$L" && pwd -P)
mkdir -p "$L/base" "$L/prefix"
git -C "$WT" archive fbd3c9b | tar -x -C "$L/base"
git -C "$WT" archive f3ec246 bin | tar -x -C "$L/prefix"
git clone -q --no-hardlinks --no-checkout "$WT" "$L/wt2"
git -C "$L/wt2" checkout -q -B fm/fm-wedge-alarm-pipeline-test-step 267c59f6bd572a6ec8efea44e498a9d41795555d
cp "$EVD/pane.sh" "$EVD/forwarder.sh" "$EVD/watch-loop.sh" "$L/"
chmod +x "$L/pane.sh" "$L/forwarder.sh" "$L/watch-loop.sh"
printf '%s\n' "$L"
