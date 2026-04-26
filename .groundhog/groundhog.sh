#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage:
  groundhog.sh init
  groundhog.sh add <when> <item-id>
  groundhog.sh tick
  groundhog.sh due
  groundhog.sh list
  groundhog.sh lint
  groundhog.sh drop <item-id>
  groundhog.sh out
  groundhog.sh sweep [days]

notes:
  - this script operates on the .groundhog/ directory beside it
  - <when> is the schedule path under schedule/:
      daily, daily/09,
      weekly, weekly/mon, weekly/mon/09,
      monthly, monthly/1, monthly/15/09,
      yearly, yearly/03-15, yearly/03-15/09,
      once, once/2026-05-01
  - hour is optional and always the innermost axis (00..23)
  - root items default to: weekly→Mon, monthly→1st, yearly→Jan 1, once→next tick
  - item contents are opaque to groundhog
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

resolve_paths() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ "$(basename "$script_dir")" == ".groundhog" ]] || die "groundhog.sh must live inside a .groundhog/ directory"
  GH_DIR="$script_dir"
  SCHED="$GH_DIR/schedule"
  OUT="$GH_DIR/out"
  FIRED="$GH_DIR/fired"
}

require_root() {
  resolve_paths
}

ensure_dirs() {
  mkdir -p "$SCHED" "$OUT" "$FIRED"
}

is_hh()  { [[ "$1" =~ ^([01][0-9]|2[0-3])$ ]]; }
is_dow() { [[ "$1" =~ ^(mon|tue|wed|thu|fri|sat|sun)$ ]]; }
is_dom() { [[ "$1" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; }
is_md()  { [[ "$1" =~ ^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; }
is_ymd() { [[ "$1" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; }

is_id() {
  local v="$1"
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  case "$v" in
    daily|weekly|monthly|yearly|once) return 1 ;;
  esac
  is_hh "$v"  && return 1
  is_dow "$v" && return 1
  is_dom "$v" && return 1
  is_md "$v"  && return 1
  is_ymd "$v" && return 1
  # Reject pure-numeric and dash-numeric shapes — these are
  # indistinguishable from typo'd axis params (`monthly/99`, `yearly/13-45`).
  [[ "$v" =~ ^[0-9]+$ ]] && return 1
  [[ "$v" =~ ^[0-9]+-[0-9]+$ ]] && return 1
  return 0
}

validate_when() {
  local when="$1"
  case "$when" in
    daily|weekly|monthly|yearly|once)
      ;;
    daily/*)
      local hh="${when#daily/}"
      [[ "$hh" != */* ]] || die "too many components in '$when'"
      is_hh "$hh" || die "expected hour 00..23 in '$when'"
      ;;
    weekly/*)
      local rest="${when#weekly/}"
      local dow="${rest%%/*}"
      is_dow "$dow" || die "expected day-of-week mon..sun in '$when'"
      if [[ "$rest" == */* ]]; then
        local hh="${rest#*/}"
        [[ "$hh" != */* ]] || die "too many components in '$when'"
        is_hh "$hh" || die "expected hour 00..23 in '$when'"
      fi
      ;;
    monthly/*)
      local rest="${when#monthly/}"
      local dom="${rest%%/*}"
      is_dom "$dom" || die "expected day-of-month 1..31 in '$when'"
      if [[ "$rest" == */* ]]; then
        local hh="${rest#*/}"
        [[ "$hh" != */* ]] || die "too many components in '$when'"
        is_hh "$hh" || die "expected hour 00..23 in '$when'"
      fi
      ;;
    yearly/*)
      local rest="${when#yearly/}"
      local md="${rest%%/*}"
      is_md "$md" || die "expected month-day MM-DD in '$when'"
      if [[ "$rest" == */* ]]; then
        local hh="${rest#*/}"
        [[ "$hh" != */* ]] || die "too many components in '$when'"
        is_hh "$hh" || die "expected hour 00..23 in '$when'"
      fi
      ;;
    once/*)
      local ymd="${when#once/}"
      [[ "$ymd" != */* ]] || die "too many components in '$when'"
      is_ymd "$ymd" || die "expected date YYYY-MM-DD in '$when'"
      ;;
    *)
      die "unknown axis in '$when' (expected daily, weekly, monthly, yearly, once)"
      ;;
  esac
}

