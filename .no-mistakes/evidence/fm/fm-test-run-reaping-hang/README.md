# Evidence: interrupted fm-test-run.sh runs end, and a wedged nested runner fails its case instead of hanging the file

Change under test: `fm/fm-test-run-reaping-hang`, first at b4b74ad (round 1) and then at 117ef23 plus this round's test-helper fix (round 2), against base 840208d.
Host: macOS (Darwin 25.6.0), runner and test files under GNU bash 3.2.57.
No Linux bash 5.2 was available locally (the Docker daemon was not running), so the exact bash 5.2 lost-job race is not reproduced here.

## Round 3 (15872ce, the final commit, test step)

All live runs below used the committed tree at 15872ce, on a host whose load average sat between about 100 and 1000 from other work, so exit times are load-dominated.

- `changed-test-files.log`: `bin/fm-test-run.sh tests/fm-test-run.test.sh tests/fm-remote-secondmate-e2e-interrupt.test.sh tests/fm-case-lanes.test.sh`, exit 0.
  It includes the four remote-job-worker reaping cases that went silent in CI run 38652324711 (Ctrl-C, TERM, killed script, killed run), both e2e interrupt cases, and `a lane killed before it ends fails the file and is reported as ended abnormally`.
- `drive-runner-interrupt.sh`: a scratch checkout with two hanging scripts on the runner's proven-isolated list, run by the real `bin/fm-test-run.sh` in its own process group, then ended one way.
  It records time to exit, exit status, every process left in the runner's and the scripts' groups 1s later, and any run root left in the caller's TMPDIR.
- `live-group-term-jobs1.log`, `live-group-term-jobs2.log`, `live-group-term-jobs2-idle.log`: 26 runs with TERM sent to the runner's whole group, the signal that also kills the script job (the hang's trigger), serial and concurrent.
  Every run exited 143 and left nothing behind.
  None needed the 30s fallback; the slowest (40s, 14s) ran while another full test file was loading the host.
- `live-group-hup-jobs{1,2}.log` (HUP to the group, exit 129), `live-group-int-jobs{1,2}.log` (Ctrl-C to the group, exit 130), `live-term-jobs{1,2}.log` (TERM to the runner alone, exit 143): 18 runs, all clean.
- `live-stuck-job-15872ce.log`: a script job frozen with SIGSTOP, then TERM to the runner, serial and concurrent.
  The runner logs `script job N was still running 30s after the interrupt; not waiting for it` and exits 143 after about 32s, leaving nothing behind.
- `live-stuck-job-base-840208d.log`: the same against the base runner: still running 90s after TERM, with its run root left behind, until the driver killed it.
- `wedged-nested-runner-15872ce.log`: `drive-wedged-nested-runner-v2.sh` at 15872ce.
  With the nested runner frozen, the case prints `not ok - term: the run was still going 120s after it was ended` and the file ends with rc 1 instead of hanging.
  Nothing the fixture started is alive at +1s, +5s, +15s or +30s.
- `lane-pid-wrap-base-840208d-600s.log`, `lane-pid-wrap-15872ce-600s.log`: `drive-lane-pid-wrap.sh` (600 lanes, 600s hold) with the base helper and the committed helper, run over the same window while the host's pid counter wrapped.
  Base: all 600 cases passed, yet the file exited 1 with seven `wait: pid N is not a child of this shell` / `not ok - a case lane ended abnormally (127)` pairs.
  15872ce: exit 0, 600 of 600 cases, no errors.
- `ci-main-38674469215-hang-excerpt.log`: read-only excerpt of main's latest CI run (fbd3c9b, without this fix), fetched for context and not driven here.
  `tests/fm-test-run.test.sh` goes silent after `--per-script-timeout-secs turns a hung script into a bounded failure` until the job is cancelled, the same signature as run 38652324711.
- `ci-diag-ab-38660257848-excerpt.log`: read-only excerpt of the author's earlier Linux diagnostic A/B (bash on a GitHub Linux runner), not driven here.
  The base copy hangs with the nested runner in `do_wait` and only its sentinel left as a child.
  The fixed copy (the same `bin/fm-test-run.sh` as 15872ce) runs the portable-parallel-1 lane once and `tests/fm-test-run.test.sh` eight more times with no hang.

## Round 2 (117ef23 plus the case-lanes fix)

The configured test command (`bin/fm-test-run.sh --changed --exclude-family real-herdr-gated`, 178 scripts) failed in one script, `tests/fm-teardown.test.sh`.
Every one of its cases passed, but the file ended with `tests/case-lanes-helpers.sh: line 219: wait: pid 22866 is not a child of this shell` and `not ok - a case lane ended abnormally (127)`.
That file uses none of this change's new helpers; the flake is in `tests/case-lanes-helpers.sh` and only shows under macOS `/bin/bash` 3.2.

Cause, from bash 3.2's `jobs.c` (`make_child`): once the host's pid counter has wrapped past the shell's first child, every new child whose pid matches a dead job deletes that job with `DEL_NOBGPID`, so its status is never saved.
The lanes helper polls with a command substitution every 0.2s while lanes that finished early sit dead in the job table, and a command substitution leaves no status of its own, so the later `wait` on that lane returns 127.
A busy host wraps its 99999 pids in about 100s, and a laned file such as `fm-teardown.test.sh` runs about 140s.
Fix: each lane writes an end marker as its last act, and the helper tells a lane that ended on its own from one killed or exited mid-way by that marker instead of by `wait`'s status.

