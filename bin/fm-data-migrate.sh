#!/usr/bin/env bash
# Move this home's flat per-task data folders into the per-project layout.
#
# Before: data/<task-id>/           After: data/<ProjectDir>/<task-id>/
# bin/fm-task-data-lib.sh owns the layout, the project-folder naming, and the
# bounded legacy read that keeps an unmigrated home working until this runs.
#
# Usage: fm-data-migrate.sh [--dry-run | --apply] [--revert] [--assign <task-id>=<Project>]...
#   --dry-run   print exactly what would move and be rewritten, change nothing
#               (the default, so a bare run is always safe)
#   --apply     perform the moves and the record rewrites
#   --revert    the inverse: move <ProjectDir>/<task-id> folders back to flat
#               data/<task-id> and rewrite the recorded links back; it is the
#               recovery path if the layout change must be undone. It moves back
#               every folder carrying a task marker plus every folder this
#               command recorded in data/.layout-migration.tsv when it moved it
#   --assign    name the project of a folder the command cannot place itself
#               (repeatable); also treats a marker-less flat folder as a task
#
# The project of a flat folder comes from, in order: --assign; the secondmate
# registry (charter briefs go to _secondmates); the repo named in its brief
# ("disposable git worktree of <repo>"); the (repo: <name>) annotation on its
# backlog or archive line. The name then maps to a folder exactly as a new brief
# would (the registry spelling for a registered project). A folder with no answer
# is reported as unresolved and left flat; it stays readable through the legacy
# lookup until --assign places it.
#
# Destinations are checked against data/ as it will be after this run's own
# moves: a name that a planned move vacates (on a case-insensitive disk, in any
# spelling) is free, and every move out of the folder holding it runs before the
# move that needs it, however long the chain. A folder whose destination needs
# its own name (task RepToday of project RepToday, or the reverse on --revert)
# passes through a temporary data/.layout-migration.* folder. Moves that wait on
# each other in a cycle are refused as a conflict, with the cycle named.
#
# What it touches, and nothing else:
#   - moves flat task folders under data/ by rename (no copy, no deletion)
#   - rewrites `data/<task-id>/` links inside data/backlog.md, done-archive.md,
#     and note-archive.md (the backlog's own records), atomically per file;
#     a `data/<name>/` link whose <name> is spelled exactly like a project
#     folder already names that folder and is never rewritten. The forward
#     run rewrites after its moves and --revert before them, so a run stopped
#     midway is finished by repeating it
# It never moves or edits any other fleet-wide root file (projects.md,
# secondmates.md, captain*.md, learnings.md, ...); legacy links still present in
# those, or inside task documents, are counted and reported, never rewritten.
#
# REFUSES (exit 3, nothing changed) while any non-secondmate task has a
# state/<id>.meta, or any process-event source or condition watch is registered,
# because those hold paths into task folders. A registered secondmate does not
# block: its charter folder is found by lookup wherever it lives.
# Exit codes: 0 done (or nothing to do), 2 usage, 3 refused, 4 conflict, 1 failure.
# Output lines: mode, blocked, move, revert, skip, unresolved, rewrite, note,
# summary. Re-running is idempotent: a migrated home reports nothing to move.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-data-lib.sh
. "$SCRIPT_DIR/fm-task-data-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

APPLY=0
REVERT=0
ASSIGNS=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) APPLY=0 ;;
    --apply) APPLY=1 ;;
    --revert) REVERT=1 ;;
    --assign)
      [ "$#" -ge 2 ] || { echo "error: --assign requires <task-id>=<Project>" >&2; exit 2; }
      ASSIGNS="$ASSIGNS$2"$'\n'
      shift ;;
    --assign=*) ASSIGNS="$ASSIGNS${1#--assign=}"$'\n' ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$ASSIGNS" ]; then
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    case "$pair" in
      *=*) fm_task_id_path_safe "${pair%%=*}" && [ -n "${pair#*=}" ] || { echo "error: bad --assign value: $pair" >&2; exit 2; } ;;
      *) echo "error: --assign value must be <task-id>=<Project>: $pair" >&2; exit 2 ;;
    esac
  done <<EOF
$ASSIGNS
EOF
  [ "$REVERT" -eq 0 ] || { echo "error: --assign applies only to the forward migration" >&2; exit 2; }
fi

