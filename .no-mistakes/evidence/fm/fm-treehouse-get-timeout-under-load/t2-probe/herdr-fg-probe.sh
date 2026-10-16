#!/usr/bin/env bash
# Probe: what Herdr 0.7.5 reports (pane get foreground_cwd and pane process-info)
# while the REAL treehouse get runs a slow post-checkout hook inside the new
# worktree, and after it fails or enters. Usage: herdr-fg-probe.sh <code-root> <slowfail|slow> <secs> <out>
set -u
CODE_ROOT=$1 MODE=$2 SECS=$3 OUT=$4
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
W=$(mktemp -d /tmp/fmp.XXXXXX); W=$(cd "$W" && pwd -P)
PROJ="$W/project"; POOL="$W/pool"; mkdir -p "$PROJ" "$POOL"
LAB=$("$CODE_ROOT/bin/fm-herdr-lab.sh" name fm-probe)
cleanup() { "$CODE_ROOT/bin/fm-herdr-lab.sh" teardown "$LAB" >/dev/null 2>&1; pkill -f "$W/" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
git -C "$PROJ" init -q
printf 'x\n' > "$PROJ/README.md"; printf 'root = "%s"\n' "$POOL" > "$PROJ/treehouse.toml"
git -C "$PROJ" add . && git -C "$PROJ" -c user.name=p -c user.email=p@e.invalid commit -qm i
git clone -q --bare "$PROJ" "$W/origin.git"; git -C "$PROJ" remote add origin "file://$W/origin.git"
cat > "$PROJ/.git/hooks/post-checkout" <<SH
#!/bin/bash
i=0; while [ \$i -lt $SECS ]; do sleep 1; i=\$((i+1)); done
[ "$MODE" = slowfail ] && { echo "hook: fatal: setup failed" >&2; exit 1; }
exit 0
SH
chmod +x "$PROJ/.git/hooks/post-checkout"
printf '#!/bin/bash\nexec /bin/bash --noprofile --norc "$@"\n' > "$W/bash-norc"; chmod +x "$W/bash-norc"
SHELL="$W/bash-norc" "$CODE_ROOT/bin/fm-herdr-lab.sh" provision "$LAB" > /dev/null 2>&1 || { echo "provision failed"; exit 2; }
H() { "$CODE_ROOT/bin/fm-herdr-lab.sh" run "$LAB" "$@"; }
ws=$(H workspace create --cwd "$PROJ" --label probe --no-focus)
pane=$(printf '%s' "$ws" | jq -r '.. | objects | .pane_id? // empty' | head -n 1)
echo "workspace create: $ws" > "$OUT"
echo "pane=$pane" >> "$OUT"
sleep 2
H pane run "$pane" "treehouse get" >/dev/null
for i in $(seq 1 $((SECS + 8))); do
  g=$(H pane get "$pane" | jq -c '{cwd: .result.pane.cwd, fg: .result.pane.foreground_cwd}')
  p=$(H pane process-info --pane "$pane" | jq -c '.result.process_info | {pgid: .foreground_process_group_id, shell: .shell_pid, fg: [.foreground_processes[] | {pid, name, cwd}]}')
  printf '%s t=%s get=%s pi=%s\n' "$(date +%H:%M:%S)" "$i" "$g" "$p" >> "$OUT"
  sleep 1
done
echo "--- pane read" >> "$OUT"
H pane read "$pane" --source recent --lines 20 >> "$OUT" 2>&1
