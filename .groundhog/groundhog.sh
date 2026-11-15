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
  groundhog.sh capabilities --json
  groundhog.sh status --json

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
  - capabilities and status are strictly read-only and print one JSON object;
    see README.md and docs/runtime-contract.md
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Exit status when the script is not inside a .groundhog/ directory: 1 for the
# legacy commands; the JSON commands set 2 (invalid configuration).
GH_BAD_INSTALL_EXIT=1

resolve_paths() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ "$(basename "$script_dir")" != ".groundhog" ]]; then
    echo "error: groundhog.sh must live inside a .groundhog/ directory" >&2
    exit "$GH_BAD_INSTALL_EXIT"
  fi
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
  # ${arr[@]+...}: an empty array is "unbound" to bash 3.2 under set -u.
  for entry in ${entries[@]+"${entries[@]}"}; do
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
#
# The same grammar serves `status --json`. Two globals widen the walk:
#   LINT_INCLUDE_PAUSED=1  descend into .paused components (matching their
#                          names with the suffix stripped) instead of skipping
#   LINT_ITEMS / LINT_ITEM_PAUSED  every recognized item directory, and the
#                          paused components above it (US-separated)
# `lint` leaves LINT_INCLUDE_PAUSED at 0, so its behavior is unchanged.
LINT_ORPHANS=()
LINT_ITEMS=()
LINT_ITEM_PAUSED=()
LINT_INCLUDE_PAUSED=0