[ -d "$DATA" ] || { echo "error: data directory not found: $DATA" >&2; exit 1; }
DATA=$(CDPATH='' cd -- "$DATA" && pwd -P)

if [ "$APPLY" -eq 1 ]; then MODE=apply; else MODE=dry-run; fi
[ "$REVERT" -eq 0 ] || MODE="$MODE revert"
echo "mode: $MODE home=$FM_HOME data=$DATA"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-data-migrate.XXXXXX") || { echo "error: cannot create a scratch directory" >&2; exit 1; }
LOCKDIR=
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  [ -z "$LOCKDIR" ] || fm_lock_release "$LOCKDIR" 2>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT
MANIFEST="$DATA/.layout-migration.tsv"   # id <TAB> ProjectDir, one line per folder this command moved
CANDIDATES="$WORK/candidates.tsv"  # every placeable move, before order_plan checks it
PLAN="$WORK/plan.tsv"        # id <TAB> source dir <TAB> destination dir <TAB> why, in apply order
REWRITE_MAP="$WORK/map.tsv"  # rewrite map, see build_rewrite_map
PLANNED="$WORK/planned.tsv"  # lowercase <TAB> spelling of project folders this run creates
: > "$CANDIDATES"; : > "$PLAN"; : > "$REWRITE_MAP"; : > "$PLANNED"
UNRESOLVED=0
SKIPPED=0
CONFLICTS=0
PROJECT_FOLDERS=

# --- the live gate ----------------------------------------------------------

BLOCKED=0
check_live() {
  local meta id kind entry
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    [ "$kind" != secondmate ] || continue
    echo "blocked: task $id is live (state/$id.meta); finish or tear it down first"
    BLOCKED=1
  done
  for entry in "$STATE/procevent" "$STATE/when"; do
    if [ -d "$entry" ] && [ -n "$(ls -A "$entry" 2>/dev/null)" ]; then
      echo "blocked: registered sources remain in $(basename "$entry") and hold paths into task folders; retire them first"
      BLOCKED=1
    fi
  done
}

# --- planning ---------------------------------------------------------------

assigned_project() {  # <id>
  local pair
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    if [ "${pair%%=*}" = "$1" ]; then printf '%s\n' "${pair#*=}"; return 0; fi
  done <<EOF
$ASSIGNS
EOF
  return 1
}

repo_from_brief() {  # <dir>
  [ -f "$1/brief.md" ] || return 1
  sed -n 's/.*disposable git worktree of \(.*\), at a detached HEAD.*/\1/p' "$1/brief.md" | head -1
}

repo_from_backlog() {  # <id>
  local file
  for file in "$DATA/backlog.md" "$DATA/done-archive.md"; do
    [ -f "$file" ] || continue
    awk -v id="$1" '
      substr($0, 1, 3) == "- [" && substr($0, 5, 2) == "] " && substr($0, 7, length(id) + 1) == id " " {
        if (match($0, /\(repo: [^)]*\)/)) {
          print substr($0, RSTART + 7, RLENGTH - 8)
          exit
        }
      }
    ' "$file"
  done | head -1
}

# The same mapping a new brief uses, made stable across one run: the first
# spelling planned for a case-insensitive name wins.
planned_dirname() {  # <project>
  local name lower planned
  name=$(fm_task_data_project_dirname "$DATA" "$1") || return 1
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  planned=$(awk -F'\t' -v l="$lower" '$1 == l { print $2; exit }' "$PLANNED")
  if [ -n "$planned" ]; then
    printf '%s\n' "$planned"
    return 0
  fi
  printf '%s\t%s\n' "$lower" "$name" >> "$PLANNED"
  printf '%s\n' "$name"
}