- `drive-lane-pid-wrap.sh`: runs a suite through the real helper with 600 lanes, 599 of which end at once while one case holds its lane, so the poll loop runs while the host's pids wrap.
- `lane-pid-wrap-before-900s.log`: the helper as committed at HEAD, 900s hold: exit 1 with nine `line 219: wait: pid N is not a child of this shell` / `not ok - a case lane ended abnormally (127)` pairs, while all 600 cases passed.
  This is the configured run's failure, at the same line.
- `lane-pid-wrap-after-900s.log`: the fixed helper, run alongside it over the same pid wrap: exit 0, no errors.
- `lane-pid-wrap-before-240s.log`, `lane-pid-wrap-after-240s.log`: a first, shorter pair that happened to draw no hit (about 2 expected), kept for completeness.
- `changed-and-lanes-run-117ef23-plus-fix.log`: `bin/fm-test-run.sh tests/fm-test-run.test.sh tests/fm-remote-secondmate-e2e-interrupt.test.sh tests/fm-teardown.test.sh tests/fm-case-lanes.test.sh`, all passing, including the remote-job-worker reaping cases that went silent in CI run 38652324711 and the new `a lane killed before it ends fails the file and is reported as ended abnormally` case.
- `interrupt-matrix-117ef23.log`: 24 runs of the real runner at 117ef23 covering Ctrl-C, TERM and HUP to the group and TERM to the runner alone, serial and concurrent; every run exited 130, 143 or 129 within about 1s and left nothing behind.
- `stopped-job-117ef23.log`: a script job frozen with SIGSTOP, then TERM to the runner, serial and concurrent; the runner logs `script job N was still running 30s after the interrupt; not waiting for it` per stuck job and exits 143, leaving nothing behind.
- `drive-wedged-nested-runner-v2.sh`: `drive-wedged-nested-runner.sh` with worker tracking scoped to the case's own `fm-test-run-worker-leak.*` temp root, because another test run on the same host had remote job workers of its own.
- `wedged-nested-runner-117ef23.log`: with the nested runner frozen, the case prints `not ok - term: the run was still going 120s after it was ended` at 122s and the file ends at 183s, and nothing the fixture started is alive at +1s, +5s, +15s or +30s.
  The round 1 finding below (fixture group orphaned after the KILL fallback) is fixed by 117ef23.

## Round 1 (b4b74ad)

- `drive-interrupt.sh`: starts the real `bin/fm-test-run.sh` in a scratch repo on hanging test scripts, signals it, and records exit code, time to exit, leftover processes, the script sandbox, and the run root.
- `interrupt-matrix-head.log`: 80 runs at HEAD covering Ctrl-C (INT to the group), TERM to the group, HUP to the group, and TERM to the runner alone, on both the serial path (`--jobs 1`) and the concurrent path (`--jobs 2`).
  Every run exited 130, 143, or 129 as expected within 1.5s and left nothing behind.
- `stopped-job-ab.log`: a script job frozen with SIGSTOP so it never reports its end, then TERM to the runner.
  HEAD logs `script job N was still running 30s after the interrupt; not waiting for it` and exits 143 after about 30s per stuck job, leaving nothing behind.
  The base runner was still hung at 100s.
- `drive-wedged-nested-runner.sh`: runs `test_terminated_run_leaves_no_remote_job_worker` from `tests/fm-test-run.test.sh` with its nested runner frozen, so the case's TERM can never end it, then tracks the fixture's processes after the file ends.
- `wedged-nested-runner-head.log`: HEAD prints `not ok - term: the run was still going 120s after it was ended` at 122s and the file ends at 182s.
  The fixture's script group (`bash -c ... | tee`, the fixture bash, `tee`, `sleep 600`) is still alive 30s after the file ended (see the finding below).
- `wedged-nested-runner-head-delay-cleanup.log`: the same run with a 3s pause between `stop_worker_leak_case` and `fm_test_cleanup` in the file's EXIT trap (diagnostic only).
  Nothing is left alive at +1s, which shows that the run's sentinel reaps the fixture when the nested run root still exists.
- `wedged-nested-runner-base.log`: the base test file prints nothing for 260s on the same wedged runner, until the driver's watchdog kills it.
  This is the silent hang seen in CI run 38652324711.
- `changed-test-files-run.log`: `bin/fm-test-run.sh tests/fm-test-run.test.sh tests/fm-remote-secondmate-e2e-interrupt.test.sh` at HEAD.

### Round 1 finding (fixed in 117ef23)

After the new KILL fallback in `stop_worker_leak_case`, the file's EXIT trap runs `fm_test_cleanup` immediately, which deletes the case's temp root and the nested run root inside it.
The nested run's sentinel then has no run root to reap, so the fixture's script group is orphaned until its `sleep 600` ends.
`stop_e2e_runner` in `tests/fm-remote-secondmate-e2e-interrupt.test.sh` has the same shape.
This only happens after a case has already failed with a nested runner that ignored TERM for 60s, and the file still ends and reports, so it is a leftover-process gap, not a hang.
