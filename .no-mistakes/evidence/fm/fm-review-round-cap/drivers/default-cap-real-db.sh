#!/usr/bin/env bash
# Default cap 3 against REAL runs in the real no-mistakes state database (opened
# mode=ro). No checked-out copy sits on these runs' branches, so a stand-in
# `no-mistakes` answers ONLY `axi status` with the run id; everything else is real.
set -u
EV=/Users/hcho/.no-mistakes/evidence/01M6HR18JABP7EHA7FYRXQ37BB/default-cap; WT=/Users/hcho/.no-mistakes/worktrees/5e4a80ba0eae/01M6HR18JABP7EHA7FYRXQ37BB
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/bin"
cat > "$LAB/bin/no-mistakes" <<'NM'
#!/usr/bin/env bash
[ "$*" = "axi status" ] || exit 1
if [ -n "${RUN:-}" ]; then printf 'run:\n  id: "%s"\n  status: fixing\n' "$RUN"; else printf 'other_branch_run:\n  id: "01M6GNQR2MFM9DGX71GGBS1DC0"\n'; fi
NM
chmod +x "$LAB/bin/no-mistakes"
truth() {  # independent ground truth straight from the database
  python3 - "$1" "$2" <<'PY'
import sqlite3, sys
db = sqlite3.connect("file:" + __import__("os").path.expanduser("~/.no-mistakes/state.sqlite") + "?mode=ro", uri=True)
rows = db.execute("select x.round, x.trigger_type from step_results s join step_rounds x on x.step_result_id=s.id where s.run_id=? and s.step_name=? order by x.round, x.rowid", (sys.argv[1], sys.argv[2])).fetchall()
print("db rounds:", " ".join("%s:%s" % r for r in rows))
PY
}
for spec in "01M6G4M5ED85ZY2VEC9NVZ1ZSG review" "01M6GNQR2MFM9DGX71GGBS1DC0 review" "01M4GAVTMAP2VAMWWCJKPVN41F review" "01M683HSVZ77Z9CT4VKHKCE1SQ review"; do
  set -- $spec
  echo "## run $1 step $2"; truth "$1" "$2"
  (cd "$LAB" && env -u NM_HOME -u NO_MISTAKES_GATE FM_HOME="$LAB" RUN="$1" PATH="$LAB/bin:$PATH" "$WT/bin/fm-nm-rounds.sh" check --step "$2" --out-dir "$EV" | grep -v '^escalation' ; echo "[exit ${PIPESTATUS[0]}]")
  (cd "$LAB" && env -u NM_HOME -u NO_MISTAKES_GATE FM_HOME="$LAB" RUN="$1" PATH="$LAB/bin:$PATH" "$WT/bin/fm-nm-rounds.sh" check --step "$2" --out-dir "$EV" | sed -n 's/^escalation: /escalation: /p')
  echo
done
echo "## only another branch's run (other_branch_run:) - must never be read as this copy's run"
(cd "$LAB" && env -u NM_HOME -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$LAB/bin:$PATH" "$WT/bin/fm-nm-rounds.sh" check --step review); echo "[exit $?]"