plan_forward() {
  local entry name id repo why project dirname
  PROJECT_FOLDERS=
  for entry in "$DATA"/*/; do
    entry=${entry%/}
    name=${entry##*/}
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    case "$name" in _*|.*) continue ;; esac
    fm_task_data_root_reserved "$name" && continue
    id=$name
    if ! fm_task_data_has_marker "$entry" && fm_task_data_registered_name "$DATA" "$name" >/dev/null 2>&1; then
      PROJECT_FOLDERS="$PROJECT_FOLDERS $name"
      continue
    fi
    if ! fm_task_data_has_marker "$entry" && ! assigned_project "$id" >/dev/null; then
      if find "$entry" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
        PROJECT_FOLDERS="$PROJECT_FOLDERS $name"
      else
        echo "skip: data/$name has no task marker and no assignment; if it is a task folder, rerun with --assign $name=<Project>"
        SKIPPED=$((SKIPPED + 1))
      fi
      continue
    fi
    repo=
    why=
    if project=$(assigned_project "$id"); then
      repo=$project; why=assigned
    elif [ -f "$DATA/secondmates.md" ] && secondmate_registry_field "$DATA/secondmates.md" "$id" home >/dev/null 2>&1; then
      repo=$FM_TASK_DATA_SECONDMATES; why="secondmate registry"
    elif repo=$(repo_from_brief "$entry") && [ -n "$repo" ]; then
      why="brief"
    elif repo=$(repo_from_backlog "$id") && [ -n "$repo" ]; then
      why="backlog repo"
    fi
    if [ -z "$repo" ]; then
      echo "unresolved: data/$id has no recorded project; rerun with --assign $id=<Project>"
      UNRESOLVED=$((UNRESOLVED + 1))
      continue
    fi
    dirname=$(planned_dirname "$repo") || { UNRESOLVED=$((UNRESOLVED + 1)); continue; }
    printf '%s\t%s\t%s\t%s\n' "$id" "$entry" "$DATA/$dirname/$id" "$why" >> "$CANDIDATES"
  done
}

in_manifest() {  # <ProjectDir> <id>
  [ -f "$MANIFEST" ] && grep -Fxq -- "$2"$'\t'"$1" "$MANIFEST"
}

plan_revert() {
  local task id project
  while IFS= read -r task; do
    case "${task#"$DATA"/}" in */*) ;; *) continue ;; esac   # flat folders stay
    id=${task##*/}
    project=$(basename "$(dirname "$task")")
    if ! fm_task_data_has_marker "$task" && ! in_manifest "$project" "$id"; then
      echo "skip: data/$project/$id has no task marker and was not moved by this command; leaving it in place"
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$id" "$task" "$DATA/$id" "revert" >> "$CANDIDATES"
  done < <(fm_task_data_task_dirs "$DATA")
}

# Whether every entry of <dir> is a candidate source, so a revert leaves it empty.
emptied_by_plan() {  # <dir>
  find "$1" -mindepth 1 -maxdepth 1 | awk -F'\t' '
    FILENAME == ARGV[1] { moved[$2] = 1; next }
    !($0 in moved) { kept = 1 }
    END { exit kept }
  ' "$CANDIDATES" -
}

