#!/usr/bin/env bash
# Read-only rendering and consistency checking of an ordinary release task body.
# Usage: fm-release.sh template <task-id>
#        fm-release.sh summary <body-file> [--now <epoch-seconds>]
#          Prints only fixed phase/health labels and readiness counts; no private
#          identifiers, observations or links. Add approved evidence links and
#          task-specific impact/recovery narrative through the selected owner.
#        fm-release.sh fingerprint <body-file>  # material plan binding, no writes
#        fm-release.sh check <body-file> [--operation deploy|expose|advance|contain|restore|complete]
#          [--target <stage-or-recovery-target>] [--operation-id <stable-id>]
#          [--peer <other-task-body>]... [--now <epoch-seconds>]
# The task body's single ```firstmate-release JSON fence is authoritative.
# template prints its schema with deliberately unassessed values. check accepts
# surrounding prose; no fence means legacy/unassessed, never low risk or ready.
# With --operation, exit 0 means consistent recorded preconditions or an
# already-observed operation. Without it, check returns a record-only assessment
# and may exit 0 with unknown health; it does not assess action readiness.
# Exit 1: blocked/legacy; exit 2: malformed input/usage. JSON output is a private
# projection, not authorization, authenticated evidence, or a public summary.
# Nothing writes a task, executes an action, schedules a watch, acquires a lease,
# or changes a phase. Firstmate interprets the result under risk-recovery policy
# and uses existing configured-backend, lock, lease, and observation owners.
# Python implementation owns exact body fields, types, and checker mechanics;
# --help there documents the field groups. No credentials belong in the body.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-release.py" "$@"
