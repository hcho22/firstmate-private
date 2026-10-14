#!/usr/bin/env bash
# Stand-in for the external `no-mistakes` CLI (v1.79.0 TOON shapes), installed
# as `no-mistakes` on the watcher's PATH. Firstmate's watcher and fm-crew-state.sh
# are the product under test; this only replaces the pipeline daemon, which a
# gate test phase may not start. It answers from the crew worktree it is run in
# (fm-crew-state.sh cds there), and its control dir is $FMLV_NM:
#   mode       none | fixing | ci | parked
#   activity   fixing: mtime = the pipeline agent's last output
#   ci-epoch   ci: epoch of the ci step's last logged line (grows old)
#   ci.log     ci: the ci step log tail (axi logs --step ci)
set -u
NM=${FMLV_NM:?}
dur() {  # <secs> -> axi compact duration
  local s=$1
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm%ss' $((s / 60)) $((s % 60))
  elif [ "$s" -lt 86400 ]; then printf '%sh%sm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%sd%sh' $((s / 86400)) $((s % 86400 / 3600)); fi
}
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
mode=$(cat "$NM/mode" 2>/dev/null || echo none)
now=$(date +%s)
branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
head=$(git rev-parse --short HEAD 2>/dev/null || true)
case "${1:-} ${2:-}" in
  "axi status")
    case "$mode" in
      fixing)
        age=$(( now - $(mtime "$NM/activity") ))
        cat <<EOF
run:
  id: "01LIVERUN"
  branch: $branch
  status: running
  head: "$head"
  pr: ""
  findings: 1 awaiting
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,216
    review,completed,0,5432
    test,fixing,1,0
  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    test,fixing,$(dur $((age + 155))),$(dur $((age + 11))),"$(dur "$age") ago: claude producing output","84750",fix 1
branch_sync:
  state: pipeline_owned
EOF
        ;;
      ci)
        age=$(( now - $(cat "$NM/ci-epoch") ))
        last=$(tail -1 "$NM/ci.log")
        cat <<EOF
run:
  id: "01LIVERUN"
  branch: $branch
  status: running
  head: "$head"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    ci,running,$(dur $((age + 14))),$(dur $((age + 14))),"$(dur "$age") ago: log: $last","",round 1
branch_sync:
  state: pipeline_owned
EOF
        ;;
      parked)
        cat <<EOF
run:
  id: "01LIVERUN"
  branch: $branch
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$head"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
        ;;
    esac
    ;;
  "axi logs")
    [ "$mode" = ci ] && cat "$NM/ci.log"
    ;;
esac
exit 0