# The candidate folder <path> resolves to when this plan's own moves vacate it:
# a flat source a forward move takes away, or a project folder a revert empties.
# Paths compare by what they resolve to, so a case-insensitive disk matches
# across spellings.
vacated_by_plan() {  # <path>
  local id src dst why
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  while IFS=$'\t' read -r id src dst why; do
    [ "$REVERT" -eq 0 ] || src=${src%/*}
    [ "$1" -ef "$src" ] || continue
    [ "$REVERT" -eq 0 ] || emptied_by_plan "$src" || return 1
    printf '%s\n' "$src"
    return 0
  done < "$CANDIDATES"
  return 1
}

# Check every candidate against data/ as it will be once this plan's own moves
# have vacated their names, then order the plan by dependency: a move whose
# destination name is held by a folder this plan vacates runs once every move
# out of that folder has run. A folder whose own name its destination needs (a
# task id equal to its project's folder name) moves through a temporary name.
# Moves still waiting when nothing more can run wait on each other in a cycle
# and are refused, the cycle named.
order_plan() {
  local id src dst why target from holder kind cycle
  : > "$WORK/deps"
  while IFS=$'\t' read -r id src dst why; do
    if [ "$REVERT" -eq 1 ]; then target=$dst; from=${src%/*}; else target=${dst%/*}; from=$src; fi
    holder=$(vacated_by_plan "$target") || holder=
    if [ -z "$holder" ]; then
      if [ "$REVERT" -eq 0 ] && ! fm_task_data_project_folder_usable "$DATA" "${target##*/}"; then
        echo "conflict: data/${target##*/} exists but is not a project folder; leaving data/${src#"$DATA"/} where it is"
        CONFLICTS=$((CONFLICTS + 1))
        continue
      fi
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        echo "conflict: $dst already exists; leaving data/${src#"$DATA"/} where it is"
        CONFLICTS=$((CONFLICTS + 1))
        continue
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$src" "$dst" "$why" "$from" "$holder" >> "$WORK/deps"
  done < "$CANDIDATES"
  while IFS=$'\t' read -r kind id src dst why cycle; do
    if [ "$kind" = move ]; then
      printf '%s\t%s\t%s\t%s\n' "$id" "$src" "$dst" "$why" >> "$PLAN"
      continue
    fi
    echo "conflict: data/${src#"$DATA"/} cannot move: each of $cycle waits for the next to free its destination; leaving it where it is"
    CONFLICTS=$((CONFLICTS + 1))
  done < <(awk -F'\t' -v OFS='\t' -v data="$DATA/" '
    function rel(p) { return "data/" (index(p, data) == 1 ? substr(p, length(data) + 1) : p) }
    function waits_on(i,   j) {
      if (holder[i] == "") return 0
      for (j = 1; j <= n; j++) if (j != i && left[j] && from[j] == holder[i]) return j
      return 0
    }
    { n++; id[n] = $1; src[n] = $2; dst[n] = $3; why[n] = $4; from[n] = $5; holder[n] = $6; left[n] = 1 }
    END {
      do {
        progress = 0
        for (i = 1; i <= n; i++) if (left[i] && !waits_on(i)) {
          print "move", id[i], src[i], dst[i], why[i]
          left[i] = 0
          progress = 1
        }
      } while (progress)
      for (i = 1; i <= n; i++) if (left[i]) {
        split("", seen)
        cycle = ""
        for (k = i; !(k in seen); k = waits_on(k)) {
          seen[k] = 1
          cycle = cycle (cycle == "" ? "" : " -> ") rel(src[k])
        }
        print "cycle", id[i], src[i], dst[i], why[i], cycle " -> " rel(src[k])
      }
    }
  ' "$WORK/deps")
}

# --- record rewriting -------------------------------------------------------

# Rewrite map, one line per task: forward "<id> <TAB> <ProjectDir>/<id>", revert
# "<ProjectDir>/<id> <TAB> <id>". It covers every task folder already in the
# canonical layout plus every planned move, so a forward run interrupted after
# its moves and before its rewrite finishes the job when repeated. It is built
# once, from the layout before any move, and drives the dry run and the apply
# alike. A forward key spelled exactly like a project folder that stays is
# dropped: data/<that name>/ already names the project folder, so it is never
# rewritten.
build_rewrite_map() {
  local task id project entry
  : > "$REWRITE_MAP"
  if [ "$REVERT" -eq 0 ]; then
    while IFS= read -r task; do
      case "${task#"$DATA"/}" in */*) ;; *) continue ;; esac
      printf '%s\t%s\n' "${task##*/}" "${task#"$DATA"/}" >> "$REWRITE_MAP"
    done < <(fm_task_data_task_dirs "$DATA")
    awk -F'\t' '{ n = split($3, p, "/"); print $1 "\t" p[n-1] "/" $1 }' "$PLAN" >> "$REWRITE_MAP"
    for entry in "$DATA"/*/; do
      entry=${entry%/}
      fm_task_data_is_project_folder "$DATA" "${entry##*/}" || continue
      awk -F'\t' -v s="$entry" '$2 == s { f = 1 } END { exit !f }' "$PLAN" && continue
      printf '%s\n' "${entry##*/}"
    done > "$WORK/project-folders"
    awk -F'\t' 'FILENAME == ARGV[1] { project[$0] = 1; next } !($1 in project)' \
      "$WORK/project-folders" "$REWRITE_MAP" > "$REWRITE_MAP.kept" && mv "$REWRITE_MAP.kept" "$REWRITE_MAP"
  else
    awk -F'\t' '{ n = split($2, p, "/"); print p[n-1] "/" $1 "\t" $1 }' "$PLAN" >> "$REWRITE_MAP"
    while IFS= read -r task; do
      case "${task#"$DATA"/}" in */*) ;; *) continue ;; esac
      id=${task##*/}
      project=$(basename "$(dirname "$task")")
      fm_task_data_has_marker "$task" || in_manifest "$project" "$id" || continue
      printf '%s/%s\t%s\n' "$project" "$id" "$id" >> "$REWRITE_MAP"
    done < <(fm_task_data_task_dirs "$DATA")
  fi
  sort -u "$REWRITE_MAP" -o "$REWRITE_MAP"
  # An id that maps to two folders is ambiguous; rewrite neither.
  awk -F'\t' '{ c[$1]++; line[NR] = $0; key[NR] = $1 } END { for (i = 1; i <= NR; i++) if (c[key[i]] == 1) print line[i] }' \
    "$REWRITE_MAP" > "$REWRITE_MAP.unique" && mv "$REWRITE_MAP.unique" "$REWRITE_MAP"
}

