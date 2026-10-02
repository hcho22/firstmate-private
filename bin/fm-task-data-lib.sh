#!/usr/bin/env bash
# fm-task-data-lib.sh - the single owner of where a task's private documents live.
#
# Canonical layout (docs/configuration.md owns the operator-facing description):
#   data/<ProjectDir>/<task-id>/   briefs, reports, findings, evidence, review pages
# <ProjectDir> is the project's name, spelled as data/projects.md spells it when
# the project is registered; the firstmate repo is an ordinary project. Two
# reserved, underscore-prefixed folders hold work with no usable project name,
# so they can never collide with a project name:
#   _secondmates   persistent secondmate charter briefs
#   _unassigned    work with no project, or whose name cannot be a folder
# Fleet-wide files (backlog.md, projects.md, secondmates.md, captain.md,
# captain-shared.md, learnings.md, archives, charter.md) stay at the data/ root,
# as do the non-task root folders handoff/, extensions/ and remote-secondmates/.
#
# Every script that builds a per-task data path goes through this library:
#   fm_task_data_dir <data> <id>                 locate an existing task folder
#   fm_task_data_dir_for_new <data> <id> [<project>]
#                                                 where a new task folder belongs
#   fm_task_data_file <data> <id> <name>         <task folder>/<name> (folder must exist)
#   fm_task_data_relpath <data> <id>             "<ProjectDir>/<id>" (or legacy "<id>")
#   fm_task_data_project_dirname <data> [<project>]   the folder name for a project
#   fm_task_data_task_dirs <data>                every task folder, one per line
#
# LOOKUP FINDS, CREATION DECIDES. Lookup scans data/*/<id>, so a script that
# only needs an existing task's folder (spawn, promote, control, teardown, the
# fleet views) never has to re-derive the project and cannot disagree with the
# brief that created the folder. Only the creator maps a project to a folder
# name, through fm_task_data_dir_for_new.
#
# BOUNDED LEGACY READ. Before the layout change, folders lived flat at
# data/<id>/. Lookup still FINDS such a folder (and only when the canonical scan
# found nothing) so a home that has not yet run bin/fm-data-migrate.sh keeps
# working, but nothing ever CREATES a flat folder. A top-level folder is a flat
# task folder exactly when it carries a task marker file, and a project folder
# otherwise, so the two can never be confused. The legacy read exists in
# exactly one place, fm_task_data__legacy_dir, and is removable once every home
# has migrated (fm-data-migrate.sh reports `legacy_remaining=0`).
#
# Return codes of fm_task_data_dir: 0 found, 1 not found, 2 invalid id,
# 3 ambiguous (the id exists under more than one project folder; candidates on
# stderr). fm_task_data_dir_for_new adds 4 for an id in the reserved underscore
# space, or when the project's folder name is held by something that is not a
# project folder. An id may equal a project name: its folder sits inside a
# project folder, so the two never share a path.
#
# No side effects on source, and nothing here creates or removes a directory.
# set -u / set -e safe.

_FM_TASK_DATA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_TASK_DATA_LIB_DIR/fm-pr-lib.sh"

FM_TASK_DATA_SECONDMATES=_secondmates
FM_TASK_DATA_UNASSIGNED=_unassigned

# A legacy flat task folder holds at least one of these at its top level; a
# project folder never does, which is how the two are told apart.
FM_TASK_DATA_MARKERS="brief.md report.md launch-brief.md ship-instructions.md"

# Strip every trailing slash so a data directory spelled with several still
# yields one canonical path prefix.
fm_task_data__root() {  # <data>
  local data=${1-}
  while [ "${data%/}" != "$data" ] && [ "$data" != / ]; do data=${data%/}; done
  printf '%s\n' "$data"
}

# Root folders that are not project folders.
fm_task_data_root_reserved() {  # <name>
  case "${1-}" in
    handoff|extensions|remote-secondmates) return 0 ;;
  esac
  return 1
}

# A legacy task folder: a real directory carrying a task marker file.
fm_task_data_has_marker() {  # <dir>
  local dir=$1 marker
  for marker in $FM_TASK_DATA_MARKERS; do
    [ -f "$dir/$marker" ] && return 0
  done
  return 1
}

# A project folder: a real (non-symlink) directory that is not a root folder,
# not a dot folder, and not itself a legacy task folder.
fm_task_data_is_project_folder() {  # <data> <name>
  local data=$1 name=$2
  case "$name" in ''|.*) return 1 ;; esac
  fm_task_data_root_reserved "$name" && return 1
  [ -d "$data/$name" ] && [ ! -L "$data/$name" ] || return 1
  fm_task_data_has_marker "$data/$name" && return 1
  return 0
}

# Whether data/<name> may hold project task folders: nothing is there yet, or a
# project folder already is.
fm_task_data_project_folder_usable() {  # <data> <name>
  [ ! -e "$1/$2" ] && [ ! -L "$1/$2" ] && return 0
  fm_task_data_is_project_folder "$1" "$2"
}

