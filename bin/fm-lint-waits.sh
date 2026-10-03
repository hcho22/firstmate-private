#!/usr/bin/env bash
# fm-lint-waits.sh - owner of firstmate's counted-wait rule for tests.
#
# A test that waits for a background event by counting a fixed number of short
# sleeps fails once a loaded host takes longer than that count adds up to, even
# though nothing is wrong. Wait on the event itself under a clock deadline
# instead (deadline=$((SECONDS + 60)); while ... [ "$SECONDS" -lt "$deadline" ]),
# which only bounds a real hang. This check finds the counted form in shell
# tests, including here-document stubs (with \$ escapes) and quoted scripts:
#   - a `while` whose condition compares a counter with -lt or -le N, or an
#     `until` whose condition compares it with -ge or -gt N;
#   - a `while` or `until` whose body guards a counter against N, as in
#     [ "$i" -lt N ] || fail, [ "$i" -ge N ] && break, if [ "$i" -ge N ];
#   - a `for` over $(seq ... N), {A..N}, a list of integers, or
#     ((i = A; i < N; i++)) whose body leaves early with break or return.
# A counter is a variable the body increments by one and never resets; N is an
# integer literal, or a variable whose nearest assignment above the loop in the
# same function is a literal or a literal default (limit=${2:-50}). The loop
# must sleep a literal number of seconds (sleep or /bin/sleep) at its own level
# (not in a nested loop, subshell block, quoted script, or here-document), and
# is flagged when its count times its sleeps is under the 60-second event-wait
# standard. Loops that also read a clock (SECONDS, date +%s) are clock-bounded,
# except a deadline the loop's own body assigns from the clock
# (deadline=$((SECONDS + 60))): it restarts every iteration and bounds nothing.
# Not detected, because the bound cannot be read reliably from the text: a
# bound computed by arithmetic or taken from the caller or environment, a
# counter that counts down or by more than one, an arithmetic (( )) condition,
# a sleep given by a variable, and a wait made inside a called function.
# A deliberately short window (an observation window, a reap grace before a
# forced kill) is kept by naming its reason on a comment directly above the
# loop, or above the counter's initialisation there:
#   # fm-lint-waits: allow <reason>
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
    sed -n '2,39{s/^# \{0,1\}//;p;}' "$SELF"
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
CMP = re.compile(r'\[\[? "?\$\{?([A-Za-z_]\w*)\}?"? -(lt|le|ge|gt) "?(?:([0-9]+)|\$\{?([A-Za-z_]\w*)\}?)"? \]\]?')
SLEEP = re.compile(r"(?:^|[;&|({\s])(?:/usr/bin/|/bin/)?sleep ([0-9]*\.?[0-9]+)(?=[\s;)&|]|$)")
HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_]\w*)['\"]?")
DQ = re.compile(r'"(?:[^"\\]|\\.)*"')
ASSIGN = re.compile(r"^\s*(?:local\s+)?[A-Za-z_]\w*=\S*\s*$")
LOOP = re.compile(r"^\s*(while|until|for)\b")
FUNC = re.compile(r"^\s*(?:function\s+)?[A-Za-z_][\w:-]*\s*\(\)\s*\{?\s*(?:#.*)?$|^\}\s*$")
FOR_SEQ = re.compile(r"^\s*for\s+[A-Za-z_]\w*\s+in\s+\$\(seq(?:\s+-w)?((?:\s+[0-9]+){1,3})\s*\)\s*(?:;|$)")
FOR_RANGE = re.compile(r"^\s*for\s+[A-Za-z_]\w*\s+in\s+\{([0-9]+)\.\.([0-9]+)\}\s*(?:;|$)")
FOR_LIST = re.compile(r"^\s*for\s+[A-Za-z_]\w*\s+in((?:\s+[0-9]+)+)\s*(?:;|$)")
FOR_C = re.compile(r"^\s*for\s*\(\(\s*([A-Za-z_]\w*)\s*=\s*([0-9]+)\s*;\s*\1\s*(<=?)\s*([0-9]+)\s*;"
                   r"\s*(?:\1\s*\+\+|\+\+\s*\1|\1\s*\+=\s*1)\s*\)\)")
OWN_EXIT = re.compile(r"(?:^|[;&|{(\s])(?:break|return)(?=[\s;)}]|$)")
OUTER_EXIT = re.compile(r"(?:^|[;&|{(\s])(?:break\s+[2-9]|return)(?=[\s;)}]|$)")
CLOCK = re.compile(r"\bSECONDS\b|\bEPOCHSECONDS\b|date \+%s")
DEADLINE_SET = re.compile(r"^\s*(?:local\s+)?[A-Za-z_]\w*=\$\(\(\s*(?:\$?\{?(?:EPOCH)?SECONDS\}?|\$\(date \+%s\))"
                          r"\s*\+[^;&|]*\)\)\s*;?\s*$")


def unescape(text):
    """Read a here-document stub or double-quoted script the way it will run."""
    return text.replace("\\$", "$").replace('\\"', '"')


def increments(var, text):
    return re.search(r"\b%s=\$\(\(\s*\$?\{?%s\}?\s*\+\s*1\s*\)\)|\(\(\s*%s\s*\+\+\s*\)\)|\(\(\s*%s\s*\+=\s*1\s*\)\)"
                     % (var, var, var, var), text) is not None


def assigns(var, text):
    """Plain assignments of var other than its increment by one."""
    return [m.group(1) for m in re.finditer(r"(?:^|[;&|{(\s])%s=(\S*)" % var, text, re.M)
            if not m.group(1).startswith("$((")]


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


def split_code(line, in_quote=False):
    """The line's code before its comment, and whether a single quote is open after it.

    in_quote says a single-quoted string is already open where the line starts.
    A comment is a # that starts a word outside quotes.
    """
    quote = "'" if in_quote else ""
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 1
            elif c == quote:
                quote = ""
        elif c == "\\":
            i += 1
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i], False
        i += 1
    return line, quote == "'"