# rewrite_links <mode: count|write> <file>... ; prints "<file> <TAB> <count>".
rewrite_links() {
  local mode=$1
  shift
  [ "$#" -gt 0 ] && [ -s "$REWRITE_MAP" ] || return 0
  perl -e '
    use strict; use warnings;
    my ($mapfile, $mode, @files) = @ARGV;
    my %map;
    open(my $m, "<", $mapfile) or die "map: $!";
    while (<$m>) { chomp; my ($k, $v) = split /\t/, $_, 2; $map{$k} = $v if defined $v; }
    close $m;
    my @keys = sort { length($b) <=> length($a) or $a cmp $b } keys %map;
    exit 0 unless @keys;
    my $alt = join("|", map { quotemeta } @keys);
    my $edge = qr#(?=/|$|[\s)\]\x7d"\x27`,;:*<>|]|\.(?:\s|$))#m;
    my $re = qr#(?<![A-Za-z0-9._-])data/($alt)$edge#m;
    for my $file (@files) {
      open(my $in, "<:raw", $file) or next;
      local $/; my $text = <$in>; close $in;
      my $count = ($text =~ s{$re}{"data/" . $map{$1}}ge) || 0;
      print "$file\t$count\n";
      next unless $mode eq "write" && $count;
      my @st = stat $file;
      my $tmp = "$file.migrate.$$";
      open(my $out, ">:raw", $tmp) or die "write $tmp: $!";
      print {$out} $text; close $out or die "close $tmp: $!";
      chmod($st[2] & 07777, $tmp);
      rename($tmp, $file) or die "rename $tmp: $!";
    }
  ' "$REWRITE_MAP" "$mode" "$@"
}

# --- run --------------------------------------------------------------------

check_live
if [ "$REVERT" -eq 1 ]; then plan_revert; else plan_forward; fi
order_plan
[ -z "$PROJECT_FOLDERS" ] || echo "note: treating as project folders:$PROJECT_FOLDERS"

MOVES=0
while IFS=$'\t' read -r id src dst why; do
  [ -n "$id" ] || continue
  if [ "$REVERT" -eq 1 ]; then
    echo "revert: $id <- ${dst##*/} from ${src#"$DATA"/}"
  else
    echo "move: $id -> ${dst#"$DATA"/} ($why)"
  fi
  MOVES=$((MOVES + 1))
done < "$PLAN"

build_rewrite_map
REWRITE_FILES=()
for name in backlog.md done-archive.md note-archive.md; do
  [ -f "$DATA/$name" ] && [ ! -L "$DATA/$name" ] && REWRITE_FILES+=("$DATA/$name")
done

if [ "$BLOCKED" -eq 1 ]; then
  echo "summary: refused move=$MOVES blocked=1"
  exit 3
fi
if [ "$CONFLICTS" -gt 0 ]; then
  echo "summary: refused move=$MOVES conflicts=$CONFLICTS"
  exit 4
fi

# Rewrite the backlog's own records, or count the rewrites on a dry run. A
# failed rewrite stops the run before anything that follows it.
REWRITE_TOTAL=0
REWRITE_FILE_COUNT=0
rewrite_records() {
  local mode=count file count
  [ "${#REWRITE_FILES[@]}" -gt 0 ] || return 0
  [ "$APPLY" -eq 0 ] || mode="write"
  rewrite_links "$mode" "${REWRITE_FILES[@]}" > "$WORK/rewrites"
  while IFS=$'\t' read -r file count; do
    [ "${count:-0}" -gt 0 ] || continue
    echo "rewrite: ${file#"$DATA"/} $count reference(s)"
    REWRITE_TOTAL=$((REWRITE_TOTAL + count))
    REWRITE_FILE_COUNT=$((REWRITE_FILE_COUNT + 1))
  done < "$WORK/rewrites"
}

