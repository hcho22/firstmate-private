#!/usr/bin/env bash
# fm-server-env-lib.sh - the single owner of what a long-lived backend server
# must never inherit from whichever process happens to start it.
#
# Sourced, never executed, and free of side effects on source beyond defining
# the names list and functions below.
#
# A tmux, Herdr, or Zellij server outlives the process that starts it and hands
# the environment it started with to every pane it creates afterwards: the
# captain's own panes, every crewmate, and every secondmate relaunch. A value
# that belonged only to the starting process therefore becomes a default for
# unrelated sessions until that server next starts. Two groups never belong there:
#
#   - Firstmate's internal handoff settings (FM_INTERNAL_ENV_NAMES). Each is
#     private input one process hands to exactly one child: session start's stage
#     file, the crew-state snapshot overrides, the home-summary worker settings,
#     the tasks-axi verdict, bootstrap's phase, lock, detect-only, verbosity, and
#     parallel-run settings, the batch spawn's guard skip, and the startup timing
#     record. Each owner also withdraws its own value once read, but a process
#     whose owner never runs passes an inherited value straight through. A session
#     started from a pane of a server that already carries them is exactly that
#     process, so a relaunch it performs would copy them into the next server.
#   - The starting process's own identity: its Firstmate home and directory
#     overrides, harness identity markers, and supervision-model override. A
#     launch that needs a home or harness sets it explicitly, so a server-wide
#     default could only misroute panes for another home or harness.
#
# Every other variable is left alone, so ordinary environment and explicit
# backend session routing still reach the server. An already-running server is
# reused untouched and keeps whatever environment it started with until it next
# starts, so restarting a server an older Firstmate started is what clears it.
# Dropping the names from each launch command instead does not fit: fm-spawn
# types that command into a pane before its shell is ready, and on macOS typed
# text past about 1 KB arrives corrupted.
#
# fm_internal_env_withdraw  unset the internal handoff settings in this shell.
#                           tests/lib.sh uses it to keep a suite run hermetic.
# fm_server_env_scrub       unset both groups in this shell. Call it only inside
#                           the subshell that starts the server, because the
#                           caller itself still needs its home.

FM_INTERNAL_ENV_NAMES=(
  FM_SESSION_START_STAGE_FILE
  FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE
  FM_HOME_SUMMARY_IF_IDLE FM_HOME_SUMMARY_WORKER_BEST_EFFORT
  FM_TASKS_AXI_COMPATIBLE
  FM_BOOTSTRAP_NETWORK FM_BOOTSTRAP_NETWORK_LOCK_PID FM_BOOTSTRAP_DETECT_ONLY
  FM_BOOTSTRAP_LOCKED FM_BOOTSTRAP_VERBOSE_FACTS FM_BOOTSTRAP_PARALLEL_DIR
  FM_SPAWN_NO_GUARD
  FM_TIMING_LOG FM_TIMING_EPOCH_MS
)

fm_internal_env_withdraw() {
  unset "${FM_INTERNAL_ENV_NAMES[@]}"
}

fm_server_env_scrub() {
  fm_internal_env_withdraw
  unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE \
    CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_SUPERVISION_MODEL
}
