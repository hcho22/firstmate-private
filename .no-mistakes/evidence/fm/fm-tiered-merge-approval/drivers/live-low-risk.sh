#!/usr/bin/env bash
# live-low-risk.sh <worktree> <out-dir> [label...]
#
# Drives the real bin/fm-pr-merge.sh --low-risk from a gate worktree against
# real, open, public GitHub pull requests, inside a disposable marked lab home
# (bin/fm-lab-home.sh). Every gh call goes to the real gh with the machine's
# existing login, EXCEPT `gh pr merge`, which a pass-through guard intercepts
# and refuses, so no third-party pull request can ever be merged by this run.
# Each scenario gets a fresh task record, a fresh config/merge-tiers, and its
# own gh call log; the transcript shows rc, stderr, the gh calls made, and the
# task record afterwards. The lab is removed on exit.
set -u
WT=$1
OUT=$2
shift 2
mkdir -p "$OUT"
REAL_GH=$(command -v gh)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/guardbin"
cat > "$LAB/guardbin/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "\$FM_LIVE_GH_LOG"
if [ "\${1:-} \${2:-}" = "pr merge" ]; then
  echo "LIVE-TEST GUARD: intercepted 'gh \$*'; nothing was merged" >&2
  exit 1
fi
exec "$REAL_GH" "\$@"
EOF
chmod 755 "$LAB/guardbin/gh"
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"