lint_walk() {
  local dir="$1"
  local state="$2"
  local paused_by="${3:-}"
  local entry name eff paused_now
  shopt -s nullglob
  for entry in "$dir"/*; do
    [[ -d "$entry" ]] || continue
    name="$(basename "$entry")"
    eff="$name"
    paused_now="$paused_by"
    if is_paused "$name"; then
      (( LINT_INCLUDE_PAUSED )) || continue
      eff="${name%.paused}"
      paused_now="${paused_now:+$paused_now$'\x1f'}$entry"
    fi

    case "$state" in
      axis-daily)
        if   is_hh "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now"
        elif is_id "$eff"; then lint_item "$entry" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-weekly)
        if   is_dow "$eff"; then lint_walk "$entry" "weekly-dow" "$paused_now"
        elif is_hh  "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now"
        elif is_id  "$eff"; then lint_item "$entry" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-monthly)
        if   is_dom "$eff"; then lint_walk "$entry" "param-with-hour-or-item" "$paused_now"
        elif is_hh  "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now"
        elif is_id  "$eff"; then lint_item "$entry" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-yearly)
        # HH-MM forbidden at yearly root — would collide with MM-DD shape.
        if   is_md "$eff"; then lint_walk "$entry" "param-with-hour-or-item" "$paused_now"
        elif is_hh "$eff"; then lint_walk "$entry" "item-only" "$paused_now"
        elif is_id "$eff"; then lint_item "$entry" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-once)
        if   is_ymd "$eff"; then lint_walk "$entry" "param-with-hour-or-item" "$paused_now"
        elif is_hh  "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now"
        elif is_id  "$eff"; then lint_item "$entry" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-every)
        # every/ requires a bucket; bare items at axis root are orphans.
        if   is_interval "$eff"; then lint_walk "$entry" "every-bucket" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      every-bucket)
        if is_id "$eff"; then lint_item "$entry" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      weekly-dow|param-with-hour-or-item)
        if   is_hh "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now"
        elif is_id "$eff"; then lint_item "$entry" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      item-only)
        if is_id "$eff"; then lint_item "$entry" "$paused_now"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
    esac
  done
  shopt -u nullglob
}

# A recognized item: remember it (and what pauses it); never look inside.
lint_item() {
  LINT_ITEMS+=("$1")
  LINT_ITEM_PAUSED+=("$2")
}

# Fill LINT_ORPHANS / LINT_ITEMS / LINT_ITEM_PAUSED from schedule/.
# Read-only: a missing schedule/ simply yields empty lists.
lint_scan() {
  LINT_ORPHANS=()
  LINT_ITEMS=()
  LINT_ITEM_PAUSED=()
  local axis_dir name eff paused_now
  shopt -s nullglob
  for axis_dir in "$SCHED"/*; do
    [[ -d "$axis_dir" ]] || continue
    name="$(basename "$axis_dir")"
    eff="$name"
    paused_now=""
    if is_paused "$name"; then
      (( LINT_INCLUDE_PAUSED )) || continue
      eff="${name%.paused}"
      paused_now="$axis_dir"
    fi
    case "$eff" in
      daily)   lint_walk "$axis_dir" "axis-daily"   "$paused_now" ;;
      weekly)  lint_walk "$axis_dir" "axis-weekly"  "$paused_now" ;;
      monthly) lint_walk "$axis_dir" "axis-monthly" "$paused_now" ;;
      yearly)  lint_walk "$axis_dir" "axis-yearly"  "$paused_now" ;;
      once)    lint_walk "$axis_dir" "axis-once"    "$paused_now" ;;
      every)   lint_walk "$axis_dir" "axis-every"   "$paused_now" ;;
      *)       LINT_ORPHANS+=("$axis_dir") ;;
    esac
  done
  shopt -u nullglob
}

cmd_lint() {
  require_root
  LINT_INCLUDE_PAUSED=0
  lint_scan

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

# ---------------------------------------------------------------------------
# Read-only inspection: `capabilities --json` and `status --json`.
#
# Nothing below may create, repair, lock, tick or rewrite anything, and
# nothing may read the contents of a payload. It only stats directory names
# (the schedule grammar, via lint_scan and walk_due), reads the small optional
# files under runtime/, and prints one JSON object. No jq, python or perl:
# JSON is written and parsed by the small helpers here, which also run under
# macOS's stock bash 3.2 (no associative arrays, mapfile or ${var,,}).
# ---------------------------------------------------------------------------

GH_PROTOCOL="groundhog-runtime"
GH_PROTOCOL_VERSION=1
# Informational only; clients must not branch on it.
GH_IMPLEMENTATION_VERSION="dev"
# Advertise only what this script implements. Each later runtime stitch adds
# its own capability names here when (and only when) the commands exist.
GH_CAPABILITIES=("status-json-v1")

US=$'\x1f'          # separator inside parsed-JSON keys and path lists
JSON_LOSSY=0        # set when json_str had to replace bytes that are not UTF-8
JSTR=""
JR=""

# json_str VALUE — sets JSTR to VALUE as a quoted JSON string. Quotes,
# backslashes and control characters are escaped; valid UTF-8 passes through;
# bytes that are not valid UTF-8 become U+FFFD (and JSON_LOSSY is set).
json_str() {
  local LC_ALL=C
  local s="$1"
  if [[ "$s" != *[^\ -~]* && "$s" != *[\"\\]* ]]; then
    JSTR="\"$s\""
    return 0
  fi
  local n=${#s} i=0 c b out="" need j k lo hi ok seq
  while (( i < n )); do
    c="${s:i:1}"
    case "$c" in
      '"')   out+='\"'; i=$((i + 1)); continue ;;
      '\')   out+='\\'; i=$((i + 1)); continue ;;
      $'\n') out+='\n'; i=$((i + 1)); continue ;;
      $'\t') out+='\t'; i=$((i + 1)); continue ;;
      $'\r') out+='\r'; i=$((i + 1)); continue ;;
      $'\b') out+='\b'; i=$((i + 1)); continue ;;
      $'\f') out+='\f'; i=$((i + 1)); continue ;;
    esac
    printf -v b '%d' "'$c"
    (( b >= 0 )) || b=$((b + 256))   # bash 3.2 prints high bytes as negative
    if (( b < 32 || b == 127 )); then
      printf -v seq '\\u%04x' "$b"
      out+="$seq"
      i=$((i + 1))
    elif (( b < 128 )); then
      out+="$c"
      i=$((i + 1))
    else
      need=-1; lo=128; hi=191
      if   (( b >= 194 && b <= 223 )); then need=1
      elif (( b >= 224 && b <= 239 )); then
        need=2
        (( b == 224 )) && lo=160
        (( b == 237 )) && hi=159
      elif (( b >= 240 && b <= 244 )); then
        need=3
        (( b == 240 )) && lo=144
        (( b == 244 )) && hi=143
      fi
      ok=0
      if (( need > 0 && i + need < n )); then
        ok=1
        seq="$c"
        for (( j = 1; j <= need; j++ )); do
          printf -v k '%d' "'${s:i+j:1}"
          (( k >= 0 )) || k=$((k + 256))
          if (( k < lo || k > hi )); then ok=0; break; fi
          lo=128; hi=191
          seq+="${s:i+j:1}"
        done
      fi
      if (( ok )); then
        out+="$seq"
        i=$((i + need + 1))
      else
        out+='�'
        JSON_LOSSY=1
        i=$((i + 1))
      fi
    fi
  done
  JSTR="\"$out\""
}

# --- minimal JSON parser -----------------------------------------------------
# jp_parse TEXT flattens a JSON document into parallel arrays: JP_K (key path,
# each segment prefixed by US; the root is ""), JP_T (o object, a array,
# s string, n number, b boolean, z null) and JP_V (decoded string, number or
# boolean text; for arrays, the element count). Returns 1 with JP_ERR set on
# anything that is not valid JSON. It never evaluates the text.
JP_K=(); JP_T=(); JP_V=()
JP_S=""; JP_I=0; JP_N=0; JP_ERR=""; JP_STR=""; JP_CH=""
JP_GT=""; JP_GV=""

jp_fail() { JP_ERR="$1 at byte $JP_I"; return 1; }

jp_add() { JP_K+=("$1"); JP_T+=("$2"); JP_V+=("$3"); }

jp_ws() {
  while (( JP_I < JP_N )); do
    case "${JP_S:JP_I:1}" in
      ' '|$'\t'|$'\n'|$'\r') JP_I=$((JP_I + 1)) ;;
      *) break ;;
    esac
  done
}

# jp_utf8 CODEPOINT — sets JP_CH to its UTF-8 bytes.
jp_utf8() {
  local cp=$1 fmt="" o b
  local bytes=()
  if   (( cp < 128 ));   then bytes=("$cp")
  elif (( cp < 2048 ));  then bytes=($((192 | (cp >> 6))) $((128 | (cp & 63))))
  elif (( cp < 65536 )); then bytes=($((224 | (cp >> 12))) $((128 | ((cp >> 6) & 63))) $((128 | (cp & 63))))
  else bytes=($((240 | (cp >> 18))) $((128 | ((cp >> 12) & 63))) $((128 | ((cp >> 6) & 63))) $((128 | (cp & 63))))
  fi
  for b in "${bytes[@]}"; do
    printf -v o '\\%03o' "$b"
    fmt+="$o"
  done
  printf -v JP_CH "$fmt"
}

# jp_string — at an opening quote; leaves the decoded text in JP_STR.
jp_string() {
  local out="" rest chunk c e hex cp lo
  local re='^[^"\\]*'
  JP_I=$((JP_I + 1))
  while :; do
    rest="${JP_S:JP_I}"
    [[ $rest =~ $re ]]
    chunk="${BASH_REMATCH[0]}"
    if [[ "$chunk" == *[$'\001'-$'\037']* ]]; then
      jp_fail "control character in string"; return 1
    fi
    out+="$chunk"
    JP_I=$((JP_I + ${#chunk}))
    c="${JP_S:JP_I:1}"
    case "$c" in
      '"')
        JP_I=$((JP_I + 1))
        JP_STR="$out"
        return 0
        ;;
      '\')
        e="${JP_S:JP_I+1:1}"
        case "$e" in
          '"') out+='"';  JP_I=$((JP_I + 2)) ;;
          '\') out+='\';  JP_I=$((JP_I + 2)) ;;
          '/') out+='/';  JP_I=$((JP_I + 2)) ;;
          b)   out+=$'\b'; JP_I=$((JP_I + 2)) ;;
          f)   out+=$'\f'; JP_I=$((JP_I + 2)) ;;
          n)   out+=$'\n'; JP_I=$((JP_I + 2)) ;;
          r)   out+=$'\r'; JP_I=$((JP_I + 2)) ;;
          t)   out+=$'\t'; JP_I=$((JP_I + 2)) ;;
          u)
            hex="${JP_S:JP_I+2:4}"
            [[ "$hex" =~ ^[0-9a-fA-F]{4}$ ]] || { jp_fail "bad \\u escape"; return 1; }
            cp=$((16#$hex))
            JP_I=$((JP_I + 6))
            if (( cp >= 55296 && cp <= 56319 )); then          # high surrogate
              hex="${JP_S:JP_I+2:4}"
              if [[ "${JP_S:JP_I:2}" == '\u' && "$hex" =~ ^[dD][c-fC-F][0-9a-fA-F]{2}$ ]]; then
                lo=$((16#$hex))
                cp=$((65536 + ((cp - 55296) << 10) + (lo - 56320)))
                JP_I=$((JP_I + 6))
              else
                cp=65533
              fi
            elif (( cp >= 56320 && cp <= 57343 )); then        # lone low surrogate
              cp=65533
            fi
            (( cp != 0 )) || { jp_fail "NUL in string"; return 1; }
            jp_utf8 "$cp"
            out+="$JP_CH"
            ;;
          *) jp_fail "bad escape"; return 1 ;;
        esac
        ;;
      *) jp_fail "unterminated string"; return 1 ;;
    esac
  done
}

jp_object() {
  local path="$1" depth="$2" key
  jp_add "$path" o ""
  JP_I=$((JP_I + 1))
  jp_ws
  if [[ "${JP_S:JP_I:1}" == '}' ]]; then JP_I=$((JP_I + 1)); return 0; fi
  while :; do
    jp_ws
    [[ "${JP_S:JP_I:1}" == '"' ]] || { jp_fail "expected object key"; return 1; }
    jp_string || return 1
    key="$JP_STR"
    jp_ws
    [[ "${JP_S:JP_I:1}" == ':' ]] || { jp_fail "expected ':'"; return 1; }
    JP_I=$((JP_I + 1))
    jp_value "$path$US$key" $((depth + 1)) || return 1
    jp_ws
    case "${JP_S:JP_I:1}" in
      ',') JP_I=$((JP_I + 1)) ;;
      '}') JP_I=$((JP_I + 1)); return 0 ;;
      *) jp_fail "expected ',' or '}'"; return 1 ;;
    esac
  done
}

jp_array() {
  local path="$1" depth="$2" idx n=0
  idx=${#JP_K[@]}
  jp_add "$path" a 0
  JP_I=$((JP_I + 1))
  jp_ws
  if [[ "${JP_S:JP_I:1}" == ']' ]]; then JP_I=$((JP_I + 1)); return 0; fi
  while :; do
    jp_value "$path$US$n" $((depth + 1)) || return 1
    n=$((n + 1))
    JP_V[idx]=$n
    jp_ws
    case "${JP_S:JP_I:1}" in
      ',') JP_I=$((JP_I + 1)) ;;
      ']') JP_I=$((JP_I + 1)); return 0 ;;
      *) jp_fail "expected ',' or ']'"; return 1 ;;
    esac
  done
}

jp_value() {
  local path="$1" depth="$2" c rest
  local num_re='^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?'
  (( depth <= 32 )) || { jp_fail "nesting too deep"; return 1; }
  jp_ws
  (( JP_I < JP_N )) || { jp_fail "unexpected end"; return 1; }
  c="${JP_S:JP_I:1}"
  case "$c" in
    '{') jp_object "$path" "$depth" || return 1 ;;
    '[') jp_array  "$path" "$depth" || return 1 ;;
    '"')
      jp_string || return 1
      jp_add "$path" s "$JP_STR"
      ;;
    t) [[ "${JP_S:JP_I:4}" == true  ]] || { jp_fail "bad literal"; return 1; }
       JP_I=$((JP_I + 4)); jp_add "$path" b true ;;
    f) [[ "${JP_S:JP_I:5}" == false ]] || { jp_fail "bad literal"; return 1; }
       JP_I=$((JP_I + 5)); jp_add "$path" b false ;;
    n) [[ "${JP_S:JP_I:4}" == null  ]] || { jp_fail "bad literal"; return 1; }
       JP_I=$((JP_I + 4)); jp_add "$path" z null ;;
    -|[0-9])
      rest="${JP_S:JP_I}"
      [[ $rest =~ $num_re ]] || { jp_fail "bad number"; return 1; }
      JP_I=$((JP_I + ${#BASH_REMATCH[0]}))
      jp_add "$path" n "${BASH_REMATCH[0]}"
      ;;
    *) jp_fail "unexpected character"; return 1 ;;
  esac
  return 0
}

jp_parse() {
  local LC_ALL=C
  JP_K=(); JP_T=(); JP_V=(); JP_ERR=""
  JP_S="$1"; JP_I=0; JP_N=${#JP_S}
  jp_value "" 0 || return 1
  jp_ws
  (( JP_I == JP_N )) || { jp_fail "trailing data"; return 1; }
  return 0
}

# jp_get KEY — sets JP_GT (type, empty if absent) and JP_GV (value). First
# match wins if a document repeats a key. Always returns 0.
jp_get() {
  local i n=${#JP_K[@]}
  JP_GT=""; JP_GV=""
  for (( i = 0; i < n; i++ )); do
    if [[ "${JP_K[i]}" == "$1" ]]; then
      JP_GT="${JP_T[i]}"; JP_GV="${JP_V[i]}"
      return 0
    fi
  done
  return 0
}

# Validation helpers. Each returns 1 and sets VERR (field names only, never
# values, so a diagnostic cannot leak a secret) when a field has the wrong type.
VERR=""
jp_label() { local k="${1//$US/.}"; printf '%s' "${k#.}"; }

# jp_check KEY TYPES — absent, or one of the type letters in TYPES.
jp_check() {
  jp_get "$1"
  [[ -z "$JP_GT" || "$2" == *"$JP_GT"* ]] && return 0
  VERR="field $(jp_label "$1") has the wrong type"
  return 1
}

# jp_uint KEY — absent, or a non-negative integer.
jp_uint() {
  jp_get "$1"
  [[ -z "$JP_GT" || ( "$JP_GT" == n && "$JP_GV" =~ ^[0-9]{1,15}$ ) ]] && return 0
  VERR="field $(jp_label "$1") is not a non-negative integer"
  return 1
}

# jp_nstr KEY — null or string; sets JR to the JSON text for it.
jp_nstr() {
  jp_get "$1"
  case "$JP_GT" in
    ""|z) JR=null ;;
    s)    json_str "$JP_GV"; JR="$JSTR" ;;
    *)    VERR="field $(jp_label "$1") has the wrong type"; return 1 ;;
  esac
}

# jp_errobj KEY — null or a structured error; sets JR to {code,message,path}.
jp_errobj() {
  local key="$1" code message path
  jp_get "$key"
  case "$JP_GT" in
    ""|z) JR=null; return 0 ;;
    o) ;;
    *) VERR="field $(jp_label "$key") has the wrong type"; return 1 ;;
  esac
  jp_get "$key${US}code";    if [[ "$JP_GT" == s ]]; then json_str "$JP_GV"; code="$JSTR";    else code='"unknown"'; fi
  jp_get "$key${US}message"; if [[ "$JP_GT" == s ]]; then json_str "$JP_GV"; message="$JSTR"; else message='""'; fi
  jp_get "$key${US}path";    if [[ "$JP_GT" == s ]]; then json_str "$JP_GV"; path="$JSTR";    else path=null; fi
  JR="{\"code\":$code,\"message\":$message,\"path\":$path}"
}

# --- inspection state --------------------------------------------------------
CONSISTENT=1
DIAGS=()
INSTANCE=""
OBSERVED_AT=""

# diag_add CODE MESSAGE [RELATIVE-PATH]
diag_add() {
  local c m p=null
  json_str "$1"; c="$JSTR"
  json_str "$2"; m="$JSTR"
  if [[ -n "${3:-}" ]]; then json_str "$3"; p="$JSTR"; fi
  DIAGS+=("{\"code\":$c,\"message\":$m,\"path\":$p}")
}

# read_text FILE — sets TEXT. Returns 1 if FILE is not a readable regular file.
TEXT=""
read_text() {
  TEXT=""
  [[ -f "$1" && -r "$1" ]] || return 1
  IFS= read -r -d '' TEXT < "$1" || true
  return 0
}

S_REV=0
S_PAUSED=false
S_OWNER=null
S_OWNER_PRESENT=0
S_RUNNER_STATE=stopped
S_RUNNER_ERROR=null
S_DIGEST=null
S_VALID=1
STATE_SNAPSHOT=""

# state_check — validate the parsed runtime/state.json and fill the S_* values.
# Unknown fields are ignored; the verifier and any other secret are never read
# into the output. Returns 1 with VCODE/VERR set.
VCODE=""
state_check() {
  local id label
  VCODE="state_malformed"
  jp_get ""
  [[ "$JP_GT" == o ]] || { VERR="top level is not an object"; return 1; }
  jp_get "${US}schema_version"
  if [[ "$JP_GT" != n || "$JP_GV" != 1 ]]; then
    VCODE="state_unsupported"; VERR="schema_version is missing or not 1"; return 1
  fi
  jp_uint "${US}revision" || return 1
  jp_check "${US}paused" b || return 1
  jp_check "${US}owner" zo || return 1
  jp_check "${US}runner" o || return 1
  jp_check "${US}config_digest" zs || return 1

  jp_get "${US}revision";   [[ -z "$JP_GT" ]] || S_REV="$JP_GV"
  jp_get "${US}paused";     [[ -z "$JP_GT" ]] || S_PAUSED="$JP_GV"

  jp_get "${US}owner"
  if [[ "$JP_GT" == o ]]; then
    jp_get "${US}owner${US}id"
    [[ "$JP_GT" == s && -n "$JP_GV" ]] || { VERR="field owner.id is missing or not a string"; return 1; }
    json_str "$JP_GV"; id="$JSTR"
    jp_get "${US}owner${US}generation"
    [[ "$JP_GT" == n && "$JP_GV" =~ ^[0-9]{1,15}$ ]] || { VERR="field owner.generation is missing or not a non-negative integer"; return 1; }
    local gen="$JP_GV"
    jp_nstr "${US}owner${US}label" || return 1
    label="$JR"
    S_OWNER="{\"id\":$id,\"generation\":$gen,\"label\":$label}"
    S_OWNER_PRESENT=1
  fi

  jp_get "${US}runner"
  if [[ "$JP_GT" == o ]]; then
    jp_check "${US}runner${US}state" s || return 1
    jp_get "${US}runner${US}state"
    if [[ -n "$JP_GT" ]]; then
      case "$JP_GV" in
        stopped|running|stopping|unknown|failed) S_RUNNER_STATE="$JP_GV" ;;
        *) VERR="field runner.state is not a known runner state"; return 1 ;;
      esac
    fi
    jp_errobj "${US}runner${US}last_error" || return 1
    S_RUNNER_ERROR="$JR"
  fi

  jp_nstr "${US}config_digest" || return 1
  S_DIGEST="$JR"
  return 0
}

# inspect_state — runtime/state.json: absent means defaults; present but
# unreadable, malformed or unsupported is reported and never repaired.
inspect_state() {
  local f="$GH_DIR/runtime/state.json" rel="runtime/state.json"
  STATE_SNAPSHOT="<absent>"
  [[ -e "$f" || -L "$f" ]] || return 0
  STATE_SNAPSHOT="<unreadable>"
  if ! read_text "$f"; then
    diag_add state_unreadable "runtime/state.json exists but is not a readable regular file" "$rel"
    state_reset_invalid
    return 0
  fi
  STATE_SNAPSHOT="$TEXT"
  if ! jp_parse "$TEXT"; then
    diag_add state_malformed "runtime/state.json is not valid JSON ($JP_ERR)" "$rel"
    state_reset_invalid
    return 0
  fi
  if ! state_check; then
    diag_add "$VCODE" "runtime/state.json: $VERR" "$rel"
    state_reset_invalid
  fi
  return 0
}

# Unusable state: report neutral values, mark the snapshot inconsistent and
# the runner unknown. Callers must refresh (the contract's consistent:false).
state_reset_invalid() {
  S_VALID=0
  CONSISTENT=0
  S_REV=0
  S_PAUSED=false
  S_OWNER=null
  S_OWNER_PRESENT=0
  S_RUNNER_STATE=unknown
  S_RUNNER_ERROR=null
  S_DIGEST=null
}

C_CONFIGURED=false
C_VALID=true

# config_check — structural validity of the parsed runtime/config.json. Whether
# the executable and cwd exist belongs to the consumer-dispatch stitch.
config_check() {
  local n i key
  jp_get ""
  [[ "$JP_GT" == o ]] || { VERR="top level is not an object"; return 1; }
  jp_get "${US}schema_version"
  [[ "$JP_GT" == n && "$JP_GV" == 1 ]] || { VERR="schema_version is missing or not 1"; return 1; }
  jp_get "${US}consumer"
  [[ "$JP_GT" == o ]] || { VERR="field consumer is missing or not an object"; return 1; }
  jp_get "${US}consumer${US}argv"
  [[ "$JP_GT" == a && "$JP_GV" -ge 1 ]] || { VERR="field consumer.argv is missing or not a nonempty array"; return 1; }
  n="$JP_GV"
  for (( i = 0; i < n; i++ )); do
    jp_get "${US}consumer${US}argv${US}$i"
    [[ "$JP_GT" == s ]] || { VERR="field consumer.argv has a non-string element"; return 1; }
    if (( i == 0 )); then
      [[ "$JP_GV" == /* ]] || { VERR="consumer.argv[0] is not an absolute path"; return 1; }
    fi
  done
  jp_get "${US}consumer${US}cwd"
  [[ "$JP_GT" == s && -n "$JP_GV" ]] || { VERR="field consumer.cwd is missing or not a string"; return 1; }
  jp_check "${US}consumer${US}env" o || return 1
  n=${#JP_K[@]}
  for (( i = 0; i < n; i++ )); do
    key="${JP_K[i]}"
    if [[ "$key" == "${US}consumer${US}env${US}"* && "${JP_T[i]}" != s ]]; then
      VERR="field consumer.env has a non-string value"; return 1
    fi
  done
  return 0
}

inspect_consumer() {
  local f="$GH_DIR/runtime/config.json" rel="runtime/config.json"
  [[ -e "$f" || -L "$f" ]] || return 0
  C_CONFIGURED=true
  if ! read_text "$f"; then
    C_VALID=false
    diag_add consumer_config_unreadable "runtime/config.json exists but is not a readable regular file" "$rel"
    return 0
  fi
  if ! jp_parse "$TEXT"; then
    C_VALID=false
    diag_add consumer_config_invalid "runtime/config.json is not valid JSON ($JP_ERR)" "$rel"
    return 0
  fi
  if ! config_check; then
    C_VALID=false
    diag_add consumer_config_invalid "runtime/config.json: $VERR" "$rel"
  fi
  return 0
}

# --- deliveries --------------------------------------------------------------
DELIVERIES=()
REG_LIST=""      # US-separated out/ paths that a record claims

# attempt_json KEY — one attempt object from the parsed record, in JR.
attempt_json() {
  local k="$1" id started finished outcome exit_code signal error decision decided_at extra=""
  jp_get "$k"
  [[ "$JP_GT" == o ]] || { VERR="an attempt is not an object"; return 1; }
  jp_get "$k${US}id"
  [[ "$JP_GT" == s && -n "$JP_GV" ]] || { VERR="an attempt has no id"; return 1; }
  json_str "$JP_GV"; id="$JSTR"
  jp_get "$k${US}started_at"
  [[ "$JP_GT" == s ]] || { VERR="an attempt has no started_at"; return 1; }
  json_str "$JP_GV"; started="$JSTR"
  jp_nstr "$k${US}finished_at" || return 1; finished="$JR"
  jp_get "$k${US}outcome"
  [[ "$JP_GT" == s ]] || { VERR="an attempt has no outcome"; return 1; }
  case "$JP_GV" in
    in_flight)
      # An in-flight record with no live runner is abandoned: its result was
      # never recorded, so a read reports the outcome as unknown. Only an
      # explicit run or recovery may turn it into uncertain.
      case "$S_RUNNER_STATE" in
        running|stopping) outcome='"in_flight"' ;;
        *) outcome='"unknown"' ;;
      esac
      ;;
    accepted|failed|unknown) outcome="\"$JP_GV\"" ;;
    *) VERR="an attempt has an unknown outcome"; return 1 ;;
  esac
  jp_get "$k${US}exit_code"
  case "$JP_GT" in
    ""|z) exit_code=null ;;
    n) [[ "$JP_GV" =~ ^-?[0-9]{1,9}$ ]] || { VERR="an attempt exit_code is not an integer"; return 1; }
       exit_code="$JP_GV" ;;
    *) VERR="an attempt exit_code has the wrong type"; return 1 ;;
  esac
  jp_nstr "$k${US}signal" || return 1; signal="$JR"
  jp_errobj "$k${US}error" || return 1; error="$JR"
  jp_get "$k${US}decision"
  if [[ -n "$JP_GT" && "$JP_GT" != z ]]; then
    [[ "$JP_GT" == s && ( "$JP_GV" == retry || "$JP_GV" == accept ) ]] || { VERR="an attempt has an unknown decision"; return 1; }
    json_str "$JP_GV"; decision="$JSTR"
    jp_nstr "$k${US}decided_at" || return 1; decided_at="$JR"
    extra=",\"decision\":$decision,\"decided_at\":$decided_at"
  fi
  JR="{\"id\":$id,\"started_at\":$started,\"finished_at\":$finished,\"outcome\":$outcome,\"exit_code\":$exit_code,\"signal\":$signal,\"error\":$error$extra}"
}

# delivery_check STEM — turn the parsed deliveries/<STEM>.json into JR.
delivery_check() {
  local stem="$1" id path origin schedule_path occ date slot state reason attempts="" n i
  jp_get ""
  [[ "$JP_GT" == o ]] || { VERR="top level is not an object"; return 1; }
  jp_get "${US}schema_version"
  [[ "$JP_GT" == n && "$JP_GV" == 1 ]] || { VERR="schema_version is missing or not 1"; return 1; }
  jp_get "${US}id"
  [[ "$JP_GT" == s && "$JP_GV" == "$stem" ]] || { VERR="field id is missing or does not match the file name"; return 1; }
  json_str "$JP_GV"; id="$JSTR"
  jp_get "${US}path"
  [[ "$JP_GT" == s && "$JP_GV" =~ ^out/[^/]+$ && "$JP_GV" != out/. && "$JP_GV" != out/.. ]] \
    || { VERR="field path is missing or not an entry directly under out/"; return 1; }
  DEL_PATH="$JP_GV"
  json_str "$JP_GV"; path="$JSTR"
  jp_get "${US}origin"
  case "$JP_GT:$JP_GV" in
    :|s:runtime) origin='"runtime"' ;;
    s:legacy_out) origin='"legacy_out"' ;;
    *) VERR="field origin is not a known origin"; return 1 ;;
  esac
  jp_nstr "${US}schedule_path" || return 1; schedule_path="$JR"
  jp_get "${US}occurrence"
  case "$JP_GT" in
    ""|z) occ=null ;;
    o)
      jp_nstr "${US}occurrence${US}date" || return 1; date="$JR"
      jp_nstr "${US}occurrence${US}slot" || return 1; slot="$JR"
      occ="{\"date\":$date,\"slot\":$slot}"
      ;;
    *) VERR="field occurrence has the wrong type"; return 1 ;;
  esac
  jp_get "${US}state"
  case "$JP_GT:$JP_GV" in
    s:pending|s:in_flight|s:accepted|s:failed|s:uncertain|s:missing) state="\"$JP_GV\"" ;;
    *) VERR="field state is missing or not a known delivery state"; return 1 ;;
  esac
  DEL_STATE="$JP_GV"
  jp_nstr "${US}reason" || return 1; reason="$JR"
  jp_get "${US}attempts"
  case "$JP_GT" in
    "") ;;
    a)
      n="$JP_GV"
      for (( i = 0; i < n; i++ )); do
        attempt_json "${US}attempts${US}$i" || return 1
        attempts+="${attempts:+,}$JR"
      done
      ;;
    *) VERR="field attempts has the wrong type"; return 1 ;;
  esac
  # v1 reports execution as unknown whatever a record says (see contract).
  JR="{\"id\":$id,\"path\":$path,\"origin\":$origin,\"schedule_path\":$schedule_path,\"occurrence\":$occ,\"state\":$state,\"reason\":$reason,\"attempts\":[$attempts],\"execution\":\"unknown\"}"
}

DEL_PATH=""
DEL_STATE=""

inspect_deliveries() {
  local dir="$GH_DIR/runtime/deliveries" f base stem rel entry name
  shopt -s nullglob
  for f in "$dir"/*.json; do
    base="${f##*/}"
    stem="${base%.json}"
    rel="runtime/deliveries/$base"
    if ! read_text "$f"; then
      CONSISTENT=0
      diag_add delivery_record_unreadable "$rel is not a readable regular file" "$rel"
      continue
    fi
    if ! jp_parse "$TEXT"; then
      CONSISTENT=0
      diag_add delivery_record_malformed "$rel is not valid JSON ($JP_ERR)" "$rel"
      continue
    fi
    if ! delivery_check "$stem"; then
      CONSISTENT=0
      diag_add delivery_record_malformed "$rel: $VERR" "$rel"
      continue
    fi
    DELIVERIES+=("$JR")
    REG_LIST+="$US$DEL_PATH$US"
    case "$DEL_STATE" in
      pending|in_flight|failed|uncertain)
        if [[ ! -e "$GH_DIR/$DEL_PATH" ]]; then
          diag_add delivery_path_missing "$DEL_PATH is recorded as $DEL_STATE but is not in out/" "$DEL_PATH"
        fi
        ;;
    esac
  done

  # Entries in out/ that no record claims: read-only legacy deliveries.
  # They are not registered here; status never writes.
  for entry in "$OUT"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    [[ "$name" == *.landing ]] && continue
    if [[ ! -d "$entry" ]]; then
      diag_add out_entry_not_directory "out/$name is not a directory, so it is not listed as a delivery" "out/$name"
      continue
    fi
    [[ "$REG_LIST" == *"$US""out/$name""$US"* ]] && continue
    json_str "out/$name"
    DELIVERIES+=("{\"id\":null,\"path\":$JSTR,\"origin\":\"legacy_out\",\"schedule_path\":null,\"occurrence\":null,\"state\":\"pending\",\"reason\":\"unregistered\",\"attempts\":[],\"execution\":\"unknown\"}")
  done
  shopt -u nullglob
}

