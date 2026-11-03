# Live validation: Ubuntu 26.04 runner-image CI fixes (3efcd0a3 vs base 607a05c7)

The host is macOS, so Ubuntu 26.04 behavior was reproduced by putting the real uutils coreutils 0.10.0 binaries (the version 26.04 ships) and a real CPython 3.14.10 under /tmp, first on PATH.
The base tree is `git archive 607a05c7`; the head tree is the gate worktree.

- s1-claim-race.txt: 12 racers x 40 rounds on one claim dir. Real uutils plain `mkdir` gives more than one winner in 20/40 rounds; `fm_mkdir_exclusive` gives exactly one winner in 40/40 under uutils and on the host mkdir.
- s2-case-lanes/: tests/fm-case-lanes.test.sh under uutils mkdir fails 3/3 on base with CI's exact message and passes 3/3 on head; it also passes on head with the host mkdir.
- s3-contract-depth.txt, s3-contract-suite/: bin/fm-evidence-import-contract.py CLI under Python 3.14 and 3.11. Base accepts 513- and 10000-deep input on 3.14, which is the CI failure. Head accepts 512, refuses 513 and 10000 as invalid-json on both versions, ignores brackets inside strings, and refuses a 1 MiB unterminated escaped-quote string in about 0.1 s. The suite fails on base and passes on head under 3.14.
- s4-public-followup/: the poll-cannot-write case with the poll's shebang run through uutils `env`, as on 26.04. Base fails as CI did; head passes under both uutils and BSD env.
- s5-supervision-host/: full suite with live case-process sampling. Head at normal load passed 75/75, with mean 8.5 and max 17 live processes. Base passed here but piled up to max 61 (mean 39). Head run 1 lost one 25 s fixed wait during a host load spike of 400+ from unrelated simulator/xcodebuild work. The same cases run alone pass 3/3 on head and 3/3 on base (latch-isolation/).
- s6a-busy-event-lock.txt: 16 concurrent bin/fm-busy-event.sh applies. Under uutils mkdir, base loses updates in 9/10 rounds; head loses none, under uutils or the host mkdir.
- s6b-live-spawn/: a real bin/fm-live-lab.sh Claude lab. A real fm-spawn worker got /tmp/fm-<id> and its launch dir at mode 700 and ran Claude. A real fm-teardown then removed both, and the lab was taken down.
- s6c-teardown-missing-mkdir-lib.txt: teardown from a bin root without fm-mkdir-lib.sh refuses by name and changes nothing.
- s7-fixture-suites/: suites whose fixtures gained fm-mkdir-lib.sh (gotmp, mkdir-lib, remote-job, remote-entrypoint, orphan-reap, launchagent, claim-reap, fm-on) pass; mkdir-lib, gotmp, and remote-job also pass under uutils.
- drivers/: the scripts that produced the above.
