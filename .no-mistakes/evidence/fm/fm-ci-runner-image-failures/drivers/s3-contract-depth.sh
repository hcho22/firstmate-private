#!/usr/bin/env bash
# S3: drive bin/fm-evidence-import-contract.py --file <input> with crafted
# nesting inputs and print exit code, stdout size, stderr refusal, and wall time.
set -u
root=$1 py_dir=$2
PATH="$py_dir:$PATH"; export PATH
work=$(mktemp -d /tmp/fmnm-depth.XXXXXX)
base="$root/tests/fixtures/evidence-import-contract/producer-a.json"
python3 - "$base" "$work" <<'PY'
import sys
from pathlib import Path
base, work = sys.argv[1], Path(sys.argv[2])
raw = Path(base).read_bytes().lstrip()
def nested(arrays):
    return b'{"future_depth":' + b"[" * arrays + b"0" + b"]" * arrays + b"," + raw[1:]
(work / "depth-512.json").write_bytes(nested(511))      # top-level object + 511 arrays = 512 levels
(work / "depth-513.json").write_bytes(nested(512))      # 513 levels
(work / "depth-10000.json").write_bytes(nested(sys.getrecursionlimit() * 10))
s = b'"future_text":"\\\"' + b"[{" * 2000 + b'",'
(work / "string-brackets.json").write_bytes(b"{" + s + raw[1:])
o = b'{"future_text":"'
(work / "unterminated-escaped-quotes.json").write_bytes(o + b'\\"' * ((1048576 - len(o)) // 2))
PY
echo "interpreter: $(command -v python3) $(python3 -V 2>&1); tree: $root"
for f in depth-512 depth-513 depth-10000 string-brackets unterminated-escaped-quotes; do
  start=$(python3 -c 'import time;print(time.time())')
  rc=0
  "$root/bin/fm-evidence-import-contract.py" --file "$work/$f.json" > "$work/out" 2> "$work/err" || rc=$?
  end=$(python3 -c 'import time;print(time.time())')
  printf '%-30s bytes=%-8s exit=%s stdout_bytes=%-6s secs=%-6s stderr=%s\n' "$f" "$(wc -c < "$work/$f.json" | tr -d ' ')" "$rc" \
    "$(wc -c < "$work/out" | tr -d ' ')" "$(python3 -c "print(round($end-$start,2))")" "$(head -c 160 "$work/err")"
done
rm -rf "$work"