# --- schedule ----------------------------------------------------------------
SCHEDULE=()

inspect_schedule() {
  local now_t due_text name src is_once slot k p rel marker marker_rel due_idx i
  local paused_list part paused_json bb fired eligible allowed marker_json
  local item_paths=() item_pauses=() due_src=() due_slot=() found o
  local parts=()
  now_t="$(now_today)"

  LINT_INCLUDE_PAUSED=1
  lint_scan
  for o in ${LINT_ORPHANS[@]+"${LINT_ORPHANS[@]}"}; do
    rel="${o#"$GH_DIR"/}"
    diag_add schedule_unrecognized_path "$rel does not match the schedule grammar and is listed by 'lint'" "$rel"
  done
  item_paths=(${LINT_ITEMS[@]+"${LINT_ITEMS[@]}"})
  item_pauses=(${LINT_ITEM_PAUSED[@]+"${LINT_ITEM_PAUSED[@]}"})

  # Due logic comes from the script's own walk_due, exactly as tick and due
  # use it; this function only asks which items it emitted.
  due_text="$(walk_due)"
  while IFS=$'\t' read -r name src is_once slot; do
    [[ -n "$name" ]] || continue
    # A name holding a tab or newline splits walk_due's row (tick shares that
    # limit); skip fragments that are not schedule directories.
    [[ "$src" == "$SCHED"/* && -d "$src" ]] || continue
    due_src+=("$src")
    due_slot+=("$slot")
    found=0
    for p in ${item_paths[@]+"${item_paths[@]}"}; do
      [[ "$p" == "$src" ]] && { found=1; break; }
    done
    if (( ! found )); then
      # walk_due will fire this although the grammar does not recognize it
      # (for example a name with a space). Report it as the item it is.
      item_paths+=("$src")
      item_pauses+=("")
    fi
  done <<< "$due_text"

  for (( k = 0; k < ${#item_paths[@]}; k++ )); do
    p="${item_paths[k]}"
    rel="${p#"$GH_DIR"/}"
    paused_json=""
    if [[ -n "${item_pauses[k]}" ]]; then
      IFS="$US" read -r -a parts <<< "${item_pauses[k]}"
      for part in "${parts[@]}"; do
        json_str "${part#"$GH_DIR"/}"
        paused_json+="${paused_json:+,}$JSTR"
      done
    fi

    due_idx=-1
    for (( i = 0; i < ${#due_src[@]}; i++ )); do
      if [[ "${due_src[i]}" == "$p" ]]; then due_idx=$i; break; fi
    done

    fired=false
    marker_json=null
    if (( due_idx >= 0 )); then
      marker="$(fired_marker_for "$p" "$now_t" "${due_slot[due_idx]}")"
      json_str "${marker#"$GH_DIR"/}"
      marker_json="$JSTR"
      [[ -e "$marker" ]] && fired=true
    fi

    bb=""
    if [[ -n "${item_pauses[k]}" ]]; then bb+="${bb:+,}\"subtree_paused\""
    elif (( due_idx < 0 )); then bb+="${bb:+,}\"not_due\""
    elif [[ "$fired" == true ]]; then bb+="${bb:+,}\"already_fired\""
    fi
    [[ "$S_PAUSED" == true ]] && bb+="${bb:+,}\"instance_paused\""
    (( S_OWNER_PRESENT )) && bb+="${bb:+,}\"owned\""
    (( S_VALID )) || bb+="${bb:+,}\"invalid_state\""

    eligible=false
    (( due_idx >= 0 )) && [[ "$fired" == false ]] && eligible=true
    allowed=false
    [[ -z "$bb" ]] && allowed=true

    json_str "$rel"; local path_json="$JSTR"
    json_str "${p##*/}"; local id_json="$JSTR"
    SCHEDULE+=("{\"path\":$path_json,\"item_id\":$id_json,\"paused_by\":[$paused_json],\"eligible_now\":$eligible,\"fired_marker\":$marker_json,\"fired\":$fired,\"firing_allowed\":$allowed,\"blocked_by\":[$bb]}")
  done
  LINT_INCLUDE_PAUSED=0
}

# json_array NAME… helper: join an array's elements with commas into JR.
join_by_comma() {
  local out="" e
  for e in "$@"; do out+="${out:+,}$e"; done
  JR="$out"
}

# json_only_args COMMAND ARGS… — both new commands take exactly --json.
json_only_args() {
  local cmd="$1" a
  shift
  if (( $# == 0 )); then
    echo "error: $cmd requires --json" >&2
    exit 2
  fi
  for a in "$@"; do
    if [[ "$a" != --json ]]; then
      echo "error: $cmd: unknown option '$a'" >&2
      exit 2
    fi
  done
  if (( $# > 1 )); then
    echo "error: $cmd: --json given more than once" >&2
    exit 2
  fi
}

cmd_capabilities() {
  json_only_args capabilities "$@"
  local caps="" c
  for c in "${GH_CAPABILITIES[@]}"; do
    json_str "$c"
    caps+="${caps:+,}$JSTR"
  done
  json_str "$GH_IMPLEMENTATION_VERSION"
  printf '{"protocol":"%s","protocol_version":%s,"implementation_version":%s,"capabilities":[%s]}\n' \
    "$GH_PROTOCOL" "$GH_PROTOCOL_VERSION" "$JSTR" "$caps"
}

cmd_status() {
  json_only_args status "$@"
  GH_BAD_INSTALL_EXIT=2
  resolve_paths
  INSTANCE="$(cd "$GH_DIR" && pwd -P)"
  OBSERVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  inspect_state
  inspect_consumer
  inspect_deliveries
  inspect_schedule

  # A writer that changed state.json while we read would give a mixed view.
  local again="<absent>"
  if [[ -e "$GH_DIR/runtime/state.json" || -L "$GH_DIR/runtime/state.json" ]]; then
    again="<unreadable>"
    if read_text "$GH_DIR/runtime/state.json"; then again="$TEXT"; fi
  fi
  if [[ "$again" != "$STATE_SNAPSHOT" ]]; then
    CONSISTENT=0
    diag_add state_changed_during_read "runtime/state.json changed while status was reading; refresh before acting" "runtime/state.json"
  fi
  if (( JSON_LOSSY )); then
    diag_add path_not_utf8 "some names are not valid UTF-8; invalid bytes are shown as U+FFFD" ""
  fi

  local consistent=true
  (( CONSISTENT )) || consistent=false
  local instance_json observed_json schedule deliveries diags
  json_str "$INSTANCE"; instance_json="$JSTR"
  json_str "$OBSERVED_AT"; observed_json="$JSTR"
  join_by_comma ${SCHEDULE[@]+"${SCHEDULE[@]}"};   schedule="$JR"
  join_by_comma ${DELIVERIES[@]+"${DELIVERIES[@]}"}; deliveries="$JR"
  join_by_comma ${DIAGS[@]+"${DIAGS[@]}"};          diags="$JR"

  printf '{"protocol":"%s","protocol_version":%s,"instance":%s,"observed_at":%s,"revision":%s,"consistent":%s,"paused":%s,"owner":%s,"runner":{"state":"%s","last_error":%s},"consumer":{"configured":%s,"valid":%s,"config_digest":%s},"schedule":[%s],"deliveries":[%s],"diagnostics":[%s]}\n' \
    "$GH_PROTOCOL" "$GH_PROTOCOL_VERSION" "$instance_json" "$observed_json" \
    "$S_REV" "$consistent" "$S_PAUSED" "$S_OWNER" "$S_RUNNER_STATE" "$S_RUNNER_ERROR" \
    "$C_CONFIGURED" "$C_VALID" "$S_DIGEST" "$schedule" "$deliveries" "$diags"
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
    capabilities) shift; cmd_capabilities "$@" ;;
    status) shift; cmd_status "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

main "$@"