# Print the registry spelling of a project name, matching case-insensitively.
fm_task_data_registered_name() {  # <data> <name>
  local data=$1 name=$2 found
  [ -f "$data/projects.md" ] || return 1
  found=$(awk -v n="$name" '
    $1 == "-" && tolower($2) == tolower(n) { print $2; exit }
  ' "$data/projects.md") || return 1
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_task_data__name_valid() {  # <name>
  local name=${1-} LC_ALL=C
  case "$name" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#name}" -le 64 ] || return 1
  fm_task_data_root_reserved "$name" && return 1
  return 0
}

# Print the folder name for a project argument (a name, projects/<Name>, or an
# absolute path; empty means no project). A differently-cased folder already on
# disk is adopted so a case-insensitive disk never holds two spellings.
fm_task_data_project_dirname() {  # <data> [<project>]
  local data=$1 project=${2-} name reg existing lower entry
  case "$project" in
    "$FM_TASK_DATA_SECONDMATES"|"$FM_TASK_DATA_UNASSIGNED")
      printf '%s\n' "$project"
      return 0 ;;
  esac
  project=${project%/}
  name=${project##*/}
  if [ -z "$name" ]; then
    printf '%s\n' "$FM_TASK_DATA_UNASSIGNED"
    return 0
  fi
  if reg=$(fm_task_data_registered_name "$data" "$name"); then
    name=$reg
  fi
  if ! fm_task_data__name_valid "$name"; then
    echo "warning: project '$name' cannot be a data folder name; filing under $FM_TASK_DATA_UNASSIGNED" >&2
    printf '%s\n' "$FM_TASK_DATA_UNASSIGNED"
    return 0
  fi
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  for entry in "$data"/*/; do
    entry=${entry%/}
    existing=${entry##*/}
    [ -d "$entry" ] || continue
    if [ "$(printf '%s' "$existing" | tr '[:upper:]' '[:lower:]')" = "$lower" ]; then
      fm_task_data_is_project_folder "$data" "$existing" || continue
      printf '%s\n' "$existing"
      return 0
    fi
  done
  printf '%s\n' "$name"
}

# The one place the pre-layout flat path is read. Prints data/<id> when it is a
# real directory, outside the reserved names, that carries a task marker.
fm_task_data__legacy_dir() {  # <data> <id>
  local data=$1 id=$2
  case "$id" in _*) return 1 ;; esac
  fm_task_data_root_reserved "$id" && return 1
  [ -d "$data/$id" ] && [ ! -L "$data/$id" ] || return 1
  fm_task_data_has_marker "$data/$id" || return 1
  printf '%s/%s\n' "$data" "$id"
}

fm_task_data_dir() {  # <data> <id>
  local data id=${2-} entry name found=() legacy
  data=$(fm_task_data__root "$1")
  fm_task_id_path_safe "$id" || return 2
  for entry in "$data"/*/; do
    entry=${entry%/}
    name=${entry##*/}
    fm_task_data_is_project_folder "$data" "$name" || continue
    [ -d "$entry/$id" ] && [ ! -L "$entry/$id" ] || continue
    found+=("$entry/$id")
  done
  case "${#found[@]}" in
    1) printf '%s\n' "${found[0]}"; return 0 ;;
    0) ;;
    *)
      echo "error: task $id exists under more than one project folder: ${found[*]}" >&2
      return 3 ;;
  esac
  if legacy=$(fm_task_data__legacy_dir "$data" "$id"); then
    printf '%s\n' "$legacy"
    return 0
  fi
  return 1
}

fm_task_data_dir_for_new() {  # <data> <id> [<project>]
  local data id=${2-} project=${3-} existing rc=0 dirname
  data=$(fm_task_data__root "$1")
  fm_task_id_creation_valid "$id" || return 2
  existing=$(fm_task_data_dir "$data" "$id") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$existing"; return 0 ;;
    1) ;;
    *) return "$rc" ;;
  esac
  case "$id" in _*) return 4 ;; esac
  dirname=$(fm_task_data_project_dirname "$data" "$project") || return 1
  if ! fm_task_data_project_folder_usable "$data" "$dirname"; then
    echo "error: data/$dirname exists but is not a project folder; migrate or move it before placing task $id there" >&2
    return 4
  fi
  printf '%s/%s/%s\n' "$data" "$dirname" "$id"
}

fm_task_data_file() {  # <data> <id> <name>
  local dir
  dir=$(fm_task_data_dir "$1" "$2") || return $?
  printf '%s/%s\n' "$dir" "$3"
}

fm_task_data_relpath() {  # <data> <id>
  local data dir
  data=$(fm_task_data__root "$1")
  dir=$(fm_task_data_dir "$data" "$2") || return $?
  printf '%s\n' "${dir#"$data"/}"
}

# Every task folder, one absolute path per line, in a stable order: folders
# under project folders first, then legacy flat folders still awaiting
# migration.
fm_task_data_task_dirs() {  # <data>
  local data entry name task
  data=$(fm_task_data__root "$1")
  for entry in "$data"/*/; do
    entry=${entry%/}
    name=${entry##*/}
    if fm_task_data_is_project_folder "$data" "$name"; then
      for task in "$entry"/*/; do
        task=${task%/}
        [ -d "$task" ] && [ ! -L "$task" ] || continue
        printf '%s\n' "$task"
      done
    fi
  done
  for entry in "$data"/*/; do
    entry=${entry%/}
    fm_task_data__legacy_dir "$data" "${entry##*/}" || continue
  done
}
