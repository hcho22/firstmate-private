# Live low-risk merge tier, head c6bc0324

Driver: drivers/live-low-risk.sh drives the real bin/fm-pr-merge.sh --low-risk from this worktree, in a disposable bin/fm-lab-home.sh lab home, against real public GitHub pull requests with the real gh login.
A pass-through gh guard refuses only 'gh pr merge', so nothing was merged; every other gh read is real.

| scenario | PR | exit | gh pr merge reached | outcome |
| --- | --- | --- | --- | --- |
| accept-all-low-risk | github.com/krovacloud/krova-node/pull/91 | 1 | 1 | verified: all 2 changed files of https://github.com/krovacloud/krova-node/pull/91 at head 9e83a1bef8ef717d2180ebd6977736d9a8c78818 are in the low-risk |
| builtin-agent-instructions | github.com/DataDog/browser-sdk/pull/5219 | 4 | 0 | error: refusing a low-risk merge of https://github.com/DataDog/browser-sdk/pull/5219: 6 changed path(s) fall outside the low-risk tier for browser-sdk |
| builtin-ci-beats-project-rule | github.com/frostney/herakles/pull/41 | 4 | 0 | error: refusing a low-risk merge of https://github.com/frostney/herakles/pull/41: 1 changed path(s) fall outside the low-risk tier for herakles, so th |
| doc-example-instruction-surfaces | github.com/kunchenguid/firstmate/pull/8035 | 4 | 0 | error: refusing a low-risk merge of https://github.com/kunchenguid/firstmate/pull/8035: 6 changed path(s) fall outside the low-risk tier for firstmate |
| doc-example-supervision-protocols | github.com/kunchenguid/firstmate/pull/8081 | 4 | 0 | error: refusing a low-risk merge of https://github.com/kunchenguid/firstmate/pull/8081: 9 changed path(s) fall outside the low-risk tier for firstmate |
| doc-example-tests-only | github.com/kunchenguid/firstmate/pull/7899 | 1 | 1 | verified: all 1 changed files of https://github.com/kunchenguid/firstmate/pull/7899 at head ceb8efc6a931d1d62d29d7eefdd995e06827ec39 are in the low-ri |
| gitlab-refused | gitlab.com/gitlab-org/gitlab/-/merge_requests/1 | 4 | 0 | error: refusing a low-risk merge of https://gitlab.com/gitlab-org/gitlab/-/merge_requests/1: the low-risk tier reads changed files only from GitHub, s |
| jenkinsfile-dot-release | github.com/sonatype/docker-nexus-iq-server/pull/216 | 1 | 0 | error: refusing to merge https://github.com/sonatype/docker-nexus-iq-server/pull/216 |
| jenkinsfile-dot-suffix | github.com/stolostron/acmqe-mcn-test/pull/831 | 1 | 0 | error: refusing to merge https://github.com/stolostron/acmqe-mcn-test/pull/831 |
| jenkinsfile-dotted-name | github.com/DIGITALAPPLICATION/JarProject/pull/5 | 4 | 0 | error: refusing a low-risk merge of https://github.com/DIGITALAPPLICATION/JarProject/pull/5: 1 changed path(s) fall outside the low-risk tier for JarP |
| jenkinsfile-lowercase | github.com/betawins/VProfile-1/pull/7 | 4 | 0 | error: refusing a low-risk merge of https://github.com/betawins/VProfile-1/pull/7: 1 changed path(s) fall outside the low-risk tier for VProfile-1, so |
| jenkinsfile-suffix-name | github.com/shibumicorp/polis/pull/2 | 4 | 0 | error: refusing a low-risk merge of https://github.com/shibumicorp/polis/pull/2: 1 changed path(s) fall outside the low-risk tier for polis, so this m |
| jenkinsfile-underscore-variants | github.com/hmcts/et-shared-infrastructure/pull/151 | 4 | 0 | error: refusing a low-risk merge of https://github.com/hmcts/et-shared-infrastructure/pull/151: 2 changed path(s) fall outside the low-risk tier for e |
| malformed-refuses-before-forge | github.com/krovacloud/krova-node/pull/91 | 4 | 0 | error: refusing a low-risk merge of https://github.com/krovacloud/krova-node/pull/91: /var/folders/9t/k_yy9fqs5vd27rf12jx_rzqh0000gn/T//fm-lab.TQP0oA/ |
| other-project-only | github.com/krovacloud/krova-node/pull/91 | 4 | 0 | error: refusing a low-risk merge of https://github.com/krovacloud/krova-node/pull/91: no low-risk merge tier is declared for krova-node: /var/folders/ |
| project-always-ask-wins | github.com/thephpleague/oauth2-server/pull/1522 | 4 | 0 | error: refusing a low-risk merge of https://github.com/thephpleague/oauth2-server/pull/1522: 3 changed path(s) fall outside the low-risk tier for oaut |
| red-still-refused | github.com/juninmd/appmetrics-dash-hapi/pull/39 | 1 | 0 | error: refusing to merge https://github.com/juninmd/appmetrics-dash-hapi/pull/39 |
| refuse-unmatched | github.com/Codeplain-ai/codeplain/pull/356 | 4 | 0 | error: refusing a low-risk merge of https://github.com/Codeplain-ai/codeplain/pull/356: 3 changed path(s) fall outside the low-risk tier for codeplain |
| rename-both-low-risk | github.com/bmx-ng/pub.mod/pull/83 | 1 | 1 | verified: all 5 changed files of https://github.com/bmx-ng/pub.mod/pull/83 at head 8e1f0c03bdf3ea25422fa1324bd7a46d10e9d2b5 are in the low-risk tier f |
| rename-old-path-judged | github.com/bmx-ng/pub.mod/pull/83 | 4 | 0 | error: refusing a low-risk merge of https://github.com/bmx-ng/pub.mod/pull/83: 5 changed path(s) fall outside the low-risk tier for pub.mod, so this m |
| tests-rule-cannot-reach-nested-instructions | github.com/athombv/node-homey/pull/696 | 4 | 0 | error: refusing a low-risk merge of https://github.com/athombv/node-homey/pull/696: 4 changed path(s) fall outside the low-risk tier for node-homey, s |
| undeclared-refuses-before-forge | github.com/krovacloud/krova-node/pull/91 | 4 | 0 | error: refusing a low-risk merge of https://github.com/krovacloud/krova-node/pull/91: no low-risk merge tier is declared for krova-node: /var/folders/ |
| unsupported-pattern | github.com/krovacloud/krova-node/pull/91 | 4 | 0 | error: refusing a low-risk merge of https://github.com/krovacloud/krova-node/pull/91: /var/folders/9t/k_yy9fqs5vd27rf12jx_rzqh0000gn/T//fm-lab.TQP0oA/ |
| waiver-refused-allow-red | github.com/krovacloud/krova-node/pull/91 | 2 | 0 | error: --low-risk takes no attended waiver: --attended-override, --allow-red, --allow-missing, and --allow-no-pipeline need an explicit captain instru |
| waiver-refused-attended-override | github.com/krovacloud/krova-node/pull/91 | 2 | 0 | error: --low-risk takes no attended waiver: --attended-override, --allow-red, --allow-missing, and --allow-no-pipeline need an explicit captain instru |
| without-flag-unchanged | github.com/krovacloud/krova-node/pull/91 | 1 | 1 | no --low-risk and a malformed merge-tiers file: the tier is never read and the green PR reaches the head-bound merge as before |

Exit 1 with 'gh pr merge reached' = 1 is the expected end of an accepted merge here: the guard refused the head-bound 'gh pr merge --match-head-commit', and fm-pr-merge.sh then reported the PR still open.

jenkinsfile-dot-release and jenkinsfile-dot-suffix stopped at the existing draft and green checks before the tier; jenkinsfile-dotted-name and jenkinsfile-suffix-name cover those name shapes on green PRs.
