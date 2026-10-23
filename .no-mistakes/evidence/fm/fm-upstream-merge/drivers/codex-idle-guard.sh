#!/usr/bin/env bash
# tests/fm-composer-codex-idle-live-e2e.test.sh at <commit>, run through the
# gate's runner under the gate's 256-fd limit, two ways:
#  A. the gate worktree with the host PATH codex (what the configured command ran);
#  B. a /tmp copy of the same commit with the managed daemon's own codex binary,
#     that folder trusted and hooks off for these invocations only (-c flags, no
#     change to ~/.codex/config.toml).
# usage: codex-idle-guard.sh <commit> <out>
set -u
WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M5K9VKC2EZBSHY79EY356RH1
COMMIT=$1; OUT=$2
COPY=$(mktemp -d /tmp/fmcxXXXXXX); COPY=$(cd "$COPY" && pwd -P)
SHIM=$(mktemp -d /tmp/fmcsXXXXXX)
trap 'rm -rf "$COPY" "$SHIM"' EXIT
git -C "$WT" archive "$COMMIT" | tar -x -C "$COPY"
DAEMON_CODEX=$(ls -d "$HOME"/.codex/packages/app-server-daemon/releases/*/bin/codex | sort -V | tail -1)
cat > "$SHIM/codex" <<SH
#!/usr/bin/env bash
exec "$DAEMON_CODEX" -c 'projects.$COPY.trust_level="trusted"' -c features.hooks=false "\$@"
SH
chmod +x "$SHIM/codex"
scrub() { sed "s#$COPY#<copy>#g; s#$WT#<worktree>#g; s#$SHIM#<shim>#g; s#$HOME#~#g"; }
{
  echo "commit: $(git -C "$WT" log -1 --format='%h %s' "$COMMIT" | cut -c1-100)"
  echo "host PATH codex: $(command -v codex) -> $(codex --version)"
  echo "running managed app-server daemon: $(pgrep -fl 'app-server --listen' | awk '{print $2}' | head -1 | scrub)"
  echo
  echo "# A: gate worktree, host PATH codex"
  echo "\$ ulimit -n 256; bin/fm-test-run.sh tests/fm-composer-codex-idle-live-e2e.test.sh"
  ( cd "$WT" && ulimit -n 256 && env -u NO_MISTAKES_GATE bin/fm-test-run.sh tests/fm-composer-codex-idle-live-e2e.test.sh ) 2>&1 \
    | grep -v '^fm-test-run: test runtime' | grep -v '^FM_TEST_SUMMARY_\|^FM_TEST_SLOWEST' | scrub
  echo
  echo "# B: <copy> of the same commit, daemon's own codex ($("$DAEMON_CODEX" --version)), -c projects.<copy>.trust_level=\"trusted\" -c features.hooks=false"
  echo "\$ cd <copy>; ulimit -n 256; PATH=<shim>:\$PATH bin/fm-test-run.sh tests/fm-composer-codex-idle-live-e2e.test.sh"
  ( cd "$COPY" && ulimit -n 256 && PATH="$SHIM:$PATH" env -u NO_MISTAKES_GATE bin/fm-test-run.sh tests/fm-composer-codex-idle-live-e2e.test.sh ) 2>&1 \
    | grep -v '^fm-test-run: test runtime' | grep -v '^FM_TEST_SUMMARY_\|^FM_TEST_SLOWEST' | scrub
} >"$OUT" 2>&1
echo "driver done"