now_today() { date +%Y-%m-%d; }
now_dow()   { date +%a | tr '[:upper:]' '[:lower:]'; }
now_dom()   { echo $((10#$(date +%d))); }
now_hh()    { echo $((10#$(date +%H))); }
now_md()    { date +%m-%d; }

# Emits one tab-separated row per due item:
#   <item-name>\t<source-path>\t<is-once>
walk_due() {
  shopt -s nullglob
  local now_t now_d now_dom_v now_hh_v now_md_v
  now_t="$(now_today)"
  now_d="$(now_dow)"
  now_dom_v="$(now_dom)"
  now_hh_v="$(now_hh)"
  now_md_v="$(now_md)"

  # Walks <parent>/* where children are either <HH>/<item>/ or <item>/.
  # Used both for explicit sub-axis dirs (weekly/mon, monthly/15, …)
  # and — via emit_axis_root — for the root of an axis after filtering
  # out the sub-axis selectors.
  emit_with_optional_hour() {
    local parent="$1"
    local is_once="$2"
    [[ -d "$parent" ]] || return 0
    local entry name
    for entry in "$parent"/*; do
      [[ -d "$entry" ]] || continue
      name="$(basename "$entry")"
      if is_hh "$name"; then
        local hh=$((10#$name))
        (( now_hh_v >= hh )) || continue
        local sub
        for sub in "$entry"/*; do
          [[ -d "$sub" ]] || continue
          printf '%s\t%s\t%s\n' "$(basename "$sub")" "$sub" "$is_once"
        done
      else
        printf '%s\t%s\t%s\n' "$name" "$entry" "$is_once"
      fi
    done
  }

  # Items at the root of an axis (weekly/<item>, once/<item>, …) belong
  # to the default sub-axis. Skip any name that looks like a sub-axis
  # selector — those are handled by the explicit emit above.
  emit_axis_root() {
    local parent="$1"
    local sub_check="$2"
    local is_once="$3"
    [[ -d "$parent" ]] || return 0
    local entry name
    for entry in "$parent"/*; do
      [[ -d "$entry" ]] || continue
      name="$(basename "$entry")"
      "$sub_check" "$name" && continue
      if is_hh "$name"; then
        local hh=$((10#$name))
        (( now_hh_v >= hh )) || continue
        local sub
        for sub in "$entry"/*; do
          [[ -d "$sub" ]] || continue
          printf '%s\t%s\t%s\n' "$(basename "$sub")" "$sub" "$is_once"
        done
      else
        printf '%s\t%s\t%s\n' "$name" "$entry" "$is_once"
      fi
    done
  }

  # daily: every day
  emit_with_optional_hour "$SCHED/daily" 0

  # weekly: explicit dow + Monday default at root
  emit_with_optional_hour "$SCHED/weekly/$now_d" 0
  [[ "$now_d" == "mon" ]] && emit_axis_root "$SCHED/weekly" is_dow 0

  # monthly: explicit dom + 1st default at root
  emit_with_optional_hour "$SCHED/monthly/$now_dom_v" 0
  [[ "$now_dom_v" == "1" ]] && emit_axis_root "$SCHED/monthly" is_dom 0

  # yearly: explicit MM-DD + Jan 1 default at root
  emit_with_optional_hour "$SCHED/yearly/$now_md_v" 0
  [[ "$now_md_v" == "01-01" ]] && emit_axis_root "$SCHED/yearly" is_md 0

  # once: explicit YYYY-MM-DD on/before today + next-tick default at root
  if [[ -d "$SCHED/once" ]]; then
    local date_dir entry d
    for date_dir in "$SCHED/once"/*; do
      [[ -d "$date_dir" ]] || continue
      d="$(basename "$date_dir")"
      is_ymd "$d" || continue
      [[ "$d" > "$now_t" ]] && continue
      for entry in "$date_dir"/*; do
        [[ -d "$entry" ]] || continue
        printf '%s\t%s\t1\n' "$(basename "$entry")" "$entry"
      done
    done
  fi
  emit_axis_root "$SCHED/once" is_ymd 1

  shopt -u nullglob
}

cmd_init() {
  resolve_paths
  ensure_dirs
  echo "initialized $GH_DIR"
}

cmd_add() {
  require_root
  ensure_dirs
  local when="${1:-}"
  local id="${2:-}"
  [[ -n "$when" ]] || die "add requires <when> and <item-id>"
  [[ -n "$id" ]]   || die "add requires <item-id>"
  when="${when%/}"
  validate_when "$when"
  is_id "$id" || die "invalid item id '$id' (use letters, digits, ., _, -; cannot collide with axis tokens or date/hour shapes)"
  local path="$SCHED/$when/$id"
  [[ ! -e "$path" ]] || die "item already exists: $path"
  mkdir -p "$path"
  echo "$path"
}

# Translate a source schedule path into its fired-marker path.
# The marker mirrors the schedule subtree, so two distinct items
# with the same name (e.g. weekly/sat/foo and monthly/25/foo) get
# distinct markers and neither is silently swallowed.
fired_marker_for() {
  local src="$1" now_t="$2"
  local rel="${src#"$SCHED"/}"
  printf '%s/%s/%s\n' "$FIRED" "$now_t" "$rel"
}

cmd_due() {
  require_root
  ensure_dirs
  local now_t
  now_t="$(now_today)"
  local name src is_once marker
  while IFS=$'\t' read -r name src is_once; do
    [[ -n "$name" ]] || continue
    marker="$(fired_marker_for "$src" "$now_t")"
    [[ -e "$marker" ]] && continue
    printf '%s\n' "$src"
  done < <(walk_due)
}

cmd_tick() {
  require_root
  ensure_dirs
  local now_t
  now_t="$(now_today)"
  local name src is_once dst tmp date_dir marker
  while IFS=$'\t' read -r name src is_once; do
    [[ -n "$name" ]] || continue
    dst="$OUT/${name}-${now_t}"
    marker="$(fired_marker_for "$src" "$now_t")"
    if [[ -e "$marker" ]]; then
      :  # journal says this already fired today — leave it alone
    elif [[ -e "$dst" ]]; then
      printf 'warning: %s already exists in out/; recording firing without overwrite\n' "$(basename "$dst")" >&2
      mkdir -p "$(dirname "$marker")"
      touch "$marker"
    else
      tmp="$OUT/${name}-${now_t}.landing"
      [[ -e "$tmp" ]] && rm -rf -- "$tmp"
      cp -R -- "$src" "$tmp"
      mv -- "$tmp" "$dst"
      mkdir -p "$(dirname "$marker")"
      touch "$marker"
      printf 'fired %s -> %s\n' "$name" "$dst"
    fi
    if [[ "$is_once" == "1" ]]; then
      rm -rf -- "$src"
      date_dir="$(dirname "$src")"
      if [[ "$date_dir" != "$SCHED/once" ]]; then
        rmdir "$date_dir" 2>/dev/null || true
      fi
    fi
  done < <(walk_due)
}

print_tree() {
  local dir="$1"
  local prefix="$2"
  local entries=() entry
  shopt -s nullglob
  for entry in "$dir"/*; do
    [[ -d "$entry" ]] || continue
    entries+=("$entry")
  done
  shopt -u nullglob
  local count="${#entries[@]}" i=0
  for entry in "${entries[@]}"; do
    i=$((i + 1))
    local name branch child_prefix
    name="$(basename "$entry")"
    if (( i == count )); then
      branch="└──"; child_prefix="    "
    else
      branch="├──"; child_prefix="│   "
    fi
    printf '%s%s %s\n' "$prefix" "$branch" "$name"
    print_tree "$entry" "$prefix$child_prefix"
  done
}

cmd_list() {
  require_root
  ensure_dirs
  if find "$SCHED" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    print_tree "$SCHED" ""
  else
    echo "(no items scheduled)"
  fi
}

# Walk the schedule tree and report directories that walk_due will
# never reach — orphans from typos, manual mkdirs, or invalid paths.
# The "state" arg is the small grammar machine: at each position we
# know which dir-name shapes are valid; anything else is an orphan.
# When we hit a valid item-id, we stop descending (item contents are opaque).
LINT_ORPHANS=()

lint_walk() {
  local dir="$1"
  local state="$2"
  local entry name
  shopt -s nullglob
  for entry in "$dir"/*; do
    [[ -d "$entry" ]] || continue
    name="$(basename "$entry")"

    case "$state" in
      axis-daily)
        if   is_hh "$name"; then lint_walk "$entry" "item-only"
        elif is_id "$name"; then : # item; opaque below
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-weekly)
        if   is_dow "$name"; then lint_walk "$entry" "weekly-dow"
        elif is_hh  "$name"; then lint_walk "$entry" "item-only"
        elif is_id  "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-monthly)
        if   is_dom "$name"; then lint_walk "$entry" "param-with-hour-or-item"
        elif is_hh  "$name"; then lint_walk "$entry" "item-only"
        elif is_id  "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-yearly)
        if   is_md "$name"; then lint_walk "$entry" "param-with-hour-or-item"
        elif is_hh "$name"; then lint_walk "$entry" "item-only"
        elif is_id "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-once)
        # once supports YYYY-MM-DD or root-with-optional-HH; no HH below a date
        if   is_ymd "$name"; then lint_walk "$entry" "item-only"
        elif is_hh  "$name"; then lint_walk "$entry" "item-only"
        elif is_id  "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      weekly-dow|param-with-hour-or-item)
        if   is_hh "$name"; then lint_walk "$entry" "item-only"
        elif is_id "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      item-only)
        if is_id "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
    esac
  done
  shopt -u nullglob
}

cmd_lint() {
  require_root
  LINT_ORPHANS=()
  local axis_dir name
  shopt -s nullglob
  for axis_dir in "$SCHED"/*; do
    [[ -d "$axis_dir" ]] || continue
    name="$(basename "$axis_dir")"
    case "$name" in
      daily)   lint_walk "$axis_dir" "axis-daily"   ;;
      weekly)  lint_walk "$axis_dir" "axis-weekly"  ;;
      monthly) lint_walk "$axis_dir" "axis-monthly" ;;
      yearly)  lint_walk "$axis_dir" "axis-yearly"  ;;
      once)    lint_walk "$axis_dir" "axis-once"    ;;
      *)       LINT_ORPHANS+=("$axis_dir") ;;
    esac
  done
  shopt -u nullglob

  if (( ${#LINT_ORPHANS[@]} == 0 )); then
    echo "schedule is clean"
    return 0
  fi
  printf 'orphan: %s\n' "${LINT_ORPHANS[@]}"
  echo "${#LINT_ORPHANS[@]} orphan(s) found — these paths will not fire" >&2
  return 1
}

cmd_drop() {
  require_root
  ensure_dirs
  local id="${1:-}"
  [[ -n "$id" ]] || die "drop requires <item-id>"
  is_id "$id" || die "invalid item id '$id'"
  local matches=() p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    matches+=("$p")
  done < <(find "$SCHED" -type d -name "$id")
  if (( ${#matches[@]} == 0 )); then
    die "item '$id' not found under schedule/"
  fi
  if (( ${#matches[@]} > 1 )); then
    printf '%s\n' "${matches[@]}" >&2
    die "multiple items found for '$id'"
  fi
  rm -rf -- "${matches[0]}"
  echo "dropped $id"
}

cmd_out() {
  require_root
  ensure_dirs
  local entry name
  shopt -s nullglob
  for entry in "$OUT"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    [[ "$name" == *.landing ]] && continue
    printf '%s\n' "$name"
  done
  shopt -u nullglob
}

sweep_dir() {
  local dir="$1" kind="$2" days="$3"
  [[ -d "$dir" ]] || return 0
  local entry name
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="$(basename "$entry")"
    rm -rf -- "$entry"
    printf 'swept %s %s\n' "$kind" "$name"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" | sort)
}

cmd_sweep() {
  require_root
  ensure_dirs
  local days="${1:-14}"
  [[ "$days" =~ ^[0-9]+$ ]] || die "sweep <days> must be a non-negative integer"
  sweep_dir "$OUT" out "$days"
  sweep_dir "$FIRED" fired "$days"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    init)  shift; cmd_init  "$@" ;;
    add)   shift; cmd_add   "$@" ;;
    tick)  shift; cmd_tick  "$@" ;;
    due)   shift; cmd_due   "$@" ;;
    list)  shift; cmd_list  "$@" ;;
    lint)  shift; cmd_lint  "$@" ;;
    drop)  shift; cmd_drop  "$@" ;;
    out)   shift; cmd_out   "$@" ;;
    sweep) shift; cmd_sweep "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

main "$@"