if [ "$APPLY" -eq 1 ] && { [ "$MOVES" -gt 0 ] || [ -s "$REWRITE_MAP" ]; }; then
  LOCKDIR="$STATE/.data-migrate.lock"
  mkdir -p "$STATE"
  fm_lock_try_acquire "$LOCKDIR" || { LOCKDIR=; echo "error: another data migration is running" >&2; exit 1; }
fi
# Forward rewrites after its moves and --revert before them, so a run stopped
# midway never leaves a link into a project folder its task already left: no
# repeat could find that link again, while every other mix of flat and
# canonical links and folders is finished by repeating either direction.
[ "$REVERT" -eq 0 ] || rewrite_records
if [ "$APPLY" -eq 1 ]; then
  while IFS=$'\t' read -r id src dst why; do
    [ -n "$id" ] || continue
    [ -d "$src" ] && [ ! -L "$src" ] || { echo "error: $src vanished before it could be moved" >&2; exit 1; }
    from=$src
    stage=
    if [ "${dst%/*}" -ef "$src" ] || [ "$dst" -ef "${src%/*}" ]; then
      stage=$(mktemp -d "$DATA/.layout-migration.XXXXXX")
      mv -- "$src" "$stage/$id"
      from="$stage/$id"
      if [ "$REVERT" -eq 1 ]; then
        rmdir "${src%/*}" || { echo "error: ${src%/*} is not empty; $id is parked at $from" >&2; exit 1; }
      fi
    fi
    [ ! -e "$dst" ] && [ ! -L "$dst" ] || { echo "error: $dst appeared before it could be moved" >&2; exit 1; }
    mkdir -p "$(dirname "$dst")"
    mv -- "$from" "$dst"
    [ -z "$stage" ] || rmdir "$stage"
    if [ "$REVERT" -eq 0 ]; then
      printf '%s\t%s\n' "$id" "$(basename "$(dirname "$dst")")" >> "$MANIFEST"
    else
      if [ -f "$MANIFEST" ]; then
        grep -Fxv -- "$id"$'\t'"$(basename "$(dirname "$src")")" "$MANIFEST" > "$MANIFEST.tmp" || true
        if [ -s "$MANIFEST.tmp" ]; then mv "$MANIFEST.tmp" "$MANIFEST"; else rm -f "$MANIFEST.tmp" "$MANIFEST"; fi
      fi
      [ -n "$stage" ] || rmdir "$(dirname "$src")" 2>/dev/null || true
    fi
  done < "$PLAN"
fi
[ "$REVERT" -eq 1 ] || rewrite_records

# Legacy links in files this command never edits: report, never rewrite. Fleet
# root files are named one by one; task documents are summarized.
if [ "$REVERT" -eq 0 ]; then
  OTHER=()
  for file in "$DATA"/*.md; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    case "${file##*/}" in backlog.md|done-archive.md|note-archive.md) continue ;; esac
    OTHER+=("$file")
  done
  if [ "${#OTHER[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r file count; do
      [ "${count:-0}" -gt 0 ] || continue
      echo "note: ${file#"$DATA"/} holds $count legacy data/<task-id>/ link(s) this command does not rewrite"
    done < <(rewrite_links count "${OTHER[@]}")
  fi
  DOCS=()
  while IFS= read -r task; do
    for file in "$task"/*.md; do
      [ -f "$file" ] && [ ! -L "$file" ] && DOCS+=("$file")
    done
  done < <(fm_task_data_task_dirs "$DATA")
  if [ "${#DOCS[@]}" -gt 0 ]; then
    DOC_LINKS=0
    DOC_FILES=0
    while IFS=$'\t' read -r file count; do
      [ "${count:-0}" -gt 0 ] || continue
      DOC_LINKS=$((DOC_LINKS + count))
      DOC_FILES=$((DOC_FILES + 1))
    done < <(rewrite_links count "${DOCS[@]}")
    [ "$DOC_LINKS" -eq 0 ] \
      || echo "note: $DOC_LINKS legacy data/<task-id>/ link(s) remain inside $DOC_FILES task document(s); they are history and are not rewritten"
  fi
fi

# Folders this run left flat: the ones it could not place.
REMAINING=0
[ "$REVERT" -eq 1 ] || REMAINING=$((UNRESOLVED + SKIPPED))
echo "summary: ${MODE%% *} move=$MOVES rewrite_files=$REWRITE_FILE_COUNT rewrite_refs=$REWRITE_TOTAL unresolved=$UNRESOLVED legacy_remaining=$REMAINING"
exit 0