def strip_comment(line):
    return split_code(line)[0]


def code_lines(lines):
    """Yield body lines' shell code, without comments, quoted script, or heredoc text."""
    in_quote = False
    heredoc = None
    for line in lines:
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        opened = in_quote
        code, in_quote = split_code(line, in_quote)
        if not opened:
            yield code
        if not in_quote:
            m = HEREDOC.search(DQ.sub("", code))
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


def literal_value(lines, i, var):
    """The literal a bound variable holds at loop line i, or None.

    Only the nearest assignment above the loop in the same function counts, and
    only when it is a literal or a literal default such as ${2:-50}.
    """
    for j in range(i - 1, -1, -1):
        text = unescape(strip_comment(lines[j]))
        values = assigns(var, text)
        if values:
            m = re.fullmatch(r'"?(?:([0-9]+)|\$\{[A-Za-z0-9_]+:-([0-9]+)\})"?;?', values[-1])
            return int(m.group(1) or m.group(2)) if m else None
        if FUNC.match(text):
            return None
    return None


def for_count(header):
    """The iteration count of a `for` over literal integers, or None."""
    m = FOR_SEQ.match(header)
    if m:
        nums = [int(n) for n in m.group(1).split()]
        first, step, last = (1, 1, nums[0]) if len(nums) == 1 else \
            (nums[0], 1, nums[1]) if len(nums) == 2 else nums
        return (last - first) // step + 1 if step > 0 and last >= first else None
    m = FOR_RANGE.match(header)
    if m:
        return int(m.group(2)) - int(m.group(1)) + 1
    m = FOR_LIST.match(header)
    if m:
        return len(m.group(1).split())
    m = FOR_C.match(header)
    if m:
        return int(m.group(4)) - int(m.group(2)) + (1 if m.group(3) == "<=" else 0)
    return None


def counter_bound(lines, i, kind, cond, text):
    """The iteration count a counter allows, or None (see the header)."""
    for place, where in ((cond, kind), (text, "body")):
        for var, op, literal, bound_var in CMP.findall(place):
            if not increments(var, text) or assigns(var, text):
                continue
            if where == "while" and op not in ("lt", "le"):
                continue
            if where == "until" and op not in ("ge", "gt"):
                continue
            if literal:
                limit = int(literal)
            elif assigns(bound_var, text):
                continue
            else:
                limit = literal_value(lines, i, bound_var)
                if limit is None:
                    continue
            return limit + (1 if op in ("le", "gt") else 0)
    return None


findings = []
for path in sys.argv[1:]:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError as exc:
        print(f"fm-lint-waits.sh: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(2)
    for i, line in enumerate(lines):
        loop = LOOP.match(line)
        if not loop or line.lstrip().startswith("#"):
            continue
        kind = loop.group(1)
        indent = re.match(r"[ \t]*", line).group(0)
        # The header runs to the line that opens the body with `do`.
        h = i
        while h < len(lines) and not re.search(r"(?:;|^|\s)do(?:\s|$)", strip_comment(lines[h])) and h - i < 10:
            h += 1
        if h >= len(lines):
            continue
        header = unescape(" ".join(strip_comment(text) for text in lines[i:h + 1]))
        cond = re.split(r"(?:;|\s)do(?:\s|$)", header, maxsplit=1)[0]
        if re.search(r";\s*done\b", strip_comment(lines[h])):
            body = [re.split(r"(?:;|\s)do(?:\s|$)", strip_comment(lines[h]), maxsplit=1)[-1]]
        else:
            closer = re.compile(re.escape(indent) + r"done(?:[\s;)|&]|$)")
            end = next((k for k in range(h + 1, len(lines)) if closer.match(lines[k])), None)
            if end is None:
                continue
            body = lines[h + 1:end]
        code = list(own_level(code_lines(body)))
        text = unescape("\n".join(code))
        clock_text = "\n".join(c for c in text.split("\n") if not DEADLINE_SET.match(c))
        if CLOCK.search(cond) or CLOCK.search(clock_text):
            continue
        per_iteration = sum(float(s) for c in code for s in SLEEP.findall(DQ.sub('""', c)))
        if per_iteration <= 0:
            continue
        if kind == "for":
            # Without an early exit a `for` is paced work, not a wait for an event.
            leaves = OWN_EXIT.search(text) or OUTER_EXIT.search(unescape("\n".join(code_lines(body))))
            iterations = for_count(header) if leaves else None
        else:
            iterations = counter_bound(lines, i, kind, cond, text)
        if iterations is None:
            continue
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
