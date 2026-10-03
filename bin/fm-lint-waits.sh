#!/usr/bin/env bash
# fm-lint-waits.sh - owner of firstmate's counted-wait rule for tests.
#
# A test that waits for a background event by counting a fixed number of short
# sleeps fails once a loaded host takes longer than that count adds up to, even
# though nothing is wrong. Wait on the event itself under a clock deadline
# instead (deadline=$((SECONDS + 60)); while ... [ "$SECONDS" -lt "$deadline" ]),
# which only bounds a real hang. This check finds the counted form in shell
# tests: a `while` whose condition (continuation lines included) compares a
# variable with an integer literal through -lt or -le, whose body increments
# that variable by one and sleeps a literal number of seconds at its own level
# (not in a nested loop, subshell block, quoted script, or here-document), and
# whose count times its sleeps is under the 60-second event-wait standard. A
# deliberately short window (an observation window, a reap grace before a forced
# kill) is kept by naming its reason on a comment directly above the loop, or
# above the counter's initialisation there:
#   # fm-lint-waits: allow <reason>
# Loops bounded by a variable, or counting 60 seconds or more, are not flagged.
# bin/fm-lint.sh runs this owner on its default (no explicit-path) path, which
# CI and commands.lint both use.
#
# Usage:
#   fm-lint-waits.sh              check tests/*.sh under this repo
#   fm-lint-waits.sh <path>...    check explicit files
#   fm-lint-waits.sh --help
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint-waits.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

case "${1:-}" in
  -h|--help)
    sed -n '2,23{s/^# \{0,1\}//;p;}' "$SELF"
    exit 0
    ;;
esac

if [ "$#" -eq 0 ]; then
  cd "$ROOT"
  set -- tests/*.sh
fi

command -v python3 >/dev/null 2>&1 || {
  printf 'fm-lint-waits.sh: python3 is required.\n' >&2
  exit 127
}

python3 - "$@" <<'PY'
import re
import sys

STANDARD_SECS = 60
MARKER = re.compile(r"#\s*fm-lint-waits:\s*allow\s+\S")
COUNTER = re.compile(r'\[ "?\$\{?([A-Za-z_]\w*)\}?"? -(lt|le) ([0-9]+) \]')
SLEEP = re.compile(r"(?:^|[;&|({\s])sleep ([0-9]*\.?[0-9]+)(?=[\s;)&|]|$)")
HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_]\w*)['\"]?")
DQ = re.compile(r'"(?:[^"\\]|\\.)*"')
ASSIGN = re.compile(r"^\s*(?:local\s+)?[A-Za-z_]\w*=\S*\s*$")


def increments(var, text):
    return re.search(r"\b%s=\$\(\(\s*%s\s*\+\s*1\s*\)\)|\(\(\s*%s\+\+\s*\)\)|\(\(\s*%s\s*\+=\s*1\s*\)\)"
                     % (var, var, var, var), text) is not None


def own_level(lines):
    """Drop nested loops and subshell blocks, whose sleeps are not this loop's."""
    closer = None
    for line in lines:
        if closer is not None:
            if closer.match(line):
                closer = None
            continue
        nested = re.match(r"^([ \t]*)(?:while|until|for)\b", line)
        if nested and not re.search(r";\s*done\b", line):
            closer = re.compile(re.escape(nested.group(1)) + r"done(?:[\s;)|&<>]|$)")
            continue
        if nested:
            continue
        sub = re.match(r"^([ \t]*)\(\s*$", line)
        if sub:
            closer = re.compile(re.escape(sub.group(1)) + r"\)")
            continue
        yield line


def code_lines(lines):
    """Yield body lines that are shell code, not quoted script or heredoc text."""
    in_quote = False
    heredoc = None
    for line in lines:
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        if not in_quote:
            yield line
        if line.lstrip().startswith("#"):
            continue
        bare = DQ.sub("", line)
        if bare.count("'") % 2 == 1:
            in_quote = not in_quote
        if not in_quote:
            m = HEREDOC.search(bare)
            if m:
                heredoc = m.group(1)


def allowed(lines, i):
    j = i - 1
    while j >= 0 and i - j <= 8:
        text = lines[j]
        if MARKER.search(text):
            return True
        if text.lstrip().startswith("#") or ASSIGN.match(text):
            j -= 1
            continue
        break
    return False


findings = []
for path in sys.argv[1:]:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError as exc:
        print(f"fm-lint-waits.sh: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(2)
    for i, line in enumerate(lines):
        if not re.match(r"^\s*while\b", line) or line.lstrip().startswith("#"):
            continue
        indent = re.match(r"[ \t]*", line).group(0)
        # The condition runs to the line that opens the body with `do`.
        h = i
        while h < len(lines) and not re.search(r"(?:;|^|\s)do(?:\s|$)", lines[h]) and h - i < 10:
            h += 1
        if h >= len(lines):
            continue
        header = " ".join(lines[i:h + 1])
        cond = re.split(r"(?:;|\s)do(?:\s|$)", header, maxsplit=1)[0]
        m = COUNTER.search(cond)
        if not m or "SECONDS" in cond:
            continue
        var, op, limit = m.group(1), m.group(2), int(m.group(3))
        if re.search(r";\s*done\b", lines[h]):
            body = [re.split(r"(?:;|\s)do(?:\s|$)", lines[h], maxsplit=1)[-1]]
        else:
            closer = re.compile(re.escape(indent) + r"done(?:[\s;)|&]|$)")
            end = next((k for k in range(h + 1, len(lines)) if closer.match(lines[k])), None)
            if end is None:
                continue
            body = lines[h + 1:end]
        code = list(own_level(code_lines(body)))
        text = "\n".join(code)
        if not increments(var, text):
            continue
        per_iteration = sum(float(s) for c in code for s in SLEEP.findall(DQ.sub('""', c)))
        if per_iteration <= 0:
            continue
        iterations = limit + (1 if op == "le" else 0)
        budget = iterations * per_iteration
        if budget >= STANDARD_SECS or allowed(lines, i):
            continue
        findings.append(
            f"{path}:{i + 1}: counted wait of {iterations} x {per_iteration:g} s ({budget:g} s); "
            f"wait on the event under a clock deadline (deadline=$((SECONDS + {STANDARD_SECS}))) "
            f"or name a deliberate window with '# fm-lint-waits: allow <reason>' above the loop")

for finding in findings:
    print(finding)
if findings:
    print(f"fm-lint-waits.sh: {len(findings)} counted short wait(s)", file=sys.stderr)
    sys.exit(1)
print(f"fm-lint-waits.sh: {len(sys.argv) - 1} files have no counted short waits", file=sys.stderr)
PY
