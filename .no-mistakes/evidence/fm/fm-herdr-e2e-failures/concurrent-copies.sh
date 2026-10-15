#!/usr/bin/env bash
# Run N concurrent copies of one real-Herdr e2e script, each in its own private
# TMPDIR and its own uniquely named Herdr lab session (the script provisions
# that itself), and summarize each copy's exit status and failing line.
# Usage: concurrent-copies.sh <label> <copies> <script> <out-dir>
set -u
label=$1 copies=$2 script=$3 out=$4
mkdir -p "$out"
run_root=$(mktemp -d /tmp/fm-cc-"$label".XXXXXX)
pids=()
for i in $(seq 1 "$copies"); do
  mkdir -m 700 "$run_root/tmp$i"
  (
    start=$SECONDS
    env TMPDIR="$run_root/tmp$i" bash "$script" > "$out/$label-copy$i.log" 2>&1
    status=$?
    printf 'exit=%s duration_s=%s\n' "$status" "$((SECONDS - start))" >> "$out/$label-copy$i.log"
  ) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
pass=0 fail=0
{
  printf '%s: %s concurrent copies of %s\n' "$label" "$copies" "$script"
  for i in $(seq 1 "$copies"); do
    line=$(tail -n 1 "$out/$label-copy$i.log")
    case "$line" in
      exit=0*) pass=$((pass + 1)); printf 'copy %s: PASS (%s)\n' "$i" "$line" ;;
      *) fail=$((fail + 1))
         printf 'copy %s: FAIL (%s) %s\n' "$i" "$line" "$(grep -m1 '^not ok' "$out/$label-copy$i.log")" ;;
    esac
  done
  printf '%s: %s passed, %s failed\n' "$label" "$pass" "$fail"
} | tee "$out/$label-summary.txt"
rm -rf "$run_root"
