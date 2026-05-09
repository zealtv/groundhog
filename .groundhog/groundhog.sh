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
      daily, daily/09, daily/09-30,
      weekly, weekly/mon, weekly/mon/09, weekly/mon/09-30,
      monthly, monthly/1, monthly/15/09, monthly/15/09-30,
      yearly, yearly/03-15, yearly/03-15/09, yearly/03-15/09-30,
      once, once/2026-05-01, once/2026-05-01/09-30,
      every/15m, every/3h
  - time is optional and always the innermost axis: HH (00..23) or HH-MM
  - HH-MM is forbidden at yearly root (would collide with MM-DD shape)
  - every/ is sub-day interval recurrence anchored to 00:00; bucket is <N>m or <N>h
  - root items default to: weekly→Mon, monthly→1st, yearly→Jan 1, once→next tick
  - every/ has no default — a bucket like 15m or 3h is required
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

is_paused() { [[ "$1" == *.paused ]]; }

is_hh()  { [[ "$1" =~ ^([01][0-9]|2[0-3])$ ]]; }
is_hm()  { [[ "$1" =~ ^([01][0-9]|2[0-3])-[0-5][0-9]$ ]]; }
is_dow() { [[ "$1" =~ ^(mon|tue|wed|thu|fri|sat|sun)$ ]]; }
is_dom() { [[ "$1" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; }
is_md()  { [[ "$1" =~ ^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; }
is_ymd() { [[ "$1" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; }
# every/ bucket: <N>m or <N>h, N a positive integer with no leading zero.
is_interval() { [[ "$1" =~ ^[1-9][0-9]*[mh]$ ]]; }

# Selector → minutes-since-midnight. Nonzero exit means "not a time selector."
selector_minutes() {
  if is_hh "$1"; then echo $((10#$1 * 60)); return 0; fi
  if is_hm "$1"; then
    local hh="${1%-*}" mm="${1#*-}"
    echo $((10#$hh * 60 + 10#$mm))
    return 0
  fi
  return 1
}
# Yearly-root variant: HH-MM there would collide with MM-DD shape, so forbid it.
selector_minutes_hh_only() {
  is_hh "$1" || return 1
  echo $((10#$1 * 60))
}

is_id() {
  local v="$1"
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  case "$v" in
    daily|weekly|monthly|yearly|once|every) return 1 ;;
  esac
  is_hh "$v"  && return 1
  is_dow "$v" && return 1
  is_dom "$v" && return 1
  is_md "$v"  && return 1
  is_ymd "$v" && return 1
  is_interval "$v" && return 1
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
      is_hh "$hh" || is_hm "$hh" || die "expected HH or HH-MM in '$when'"
      ;;
    weekly/*)
      local rest="${when#weekly/}"
      local dow="${rest%%/*}"
      is_dow "$dow" || die "expected day-of-week mon..sun in '$when'"
      if [[ "$rest" == */* ]]; then
        local hh="${rest#*/}"
        [[ "$hh" != */* ]] || die "too many components in '$when'"
        is_hh "$hh" || is_hm "$hh" || die "expected HH or HH-MM in '$when'"
      fi
      ;;
    monthly/*)
      local rest="${when#monthly/}"
      local dom="${rest%%/*}"
      is_dom "$dom" || die "expected day-of-month 1..31 in '$when'"
      if [[ "$rest" == */* ]]; then
        local hh="${rest#*/}"
        [[ "$hh" != */* ]] || die "too many components in '$when'"
        is_hh "$hh" || is_hm "$hh" || die "expected HH or HH-MM in '$when'"
      fi
      ;;
    yearly/*)
      local rest="${when#yearly/}"
      local md="${rest%%/*}"
      is_md "$md" || die "expected month-day MM-DD in '$when'"
      if [[ "$rest" == */* ]]; then
        local hh="${rest#*/}"
        [[ "$hh" != */* ]] || die "too many components in '$when'"
        is_hh "$hh" || is_hm "$hh" || die "expected HH or HH-MM in '$when'"
      fi
      ;;
    once/*)
      local rest="${when#once/}"
      local ymd="${rest%%/*}"
      is_ymd "$ymd" || die "expected date YYYY-MM-DD in '$when'"
      if [[ "$rest" == */* ]]; then
        local hh="${rest#*/}"
        [[ "$hh" != */* ]] || die "too many components in '$when'"
        is_hh "$hh" || is_hm "$hh" || die "expected HH or HH-MM in '$when'"
      fi
      ;;
    every)
      die "every requires a bucket like every/15m or every/3h"
      ;;
    every/*)
      local rest="${when#every/}"
      local bucket="${rest%%/*}"
      [[ "$rest" != */* ]] || die "too many components in '$when'"
      is_interval "$bucket" || die "expected <N>m or <N>h in '$when'"
      ;;
    *)
      die "unknown axis in '$when' (expected daily, weekly, monthly, yearly, once, every)"
      ;;
  esac
}

now_today() { date +%Y-%m-%d; }
now_dow()   { date +%a | tr '[:upper:]' '[:lower:]'; }
now_dom()   { echo $((10#$(date +%d))); }
now_hh()    { echo $((10#$(date +%H))); }
now_mm()    { echo $((10#$(date +%M))); }
now_md()    { date +%m-%d; }

# Emits one tab-separated row per due item:
#   <item-name>\t<source-path>\t<is-once>\t<slot>
# <slot> is empty for calendar axes; for every/ it is the latest sub-day slot
# (HH-MM) at-or-before now. Per-slot keying lets fired/ track each slot.
walk_due() {
  shopt -s nullglob
  local now_t now_d now_dom_v now_hh_v now_mm_v now_md_v now_min_total
  now_t="$(now_today)"
  now_d="$(now_dow)"
  now_dom_v="$(now_dom)"
  now_hh_v="$(now_hh)"
  now_mm_v="$(now_mm)"
  now_md_v="$(now_md)"
  now_min_total=$(( now_hh_v * 60 + now_mm_v ))

  # Walks <parent>/* where children are either <time>/<item>/ or <item>/.
  # `time_fn` decides what counts as a time selector and yields minutes-since-midnight
  # (selector_minutes everywhere except yearly root, which uses selector_minutes_hh_only).
  emit_with_optional_time() {
    local parent="$1"
    local time_fn="$2"
    local is_once="$3"
    [[ -d "$parent" ]] || return 0
    local entry name mins
    for entry in "$parent"/*; do
      [[ -d "$entry" ]] || continue
      name="$(basename "$entry")"
      is_paused "$name" && continue
      if mins=$("$time_fn" "$name"); then
        (( now_min_total >= mins )) || continue
        local sub sub_name
        for sub in "$entry"/*; do
          [[ -d "$sub" ]] || continue
          sub_name="$(basename "$sub")"
          is_paused "$sub_name" && continue
          printf '%s\t%s\t%s\n' "$sub_name" "$sub" "$is_once"
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
    local time_fn="$3"
    local is_once="$4"
    [[ -d "$parent" ]] || return 0
    local entry name mins
    for entry in "$parent"/*; do
      [[ -d "$entry" ]] || continue
      name="$(basename "$entry")"
      is_paused "$name" && continue
      "$sub_check" "$name" && continue
      if mins=$("$time_fn" "$name"); then
        (( now_min_total >= mins )) || continue
        local sub sub_name
        for sub in "$entry"/*; do
          [[ -d "$sub" ]] || continue
          sub_name="$(basename "$sub")"
          is_paused "$sub_name" && continue
          printf '%s\t%s\t%s\n' "$sub_name" "$sub" "$is_once"
        done
      else
        printf '%s\t%s\t%s\n' "$name" "$entry" "$is_once"
      fi
    done
  }

  # every/<N>{m,h}/<item>/ — interval recurrence anchored to 00:00 local.
  # Pick only the latest slot at-or-before now: missed earlier slots are gone
  # (recurrence beats fidelity), and the per-slot fired marker prevents refire
  # within the same slot. Each slot gets a distinct out/ name and fired/ entry.
  emit_every() {
    [[ -d "$SCHED/every" ]] || return 0
    local bucket bucket_name n unit step item item_name slot_min slot_str
    for bucket in "$SCHED/every"/*; do
      [[ -d "$bucket" ]] || continue
      bucket_name="$(basename "$bucket")"
      is_paused "$bucket_name" && continue
      is_interval "$bucket_name" || continue   # lint flags; walker skips
      n="${bucket_name%[mh]}"
      unit="${bucket_name: -1}"
      if [[ "$unit" == "m" ]]; then step=$((10#$n)); else step=$((10#$n * 60)); fi
      (( step > 0 )) || continue
      slot_min=$(( (now_min_total / step) * step ))
      printf -v slot_str '%02d-%02d' $((slot_min/60)) $((slot_min%60))
      for item in "$bucket"/*; do
        [[ -d "$item" ]] || continue
        item_name="$(basename "$item")"
        is_paused "$item_name" && continue
        printf '%s\t%s\t%s\t%s\n' "$item_name" "$item" "0" "$slot_str"
      done
    done
  }

  # Past one-shots fire regardless of inner time — the day is already gone.
  emit_past_once() {
    local parent="$1" entry name sub sub_name
    for entry in "$parent"/*; do
      [[ -d "$entry" ]] || continue
      name="$(basename "$entry")"
      is_paused "$name" && continue
      if is_hh "$name" || is_hm "$name"; then
        for sub in "$entry"/*; do
          [[ -d "$sub" ]] || continue
          sub_name="$(basename "$sub")"
          is_paused "$sub_name" && continue
          printf '%s\t%s\t1\n' "$sub_name" "$sub"
        done
      else
        printf '%s\t%s\t1\n' "$name" "$entry"
      fi
    done
  }

  # daily: every day
  emit_with_optional_time "$SCHED/daily" selector_minutes 0

  # weekly: explicit dow + Monday default at root
  emit_with_optional_time "$SCHED/weekly/$now_d" selector_minutes 0
  [[ "$now_d" == "mon" ]] && emit_axis_root "$SCHED/weekly" is_dow selector_minutes 0

  # monthly: explicit dom + 1st default at root
  emit_with_optional_time "$SCHED/monthly/$now_dom_v" selector_minutes 0
  [[ "$now_dom_v" == "1" ]] && emit_axis_root "$SCHED/monthly" is_dom selector_minutes 0

  # yearly: explicit MM-DD + Jan 1 default at root.
  # At yearly root, HH-MM would collide with MM-DD shape, so root accepts HH only.
  emit_with_optional_time "$SCHED/yearly/$now_md_v" selector_minutes 0
  [[ "$now_md_v" == "01-01" ]] && emit_axis_root "$SCHED/yearly" is_md selector_minutes_hh_only 0

  # once: explicit YYYY-MM-DD on/before today + next-tick default at root
  if [[ -d "$SCHED/once" ]]; then
    local date_dir d
    for date_dir in "$SCHED/once"/*; do
      [[ -d "$date_dir" ]] || continue
      d="$(basename "$date_dir")"
      is_paused "$d" && continue
      is_ymd "$d" || continue
      if [[ "$d" > "$now_t" ]]; then
        continue
      elif [[ "$d" == "$now_t" ]]; then
        emit_with_optional_time "$date_dir" selector_minutes 1
      else
        emit_past_once "$date_dir"
      fi
    done
  fi
  emit_axis_root "$SCHED/once" is_ymd selector_minutes 1

  # every: sub-day intervals
  emit_every

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
  local src="$1" now_t="$2" slot="${3:-}"
  local rel="${src#"$SCHED"/}"
  if [[ -n "$slot" ]]; then
    printf '%s/%s/%s/%s\n' "$FIRED" "$now_t" "$rel" "$slot"
  else
    printf '%s/%s/%s\n' "$FIRED" "$now_t" "$rel"
  fi
}

cmd_due() {
  require_root
  ensure_dirs
  local now_t
  now_t="$(now_today)"
  local name src is_once slot marker
  while IFS=$'\t' read -r name src is_once slot; do
    [[ -n "$name" ]] || continue
    marker="$(fired_marker_for "$src" "$now_t" "$slot")"
    [[ -e "$marker" ]] && continue
    printf '%s\n' "$src"
  done < <(walk_due)
}

cmd_tick() {
  require_root
  ensure_dirs
  local now_t
  now_t="$(now_today)"
  local name src is_once slot dst tmp date_dir marker
  while IFS=$'\t' read -r name src is_once slot; do
    [[ -n "$name" ]] || continue
    if [[ -n "$slot" ]]; then
      dst="$OUT/${name}-${now_t}-${slot}"
    else
      dst="$OUT/${name}-${now_t}"
    fi
    marker="$(fired_marker_for "$src" "$now_t" "$slot")"
    if [[ -e "$marker" ]]; then
      :  # journal says this already fired today — leave it alone
    elif [[ -e "$dst" ]]; then
      printf 'warning: %s already exists in out/; recording firing without overwrite\n' "$(basename "$dst")" >&2
      mkdir -p "$(dirname "$marker")"
      touch "$marker"
    else
      tmp="${dst}.landing"
      [[ -e "$tmp" ]] && rm -rf -- "$tmp"
      cp -R -- "$src" "$tmp"
      mv -- "$tmp" "$dst"
      mkdir -p "$(dirname "$marker")"
      touch "$marker"
      printf 'fired %s -> %s\n' "$name" "$dst"
    fi
    if [[ "$is_once" == "1" ]]; then
      rm -rf -- "$src"
      # Walk up removing now-empty schedule dirs (e.g. <date>/<HH-MM>/, then <date>/),
      # but never the once axis root itself.
      local parent
      parent="$(dirname "$src")"
      while [[ "$parent" != "$SCHED/once" && "$parent" == "$SCHED/once/"* ]]; do
        rmdir "$parent" 2>/dev/null || break
        parent="$(dirname "$parent")"
      done
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
    local name branch child_prefix tag display
    name="$(basename "$entry")"
    if (( i == count )); then
      branch="└──"; child_prefix="    "
    else
      branch="├──"; child_prefix="│   "
    fi
    if is_paused "$name"; then
      display="${name%.paused}"
      tag=" [paused]"
    else
      display="$name"
      tag=""
    fi
    printf '%s%s %s%s\n' "$prefix" "$branch" "$display" "$tag"
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
    is_paused "$name" && continue

    case "$state" in
      axis-daily)
        if   is_hh "$name" || is_hm "$name"; then lint_walk "$entry" "item-only"
        elif is_id "$name"; then : # item; opaque below
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-weekly)
        if   is_dow "$name"; then lint_walk "$entry" "weekly-dow"
        elif is_hh  "$name" || is_hm "$name"; then lint_walk "$entry" "item-only"
        elif is_id  "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-monthly)
        if   is_dom "$name"; then lint_walk "$entry" "param-with-hour-or-item"
        elif is_hh  "$name" || is_hm "$name"; then lint_walk "$entry" "item-only"
        elif is_id  "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-yearly)
        # HH-MM forbidden at yearly root — would collide with MM-DD shape.
        if   is_md "$name"; then lint_walk "$entry" "param-with-hour-or-item"
        elif is_hh "$name"; then lint_walk "$entry" "item-only"
        elif is_id "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-once)
        if   is_ymd "$name"; then lint_walk "$entry" "param-with-hour-or-item"
        elif is_hh  "$name" || is_hm "$name"; then lint_walk "$entry" "item-only"
        elif is_id  "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-every)
        # every/ requires a bucket; bare items at axis root are orphans.
        if   is_interval "$name"; then lint_walk "$entry" "every-bucket"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      every-bucket)
        if is_id "$name"; then :
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      weekly-dow|param-with-hour-or-item)
        if   is_hh "$name" || is_hm "$name"; then lint_walk "$entry" "item-only"
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
    is_paused "$name" && continue
    case "$name" in
      daily)   lint_walk "$axis_dir" "axis-daily"   ;;
      weekly)  lint_walk "$axis_dir" "axis-weekly"  ;;
      monthly) lint_walk "$axis_dir" "axis-monthly" ;;
      yearly)  lint_walk "$axis_dir" "axis-yearly"  ;;
      once)    lint_walk "$axis_dir" "axis-once"    ;;
      every)   lint_walk "$axis_dir" "axis-every"   ;;
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
  done < <(find "$SCHED" -type d \( -name "$id" -o -name "$id.paused" \))
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
