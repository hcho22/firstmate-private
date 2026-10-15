#!/usr/bin/env bash
# Round 3 live fixture (target 6273c67): prints the fixture root.
#   base/       git archive of fbd3c9b (watcher and crew-state reader before this change)
#   prefix/     git archive of f3ec246 bin/ (wake lock before the 267c59f re-observe fix)
#   wt2/        a fixture crew worktree: a clone at this run's head on this run's branch
#   tt-head/    HEAD's tree with only bin/fm-classify-lib.sh taken from base, to show the
#               revised run-step test still fails when the behavior is missing
#   tt-r2/      the same, but with the test file as of 267c59f (before 6273c67)
#   pane.sh     the static idle worker pane
#   forwarder*  the stand-in `no-mistakes` that pins `axi status` to the live run id;
#               every answer still comes from the real no-mistakes CLI and daemon
set -eu
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M4Z2NDNVFJXVP6PM2K4SF305
EVD=/Users/hcho/.no-mistakes/evidence/01M4Z2NDNVFJXVP6PM2K4SF305/round3/drivers
HEADSHA=6273c67fd0ca167fda16ef0170f93c7ff2fa2769
L=$(mktemp -d /tmp/fmr3.XXXX)
L=$(cd "$L" && pwd -P)
mkdir -p "$L/base" "$L/prefix" "$L/tt-head" "$L/tt-r2"
git -C "$WT" archive fbd3c9b | tar -x -C "$L/base"
git -C "$WT" archive f3ec246 bin | tar -x -C "$L/prefix"
git -C "$WT" archive "$HEADSHA" | tar -x -C "$L/tt-head"
git -C "$WT" archive "$HEADSHA" | tar -x -C "$L/tt-r2"
git -C "$WT" show fbd3c9b:bin/fm-classify-lib.sh > "$L/tt-head/bin/fm-classify-lib.sh"
git -C "$WT" show fbd3c9b:bin/fm-classify-lib.sh > "$L/tt-r2/bin/fm-classify-lib.sh"
git -C "$WT" show 267c59f:tests/fm-crew-state.test.sh > "$L/tt-r2/tests/fm-crew-state.test.sh"
chmod +x "$L/tt-head/bin/fm-classify-lib.sh" "$L/tt-r2/bin/fm-classify-lib.sh" "$L/tt-r2/tests/fm-crew-state.test.sh"
git clone -q --no-hardlinks --no-checkout "$WT" "$L/wt2"
git -C "$L/wt2" checkout -q -B fm/fm-wedge-alarm-pipeline-test-step "$HEADSHA"
cp "$EVD/pane.sh" "$EVD/forwarder.sh" "$EVD/watch-loop.sh" "$L/"
chmod +x "$L/pane.sh" "$L/forwarder.sh" "$L/watch-loop.sh"
printf '%s\n' "$L"
