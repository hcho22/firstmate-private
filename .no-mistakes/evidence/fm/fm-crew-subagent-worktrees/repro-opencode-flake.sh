#!/usr/bin/env bash
# Deterministic reproduction of the configured-run flake in
# tests/fm-pi-watch-extension.test.sh "OpenCode watch plugin must use FM_HOME
# state outside the repo root". Uses the real OpenCode plugin and the case's own
# node program. The arm fixture pauses between creating its log (the `>>`
# redirection's O_CREAT) and writing its row - the window a loaded host opens.
# WAIT=exists reproduces the test's current wait; WAIT=row is the fixed wait.
set -u
ROOT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M44BR43SXK4JJJ6D2ES4X423
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FM_OPENCODE_ARM_READY_TIMEOUT_MS=60000
cat > "$T/wait.mjs" <<'JS'
import { existsSync, readFileSync } from "node:fs";
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export async function until(p, { guardMs = 60000, pollMs = 10 } = {}) {
  const s = performance.now();
  for (;;) { if (await p()) return true; if (performance.now() - s >= guardMs) return false; await sleep(pollMs); }
}
export const hasRow = (path) => existsSync(path) && readFileSync(path, "utf8").includes("\n");
JS
for WAIT in exists row; do
  repo="$T/$WAIT-root" home="$T/$WAIT-home" log="$T/$WAIT.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"; git init -q "$repo"; : > "$repo/AGENTS.md"; : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exec 3>>"${FM_ARM_LOG:?}"
sleep 0.5
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >&3
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(WAIT="$WAIT" W="file://$T/wait.mjs" PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { until, hasRow } = await import(process.env.W);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (process.env.WAIT === "exists") await until(() => existsSync(process.env.FM_ARM_LOG));
else await until(() => hasRow(process.env.FM_ARM_LOG));
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(`read ${JSON.stringify(text)}`);
  process.exit(1);
}
EOF
)
  echo "wait=$WAIT exit=$? ${out}"
done