N=0
# run_case <label> <project-name> <url> <merge-tiers-file|-> [fm-pr-merge args...]
run_case() {
  local label=$1 project=$2 url=$3 tiers=$4 id rc wt log t
  shift 4
  N=$((N + 1))
  id="task-l$N"
  wt="$LAB/wt-$N"
  git init -q "$wt"
  git -C "$wt" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
  printf '%s\n' "window=fm-$id" "worktree=$wt" "project=$LAB/projects/$project" \
    "kind=ship" "mode=no-mistakes" > "$LAB/state/$id.meta"
  chmod 600 "$LAB/state/$id.meta"
  rm -f "$LAB/config/merge-tiers"
  [ "$tiers" = - ] || cp "$tiers" "$LAB/config/merge-tiers"
  log="$OUT/$label.gh.log"
  : > "$log"
  t="$OUT/$label.txt"
  {
    echo "### scenario: $label"
    echo "### $(date -u +%Y-%m-%dT%H:%M:%SZ)  worktree HEAD: $(git -C "$WT" rev-parse HEAD)"
    echo "### command: FM_HOME=<lab> bin/fm-pr-merge.sh $id $url $*"
    echo "### project (registry name from project= basename): $project"
    if [ "$tiers" = - ]; then
      echo "### config/merge-tiers: (absent)"
    else
      echo "### config/merge-tiers:"
      sed 's/^/    /' "$LAB/config/merge-tiers"
    fi
    echo "### stderr+stdout:"
  } > "$t"
  set +e
  ( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" FM_LIVE_GH_LOG="$log" PATH="$LAB/guardbin:$PATH" \
      "$WT/bin/fm-pr-merge.sh" "$id" "$url" "$@" ) >> "$t" 2>&1
  rc=$?
  {
    echo "### exit status: $rc"
    echo "### gh calls made (real gh unless marked intercepted):"
    sed 's/^/    /' "$log"
    [ -s "$log" ] || echo "    (none)"
    echo "### task record afterwards (state/$id.meta):"
    sed 's/^/    /' "$LAB/state/$id.meta"
    if [ -e "$LAB/state/$id.check.sh" ]; then
      echo "### merge poll armed: state/$id.check.sh exists"
    else
      echo "### merge poll armed: no"
    fi
  } >> "$t"
  echo "$label rc=$rc"
}

want() {  # run a scenario only when selected (no labels = all)
  [ "$#" -gt 0 ] || return 0
  local l
  for l in "${SELECTED[@]}"; do [ "$l" = "$1" ] && return 0; done
  return 1
}
SELECTED=("$@")
sel() { [ "${#SELECTED[@]}" -eq 0 ] && return 0; want "$1"; }

T="$LAB/tiers"
mkdir -p "$T"

if sel accept-all-low-risk; then
  printf '%s\n' '# the MCP package docs merge on green' 'krova-node low-risk packages/mcp/**' > "$T/a"
  run_case accept-all-low-risk krova-node https://github.com/krovacloud/krova-node/pull/91 "$T/a" --low-risk
fi
if sel refuse-unmatched; then
  printf '%s\n' 'codeplain low-risk docs/**' 'codeplain low-risk tests/**' > "$T/b"
  run_case refuse-unmatched codeplain https://github.com/Codeplain-ai/codeplain/pull/356 "$T/b" --low-risk
fi
if sel builtin-ci-beats-project-rule; then
  printf '%s\n' 'herakles low-risk **' 'herakles low-risk .github/**' > "$T/c"
  run_case builtin-ci-beats-project-rule herakles https://github.com/frostney/herakles/pull/41 "$T/c" --low-risk
fi
if sel builtin-agent-instructions; then
  printf '%s\n' 'browser-sdk low-risk **' 'browser-sdk low-risk **/CLAUDE.md' 'browser-sdk low-risk .cursor/**' > "$T/d"
  run_case builtin-agent-instructions browser-sdk https://github.com/DataDog/browser-sdk/pull/5219 "$T/d" --low-risk
fi
if sel tests-rule-cannot-reach-nested-instructions; then
  printf '%s\n' 'node-homey low-risk tests/**' 'node-homey low-risk lib/**' > "$T/e"
  run_case tests-rule-cannot-reach-nested-instructions node-homey https://github.com/athombv/node-homey/pull/696 "$T/e" --low-risk
fi
if sel project-always-ask-wins; then
  printf '%s\n' 'oauth2-server low-risk **' 'oauth2-server always-ask src/**' > "$T/f"
  run_case project-always-ask-wins oauth2-server https://github.com/thephpleague/oauth2-server/pull/1522 "$T/f" --low-risk
fi
if sel rename-old-path-judged; then
  printf '%s\n' \
    'caylex-developer-docs low-risk administration/**' \
    'caylex-developer-docs low-risk widget/**' \
    'caylex-developer-docs low-risk docs.json' \
    'caylex-developer-docs low-risk **/data-sync.mdx' \
    'caylex-developer-docs low-risk cookbooks/overview.mdx' \
    'caylex-developer-docs low-risk cookbooks/background-agent-file-sync.mdx' > "$T/g"
  run_case rename-old-path-judged caylex-developer-docs https://github.com/caylex-ai/caylex-developer-docs/pull/38 "$T/g" --low-risk
fi
if sel jenkinsfile-variants; then
  printf '%s\n' 'et-shared-infrastructure low-risk **' > "$T/h"
  run_case jenkinsfile-variants et-shared-infrastructure https://github.com/hmcts/et-shared-infrastructure/pull/151 "$T/h" --low-risk
fi
if sel red-still-refused; then
  printf '%s\n' 'appmetrics-dash-hapi low-risk **' > "$T/i"
  run_case red-still-refused appmetrics-dash-hapi https://github.com/juninmd/appmetrics-dash-hapi/pull/39 "$T/i" --low-risk
fi
if sel undeclared-refuses-before-forge; then
  run_case undeclared-refuses-before-forge krova-node https://github.com/krovacloud/krova-node/pull/91 - --low-risk
fi
if sel other-project-only; then
  printf '%s\n' 'some-other-project low-risk **' 'krova-node always-ask src/**' > "$T/j"
  run_case other-project-only krova-node https://github.com/krovacloud/krova-node/pull/91 "$T/j" --low-risk
fi
if sel malformed-refuses-before-forge; then
  printf '%s\n' 'krova-node low-risk packages/mcp/**' 'some-other-project lowrisk docs/' > "$T/k"
  run_case malformed-refuses-before-forge krova-node https://github.com/krovacloud/krova-node/pull/91 "$T/k" --low-risk
fi
if sel unsupported-pattern; then
  printf '%s\n' 'krova-node low-risk packages/{mcp,cli}/**' > "$T/k2"
  run_case unsupported-pattern krova-node https://github.com/krovacloud/krova-node/pull/91 "$T/k2" --low-risk
fi
if sel waiver-refused; then
  printf '%s\n' 'krova-node low-risk **' > "$T/l"
  run_case waiver-refused-attended-override krova-node https://github.com/krovacloud/krova-node/pull/91 "$T/l" --low-risk --attended-override
  run_case waiver-refused-allow-red krova-node https://github.com/krovacloud/krova-node/pull/91 "$T/l" --low-risk --allow-red ci
fi
if sel gitlab-refused; then
  printf '%s\n' 'gitlab low-risk **' > "$T/m"
  run_case gitlab-refused gitlab https://gitlab.com/gitlab-org/gitlab/-/merge_requests/1 "$T/m" --low-risk
fi
if sel without-flag-unchanged; then
  printf '%s\n' 'krova-node lowrisk docs/' > "$T/n"
  run_case without-flag-unchanged krova-node https://github.com/krovacloud/krova-node/pull/91 "$T/n"
fi
exit 0
