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
  groundhog.sh enroll --owner-label LABEL --token-file ABSENT_ABSOLUTE_PATH
  groundhog.sh run --token-file PATH [--interval-seconds N]
  groundhog.sh pause --token-file PATH
  groundhog.sh resume --token-file PATH
  groundhog.sh stop --token-file PATH
  groundhog.sh release --token-file PATH
  groundhog.sh retry --token-file PATH --delivery ID
  groundhog.sh recover --token-file PATH --delivery ID --decision retry|accept

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
  - enroll, run, pause, resume, stop, release, retry and recover are the
    optional runner commands; they need the OS-released locking described in
    README.md, and an owned instance refuses tick, init, add, drop and sweep
  - run hands pending deliveries to the consumer in runtime/config.json, if
    there is one; retry and recover are the operator's decisions about a
    failed or uncertain handoff (see README.md)
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
  passive_enter init
  ensure_dirs
  echo "initialized $GH_DIR"
}

cmd_add() {
  require_root
  passive_enter add
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
  LINT_INCLUDE_PAUSED=0
  lint_scan
  note_shared_names "$id"
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

# A standalone tick: serialized with the runtime's writers, refused while the
# instance is owned (the runner ticks under its token), and a no-op while the
# instance is globally paused. An unowned, unpaused tick is the legacy tick.
cmd_tick() {
  require_root
  passive_enter tick
  if [[ "$PASSIVE_PAUSED" == true ]]; then
    echo "tick: the instance is paused; nothing fired" >&2
    return 0
  fi
  tick_body
}

# The tick itself. The runner calls it too, under its own admission checks.
tick_body() {
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
      legacy_note_collision "out/$(basename "$dst")" "${src#"$GH_DIR"/}" "$now_t" "$slot"
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
#   LINT_ITEMS / LINT_ITEM_PAUSED / LINT_ITEM_CAD  every recognized item
#                          directory, the paused components above it, and its
#                          cadence parts (axis=…, dow=…, time=…; US-separated)
# `lint` leaves LINT_INCLUDE_PAUSED at 0, so its behavior is unchanged.
LINT_ORPHANS=()
LINT_ITEMS=()
LINT_ITEM_PAUSED=()
LINT_ITEM_CAD=()
LINT_INCLUDE_PAUSED=0
US=$'\x1f'          # separator inside parsed-JSON keys and path lists

lint_walk() {
  local dir="$1"
  local state="$2"
  local paused_by="${3:-}"
  local cad="${4:-}"
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
        if   is_hh "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now" "$cad${cad:+$US}time=$eff"
        elif is_id "$eff"; then lint_item "$entry" "$paused_now" "$cad"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-weekly)
        if   is_dow "$eff"; then lint_walk "$entry" "weekly-dow" "$paused_now" "$cad${cad:+$US}dow=$eff"
        elif is_hh  "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now" "$cad${cad:+$US}time=$eff"
        elif is_id  "$eff"; then lint_item "$entry" "$paused_now" "$cad"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-monthly)
        if   is_dom "$eff"; then lint_walk "$entry" "param-with-hour-or-item" "$paused_now" "$cad${cad:+$US}dom=$eff"
        elif is_hh  "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now" "$cad${cad:+$US}time=$eff"
        elif is_id  "$eff"; then lint_item "$entry" "$paused_now" "$cad"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-yearly)
        # HH-MM forbidden at yearly root — would collide with MM-DD shape.
        if   is_md "$eff"; then lint_walk "$entry" "param-with-hour-or-item" "$paused_now" "$cad${cad:+$US}md=$eff"
        elif is_hh "$eff"; then lint_walk "$entry" "item-only" "$paused_now" "$cad${cad:+$US}time=$eff"
        elif is_id "$eff"; then lint_item "$entry" "$paused_now" "$cad"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-once)
        if   is_ymd "$eff"; then lint_walk "$entry" "param-with-hour-or-item" "$paused_now" "$cad${cad:+$US}ymd=$eff"
        elif is_hh  "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now" "$cad${cad:+$US}time=$eff"
        elif is_id  "$eff"; then lint_item "$entry" "$paused_now" "$cad"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      axis-every)
        # every/ requires a bucket; bare items at axis root are orphans.
        if   is_interval "$eff"; then lint_walk "$entry" "every-bucket" "$paused_now" "$cad${cad:+$US}interval=$eff"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      every-bucket)
        if is_id "$eff"; then lint_item "$entry" "$paused_now" "$cad"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      weekly-dow|param-with-hour-or-item)
        if   is_hh "$eff" || is_hm "$eff"; then lint_walk "$entry" "item-only" "$paused_now" "$cad${cad:+$US}time=$eff"
        elif is_id "$eff"; then lint_item "$entry" "$paused_now" "$cad"
        else LINT_ORPHANS+=("$entry"); fi
        ;;
      item-only)
        if is_id "$eff"; then lint_item "$entry" "$paused_now" "$cad"
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
  LINT_ITEM_CAD+=("$3")
}

# Fill LINT_ORPHANS / LINT_ITEMS / LINT_ITEM_PAUSED from schedule/.
# Read-only: a missing schedule/ simply yields empty lists.
lint_scan() {
  LINT_ORPHANS=()
  LINT_ITEMS=()
  LINT_ITEM_PAUSED=()
  LINT_ITEM_CAD=()
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
      daily)   lint_walk "$axis_dir" "axis-daily"   "$paused_now" "axis=daily" ;;
      weekly)  lint_walk "$axis_dir" "axis-weekly"  "$paused_now" "axis=weekly" ;;
      monthly) lint_walk "$axis_dir" "axis-monthly" "$paused_now" "axis=monthly" ;;
      yearly)  lint_walk "$axis_dir" "axis-yearly"  "$paused_now" "axis=yearly" ;;
      once)    lint_walk "$axis_dir" "axis-once"    "$paused_now" "axis=once" ;;
      every)   lint_walk "$axis_dir" "axis-every"   "$paused_now" "axis=every" ;;
      *)       LINT_ORPHANS+=("$axis_dir") ;;
    esac
  done
  shopt -u nullglob
}

# note_shared_names [ID] — after lint_scan: a note on stderr for every item id
# (or only ID) that exists at more than one schedule path. A firing lands in
# out/<id>-<date>[-<slot>], so two such items that fire on the same date share
# one out name: the later firing is recorded in fired/ but not delivered (and a
# one-shot is still removed). Advisory only; it changes no output or exit code.
note_shared_names() {
  local id ids p list n
  if (( ${#LINT_ITEMS[@]} == 0 )); then return 0; fi
  if [[ -n "${1:-}" ]]; then ids="$1"
  else ids="$(printf '%s\n' "${LINT_ITEMS[@]}" | sed 's#.*/##' | LC_ALL=C sort | uniq -d)"; fi
  [[ -n "$ids" ]] || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    list=""; n=0
    for p in "${LINT_ITEMS[@]}"; do
      if [[ "${p##*/}" == "$id" ]]; then list+="${list:+, }${p#"$GH_DIR"/}"; n=$((n + 1)); fi
    done
    if (( n > 1 )); then
      printf "note: item id '%s' exists at %d schedule paths (%s); firings on one date share out/%s-<date>[-<slot>], and only the first is delivered\n" "$id" "$n" "$list" "$id" >&2
    fi
  done <<< "$ids"
  return 0
}

cmd_lint() {
  require_root
  LINT_INCLUDE_PAUSED=0
  lint_scan
  note_shared_names

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
  passive_enter drop
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
  passive_enter sweep
  ensure_dirs
  local days="${1:-14}"
  [[ "$days" =~ ^[0-9]+$ ]] || die "sweep <days> must be a non-negative integer"
  if sweep_supervised; then
    sweep_runtime "$days"
  else
    sweep_dir "$OUT" out "$days"
    sweep_dir "$FIRED" fired "$days"
  fi
}

# An instance with delivery records or runtime state is supervised: its sweep
# keeps every payload whose handoff has not been settled.
sweep_supervised() {
  [[ -d "$RT_DIR/deliveries" || -e "$RT_STATE" ]]
}

# sweep_runtime DAYS — the supervised sweep. Pending, failed, in-flight and
# uncertain deliveries keep their out/ entry, their record and the fired-marker
# date directory they reference; so do entries no record claims yet (they are
# unregistered deliveries). Accepted deliveries leave together with their
# record; a record whose path has been removed from outside leaves as a
# terminal record once it is old enough. Skipped entries are reported.
# Unreadable evidence stops the sweep before anything is removed.
sweep_runtime() {
  local days="$1" f entry name rel state k n
  local prot_paths="" prot_dates="" acc_paths="" acc_ids="" gone_ids="" prot_state_list=""
  local md date_dir
  shopt -s nullglob
  for f in "$RT_DIR"/deliveries/*.json "$RT_DIR"/deliveries/done/*.json; do
    if ! drec_load "$f"; then
      shopt -u nullglob
      die "sweep: ${f##*/} is unreadable or of an unsupported shape; nothing was swept"
    fi
    case "$D_STATE" in
      pending|in_flight|failed|uncertain)
        prot_paths+="$US$D_PATH$US"
        prot_state_list+="$US$D_PATH=$D_STATE$US"
        if [[ "$D_MARKER" == fired/*/* ]]; then
          md="${D_MARKER#fired/}"; md="${md%%/*}"
          prot_dates+="$US$md$US"
        fi
        ;;
      accepted)
        acc_paths+="$US$D_PATH$US"
        acc_ids+="$US$D_ID$US"
        ;;
      missing)
        gone_ids+="$US$D_ID$US"
        ;;
    esac
  done
  for entry in "$OUT"/*; do
    [[ -d "$entry" ]] || continue
    name="${entry##*/}"
    rel="out/$name"
    if [[ "$name" == *.landing ]]; then
      if [[ -n "$(find "$entry" -maxdepth 0 -type d -mtime +"$days")" ]]; then
        rm -rf -- "$entry"; printf 'swept out %s\n' "$name"
      fi
    elif [[ "$prot_paths" == *"$US$rel$US"* ]]; then
      state="${prot_state_list#*"$US$rel="}"; state="${state%%"$US"*}"
      printf 'skipped out %s (%s)\n' "$name" "$state"
    elif [[ "$acc_paths" == *"$US$rel$US"* ]]; then
      if [[ -n "$(find "$entry" -maxdepth 0 -type d -mtime +"$days")" ]]; then
        rm -rf -- "$entry"
        printf 'swept out %s\n' "$name"
        sweep_remove_records_for "$rel"
      fi
    else
      printf 'skipped out %s (unregistered)\n' "$name"
    fi
  done
  # Records of removed or terminal deliveries: old enough by the record's own age.
  for f in "$RT_DIR"/deliveries/*.json "$RT_DIR"/deliveries/done/*.json; do
    name="${f##*/}"; name="${name%.json}"
    if [[ "$gone_ids" == *"$US$name$US"* ]] \
       && [[ -n "$(find "$f" -maxdepth 0 -type f -mtime +"$days")" ]]; then
      rm -f "$f"; printf 'swept delivery %s\n' "$name"
    elif [[ "$acc_ids" == *"$US$name$US"* ]] \
       && drec_load "$f" && [[ ! -d "$GH_DIR/$D_PATH" ]] \
       && [[ -n "$(find "$f" -maxdepth 0 -type f -mtime +"$days")" ]]; then
      rm -f "$f"; printf 'swept delivery %s\n' "$name"
    fi
  done
  shopt -u nullglob
  for date_dir in "$FIRED"/*; do
    [[ -d "$date_dir" ]] || continue
    name="${date_dir##*/}"
    if [[ -z "$(find "$date_dir" -maxdepth 0 -type d -mtime +"$days")" ]]; then continue; fi
    if [[ "$prot_dates" == *"$US$name$US"* ]]; then
      printf 'skipped fired %s (referenced by an unsettled delivery)\n' "$name"
    else
      rm -rf -- "$date_dir"; printf 'swept fired %s\n' "$name"
    fi
  done
}

# sweep_remove_records_for OUT_REL — remove the accepted records that claim a
# swept out/ entry.
sweep_remove_records_for() {
  local f
  for f in "$RT_DIR"/deliveries/*.json "$RT_DIR"/deliveries/done/*.json; do
    if drec_load "$f" && [[ "$D_PATH" == "$1" && "$D_STATE" == accepted ]]; then
      rm -f "$f"; printf 'swept delivery %s\n' "$D_ID"
    fi
  done
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
# Advertise only what this script implements here. cmd_capabilities adds
# ownership-v1, runner-v1 and pause-v1 on hosts where rt_detect finds the locking
# and durability tools, and consumer-v1 and delivery-v1 where it also finds a way
# to start a consumer in its own session.
GH_CAPABILITIES=("status-json-v1")

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

# utf8_valid VALUE — is VALUE valid UTF-8? Names that are not would be stored
# lossily in a record (json_str), so the path in the record would never match
# the directory again. Leaves JSON_LOSSY and JSTR as they were.
utf8_valid() {
  local LC_ALL=C lossy="$JSON_LOSSY" keep="$JSTR" ok=1
  if [[ "$1" == *[^\ -~]* ]]; then
    JSON_LOSSY=0
    json_str "$1"
    if (( JSON_LOSSY )); then ok=0; fi
    JSON_LOSSY="$lossy"; JSTR="$keep"
  fi
  (( ok ))
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

# canonical_dir DIR — the physical path as the file system spells it. The
# external pwd asks the kernel (getcwd); bash's builtin `pwd -P` keeps the case
# the caller typed, which differs on a case-insensitive file system.
canonical_dir() {
  local d
  if [[ -x /bin/pwd ]]; then d="$(cd "$1" && /bin/pwd -P)" || return 1
  else d="$(cd "$1" && pwd -P)" || return 1; fi
  printf '%s\n' "$d"
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
  else
    state_bound_check
    state_liveness
  fi
  return 0
}

# A state bound to another directory (the project moved, or was reached by a
# different path) stays usable while unowned: the next save rebinds it. While
# owned, control fails closed (exit 5); status says why and asks for a refresh.
state_bound_check() {
  jp_get "${US}instance"
  if [[ "$JP_GT" == s && "$JP_GV" != "$INSTANCE" ]] && (( S_OWNER_PRESENT )); then
    CONSISTENT=0
    diag_add state_bound_elsewhere "runtime/state.json is owned and bound to a different instance directory; control commands exit 5 until it is repaired (see README.md)" "runtime/state.json"
  fi
}

# A state file that says a runner is running or stopping may be left over from
# a crash. Status holds no locks, so it cannot prove activity; it can only look
# for the recorded process (a diagnostic, never authority). No matching
# process: report the runner as unknown and keep ownership as recorded.
state_liveness() {
  local pid start cur
  case "$S_RUNNER_STATE" in running|stopping) ;; *) return 0 ;; esac
  jp_get "${US}runner${US}pid"
  [[ "$JP_GT" == n && "$JP_GV" =~ ^[0-9]{1,9}$ ]] || return 0
  pid="$JP_GV"
  jp_get "${US}runner${US}start_id"
  start=""
  [[ "$JP_GT" == s ]] && start="$JP_GV"
  # If ps cannot even see this shell, it cannot answer for the recorded pid.
  [[ -n "$(proc_start_id $$)" ]] || return 0
  cur="$(proc_start_id "$pid")"
  if [[ -z "$cur" || ( -n "$start" && "$cur" != "$start" ) ]]; then
    diag_add runner_not_observed "runtime/state.json records a $S_RUNNER_STATE runner but no matching process was found; ownership is retained" "runtime/state.json"
    S_RUNNER_STATE=unknown
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

# config_check — structural validity of the parsed runtime/config.json.
# config_verify (consumer dispatch section) adds what only this host can judge:
# the executable, the cwd and the environment names. status runs both; they
# stat paths and write nothing.
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
  if ! config_check || ! config_verify; then
    C_VALID=false
    diag_add consumer_config_invalid "runtime/config.json: $VERR" "$rel"
  fi
  return 0
}

# out_unclaimed CLAIMED — sets UNCL_SET to the out/ directories (not .landing)
# that CLAIMED, a US-delimited list of out/ paths, does not name, each as
# US out/NAME US. One sort and one comm instead of a substring search per entry
# (that search grows with the square of the journal). A name holding a newline
# cannot travel through those tools and is checked the slow way, as is every
# name on a host without comm or sort: slower, never wrong.
UNCL_SET=""
out_unclaimed() {
  local entry name cand="" line fast=1
  UNCL_SET=""
  if ! command -v comm >/dev/null 2>&1 || ! command -v sort >/dev/null 2>&1 || ! command -v tr >/dev/null 2>&1; then fast=0; fi
  shopt -s nullglob
  for entry in "$OUT"/*; do
    [[ -d "$entry" ]] || continue
    name="${entry##*/}"
    [[ "$name" == *.landing ]] && continue
    if (( ! fast )) || [[ "$name" == *$'\n'* ]]; then
      if [[ "$1" != *"$US""out/$name""$US"* ]]; then UNCL_SET+="$US""out/$name""$US"; fi
      continue
    fi
    cand+="out/$name"$'\n'
  done
  if [[ -n "$cand" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      UNCL_SET+="$US$line$US"
    done < <( LC_ALL=C comm -23 <(printf '%s' "$cand" | LC_ALL=C sort) <(printf '%s' "$1" | tr "$US" '\n' | LC_ALL=C sort -u) )
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

# delivery_collision_diags OUT_PATH — after delivery_check on a record: one
# out_collision diagnostic per later firing that found this out/ entry already
# present and was recorded without overwriting it.
delivery_collision_diags() {
  local n i k date slot sched what
  jp_get "${US}collisions"
  [[ "$JP_GT" == a ]] || return 0
  n="$JP_GV"
  for (( i = 0; i < n; i++ )); do
    k="${US}collisions${US}$i"
    jp_get "$k${US}schedule_path"; sched=""; [[ "$JP_GT" == s ]] && sched="$JP_GV"
    jp_get "$k${US}date"; date=""; [[ "$JP_GT" == s ]] && date="$JP_GV"
    jp_get "$k${US}slot"; slot=""; [[ "$JP_GT" == s ]] && slot="$JP_GV"
    what="${sched:-a schedule item}${date:+ on $date}${slot:+ slot $slot}"
    diag_add out_collision "$1 already existed when $what fired; the firing was recorded without overwriting it and without a second delivery" "$1"
  done
}

# status_record FILE REL — read one record file for status: its JSON joins
# DELIVERIES, or a diagnostic says why it cannot.
LIVE_IDS=""      # US-delimited ids listed from deliveries/ (a record the runner files meanwhile is not listed twice)
status_record() {
  local f="$1" rel="$2" stem
  stem="${f##*/}"; stem="${stem%.json}"
  if ! read_text "$f"; then
    CONSISTENT=0
    diag_add delivery_record_unreadable "$rel is not a readable regular file" "$rel"
    return 0
  fi
  if ! jp_parse "$TEXT"; then
    CONSISTENT=0
    diag_add delivery_record_malformed "$rel is not valid JSON ($JP_ERR)" "$rel"
    return 0
  fi
  if ! delivery_check "$stem"; then
    CONSISTENT=0
    diag_add delivery_record_malformed "$rel: $VERR" "$rel"
    return 0
  fi
  DELIVERIES+=("$JR")
  REG_LIST+="$US$DEL_PATH$US"
  LIVE_IDS+="$US$stem$US"
  delivery_collision_diags "$DEL_PATH"
  case "$DEL_STATE" in
    pending|in_flight|failed|uncertain)
      if [[ ! -e "$GH_DIR/$DEL_PATH" ]]; then
        diag_add delivery_path_missing "$DEL_PATH is recorded as $DEL_STATE but is not in out/" "$DEL_PATH"
      fi
      ;;
  esac
  return 0
}

inspect_deliveries() {
  local dir="$GH_DIR/runtime/deliveries" f entry name key i stem
  shopt -s nullglob
  for f in "$dir"/*.json; do
    status_record "$f" "runtime/deliveries/${f##*/}"
  done

  # Terminal records the runner filed under done/: the ones its index vouches
  # for (same inode, size, mtime and mode as when it last parsed them) are not
  # parsed again; any other is read exactly like a record in deliveries/.
  DN_DIR="$dir/done"; DN_LAST=""
  done_classify
  if (( DN_LISTING_BAD )); then
    CONSISTENT=0
    diag_add delivery_record_unreadable "runtime/deliveries/done/ could not be listed reliably; refresh before acting" "runtime/deliveries/done"
  fi
  for (( i = 0; i < ${#DN_KEY[@]}; i++ )); do
    key="${DN_KEY[i]#./}"
    [[ "$LIVE_IDS" != *"$US${key%.json}$US"* ]] || continue
    DELIVERIES+=("${DN_VIEW[i]}")
    REG_LIST+="$US${DN_PATH[i]}$US"
  done
  for key in ${DN_TODO[@]+"${DN_TODO[@]}"}; do
    stem="${key#./}"; stem="${stem%.json}"
    [[ "$LIVE_IDS" != *"$US$stem$US"* ]] || continue
    status_record "$DN_DIR/${key#./}" "runtime/deliveries/done/${key#./}"
  done
  for key in ${DN_DUP[@]+"${DN_DUP[@]}"}; do
    CONSISTENT=0
    diag_add delivery_record_malformed "runtime/deliveries/done/${key#./} also exists in runtime/deliveries/" "runtime/deliveries/done/${key#./}"
  done

  # Entries in out/ that no record claims: read-only legacy deliveries.
  # They are not registered here; status never writes.
  out_unclaimed "$REG_LIST"
  for entry in "$OUT"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    [[ "$name" == *.landing ]] && continue
    if [[ ! -d "$entry" ]]; then
      diag_add out_entry_not_directory "out/$name is not a directory, so it is not listed as a delivery" "out/$name"
      continue
    fi
    [[ "$UNCL_SET" == *"$US""out/$name""$US"* ]] || continue
    if ! utf8_valid "$name"; then
      diag_add out_entry_name_not_utf8 "out/$name has a name that is not valid UTF-8, so the runner does not import or hand it off; rename it" "out/$name"
      continue
    fi
    json_str "out/$name"
    DELIVERIES+=("{\"id\":null,\"path\":$JSTR,\"origin\":\"legacy_out\",\"schedule_path\":null,\"occurrence\":null,\"state\":\"pending\",\"reason\":\"unregistered\",\"attempts\":[],\"execution\":\"unknown\"}")
  done

  # Firings the runner could not reconcile are set aside, not guessed at.
  for entry in "$GH_DIR"/runtime/prepared/*.blocked; do
    name="${entry##*/}"
    diag_add firing_reconciliation_error "runtime/prepared/$name is a firing that could not be reconciled; its occurrence stays blocked until an operator deals with it" "runtime/prepared/$name"
  done
  shopt -u nullglob
}

# --- schedule ----------------------------------------------------------------
SCHEDULE=()

# cadence_json PARTS — JR is the item's cadence as a structured object, built
# from the components the grammar walk matched (never by re-parsing the path):
#   axis      daily | weekly | monthly | yearly | once | every
#   day       weekly: mon..sun; monthly: day of month "1".."31"; else null
#   date      yearly: "MM-DD"; once: "YYYY-MM-DD"; else null
#   time      "HH:MM" local when the path names one, else null
#   interval  every: "<N>m" or "<N>h"; else null
#   defaulted true when the axis root supplied a default: weekly→mon,
#             monthly→1, yearly→01-01, once→next tick (date null)
# PARTS empty (an item the grammar did not recognize) gives null.
cadence_json() {
  local parts=() part axis="" day="" date="" time="" interval="" defaulted=false
  if [[ -z "$1" ]]; then JR=null; return 0; fi
  IFS="$US" read -r -a parts <<< "$1"
  for part in "${parts[@]}"; do
    case "$part" in
      axis=*)     axis="${part#axis=}" ;;
      dow=*)      day="${part#dow=}" ;;
      dom=*)      day="${part#dom=}" ;;
      md=*)       date="${part#md=}" ;;
      ymd=*)      date="${part#ymd=}" ;;
      interval=*) interval="${part#interval=}" ;;
      time=*)
        time="${part#time=}"
        [[ "$time" == *-* ]] && time="${time/-/:}" || time="$time:00"
        ;;
    esac
  done
  case "$axis" in
    weekly)  [[ -n "$day" ]]  || { day=mon; defaulted=true; } ;;
    monthly) [[ -n "$day" ]]  || { day=1; defaulted=true; } ;;
    yearly)  [[ -n "$date" ]] || { date=01-01; defaulted=true; } ;;
    once)    [[ -n "$date" ]] || defaulted=true ;;
  esac
  local f v out=""
  for f in axis day date time interval; do
    case "$f" in
      axis) v="$axis" ;; day) v="$day" ;; date) v="$date" ;;
      time) v="$time" ;; interval) v="$interval" ;;
    esac
    if [[ -n "$v" ]]; then json_str "$v"; v="$JSTR"; else v=null; fi
    out+="${out:+,}\"$f\":$v"
  done
  JR="{$out,\"defaulted\":$defaulted}"
}

inspect_schedule() {
  local now_t due_text name src is_once slot k p rel marker marker_rel due_idx i
  local paused_list part paused_json bb fired eligible allowed marker_json
  local item_paths=() item_pauses=() due_src=() due_slot=() found o
  local parts=() item_cads=() cad_json
  now_t="$(now_today)"

  LINT_INCLUDE_PAUSED=1
  lint_scan
  for o in ${LINT_ORPHANS[@]+"${LINT_ORPHANS[@]}"}; do
    rel="${o#"$GH_DIR"/}"
    diag_add schedule_unrecognized_path "$rel does not match the schedule grammar and is listed by 'lint'" "$rel"
  done
  item_paths=(${LINT_ITEMS[@]+"${LINT_ITEMS[@]}"})
  item_pauses=(${LINT_ITEM_PAUSED[@]+"${LINT_ITEM_PAUSED[@]}"})
  item_cads=(${LINT_ITEM_CAD[@]+"${LINT_ITEM_CAD[@]}"})

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
      item_cads+=("")
    fi
  done <<< "$due_text"

  for (( k = 0; k < ${#item_paths[@]}; k++ )); do
    p="${item_paths[k]}"
    rel="${p#"$GH_DIR"/}"
    if ! utf8_valid "$rel"; then
      diag_add schedule_name_not_utf8 "$rel has a name that is not valid UTF-8, so the runner does not fire it; rename it" "$rel"
    fi
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

    cadence_json "${item_cads[k]}"; cad_json="$JR"
    json_str "$rel"; local path_json="$JSTR"
    json_str "${p##*/}"; local id_json="$JSTR"
    SCHEDULE+=("{\"path\":$path_json,\"item_id\":$id_json,\"cadence\":$cad_json,\"paused_by\":[$paused_json],\"eligible_now\":$eligible,\"fired_marker\":$marker_json,\"fired\":$fired,\"firing_allowed\":$allowed,\"blocked_by\":[$bb]}")
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
  rt_detect
  if [[ -z "$GH_RT_MISSING" ]]; then
    GH_CAPABILITIES+=("ownership-v1" "runner-v1" "pause-v1")
    if [[ -n "$GH_ISOLATE" ]]; then
      GH_CAPABILITIES+=("consumer-v1" "delivery-v1")
    fi
  fi
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
  INSTANCE="$(canonical_dir "$GH_DIR")"
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

# ---------------------------------------------------------------------------
# Runtime: ownership, the runner, persistent pause, and the locks beneath them.
#
# Everything here is optional state under .groundhog/runtime/. Locks are
# flock(2) advisory locks on files in runtime/locks/. A flock(2) lock belongs
# to an open file description: this shell opens the lock file on a numbered fd
# (8 = runner lock, 9 = mutation lock) and a short-lived helper (util-linux
# flock(1), else perl) takes the lock on that inherited fd. The lock outlives
# the helper and the OS releases it when the last holder of the description
# dies, so a crashed runner frees it and no PID is ever consulted. The flip
# side: any child that inherits the fd keeps the lock alive after the holder
# dies, so every long-lived child (sleep, later a consumer) must be started
# with `8>&- 9>&-`. Lock files are never deleted.
# ---------------------------------------------------------------------------

LOCK_FD_RUNNER=8
LOCK_FD_MUTATION=9
GH_LOCK_HELPER=""      # flock | perl | empty (no locking available)
GH_HASH_TOOL=""        # sha256sum | shasum | openssl
GH_SYNC_TOOL=""        # perl | sync
GH_RT_MISSING=""       # what the host lacks for ownership-v1/runner-v1/pause-v1
GH_ISOLATE=""          # perl | setsid | empty (no way to start a consumer in its own session)
GH_PERL_BIN=""
GH_SETSID_BIN=""
GH_RT_DETECTED=0
MUT_HELD=0
PASSIVE_PAUSED=false

# rt_detect — decide what this host can do. Nothing is created or run beyond
# version probes, so `capabilities` stays read-only.
rt_detect() {
  (( GH_RT_DETECTED )) && return 0
  GH_RT_DETECTED=1
  local v missing=""
  if command -v flock >/dev/null 2>&1; then
    v="$(flock --version 2>&1 || true)"
    [[ "$v" == *util-linux* ]] && GH_LOCK_HELPER=flock
  fi
  if [[ -z "$GH_LOCK_HELPER" ]] && command -v perl >/dev/null 2>&1 \
     && perl -MFcntl=:flock -e 'exit 0' >/dev/null 2>&1; then
    GH_LOCK_HELPER=perl
  fi
  [[ -n "$GH_LOCK_HELPER" ]] || missing+="${missing:+, }flock(1) from util-linux or perl with Fcntl"
  if command -v sha256sum >/dev/null 2>&1; then GH_HASH_TOOL=sha256sum
  elif command -v shasum >/dev/null 2>&1; then GH_HASH_TOOL=shasum
  elif command -v openssl >/dev/null 2>&1; then GH_HASH_TOOL=openssl
  else missing+="${missing:+, }sha256sum, shasum or openssl"; fi
  if command -v perl >/dev/null 2>&1 && perl -MIO::Handle -e 'exit 0' >/dev/null 2>&1; then GH_SYNC_TOOL=perl
  elif command -v sync >/dev/null 2>&1; then GH_SYNC_TOOL=sync
  else missing+="${missing:+, }perl or sync(1) for durable writes"; fi
  [[ -r /dev/urandom ]] || missing+="${missing:+, }/dev/urandom"
  command -v od >/dev/null 2>&1 || missing+="${missing:+, }od"
  GH_RT_MISSING="$missing"
  # Consumers run in a session of their own (so Ctrl-C on the runner cannot
  # reach them). Bash cannot do that by itself without job control, so a helper
  # is needed: perl's POSIX::setsid (preferred; perl is the lock helper on
  # macOS) or setsid(1). Without one this host offers no consumer-v1.
  if command -v perl >/dev/null 2>&1 && perl -MPOSIX -e 'exit 0' >/dev/null 2>&1; then
    GH_ISOLATE=perl
    GH_PERL_BIN="$(command -v perl)"
  elif command -v setsid >/dev/null 2>&1; then
    GH_ISOLATE=setsid
    GH_SETSID_BIN="$(command -v setsid)"
  fi
  return 0
}

rt_die() { echo "error: $2" >&2; exit "$1"; }

RT_DIR=""; RT_LOCKS=""; RT_STATE=""; RT_ERR=""

rt_paths() {
  RT_DIR="$GH_DIR/runtime"
  RT_LOCKS="$RT_DIR/locks"
  RT_STATE="$RT_DIR/state.json"
  INSTANCE="$(canonical_dir "$GH_DIR")"
}

# rt_begin CMD — common start of the new runtime commands.
rt_begin() {
  GH_BAD_INSTALL_EXIT=2
  resolve_paths
  rt_paths
  rt_detect
  if [[ -n "$GH_RT_MISSING" ]]; then
    rt_die 5 "$1: this host lacks what the runner needs ($GH_RT_MISSING); see README.md. Ownership, runner and pause are not offered here."
  fi
  mkdir -p "$RT_LOCKS" 2>/dev/null || rt_die 6 "$1: cannot create $RT_LOCKS"
}

# --- locks -------------------------------------------------------------------
# lock_open FD FILE — open FILE (created if absent) on FD. Return 0, or 2.
lock_open() {
  { eval "exec $1>>\"\$2\""; } 2>/dev/null || return 2
}

# lock_try FD — one nonblocking exclusive attempt on the open FD.
# Returns 0 acquired, 1 busy, 2 helper error.
lock_try() {
  local rc=0
  case "$GH_LOCK_HELPER" in
    flock) flock -n "$1" || rc=$? ;;
    perl)  perl -MFcntl=:flock -e 'open(my $f, ">&=", $ARGV[0]) or exit 2; flock($f, LOCK_EX|LOCK_NB) or exit 1' "$1" || rc=$? ;;
    *)     rc=2 ;;
  esac
  (( rc <= 1 )) || rc=2
  return "$rc"
}

# lock_runner_try — take runner exclusion without waiting. 0 / 1 busy / 2 error.
lock_runner_try() {
  local rc=0
  lock_open "$LOCK_FD_RUNNER" "$RT_LOCKS/runner.lock" || return 2
  lock_try "$LOCK_FD_RUNNER" || rc=$?
  if (( rc != 0 )); then exec 8>&-; fi
  return "$rc"
}
unlock_runner() { exec 8>&-; }

# lock_mutation — take the short-lived mutation lock, waiting up to about
# three seconds. 0 / 1 busy / 2 error.
lock_mutation() {
  local tries=0 rc
  lock_open "$LOCK_FD_MUTATION" "$RT_LOCKS/mutation.lock" || return 2
  while :; do
    rc=0
    lock_try "$LOCK_FD_MUTATION" || rc=$?
    if (( rc == 0 )); then MUT_HELD=1; return 0; fi
    if (( rc != 1 )); then exec 9>&-; return 2; fi
    tries=$((tries + 1))
    if (( tries >= 30 )); then exec 9>&-; return 1; fi
    sleep 0.1 8>&- 9>&-
  done
}
unlock_mutation() { exec 9>&-; MUT_HELD=0; }

# lock_mutation_or_die CMD
lock_mutation_or_die() {
  local rc=0
  lock_mutation || rc=$?
  case "$rc" in
    0) ;;
    1) rt_die 4 "$1: the instance is busy (another writer holds the mutation lock)" ;;
    *) rt_die 6 "$1: cannot take the mutation lock" ;;
  esac
}

# --- small tools -------------------------------------------------------------
RAND=""
rand_hex() { # BYTES — sets RAND
  RAND="$(od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n')"
  [[ ${#RAND} -eq $(( $1 * 2 )) ]]
}

HASH=""
sha256_text() { # TEXT — sets HASH; the text goes in by stdin, never argv
  case "$GH_HASH_TOOL" in
    sha256sum) HASH="$(printf '%s' "$1" | sha256sum | awk '{print $1}')" ;;
    shasum)    HASH="$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')" ;;
    openssl)   HASH="$(printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}')" ;;
    *)         return 1 ;;
  esac
  [[ "$HASH" =~ ^[0-9a-f]{64}$ ]]
}

# rt_fsync PATH — flush a file or directory to stable storage where the host
# allows (fsync on macOS does not force the drive cache; see README.md).
rt_fsync() {
  case "$GH_SYNC_TOOL" in
    perl) perl -MIO::Handle -e 'open(my $f, "<", $ARGV[0]) or exit 1; $f->sync or exit 1; close($f) or exit 1' "$1" ;;
    sync) sync ;;
    *)    return 1 ;;
  esac
}

# proc_start_id PID — a normalized process start time, or empty. Fixed to UTC
# and the C locale so every caller, whatever its TZ, reads the same string.
proc_start_id() {
  TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//' || true
}

# --- state -------------------------------------------------------------------
# R_* hold what the status reader drops: the verifier, the raw label, the
# generation counter and the runner's diagnostics. S_* (shared with status)
# hold revision, pause, runner state and last_error.
R_OWNER_ID=""; R_OWNER_GEN=0; R_OWNER_LABEL=""; R_VERIFIER=""; R_LASTGEN=0
R_RUNNER_ID=""; R_RUNNER_PID=""; R_RUNNER_START=""; R_STOPREQ=""

state_defaults() {
  S_REV=0; S_PAUSED=false; S_OWNER=null; S_OWNER_PRESENT=0
  S_RUNNER_STATE=stopped; S_RUNNER_ERROR=null; S_DIGEST=null; S_VALID=1
  R_OWNER_ID=""; R_OWNER_GEN=0; R_OWNER_LABEL=""; R_VERIFIER=""; R_LASTGEN=0
  R_RUNNER_ID=""; R_RUNNER_PID=""; R_RUNNER_START=""; R_STOPREQ=""
}

# rt_load — read runtime/state.json for a control command. Absent means
# defaults. Returns 1 with RT_ERR set when the file is unusable: control
# commands fail closed (exit 5) and never overwrite it.
rt_load() {
  state_defaults
  RT_ERR=""
  [[ -e "$RT_STATE" || -L "$RT_STATE" ]] || return 0
  if ! read_text "$RT_STATE"; then RT_ERR="runtime/state.json exists but is not a readable regular file"; return 1; fi
  if ! jp_parse "$TEXT"; then RT_ERR="runtime/state.json is not valid JSON ($JP_ERR)"; return 1; fi
  if ! state_check; then RT_ERR="runtime/state.json: $VERR"; return 1; fi
  jp_get "${US}instance"
  if [[ "$JP_GT" == s && "$JP_GV" != "$INSTANCE" ]] && (( S_OWNER_PRESENT )); then
    RT_ERR="runtime/state.json is bound to a different instance directory"; return 1
  fi
  if (( S_OWNER_PRESENT )); then
    jp_get "${US}owner${US}id";             R_OWNER_ID="$JP_GV"
    jp_get "${US}owner${US}generation";     R_OWNER_GEN="$JP_GV"
    jp_get "${US}owner${US}label";          [[ "$JP_GT" == s ]] && R_OWNER_LABEL="$JP_GV"
    jp_get "${US}owner${US}token_verifier"
    if [[ "$JP_GT" != s || -z "$JP_GV" ]]; then RT_ERR="runtime/state.json: owner has no verifier"; return 1; fi
    R_VERIFIER="$JP_GV"
  fi
  jp_get "${US}last_generation"
  if [[ "$JP_GT" == n && "$JP_GV" =~ ^[0-9]{1,15}$ ]]; then R_LASTGEN="$JP_GV"; fi
  if (( R_OWNER_GEN > R_LASTGEN )); then R_LASTGEN="$R_OWNER_GEN"; fi
  jp_get "${US}runner${US}id";                 [[ "$JP_GT" == s ]] && R_RUNNER_ID="$JP_GV"
  jp_get "${US}runner${US}pid";                [[ "$JP_GT" == n && "$JP_GV" =~ ^[0-9]{1,9}$ ]] && R_RUNNER_PID="$JP_GV"
  jp_get "${US}runner${US}start_id";           [[ "$JP_GT" == s ]] && R_RUNNER_START="$JP_GV"
  jp_get "${US}runner${US}stop_requested_for"; [[ "$JP_GT" == s ]] && R_STOPREQ="$JP_GV"
  return 0
}

str_or_null() { # TEXT — sets JR to a JSON string, or null for empty
  if [[ -z "$1" ]]; then JR=null; else json_str "$1"; JR="$JSTR"; fi
}

# rt_save — write state from S_*/R_* with revision + 1, atomically: temp file
# in the same directory, fsync, rename, fsync the directory.
# Returns 0; 1 = failed before the replacement (state.json untouched);
# 2 = the replacement was attempted, so the outcome is uncertain.
rt_save() {
  local rev=$((S_REV + 1)) inst owner id pid start stopreq label tmp doc
  json_str "$INSTANCE"; inst="$JSTR"
  if (( S_OWNER_PRESENT )); then
    json_str "$R_OWNER_ID"; id="$JSTR"
    str_or_null "$R_OWNER_LABEL"; label="$JR"
    json_str "$R_VERIFIER"; owner="{\"id\":$id,\"generation\":$R_OWNER_GEN,\"label\":$label,\"token_verifier\":$JSTR}"
  else
    owner=null
  fi
  str_or_null "$R_RUNNER_ID"; id="$JR"
  pid="${R_RUNNER_PID:-null}"
  str_or_null "$R_RUNNER_START"; start="$JR"
  str_or_null "$R_STOPREQ"; stopreq="$JR"
  doc="{\"schema_version\":1,\"revision\":$rev,\"instance\":$inst,\"paused\":$S_PAUSED,\"last_generation\":$R_LASTGEN,\"owner\":$owner,\"runner\":{\"state\":\"$S_RUNNER_STATE\",\"last_error\":$S_RUNNER_ERROR,\"id\":$id,\"pid\":$pid,\"start_id\":$start,\"stop_requested_for\":$stopreq},\"config_digest\":$S_DIGEST}"
  tmp="$RT_DIR/.state.json.$$.tmp"
  rm -f "$tmp"
  if ! printf '%s\n' "$doc" > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  if ! rt_fsync "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv -f "$tmp" "$RT_STATE" 2>/dev/null; then rm -f "$tmp"; return 2; fi
  S_REV="$rev"
  rt_fsync "$RT_DIR" || return 2
  return 0
}

# rt_save_or_die CMD — for commands whose failure is a plain I/O error.
rt_save_or_die() {
  local rc=0
  rt_save || rc=$?
  if (( rc != 0 )); then rt_die 6 "$1: could not write runtime/state.json (it may or may not have changed; run status to see)"; fi
}

# --- tokens ------------------------------------------------------------------
TOK_SECRET=""; TOK_OWNER_ID=""; TOK_GEN=""; TOK_VERIFIER=""

# token_read FILE — load the private token file. Exits 2 for an unusable file
# and 3 for a token that belongs to another instance. The secret stays in shell
# variables: never exported, never in argv, never printed.
token_read() {
  local f="$1" inst
  if ! read_text "$f"; then rt_die 2 "the token file is missing or not a readable file"; fi
  if ! jp_parse "$TEXT"; then TEXT=""; rt_die 2 "the token file is not valid JSON"; fi
  jp_get "${US}schema_version"; [[ "$JP_GT" == n && "$JP_GV" == 1 ]] || { TEXT=""; rt_die 2 "the token file has an unsupported schema_version"; }
  jp_get "${US}token";       [[ "$JP_GT" == s && -n "$JP_GV" ]] || { TEXT=""; rt_die 2 "the token file has no token"; }
  TOK_SECRET="$JP_GV"
  jp_get "${US}instance";    [[ "$JP_GT" == s && -n "$JP_GV" ]] || { TEXT=""; rt_die 2 "the token file names no instance"; }
  inst="$JP_GV"
  jp_get "${US}owner_id";    [[ "$JP_GT" == s && -n "$JP_GV" ]] || { TEXT=""; rt_die 2 "the token file has no owner_id"; }
  TOK_OWNER_ID="$JP_GV"
  jp_get "${US}generation";  [[ "$JP_GT" == n && "$JP_GV" =~ ^[0-9]{1,15}$ ]] || { TEXT=""; rt_die 2 "the token file has no generation"; }
  TOK_GEN="$JP_GV"
  TEXT=""; JP_S=""; JP_K=(); JP_T=(); JP_V=()
  if [[ "$inst" != "$INSTANCE" ]]; then rt_die 3 "the token belongs to a different instance"; fi
  sha256_text "$TOK_OWNER_ID"$'\n'"$TOK_SECRET" || rt_die 6 "cannot hash the token"
  TOK_VERIFIER="sha256:$HASH"
}

# token_verify — after rt_load: does the token match the current owner?
token_verify() {
  (( S_OWNER_PRESENT )) || return 1
  [[ "$R_OWNER_ID" == "$TOK_OWNER_ID" && "$R_OWNER_GEN" == "$TOK_GEN" && "$R_VERIFIER" == "$TOK_VERIFIER" ]]
}

# control_open CMD — under the mutation lock: load state, check the token.
# Exits 5 (unusable state) or 3 (stale token / not owned). Caller holds the lock.
control_check() {
  rt_load || { unlock_mutation; rt_die 5 "$1: $RT_ERR"; }
  token_verify || { unlock_mutation; rt_die 3 "$1: the token does not match the current owner (not owned, or a stale token)"; }
}

# --- options -----------------------------------------------------------------
OPT_TOKEN_FILE=""; OPT_LABEL=""; OPT_INTERVAL=""; OPT_DELIVERY=""; OPT_DECISION=""
# parse_opts CMD ALLOWED… -- ARGS… — every option takes one value and may
# appear once. Unknown options and stray arguments exit 2.
parse_opts() {
  local cmd="$1" allowed=" " name
  shift
  while [[ "$1" != -- ]]; do allowed+="$1 "; shift; done
  shift
  OPT_TOKEN_FILE=""; OPT_LABEL=""; OPT_INTERVAL=""; OPT_DELIVERY=""; OPT_DECISION=""
  while (( $# )); do
    case "$1" in
      --token-file|--owner-label|--interval-seconds|--delivery|--decision)
        name="${1#--}"
        [[ "$allowed" == *" $name "* ]] || rt_die 2 "$cmd: unknown option '$1'"
        (( $# >= 2 )) && [[ -n "$2" ]] || rt_die 2 "$cmd: $1 needs a value"
        case "$name" in
          token-file)       [[ -z "$OPT_TOKEN_FILE" ]] || rt_die 2 "$cmd: --token-file given more than once"; OPT_TOKEN_FILE="$2" ;;
          owner-label)      [[ -z "$OPT_LABEL" ]]      || rt_die 2 "$cmd: --owner-label given more than once"; OPT_LABEL="$2" ;;
          interval-seconds) [[ -z "$OPT_INTERVAL" ]]   || rt_die 2 "$cmd: --interval-seconds given more than once"; OPT_INTERVAL="$2" ;;
          delivery)         [[ -z "$OPT_DELIVERY" ]]   || rt_die 2 "$cmd: --delivery given more than once"; OPT_DELIVERY="$2" ;;
          decision)         [[ -z "$OPT_DECISION" ]]   || rt_die 2 "$cmd: --decision given more than once"; OPT_DECISION="$2" ;;
        esac
        shift 2
        ;;
      *) rt_die 2 "$cmd: unknown option or argument '$1'" ;;
    esac
  done
}

# --- passive callers ---------------------------------------------------------
# passive_enter CMD — for tick, init, add, drop and sweep. Where locking exists:
# take the mutation lock (held until this process exits), refuse while the
# instance is owned (exit 3) or its state is unusable (exit 5), and note the
# global pause for tick. Without locking the legacy behavior is unchanged.
passive_enter() {
  rt_paths
  rt_detect
  [[ -n "$GH_LOCK_HELPER" ]] || return 0
  mkdir -p "$RT_LOCKS" 2>/dev/null || rt_die 6 "$1: cannot create $RT_LOCKS"
  lock_mutation_or_die "$1"
  rt_load || rt_die 5 "$1: $RT_ERR"
  if (( S_OWNER_PRESENT )); then
    rt_die 3 "$1: this instance is owned; its runner ticks under the owner's token, and v1 has no supervised schedule edit"
  fi
  PASSIVE_PAUSED="$S_PAUSED"
}

# --- enroll, pause, resume, stop, release -----------------------------------
cmd_enroll() {
  parse_opts enroll token-file owner-label -- "$@"
  [[ -n "$OPT_LABEL" ]]      || rt_die 2 "enroll: --owner-label is required"
  [[ -n "$OPT_TOKEN_FILE" ]] || rt_die 2 "enroll: --token-file is required"
  [[ "$OPT_TOKEN_FILE" == /* ]] || rt_die 2 "enroll: --token-file must be an absolute path"
  (( ${#OPT_LABEL} <= 256 )) || rt_die 2 "enroll: --owner-label is longer than 256 characters"
  rt_begin enroll

  local tdir="${OPT_TOKEN_FILE%/*}" tdir_real
  [[ -n "$tdir" ]] || tdir=/
  [[ -d "$tdir" ]] || rt_die 2 "enroll: the token file's directory must already exist"
  tdir_real="$(cd "$tdir" && pwd -P)"
  case "$tdir_real/" in
    "$INSTANCE"/*) rt_die 2 "enroll: the token file must live outside the instance" ;;
  esac
  if [[ -e "$OPT_TOKEN_FILE" || -L "$OPT_TOKEN_FILE" ]]; then
    rt_die 2 "enroll: the token file already exists; enroll needs an absent path"
  fi

  lock_mutation_or_die enroll
  rt_load || { unlock_mutation; rt_die 5 "enroll: $RT_ERR"; }
  if (( S_OWNER_PRESENT )); then
    unlock_mutation
    rt_die 3 "enroll: the instance already has an owner (id $R_OWNER_ID); stopped or not, only its token can control it"
  fi

  local gen=$((R_LASTGEN + 1)) oid secret verifier doc
  rand_hex 8  || { unlock_mutation; rt_die 6 "enroll: cannot read random bytes"; }
  oid="o-$RAND"
  rand_hex 32 || { unlock_mutation; rt_die 6 "enroll: cannot read random bytes"; }
  secret="$RAND"
  sha256_text "$oid"$'\n'"$secret" || { unlock_mutation; rt_die 6 "enroll: cannot hash the token"; }
  verifier="sha256:$HASH"

  # 1. The complete usable token file, durably, mode 0600, before any owner.
  json_str "$INSTANCE"
  doc="{\"schema_version\":1,\"token\":\"$secret\",\"instance\":$JSTR,\"owner_id\":\"$oid\",\"generation\":$gen}"
  if ! ( umask 077; set -C; printf '%s\n' "$doc" > "$OPT_TOKEN_FILE" ) 2>/dev/null; then
    unlock_mutation; rt_die 6 "enroll: cannot create the token file (no ownership was granted)"
  fi
  doc=""
  if ! chmod 600 "$OPT_TOKEN_FILE" 2>/dev/null || ! rt_fsync "$OPT_TOKEN_FILE" || ! rt_fsync "$tdir_real"; then
    rm -f "$OPT_TOKEN_FILE"
    unlock_mutation; rt_die 6 "enroll: cannot make the token file durable (no ownership was granted)"
  fi

  # 2. The owner record, by atomic replacement.
  S_OWNER_PRESENT=1
  R_OWNER_ID="$oid"; R_OWNER_GEN="$gen"; R_OWNER_LABEL="$OPT_LABEL"; R_VERIFIER="$verifier"; R_LASTGEN="$gen"
  local rc=0
  rt_save || rc=$?
  unlock_mutation
  if (( rc == 1 )); then
    rm -f "$OPT_TOKEN_FILE"
    rt_die 6 "enroll: could not write runtime/state.json; no ownership was granted"
  elif (( rc != 0 )); then
    echo "error: enroll: the owner record may have been written; keep the token file ($OPT_TOKEN_FILE), start nothing, and reconcile with 'status --json' (owner id $oid, generation $gen)" >&2
    exit 7
  fi
  echo "enrolled: owner $oid, generation $gen"
}

cmd_setpause() { # true|false
  local want="$1" cmd=pause
  [[ "$want" == false ]] && cmd=resume
  parse_opts "$cmd" token-file -- "${@:2}"
  [[ -n "$OPT_TOKEN_FILE" ]] || rt_die 2 "$cmd: --token-file is required"
  rt_begin "$cmd"
  token_read "$OPT_TOKEN_FILE"
  lock_mutation_or_die "$cmd"
  control_check "$cmd"
  if [[ "$S_PAUSED" != "$want" ]]; then
    S_PAUSED="$want"
    rt_save_or_die "$cmd"
  fi
  unlock_mutation
  if [[ "$want" == true ]]; then echo "paused"; else echo "resumed"; fi
}

cmd_stop() {
  parse_opts stop token-file -- "$@"
  [[ -n "$OPT_TOKEN_FILE" ]] || rt_die 2 "stop: --token-file is required"
  rt_begin stop
  token_read "$OPT_TOKEN_FILE"
  local rc
  while :; do
    # Write the request under mutation, holding nothing else...
    lock_mutation_or_die stop
    control_check stop
    case "$S_RUNNER_STATE" in
      running|stopping)
        if [[ -n "$R_RUNNER_ID" && "$R_STOPREQ" != "$R_RUNNER_ID" ]]; then
          R_STOPREQ="$R_RUNNER_ID"
          S_RUNNER_STATE=stopping
          rt_save_or_die stop
        fi
        ;;
    esac
    unlock_mutation
    # ...then wait, without holding mutation, for runner exclusion to be free.
    rc=0
    lock_runner_try || rc=$?
    if (( rc == 0 )); then
      # No runner is alive. Settle the record (runner, then mutation).
      lock_mutation_or_die stop
      control_check stop
      case "$S_RUNNER_STATE" in
        running|stopping|unknown)
          S_RUNNER_STATE=stopped
          R_RUNNER_ID=""; R_RUNNER_PID=""; R_RUNNER_START=""; R_STOPREQ=""
          rt_save_or_die stop
          ;;
        *)
          if [[ -n "$R_STOPREQ" ]]; then R_STOPREQ=""; rt_save_or_die stop; fi
          ;;
      esac
      unlock_mutation
      unlock_runner
      echo "stopped"
      return 0
    elif (( rc != 1 )); then
      rt_die 6 "stop: cannot test the runner lock"
    fi
    sleep 0.2 8>&- 9>&-
  done
}

# unresolved_attempt_exists — true when any delivery holds an unresolved attempt
# (the delivery is in_flight or uncertain, or an attempt is still in_flight), or
# a record cannot be read (unreadable evidence is never taken for "resolved").
unresolved_attempt_exists() {
  local f key
  shopt -s nullglob
  for f in "$RT_DIR"/deliveries/*.json; do
    if ! drec_load "$f" || drec_unresolved; then shopt -u nullglob; return 0; fi
  done
  shopt -u nullglob
  # Filed records are settled; only ones the cache does not vouch for are read.
  DN_DIR="$RT_DIR/deliveries/done"; DN_LAST=""
  done_classify
  (( ! DN_LISTING_BAD )) || return 0
  (( ${#DN_DUP[@]} == 0 )) || return 0
  for key in ${DN_TODO[@]+"${DN_TODO[@]}"}; do
    if ! drec_load "$DN_DIR/${key#./}" || drec_unresolved; then return 0; fi
  done
  return 1
}

cmd_release() {
  parse_opts release token-file -- "$@"
  [[ -n "$OPT_TOKEN_FILE" ]] || rt_die 2 "release: --token-file is required"
  rt_begin release
  token_read "$OPT_TOKEN_FILE"
  local rc=0
  lock_runner_try || rc=$?
  if (( rc == 1 )); then rt_die 4 "release: a runner is still alive; stop it first"; fi
  (( rc == 0 )) || rt_die 6 "release: cannot test the runner lock"
  lock_mutation_or_die release
  control_check release
  if unresolved_attempt_exists; then
    unlock_mutation
    rt_die 5 "release: a delivery attempt is unresolved (in flight or uncertain); recover it first. Ownership is retained."
  fi
  S_OWNER_PRESENT=0
  R_OWNER_ID=""; R_OWNER_GEN=0; R_OWNER_LABEL=""; R_VERIFIER=""
  S_RUNNER_STATE=stopped; S_RUNNER_ERROR=null
  R_RUNNER_ID=""; R_RUNNER_PID=""; R_RUNNER_START=""; R_STOPREQ=""
  rt_save_or_die release
  unlock_mutation
  unlock_runner
  echo "released; delete the token file, which no longer authorizes anything"
}

# ---------------------------------------------------------------------------
# Consumer dispatch: configuration, the delivery journal, serial handoff,
# retry and recovery.
#
# Delivery records live in runtime/deliveries/<id>.json (one file per delivery,
# replaced atomically); the runner files accepted and missing ones under
# runtime/deliveries/done/ (see "terminal records" below). A firing the runner makes is first written to
# runtime/prepared/<id>.json, copied into runtime/staging/<id>/, renamed into
# out/, marked in fired/, recorded as a delivery, and only then is the prepared
# record removed; every step can be redone or finished by the next run. While a
# runner is live it is the only writer of delivery records (retry, recover,
# release and sweep all refuse or wait for a stopped runner), so it keeps an
# in-memory index (IX_*) of them for a cycle and reads them without the mutation
# lock, taking the lock only for the writes (recon_scan, recon_apply).
# ---------------------------------------------------------------------------

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- consumer configuration ---------------------------------------------------
CFG_PRESENT=0
CFG_ARGV=()
CFG_ENV=()
CFG_CWD=""
CFG_DIGEST=""
RESERVED_ENV=" GROUNDHOG_INSTANCE GROUNDHOG_DELIVERY_ID GROUNDHOG_ATTEMPT_ID "

# config_verify — after config_check accepted the parsed document: the parts
# only this host can judge (executable, cwd, environment names). Fills CFG_ARGV,
# CFG_ENV and CFG_CWD. Returns 1 with VERR set (field names, never values).
# Needs INSTANCE (the canonical instance directory). Writes nothing.
config_verify() {
  local n i key name
  CFG_ARGV=(); CFG_ENV=(); CFG_CWD=""
  jp_get "${US}consumer${US}argv"
  n="$JP_GV"
  for (( i = 0; i < n; i++ )); do
    jp_get "${US}consumer${US}argv${US}$i"
    CFG_ARGV+=("$JP_GV")
  done
  if [[ ! -f "${CFG_ARGV[0]}" || ! -x "${CFG_ARGV[0]}" ]]; then
    VERR="consumer.argv[0] is not an existing executable file"
    return 1
  fi
  jp_get "${US}consumer${US}cwd"
  CFG_CWD="$( CDPATH=; cd "$INSTANCE" 2>/dev/null && cd -- "$JP_GV" 2>/dev/null && pwd -P )" || CFG_CWD=""
  if [[ -z "$CFG_CWD" ]]; then
    VERR="consumer.cwd does not name an existing directory"
    return 1
  fi
  n=${#JP_K[@]}
  for (( i = 0; i < n; i++ )); do
    key="${JP_K[i]}"
    [[ "$key" == "${US}consumer${US}env${US}"* ]] || continue
    name="${key#"${US}consumer${US}env${US}"}"
    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      VERR="consumer.env has a name that is not a plain identifier"
      return 1
    fi
    if [[ "$RESERVED_ENV" == *" $name "* ]]; then
      VERR="consumer.env names a reserved variable ($name)"
      return 1
    fi
    CFG_ENV+=("$name=${JP_V[i]}")
  done
  return 0
}

# runner_config_load — startup: read, validate and freeze runtime/config.json.
# No file means no consumer (delivery only). Returns 1 with RUNNER_CFG_ERR set
# when the file is present but unusable.
RUNNER_CFG_ERR=""
runner_config_load() {
  local f="$RT_DIR/config.json"
  CFG_PRESENT=0; CFG_DIGEST=""
  [[ -e "$f" || -L "$f" ]] || return 0
  if ! read_text "$f"; then RUNNER_CFG_ERR="runtime/config.json exists but is not a readable regular file"; return 1; fi
  sha256_text "$TEXT" || { RUNNER_CFG_ERR="cannot hash runtime/config.json"; return 1; }
  CFG_DIGEST="sha256:$HASH"
  if ! jp_parse "$TEXT"; then RUNNER_CFG_ERR="runtime/config.json is not valid JSON ($JP_ERR)"; return 1; fi
  if ! config_check; then RUNNER_CFG_ERR="runtime/config.json: $VERR"; return 1; fi
  if ! config_verify; then RUNNER_CFG_ERR="runtime/config.json: $VERR"; return 1; fi
  CFG_PRESENT=1
  return 0
}

# --- small helpers -------------------------------------------------------------
# rt_atomic_write FILE TEXT — temp file, fsync, rename, fsync the directory.
# Returns 0; 1 = nothing was replaced; 2 = the replacement may have happened.
rt_atomic_write() {
  local f="$1" dir tmp
  dir="${f%/*}"
  tmp="$dir/.${f##*/}.$$.tmp"
  rm -f "$tmp"
  if ! printf '%s\n' "$2" > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  if ! rt_fsync "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! mv -f "$tmp" "$f" 2>/dev/null; then rm -f "$tmp"; return 2; fi
  rt_fsync "$dir" || return 2
  return 0
}

# src_generation DIR — inode and modification time, enough to tell a replaced
# schedule directory from the one that was copied.
src_generation() {
  stat -c '%i %Y' -- "$1" 2>/dev/null || stat -f '%i %m' -- "$1" 2>/dev/null || true
}

# opt_json VALUE — JSON for a string, or null when VALUE is empty. Sets JR.
opt_json() { str_or_null "$1"; }

# --- delivery records --------------------------------------------------------
D_ID=""; D_PATH=""; D_ORIGIN="runtime"; D_SCHED=""; D_HASOCC=0; D_DATE=""; D_SLOT=""
D_STATE="pending"; D_REASON=""; D_REGAT=""; D_MARKER=""
D_COLL=()            # one per out_collision: date US slot US schedule_path
D_FILE=""            # the file drec_load read; drec_save writes back to it
A_ID=(); A_START=(); A_FIN=(); A_OUT=(); A_EXIT=(); A_SIG=(); A_ERR=(); A_DEC=(); A_DECAT=()

drec_reset() {
  D_ID=""; D_PATH=""; D_ORIGIN="runtime"; D_SCHED=""; D_HASOCC=0; D_DATE=""; D_SLOT=""
  D_STATE="pending"; D_REASON=""; D_REGAT=""; D_MARKER=""
  D_COLL=(); D_FILE=""
  A_ID=(); A_START=(); A_FIN=(); A_OUT=(); A_EXIT=(); A_SIG=(); A_ERR=(); A_DEC=(); A_DECAT=()
}

# rawstr KEY — the string at KEY ("" for null or absent) in RAWS. Returns 1 if
# the value has another type.
RAWS=""
rawstr() {
  jp_get "$1"
  case "$JP_GT" in
    ""|z) RAWS="" ;;
    s)    RAWS="$JP_GV" ;;
    *)    return 1 ;;
  esac
}

# drec_load FILE — parse a delivery record into D_* and A_*. Returns 1 if the
# file is unreadable, malformed or of a shape the runtime does not write; such
# a record is never rewritten and fails the barrier closed.
drec_load() {
  local f="$1" stem n i k c
  drec_reset
  D_FILE="$f"
  stem="${f##*/}"; stem="${stem%.json}"
  read_text "$f" || return 1
  jp_parse "$TEXT" || return 1
  jp_get ""; [[ "$JP_GT" == o ]] || return 1
  jp_get "${US}schema_version"; [[ "$JP_GT" == n && "$JP_GV" == 1 ]] || return 1
  jp_get "${US}id"; [[ "$JP_GT" == s && "$JP_GV" == "$stem" && -n "$stem" ]] || return 1
  D_ID="$stem"
  jp_get "${US}path"
  [[ "$JP_GT" == s && "$JP_GV" =~ ^out/[^/]+$ && "$JP_GV" != out/. && "$JP_GV" != out/.. ]] || return 1
  D_PATH="$JP_GV"
  jp_get "${US}origin"
  case "$JP_GT:$JP_GV" in
    :|s:runtime) D_ORIGIN=runtime ;;
    s:legacy_out) D_ORIGIN=legacy_out ;;
    *) return 1 ;;
  esac
  rawstr "${US}schedule_path" || return 1; D_SCHED="$RAWS"
  jp_get "${US}occurrence"
  case "$JP_GT" in
    ""|z) D_HASOCC=0 ;;
    o) D_HASOCC=1
       rawstr "${US}occurrence${US}date" || return 1; D_DATE="$RAWS"
       rawstr "${US}occurrence${US}slot" || return 1; D_SLOT="$RAWS" ;;
    *) return 1 ;;
  esac
  jp_get "${US}state"
  case "$JP_GT:$JP_GV" in
    s:pending|s:in_flight|s:accepted|s:failed|s:uncertain|s:missing) D_STATE="$JP_GV" ;;
    *) return 1 ;;
  esac
  rawstr "${US}reason" || return 1; D_REASON="$RAWS"
  rawstr "${US}registered_at" || return 1; D_REGAT="$RAWS"
  rawstr "${US}fired_marker" || return 1; D_MARKER="$RAWS"
  jp_get "${US}attempts"
  case "$JP_GT" in
    "") ;;
    a)
      n="$JP_GV"
      for (( i = 0; i < n; i++ )); do
        k="${US}attempts${US}$i"
        jp_get "$k"; [[ "$JP_GT" == o ]] || return 1
        jp_get "$k${US}id"; [[ "$JP_GT" == s && -n "$JP_GV" ]] || return 1
        A_ID[i]="$JP_GV"
        jp_get "$k${US}started_at"; [[ "$JP_GT" == s ]] || return 1
        A_START[i]="$JP_GV"
        jp_nstr "$k${US}finished_at" || return 1; A_FIN[i]="$JR"
        jp_get "$k${US}outcome"
        case "$JP_GT:$JP_GV" in
          s:in_flight|s:accepted|s:failed|s:unknown) A_OUT[i]="$JP_GV" ;;
          *) return 1 ;;
        esac
        jp_get "$k${US}exit_code"
        case "$JP_GT" in
          ""|z) A_EXIT[i]=null ;;
          n) [[ "$JP_GV" =~ ^-?[0-9]{1,9}$ ]] || return 1; A_EXIT[i]="$JP_GV" ;;
          *) return 1 ;;
        esac
        jp_nstr "$k${US}signal" || return 1; A_SIG[i]="$JR"
        jp_errobj "$k${US}error" || return 1; A_ERR[i]="$JR"
        jp_get "$k${US}decision"
        A_DEC[i]=""; A_DECAT[i]=null
        if [[ -n "$JP_GT" && "$JP_GT" != z ]]; then
          [[ "$JP_GT" == s && ( "$JP_GV" == retry || "$JP_GV" == accept ) ]] || return 1
          A_DEC[i]="$JP_GV"
          jp_nstr "$k${US}decided_at" || return 1; A_DECAT[i]="$JR"
        fi
      done
      ;;
    *) return 1 ;;
  esac
  jp_get "${US}collisions"
  case "$JP_GT" in
    "") ;;
    a)
      n="$JP_GV"
      for (( i = 0; i < n; i++ )); do
        k="${US}collisions${US}$i"
        jp_get "$k"; [[ "$JP_GT" == o ]] || return 1
        rawstr "$k${US}date" || return 1; c="$RAWS"
        rawstr "$k${US}slot" || return 1; c+="$US$RAWS"
        rawstr "$k${US}schedule_path" || return 1; c+="$US$RAWS"
        D_COLL[i]="$c"
      done
      ;;
    *) return 1 ;;
  esac
  return 0
}

# drec_render — the record as JSON text in DREC.
DREC=""
drec_render() {
  local id path origin sched occ state reason regat marker att="" coll="" i n j parts
  json_str "$D_ID"; id="$JSTR"
  json_str "$D_PATH"; path="$JSTR"
  json_str "$D_ORIGIN"; origin="$JSTR"
  str_or_null "$D_SCHED"; sched="$JR"
  if (( D_HASOCC )); then
    str_or_null "$D_DATE"; occ="{\"date\":$JR"
    str_or_null "$D_SLOT"; occ+=",\"slot\":$JR}"
  else
    occ=null
  fi
  json_str "$D_STATE"; state="$JSTR"
  str_or_null "$D_REASON"; reason="$JR"
  str_or_null "$D_REGAT"; regat="$JR"
  str_or_null "$D_MARKER"; marker="$JR"
  n=${#A_ID[@]}
  for (( i = 0; i < n; i++ )); do
    json_str "${A_ID[i]}"; local aid="$JSTR"
    json_str "${A_START[i]}"; local ast="$JSTR"
    json_str "${A_OUT[i]}"; local aout="$JSTR"
    local one="{\"id\":$aid,\"started_at\":$ast,\"finished_at\":${A_FIN[i]},\"outcome\":$aout,\"exit_code\":${A_EXIT[i]},\"signal\":${A_SIG[i]},\"error\":${A_ERR[i]}"
    if [[ -n "${A_DEC[i]}" ]]; then
      json_str "${A_DEC[i]}"; one+=",\"decision\":$JSTR,\"decided_at\":${A_DECAT[i]}"
    fi
    att+="${att:+,}$one}"
  done
  n=${#D_COLL[@]}
  for (( i = 0; i < n; i++ )); do
    IFS="$US" read -r -a parts <<< "${D_COLL[i]}"
    str_or_null "${parts[0]:-}"; local cd="$JR"
    str_or_null "${parts[1]:-}"; local cs="$JR"
    str_or_null "${parts[2]:-}"; local cp="$JR"
    coll+="${coll:+,}{\"date\":$cd,\"slot\":$cs,\"schedule_path\":$cp}"
  done
  DREC="{\"schema_version\":1,\"id\":$id,\"path\":$path,\"origin\":$origin,\"schedule_path\":$sched,\"occurrence\":$occ,\"state\":$state,\"reason\":$reason,\"registered_at\":$regat,\"fired_marker\":$marker,\"attempts\":[$att],\"collisions\":[$coll]}"
}

# drec_save — write the current D_*/A_* durably. Returns 0, 1 or 2 like
# rt_atomic_write.
drec_save() {
  mkdir -p "$RT_DIR/deliveries" 2>/dev/null || return 1
  drec_render
  rt_atomic_write "${D_FILE:-$RT_DIR/deliveries/$D_ID.json}" "$DREC"
}

# drec_locate ID — sets DREC_AT to the file holding delivery ID: the live
# directory, or done/ where the runner files terminal records. Returns 1 if
# neither has it.
DREC_AT=""
drec_locate() {
  DREC_AT="$RT_DIR/deliveries/$1.json"
  [[ -e "$DREC_AT" || -L "$DREC_AT" ]] && return 0
  DREC_AT="$RT_DIR/deliveries/done/$1.json"
  [[ -e "$DREC_AT" || -L "$DREC_AT" ]] && return 0
  DREC_AT="$RT_DIR/deliveries/$1.json"
  return 1
}

# drec_mark_uncertain CODE MESSAGE — the last unresolved attempt has no known
# result: its outcome becomes unknown and the delivery uncertain.
drec_mark_uncertain() {
  local n=${#A_ID[@]} k last=-1 c m
  for (( k = 0; k < n; k++ )); do
    if [[ "${A_OUT[k]}" == in_flight ]]; then last=$k; fi
  done
  json_str "$1"; c="$JSTR"
  json_str "$2"; m="$JSTR"
  if (( last >= 0 )); then
    A_OUT[last]=unknown
    A_ERR[last]="{\"code\":$c,\"message\":$m,\"path\":null}"
  fi
  D_STATE=uncertain
  D_REASON="$1"
}

# drec_unresolved — after drec_load: does this record hold an unresolved attempt?
drec_unresolved() {
  local k
  if [[ "$D_STATE" == in_flight || "$D_STATE" == uncertain ]]; then return 0; fi
  for (( k = 0; k < ${#A_OUT[@]}; k++ )); do
    if [[ "${A_OUT[k]}" == in_flight ]]; then return 0; fi
  done
  return 1
}

# --- the in-memory index (one runner cycle) ------------------------------------
IX_ID=(); IX_STATE=(); IX_PATH=(); IX_REG=(); IX_UN=(); IX_BAD=0
IXI=-1

ix_reset() { IX_ID=(); IX_STATE=(); IX_PATH=(); IX_REG=(); IX_UN=(); IX_BAD=0; IXI=-1; }

# ix_set I — store the loaded record at index I (-1 appends).
ix_set() {
  local i="$1" un=0
  if drec_unresolved; then un=1; fi
  if (( i < 0 )); then i=${#IX_ID[@]}; fi
  IX_ID[i]="$D_ID"; IX_STATE[i]="$D_STATE"; IX_PATH[i]="$D_PATH"; IX_REG[i]="$D_REGAT"; IX_UN[i]="$un"
}

# ix_find_path PATH — sets IXI to the first record claiming PATH whose delivery
# is not missing (a path can be reused after the first generation vanished), or
# -1.
ix_find_path() {
  local i n=${#IX_ID[@]}
  IXI=-1
  for (( i = 0; i < n; i++ )); do
    if [[ "${IX_PATH[i]}" == "$1" && "${IX_STATE[i]}" != missing ]]; then IXI=$i; return 0; fi
  done
  return 0
}

# ix_blocked — is any attempt unresolved, or any record unreadable? Either
# blocks every consumer admission.
ix_blocked() {
  local i n=${#IX_ID[@]}
  if (( IX_BAD > 0 )); then return 0; fi
  for (( i = 0; i < n; i++ )); do
    if [[ "${IX_UN[i]}" == 1 ]]; then return 0; fi
  done
  return 1
}

# ix_next_pending — sets IXI to the oldest pending delivery, or -1.
ix_next_pending() {
  local i n=${#IX_ID[@]} best="" cand
  IXI=-1
  for (( i = 0; i < n; i++ )); do
    [[ "${IX_STATE[i]}" == pending ]] || continue
    cand="${IX_REG[i]}|${IX_ID[i]}"
    if (( IXI < 0 )) || [[ "$cand" < "$best" ]]; then IXI=$i; best="$cand"; fi
  done
  return 0
}

# --- terminal records: runtime/deliveries/done/ --------------------------------
# A delivery that is accepted or missing never changes again. The runner files
# such a record under runtime/deliveries/done/ so the per-cycle scan and the
# admission loops only meet the records that can still change. done/ also holds
# `index`, a cache the runner writes: one line per filed record with the stat
# signature (inode, size, mtime, mode) the file had when the runner last parsed
# it, plus the record's state, path and the JSON status shows for it. A record
# whose signature still matches is trusted without being parsed again; one that
# differs (or has no line) is parsed, and one that cannot be parsed fails the
# barrier closed exactly as an unreadable record in deliveries/ does. Only the
# runner (and a stopped-runner command) writes; status only reads.
STAT_KIND=""; STAT_ARGS=(); STAT_NAME=""; STAT_FMT=""
stat_init() {
  if [[ -n "$STAT_KIND" ]]; then return 0; fi
  if stat -c %i / >/dev/null 2>&1; then
    STAT_KIND=gnu; STAT_ARGS=(-c); STAT_NAME="%n"; STAT_FMT="%i$US%s$US%Y$US%a"
  else
    STAT_KIND=bsd; STAT_ARGS=(-f); STAT_NAME="%N"; STAT_FMT="%i$US%z$US%m$US%Lp"
  fi
}

DN_DIR=""            # <runtime>/deliveries/done, set by the caller
DN_KEY=(); DN_SIG=(); DN_STATE=(); DN_PATH=(); DN_VIEW=()    # trusted or parsed records
DN_TODO=(); DN_TODO_SIG=()    # files whose signature the index does not vouch for
DN_DUP=()                     # files that also exist in deliveries/
DN_BADN=0                     # records in done/ that failed the barrier closed
DN_LAST=""                    # the scan the arrays above describe (runner only)
DN_DIRTY=0                    # the index needs rewriting
DN_LISTING_BAD=0              # the listing of done/ disagrees with the directory

# done_classify — scan done/ (one find, one stat, no parse) and sort each file
# into trusted (DN_*), to-parse (DN_TODO) or duplicate (DN_DUP). A scan equal
# to the previous one reuses the previous arrays untouched.
done_classify() {
  local scan="" joined="" idx key ino size mtime mode xi xs xm xo xstate xpath xview sig f line n_dir=0 n_scan=0 n_join=0
  DN_LISTING_BAD=0
  if [[ ! -d "$DN_DIR" ]]; then
    DN_KEY=(); DN_SIG=(); DN_STATE=(); DN_PATH=(); DN_VIEW=(); DN_TODO=(); DN_TODO_SIG=(); DN_DUP=()
    DN_BADN=0; DN_LAST=""
    return 0
  fi
  stat_init
  scan="$( cd -- "$DN_DIR" 2>/dev/null && find . -maxdepth 1 -name '*.json' -exec stat "${STAT_ARGS[@]}" "$STAT_NAME$US$STAT_FMT" {} + 2>/dev/null | LC_ALL=C sort )" || scan=""
  # The listing is the only evidence of what is filed, so it is checked against
  # a plain glob: a find, stat or sort that failed must not read as "nothing is
  # filed" (every filed delivery's out/ entry would look unclaimed).
  shopt -s nullglob
  for f in "$DN_DIR"/*.json; do n_dir=$((n_dir + 1)); done
  shopt -u nullglob
  if [[ -n "$scan" ]]; then n_scan="$(printf '%s\n' "$scan" | wc -l)"; fi
  if (( n_scan != n_dir )); then
    DN_KEY=(); DN_SIG=(); DN_STATE=(); DN_PATH=(); DN_VIEW=(); DN_TODO=(); DN_TODO_SIG=(); DN_DUP=()
    DN_BADN=0; DN_LAST=""; DN_LISTING_BAD=1
    return 0
  fi
  if [[ -n "$DN_LAST" && "$scan" == "$DN_LAST" ]]; then return 0; fi
  DN_KEY=(); DN_SIG=(); DN_STATE=(); DN_PATH=(); DN_VIEW=(); DN_TODO=(); DN_TODO_SIG=(); DN_DUP=()
  DN_BADN=0; DN_LAST="$scan"
  [[ -n "$scan" ]] || return 0
  idx="$DN_DIR/index"
  if [[ ! -f "$idx" || -L "$idx" ]]; then idx=/dev/null; fi
  joined="$( LC_ALL=C join -t "$US" -a 1 -e '' -o 1.1,1.2,1.3,1.4,1.5,2.2,2.3,2.4,2.5,2.6,2.7,2.8 <(printf '%s\n' "$scan") "$idx" 2>/dev/null )" || joined=""
  n_join="$(printf '%s\n' "$joined" | wc -l)"
  if (( n_scan != n_join )); then
    # join is missing, or lost a line (an index it could not merge): trust
    # nothing from the index and give every listed file an empty index half.
    joined=""
    while IFS= read -r line; do
      joined+="$line$US$US$US$US$US$US$US"$'\n'
    done <<< "$scan"
  fi
  while IFS="$US" read -r key ino size mtime mode xi xs xm xo xstate xpath xview; do
    [[ -n "$key" ]] || continue
    if [[ -e "${DN_DIR%/done}/${key#./}" || -L "${DN_DIR%/done}/${key#./}" ]]; then
      DN_DUP+=("$key"); continue
    fi
    sig="$ino$US$size$US$mtime$US$mode"
    if [[ -n "$xview" && ( "$xstate" == accepted || "$xstate" == missing ) \
          && "$sig" == "$xi$US$xs$US$xm$US$xo" ]]; then
      DN_KEY+=("$key"); DN_SIG+=("$sig"); DN_STATE+=("$xstate"); DN_PATH+=("$xpath"); DN_VIEW+=("$xview")
    else
      DN_TODO+=("$key"); DN_TODO_SIG+=("$sig")
    fi
  done <<< "$joined"
  return 0
}

# done_cacheable — after drec_load and delivery_check: may status reuse this
# record's JSON (JR) without reading the file again? Not when it carries
# collisions (they become diagnostics) or a path the index line cannot hold.
done_cacheable() {
  (( ${#D_COLL[@]} == 0 )) || return 1
  [[ "$D_PATH" != *"$US"* && "$D_PATH" != *$'\n'* ]] || return 1
  return 0
}

# done_parse_runner — parse what the index did not vouch for. A file that does
# not hold a readable, terminal record counts in DN_BADN: it blocks admission.
done_parse_runner() {
  local i key stem
  DN_BADN=$((DN_BADN + ${#DN_DUP[@]}))
  for key in ${DN_DUP[@]+"${DN_DUP[@]}"}; do
    runner_log "delivery record ${key#./} exists in both deliveries/ and deliveries/done/; every consumer admission is blocked until it is dealt with"
  done
  DN_DUP=()
  for (( i = 0; i < ${#DN_TODO[@]}; i++ )); do
    key="${DN_TODO[i]}"
    stem="${key#./}"; stem="${stem%.json}"
    if ! drec_load "$DN_DIR/${key#./}" || ! delivery_check "$stem" \
       || [[ "$D_STATE" != accepted && "$D_STATE" != missing ]] || drec_unresolved; then
      DN_BADN=$((DN_BADN + 1))
      runner_log "delivery record done/${key#./} is unreadable or not a terminal record; every consumer admission is blocked until it is dealt with"
      continue
    fi
    if done_cacheable; then
      DN_KEY+=("$key"); DN_SIG+=("${DN_TODO_SIG[i]}"); DN_STATE+=("$D_STATE"); DN_PATH+=("$D_PATH"); DN_VIEW+=("$JR")
      DN_DIRTY=1
    else
      DN_KEY+=("$key"); DN_SIG+=("${DN_TODO_SIG[i]}"); DN_STATE+=("$D_STATE"); DN_PATH+=("$D_PATH"); DN_VIEW+=("")
    fi
  done
  DN_TODO=(); DN_TODO_SIG=()
  if (( DN_BADN > 0 )); then
    runner_log "$DN_BADN delivery record(s) under deliveries/done/ cannot be trusted; every consumer admission is blocked until they are dealt with"
  fi
}

# done_index_write — rewrite done/index from the trusted records. A cache:
# a failure only costs the next reader a parse.
done_index_write() {
  local i lines="groundhog-done-index 1" text
  for (( i = 0; i < ${#DN_KEY[@]}; i++ )); do
    [[ -n "${DN_VIEW[i]}" ]] || continue
    lines+=$'\n'"${DN_KEY[i]}$US${DN_SIG[i]}$US${DN_STATE[i]}$US${DN_PATH[i]}$US${DN_VIEW[i]}"
  done
  text="$(printf '%s\n' "$lines" | LC_ALL=C sort)" || return 1
  mkdir -p "$DN_DIR" 2>/dev/null || return 1
  rt_atomic_write "$DN_DIR/index" "$text"
}

# done_file_one — after drec_load and delivery_check of a live record that is
# accepted or missing and settled: move it into done/ and remember its
# signature for the index. Returns 1 if it could not be moved.
DN_FILED=0
done_file_one() {
  local f="$1" base sig=""
  base="${f##*/}"
  mkdir -p "$DN_DIR" 2>/dev/null || return 1
  # A copy already filed under this id is evidence, not something to replace;
  # the scan has counted it, so admission stays blocked until it is dealt with.
  if [[ -e "$DN_DIR/$base" || -L "$DN_DIR/$base" ]]; then return 0; fi
  mv -f -- "$f" "$DN_DIR/$base" 2>/dev/null || return 1
  DN_FILED=1
  if done_cacheable; then
    stat_init
    sig="$(stat "${STAT_ARGS[@]}" "$STAT_FMT" "$DN_DIR/$base" 2>/dev/null)" || sig=""
    if [[ -n "$sig" ]]; then
      DN_KEY+=("./$base"); DN_SIG+=("$sig"); DN_STATE+=("$D_STATE"); DN_PATH+=("$D_PATH"); DN_VIEW+=("$JR")
      DN_DIRTY=1
    fi
  fi
  return 0
}

# --- prepared firings ------------------------------------------------------------
P_ID=""; P_OUT=""; P_MARKER=""; P_SCHED=""; P_DATE=""; P_SLOT=""; P_ONCE=false; P_GEN=""
BLOCKED_MARKERS=""      # US-delimited fired-marker paths of blocked firings

prep_load() {
  local f="$1" stem
  stem="${f##*/}"; stem="${stem%.json}"
  read_text "$f" || return 1
  jp_parse "$TEXT" || return 1
  jp_get "${US}schema_version"; [[ "$JP_GT" == n && "$JP_GV" == 1 ]] || return 1
  jp_get "${US}id"; [[ "$JP_GT" == s && "$JP_GV" == "$stem" ]] || return 1
  P_ID="$stem"
  jp_get "${US}out_path"; [[ "$JP_GT" == s && "$JP_GV" =~ ^out/[^/]+$ ]] || return 1
  P_OUT="$JP_GV"
  jp_get "${US}fired_marker"; [[ "$JP_GT" == s && "$JP_GV" == fired/* ]] || return 1
  P_MARKER="$JP_GV"
  jp_get "${US}schedule_path"; [[ "$JP_GT" == s && "$JP_GV" == schedule/* ]] || return 1
  P_SCHED="$JP_GV"
  rawstr "${US}occurrence${US}date" || return 1; P_DATE="$RAWS"
  rawstr "${US}occurrence${US}slot" || return 1; P_SLOT="$RAWS"
  jp_get "${US}once"; [[ "$JP_GT" == b ]] || return 1
  P_ONCE="$JP_GV"
  rawstr "${US}source_generation" || return 1; P_GEN="$RAWS"
  return 0
}

# prep_write ID OUT_REL MARKER_REL SCHED_REL DATE SLOT ONCE GEN
prep_write() {
  local a b c d e f g h
  json_str "$1"; a="$JSTR"; json_str "$2"; b="$JSTR"; json_str "$3"; c="$JSTR"
  json_str "$4"; d="$JSTR"; json_str "$5"; e="$JSTR"; str_or_null "$6"; f="$JR"
  json_str "$8"; h="$JSTR"
  g=false; [[ "$7" == 1 ]] && g=true
  mkdir -p "$RT_DIR/prepared" 2>/dev/null || return 1
  rt_atomic_write "$RT_DIR/prepared/$1.json" "{\"schema_version\":1,\"id\":$a,\"out_path\":$b,\"fired_marker\":$c,\"schedule_path\":$d,\"occurrence\":{\"date\":$e,\"slot\":$f},\"once\":$g,\"source_generation\":$h,\"created_at\":\"$(now_utc)\"}"
}

# prep_block FILE REASON — set a prepared firing aside as blocked: its
# occurrence is not fired again, and status reports it, until an operator deals
# with it (conflicting or corrupt evidence is never guessed at).
prep_block() {
  local f="$1"
  runner_log "firing ${f##*/} could not be reconciled ($2); its occurrence stays blocked (see status)"
  mv -f "$f" "${f%.json}.blocked" 2>/dev/null || true
}

# once_remove SRC GENERATION — remove a fired one-shot's schedule directory
# (and now-empty parents under once/), unless GENERATION is given and the
# directory is no longer the one that was copied.
once_remove() {
  local src="$1" gen="$2" parent
  [[ -d "$src" ]] || return 0
  if [[ -n "$gen" && "$(src_generation "$src")" != "$gen" ]]; then
    runner_log "left ${src#"$GH_DIR"/} in place: it changed since it was fired"
    return 0
  fi
  rm -rf -- "$src"
  parent="$(dirname "$src")"
  while [[ "$parent" != "$SCHED/once" && "$parent" == "$SCHED/once/"* ]]; do
    rmdir "$parent" 2>/dev/null || break
    parent="$(dirname "$parent")"
  done
  return 0
}

# firing_complete — finish a firing whose out/ entry exists: marker, delivery
# record, one-shot removal, then forget the prepared record. Safe to repeat.
# Uses P_*. Returns 1 on an I/O failure.
firing_complete() {
  local markerp="$GH_DIR/$P_MARKER" rec="$RT_DIR/deliveries/$P_ID.json" rc=0
  mkdir -p "$(dirname "$markerp")" || return 1
  [[ -e "$markerp" ]] || touch "$markerp" || return 1
  if [[ ! -e "$rec" ]]; then
    drec_reset
    D_ID="$P_ID"; D_PATH="$P_OUT"; D_ORIGIN=runtime; D_SCHED="$P_SCHED"; D_HASOCC=1
    D_DATE="$P_DATE"; D_SLOT="$P_SLOT"; D_STATE=pending; D_REASON=""; D_REGAT="$(now_utc)"; D_MARKER="$P_MARKER"
    if (( ! CFG_PRESENT )); then D_REASON=no_consumer; fi
    drec_save || rc=$?
    (( rc == 0 )) || return 1
    ix_set -1
  fi
  if [[ "$P_ONCE" == true ]]; then once_remove "$GH_DIR/$P_SCHED" "$P_GEN"; fi
  rm -f "$RT_DIR/prepared/$P_ID.json"
  return 0
}

# --- reconciliation (the first step of every cycle) ----------------------------
recon_prepared() {
  local f
  BLOCKED_MARKERS=""
  shopt -s nullglob
  for f in "$RT_DIR"/prepared/*.blocked; do
    if read_text "$f" && jp_parse "$TEXT"; then
      jp_get "${US}fired_marker"
      if [[ "$JP_GT" == s ]]; then BLOCKED_MARKERS+="$US$JP_GV$US"; fi
    fi
  done
  for f in "$RT_DIR"/prepared/*.json; do
    if ! prep_load "$f"; then prep_block "$f" "unreadable record"; continue; fi
    if [[ -e "$RT_DIR/staging/$P_ID" || -L "$RT_DIR/staging/$P_ID" ]]; then
      # Copy not finished (or not renamed): nothing was exposed. Discard it;
      # the occurrence still has no marker, so the tick fires it afresh.
      rm -rf -- "$RT_DIR/staging/$P_ID"
      rm -f "$f"
      runner_log "discarded an unfinished firing of $P_SCHED"
    elif [[ -d "$GH_DIR/$P_OUT" ]]; then
      if ! firing_complete; then shopt -u nullglob; return 1; fi
      runner_log "completed an interrupted firing of $P_SCHED -> $P_OUT"
    elif [[ -e "$GH_DIR/$P_MARKER" ]]; then
      prep_block "$f" "the fired marker exists but out/ has no matching entry"
      BLOCKED_MARKERS+="$US$P_MARKER$US"
    else
      rm -f "$f"
    fi
  done
  shopt -u nullglob
  return 0
}

# The reconciliation is two steps so the mutation lock is held in short slices
# whatever the journal size. recon_scan reads without the lock (a live runner
# is the only writer of delivery records; retry, recover, release, sweep and
# the standalone tick all refuse or wait for a stopped runner): it builds the
# index IX_* from done/ (trusted by signature, see above) and from the records
# still in deliveries/, and lists the work that needs a write. recon_apply
# then takes the lock for about a second at a time, reloads each record before
# touching it, and lets go in between so pause, stop, retry and recover get in.
WK_KIND=(); WK_IX=(); WK_NAME=()
UTF8_LOGGED=""
RECON_SLICE=1            # seconds of lock hold per slice (SECONDS ticks in whole seconds)

# recon_scan — build the index and the work list. Unreadable records are
# counted (they fail the barrier closed). Writes nothing but done/'s cache.
recon_scan() {
  local f entry name flag k want=""
  ix_reset
  RECON_CLAIMED=""
  WK_KIND=(); WK_IX=(); WK_NAME=()
  if (( ! CFG_PRESENT )); then want=no_consumer; fi
  DN_DIR="$RT_DIR/deliveries/done"
  done_classify
  if (( DN_LISTING_BAD )); then
    IX_BAD=$((IX_BAD + 1))
    runner_log "could not list runtime/deliveries/done/ reliably; every consumer admission is blocked and no out/ entry is imported until it can be"
  fi
  done_parse_runner
  for (( k = 0; k < ${#DN_KEY[@]}; k++ )); do
    f="${DN_KEY[k]#./}"
    IX_ID+=("${f%.json}"); IX_STATE+=("${DN_STATE[k]}"); IX_PATH+=("${DN_PATH[k]}"); IX_REG+=(""); IX_UN+=(0)
    RECON_CLAIMED+="$US${DN_PATH[k]}$US"
  done
  IX_BAD=$((IX_BAD + DN_BADN))
  shopt -s nullglob
  for f in "$RT_DIR"/deliveries/*.json; do
    if ! drec_load "$f"; then
      IX_BAD=$((IX_BAD + 1))
      runner_log "delivery record ${f##*/} is unreadable; every consumer admission is blocked until it is dealt with"
      continue
    fi
    flag=0
    case "$D_STATE" in
      in_flight) flag=1 ;;
      pending)
        if [[ ! -d "$GH_DIR/$D_PATH" || "$D_REASON" != "$want" ]]; then flag=1; fi
        ;;
      accepted|missing)
        if ! drec_unresolved; then flag=1; fi
        ;;
    esac
    ix_set -1
    if (( flag )); then WK_KIND+=(fix); WK_IX+=($(( ${#IX_ID[@]} - 1 ))); WK_NAME+=(""); fi
    RECON_CLAIMED+="$US$D_PATH$US"
  done
  # Complete out/ directories no record claims become pending deliveries with
  # origin legacy_out and an unknown occurrence (metadata only: nothing is
  # marked handed off). A name that is not valid UTF-8 would be stored lossily
  # and imported again every cycle, so it is reported and left alone.
  if (( ! DN_LISTING_BAD )); then out_unclaimed "$RECON_CLAIMED"; else UNCL_SET=""; fi
  for entry in "$OUT"/*; do
    [[ -n "$UNCL_SET" ]] || break
    [[ -d "$entry" ]] || continue
    name="${entry##*/}"
    [[ "$name" == *.landing ]] && continue
    [[ "$UNCL_SET" == *"$US""out/$name""$US"* ]] || continue
    if ! utf8_valid "$name"; then
      if [[ "$UTF8_LOGGED" != *"$US$name$US"* ]]; then
        UTF8_LOGGED+="$US$name$US"
        json_str "out/$name"
        runner_log "not importing $JSTR: its name is not valid UTF-8 (invalid bytes shown as U+FFFD); rename it"
      fi
      continue
    fi
    WK_KIND+=(import); WK_IX+=(-1); WK_NAME+=("$name")
  done
  shopt -u nullglob
  return 0
}

# recon_apply_one I — one item of the work list, under the lock. Returns 1 on
# a journal write failure.
recon_apply_one() {
  local i="$1" kind="${WK_KIND[$1]}" ix="${WK_IX[$1]}" want="" rc=0 changed=0 f name
  if (( ! CFG_PRESENT )); then want=no_consumer; fi
  if [[ "$kind" == import ]]; then
    name="${WK_NAME[i]}"
    rand_hex 8 || return 1
    drec_reset
    D_ID="d-$RAND"; D_PATH="out/$name"; D_ORIGIN=legacy_out; D_STATE=pending
    D_REASON="$want"; D_REGAT="$(now_utc)"
    drec_save || rc=$?
    if (( rc != 0 )); then return 1; fi
    ix_set -1
    RECON_CLAIMED+="$US$D_PATH$US"
    runner_log "imported out/$name as delivery $D_ID (legacy_out)"
    return 0
  fi
  f="$RT_DIR/deliveries/${IX_ID[ix]}.json"
  if ! drec_load "$f"; then
    IX_BAD=$((IX_BAD + 1))
    runner_log "delivery record ${f##*/} is unreadable; every consumer admission is blocked until it is dealt with"
    return 0
  fi
  case "$D_STATE" in
    in_flight)
      drec_mark_uncertain result_not_recorded "the runner that started this attempt ended before recording its result; the consumer may or may not have finished"
      runner_log "delivery $D_ID: its in-flight attempt is now uncertain; recover it explicitly"
      changed=1
      ;;
    pending)
      if [[ ! -d "$GH_DIR/$D_PATH" ]]; then
        D_STATE=missing; D_REASON=path_missing; changed=1
        runner_log "delivery $D_ID: $D_PATH is gone from out/; recorded as missing"
      elif [[ "$D_REASON" != "$want" ]]; then
        D_REASON="$want"; changed=1
      fi
      ;;
  esac
  if (( changed )); then
    drec_save || rc=$?
    if (( rc != 0 )); then return 1; fi
  elif [[ "$D_STATE" == accepted || "$D_STATE" == missing ]] && ! drec_unresolved && delivery_check "${IX_ID[ix]}"; then
    # Settled for good: file it under done/ (it was just read, so the view is current).
    done_file_one "$f" || return 1
  fi
  ix_set "$ix"
  return 0
}

# recon_apply — run the work list in slices of about RECON_SLICE seconds, each
# under the mutation lock, with the lock released (and a short pause for
# waiting commands to take it) between slices. Returns 0 even when the lock
# could not be had or a stop request arrived: what is left is picked up by the
# next cycle. Returns 1 on a journal write failure (the lock is released).
recon_apply() {
  local n=${#WK_KIND[@]} i=0 start
  while (( i < n )); do
    runner_enter || return 0
    start=$SECONDS; DN_FILED=0
    while (( i < n )); do
      if ! recon_apply_one "$i"; then unlock_mutation; return 1; fi
      i=$((i + 1))
      if (( SECONDS - start >= RECON_SLICE )); then break; fi
    done
    if (( DN_FILED )); then
      rt_fsync "$RT_DIR/deliveries" || true
      rt_fsync "$DN_DIR" || true
    fi
    unlock_mutation
    if (( i < n )); then sleep 0.3 8>&- 9>&-; fi
  done
  return 0
}

# recon_done_flush — persist what the scan and the slices learned about done/.
recon_done_flush() {
  if (( DN_DIRTY )); then
    done_index_write || runner_log "could not update runtime/deliveries/done/index; it is a cache and is rebuilt on demand"
    DN_DIRTY=0; DN_LAST=""
  fi
  return 0
}
RECON_CLAIMED=""

# legacy_note_collision OUT_REL SRC_REL DATE SLOT — the standalone tick found
# out/ NAME already taken. On an instance that has delivery records (it was
# supervised once), attach the same out_collision the runner would, so status
# shows the lost firing instead of leaving it to one line on stderr. Never
# fails the tick; an instance without records is left exactly as before.
legacy_note_collision() {
  local f
  [[ -d "$RT_DIR/deliveries" && -n "$GH_LOCK_HELPER" && -z "$GH_RT_MISSING" ]] || return 0
  shopt -s nullglob
  for f in "$RT_DIR"/deliveries/*.json "$RT_DIR"/deliveries/done/*.json; do
    drec_load "$f" || continue
    [[ "$D_PATH" == "$1" && "$D_STATE" != missing ]] || continue
    if (( ${#D_COLL[@]} < 20 )); then
      D_COLL+=("$3$US$4$US$2")
      drec_save || echo "warning: could not record the out_collision for $1" >&2
    fi
    break
  done
  shopt -u nullglob
  return 0
}

# --- the journaled tick --------------------------------------------------------
# Same schedule semantics as tick_body, but every firing is journaled and every
# failure is reported to the caller.
tick_runtime() {
  local now_t name src is_once slot dst marker
  now_t="$(now_today)"
  while IFS=$'\t' read -r name src is_once slot; do
    [[ -n "$name" ]] || continue
    if (( GH_SIGNALED )); then break; fi
    if [[ -n "$slot" ]]; then
      dst="$OUT/${name}-${now_t}-${slot}"
    else
      dst="$OUT/${name}-${now_t}"
    fi
    marker="$(fired_marker_for "$src" "$now_t" "$slot")"
    if ! utf8_valid "${src#"$GH_DIR"/}"; then
      if [[ "$UTF8_LOGGED" != *"$US$src$US"* ]]; then
        UTF8_LOGGED+="$US$src$US"
        json_str "${src#"$GH_DIR"/}"
        runner_log "not firing $JSTR: its name is not valid UTF-8 (invalid bytes shown as U+FFFD); rename it"
      fi
      continue
    fi
    tick_item "$name" "$src" "$is_once" "$slot" "$dst" "$marker" "$now_t" || return 1
  done < <(walk_due)
  return 0
}

tick_item() {
  local name="$1" src="$2" is_once="$3" slot="$4" dst="$5" marker="$6" now_t="$7"
  local out_rel="out/${dst##*/}" marker_rel="${marker#"$GH_DIR"/}" src_rel="${src#"$GH_DIR"/}"
  if [[ "$BLOCKED_MARKERS" == *"$US$marker_rel$US"* ]]; then
    runner_log "skipped $src_rel: an unreconciled firing blocks this occurrence (see status)"
    return 0
  fi
  if [[ -e "$marker" ]]; then
    :   # already fired for this occurrence
  elif [[ -e "$dst" || -L "$dst" ]]; then
    runner_log "warning: out/${dst##*/} already exists; recording the firing of $src_rel without overwrite (out_collision)"
    mkdir -p "$(dirname "$marker")" || return 1
    touch "$marker" || return 1
    tick_note_collision "$out_rel" "$src_rel" "$now_t" "$slot" || return 1
  else
    tick_fire "$name" "$src" "$is_once" "$slot" "$dst" "$marker" "$now_t" "$out_rel" "$marker_rel" "$src_rel" || return 1
    return 0
  fi
  if [[ "$is_once" == "1" ]]; then once_remove "$src" ""; fi
  return 0
}

# tick_note_collision OUT_REL SRC_REL DATE SLOT — attach an out_collision
# diagnostic to the delivery that owns the existing out/ entry. No second
# delivery is invented and no source identity is claimed.
tick_note_collision() {
  local rc=0
  ix_find_path "$1"
  if (( IXI < 0 )); then return 0; fi    # an entry no record claims: status shows it as unregistered
  drec_locate "${IX_ID[IXI]}" || return 0
  drec_load "$DREC_AT" || return 0
  if (( ${#D_COLL[@]} < 20 )); then
    D_COLL+=("$3$US$4$US$2")
    drec_save || rc=$?
    (( rc == 0 )) || return 1
  fi
  return 0
}

tick_fire() {
  local name="$1" src="$2" is_once="$3" slot="$4" dst="$5" marker="$6" now_t="$7"
  local out_rel="$8" marker_rel="$9" src_rel="${10}" id gen rc=0
  rand_hex 8 || return 1
  id="d-$RAND"
  gen="$(src_generation "$src")"
  prep_write "$id" "$out_rel" "$marker_rel" "$src_rel" "$now_t" "$slot" "$is_once" "$gen" || return 1
  mkdir -p "$RT_DIR/staging" || return 1
  rm -rf -- "$RT_DIR/staging/$id"
  cp -R -- "$src" "$RT_DIR/staging/$id" || return 1
  [[ ! -e "$dst" && ! -L "$dst" ]] || return 1
  mv -- "$RT_DIR/staging/$id" "$dst" || return 1
  rt_fsync "$OUT" || return 1
  mkdir -p "$(dirname "$marker")" || return 1
  touch "$marker" || return 1
  drec_reset
  D_ID="$id"; D_PATH="$out_rel"; D_ORIGIN=runtime; D_SCHED="$src_rel"; D_HASOCC=1
  D_DATE="$now_t"; D_SLOT="$slot"; D_STATE=pending; D_REGAT="$(now_utc)"; D_MARKER="$marker_rel"
  if (( ! CFG_PRESENT )); then D_REASON=no_consumer; fi
  drec_save || rc=$?
  (( rc == 0 )) || return 1
  ix_set -1
  rm -f "$RT_DIR/prepared/$id.json"
  if [[ "$is_once" == "1" ]]; then once_remove "$src" "$gen"; fi
  printf 'fired %s -> %s\n' "$name" "$dst" 2>/dev/null || runner_output_gone
  return 0
}

# --- handoff -------------------------------------------------------------------
INFLIGHT_ID=""          # the delivery whose consumer call this runner admitted
INFLIGHT_ATTEMPT=""
CPID=""
CSTATUS=0
H_ID=""; H_ATTEMPT=""; H_PATH=""
BARRIER_LOGGED=0

# consumer_start DELIVERY_ABS ID ATTEMPT — start the configured consumer as a
# background job of its own session, sets CPID. The child gets: cwd, the
# runner's environment plus the configured map plus the three reserved values,
# stdin from /dev/null, and neither lock fd (8>&- 9>&-; an inherited lock fd
# would keep a dead runner's lock alive). argv is exec'd literally: no shell,
# no PATH search. Neither the token nor the token file reaches it (they live in
# unexported shell variables and argv of this process only).
consumer_start() {
  local delivery="$1" did="$2" aid="$3"
  (
    cd -- "$CFG_CWD" || exit 126
    for e in ${CFG_ENV[@]+"${CFG_ENV[@]}"}; do
      export "$e" || exit 126
    done
    export "GROUNDHOG_INSTANCE=$INSTANCE" "GROUNDHOG_DELIVERY_ID=$did" "GROUNDHOG_ATTEMPT_ID=$aid"
    case "$GH_ISOLATE" in
      perl)
        # setsid(2) makes the child its own session and process group leader,
        # so Ctrl-C on the runner's terminal cannot reach it. A background job
        # of a non-interactive shell starts with SIGINT and SIGQUIT ignored;
        # restore them. The runner ignores SIGPIPE (see cmd_run) and an ignored
        # signal survives exec, so the consumer gets the default disposition
        # back. The indirect-object exec never goes through a shell.
        exec "$GH_PERL_BIN" -MPOSIX -e '$SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; $SIG{PIPE} = "DEFAULT"; POSIX::setsid() or do { print STDERR "groundhog: setsid failed: $!\n"; POSIX::_exit(126) }; exec { $ARGV[0] } @ARGV; print STDERR "groundhog: cannot execute $ARGV[0]: $!\n"; POSIX::_exit(127)' -- "${CFG_ARGV[@]}" "$delivery"
        ;;
      setsid)
        trap - PIPE
        exec "$GH_SETSID_BIN" -w "${CFG_ARGV[@]}" "$delivery"
        ;;
    esac
    exit 126
  ) 8>&- 9>&- </dev/null &
  CPID=$!
}

# consumer_wait — wait for CPID without blocking signals or stop requests.
# Returns 0 with CSTATUS set once it exited; 1 when this runner should detach
# (a signal, or a stop request) and leave it running. The child's own exit is
# seen by bash's SIGCHLD handling: kill -0 turns false once it is reaped and
# `wait` then yields its status.
consumer_wait() {
  local spid n=0
  while kill -0 "$CPID" 2>/dev/null; do
    if (( GH_SIGNALED )); then return 1; fi
    sleep 0.2 8>&- 9>&- &
    spid=$!
    wait "$spid" 2>/dev/null || true
    n=$((n + 1))
    if (( n % 5 == 0 )) && runner_poll_stop; then return 1; fi
  done
  CSTATUS=0
  wait "$CPID" 2>/dev/null || CSTATUS=$?
  return 0
}

# handoff_admit — one admission under the mutation lock: token, stop request,
# pause, the instance-wide barrier, then the oldest pending delivery. On
# success the attempt is durably in_flight and the lock is released. Returns 1
# when nothing is admitted.
handoff_admit() {
  local rc=0 aid n
  runner_enter || return 1
  if [[ "$S_PAUSED" == true ]]; then unlock_mutation; return 1; fi
  if ix_blocked; then
    if (( ! BARRIER_LOGGED )); then
      runner_log "consumer admission is blocked: an attempt is unresolved (in flight or uncertain) or a delivery record is unreadable; recover it explicitly"
      BARRIER_LOGGED=1
    fi
    unlock_mutation
    return 1
  fi
  BARRIER_LOGGED=0
  while :; do
    ix_next_pending
    if (( IXI < 0 )); then unlock_mutation; return 1; fi
    if ! drec_load "$RT_DIR/deliveries/${IX_ID[IXI]}.json"; then
      IX_BAD=$((IX_BAD + 1)); unlock_mutation; return 1
    fi
    if [[ "$D_STATE" != pending ]]; then ix_set "$IXI"; continue; fi
    if [[ ! -d "$GH_DIR/$D_PATH" ]]; then
      D_STATE=missing; D_REASON=path_missing
      rc=0; drec_save || rc=$?
      if (( rc != 0 )); then unlock_mutation; runner_fail 6 journal_write_failed "could not record delivery $D_ID as missing"; fi
      ix_set "$IXI"
      runner_log "delivery $D_ID: $D_PATH is gone from out/; recorded as missing"
      continue
    fi
    break
  done
  if [[ ! -f "${CFG_ARGV[0]}" || ! -x "${CFG_ARGV[0]}" ]]; then
    unlock_mutation
    runner_fail 2 consumer_unavailable "the configured consumer executable is no longer available; nothing was handed off"
  fi
  if [[ ! -d "$CFG_CWD" ]]; then
    unlock_mutation
    runner_fail 2 consumer_unavailable "the configured consumer working directory is no longer available; nothing was handed off"
  fi
  rand_hex 8 || { unlock_mutation; runner_fail 6 random_failed "cannot read random bytes"; }
  aid="a-$RAND"
  H_ID="$D_ID"; H_ATTEMPT="$aid"
  H_PATH="$( cd "$GH_DIR/$D_PATH" 2>/dev/null && pwd -P )" || H_PATH=""
  if [[ -z "$H_PATH" ]]; then unlock_mutation; runner_fail 6 delivery_path_unusable "cannot resolve $D_PATH"; fi
  n=${#A_ID[@]}
  A_ID[n]="$aid"; A_START[n]="$(now_utc)"; A_FIN[n]=null; A_OUT[n]=in_flight
  A_EXIT[n]=null; A_SIG[n]=null; A_ERR[n]=null; A_DEC[n]=""; A_DECAT[n]=null
  D_STATE=in_flight; D_REASON=""
  # Durable before the consumer exists: a crash after this line leaves an
  # in_flight attempt that the next run turns into uncertain, never a replay.
  rc=0; drec_save || rc=$?
  if (( rc != 0 )); then
    unlock_mutation
    runner_fail 6 journal_write_failed "could not record the attempt as in flight; the consumer was not started"
  fi
  ix_set "$IXI"
  INFLIGHT_ID="$H_ID"; INFLIGHT_ATTEMPT="$aid"
  unlock_mutation
  return 0
}

# handoff_record — write the consumer's result into the delivery record. If it
# cannot be written the attempt stays in_flight (uncertain after exit).
handoff_record() {
  local tries=0 rc n code msg sig=null outcome state
  while :; do
    rc=0; lock_mutation || rc=$?
    if (( rc == 0 )); then break; fi
    tries=$((tries + 1))
    if (( rc != 1 || tries >= 10 )); then
      runner_fail 6 result_not_recorded "could not take the mutation lock to record the result of delivery $H_ID; the attempt stays unresolved"
    fi
  done
  if ! drec_load "$RT_DIR/deliveries/$H_ID.json"; then
    unlock_mutation
    runner_fail 6 result_not_recorded "the record of delivery $H_ID is unreadable; its attempt stays unresolved"
  fi
  n=$(( ${#A_ID[@]} - 1 ))
  if (( n < 0 )) || [[ "${A_ID[n]}" != "$H_ATTEMPT" || "${A_OUT[n]}" != in_flight ]]; then
    unlock_mutation
    runner_fail 6 result_not_recorded "the record of delivery $H_ID no longer shows attempt $H_ATTEMPT in flight; it stays unresolved"
  fi
  A_FIN[n]="\"$(now_utc)\""
  if (( CSTATUS == 0 )); then
    outcome=accepted; state=accepted
    A_EXIT[n]=0
  else
    outcome=failed; state=failed
    A_EXIT[n]="$CSTATUS"
    msg="the consumer exited with status $CSTATUS"
    code=consumer_failed
    if (( CSTATUS > 128 && CSTATUS < 160 )); then
      sig="$(kill -l $((CSTATUS - 128)) 2>/dev/null || true)"
      if [[ "$sig" =~ ^[A-Z0-9+-]+$ ]]; then
        A_SIG[n]="\"SIG$sig\""
        msg="$msg (128 plus signal $((CSTATUS - 128)), SIG$sig, or a script that exited with that number)"
      fi
    elif (( CSTATUS == 126 || CSTATUS == 127 )); then
      msg="$msg (127 and 126 also report that the executable could not be started)"
    fi
    json_str "$code"; code="$JSTR"
    json_str "$msg"; msg="$JSTR"
    A_ERR[n]="{\"code\":$code,\"message\":$msg,\"path\":null}"
  fi
  A_OUT[n]="$outcome"
  D_STATE="$state"; D_REASON=""
  rc=0; drec_save || rc=$?
  unlock_mutation
  if (( rc != 0 )); then
    runner_fail 6 result_not_recorded "could not write the result of delivery $H_ID; its attempt stays unresolved"
  fi
  ix_find_path "$D_PATH"
  if (( IXI >= 0 )); then ix_set "$IXI"; fi
  INFLIGHT_ID=""; INFLIGHT_ATTEMPT=""
  runner_log "delivery $H_ID: $state"
}

# runner_handoff_pending — serial handoffs: one consumer call at a time, each
# admitted under the mutation lock, run outside it, recorded under it again.
runner_handoff_pending() {
  (( CFG_PRESENT )) || return 0
  while :; do
    if (( GH_SIGNALED || RUNNER_STOP )); then return 0; fi
    handoff_admit || return 0
    consumer_start "$H_PATH" "$H_ID" "$H_ATTEMPT"
    runner_log "handoff: delivery $H_ID, attempt $H_ATTEMPT"
    if ! consumer_wait; then
      runner_log "closing admission and detaching from the consumer of delivery $H_ID; it keeps running and the attempt stays unresolved"
      RUNNER_STOP=1
      return 0
    fi
    handoff_record
  done
}

# runner_finalize_inflight — EXIT trap: a consumer call this runner admitted but
# did not record is uncertain from here on; the next explicit recovery decides.
runner_finalize_inflight() {
  local held=$MUT_HELD rc=0
  [[ -n "$INFLIGHT_ID" ]] || return 0
  if (( ! held )); then lock_mutation || return 1; fi
  if drec_load "$RT_DIR/deliveries/$INFLIGHT_ID.json" && [[ "$D_STATE" == in_flight ]]; then
    drec_mark_uncertain consumer_detached "the runner ended while the consumer's result was not recorded; the consumer may or may not have finished"
    drec_save || rc=$?
  fi
  if (( ! held )); then unlock_mutation; fi
  INFLIGHT_ID=""
  return 0
}

# --- retry and recover -----------------------------------------------------------
# delivery_control CMD — shared start of retry and recover: a stopped runner
# (runner exclusion, held until this process exits), the mutation lock, token
# and state checks, and the named record loaded into D_*/A_*.
delivery_control() {
  local cmd="$1" rc=0
  [[ -n "$OPT_TOKEN_FILE" ]] || rt_die 2 "$cmd: --token-file is required"
  [[ -n "$OPT_DELIVERY" ]]   || rt_die 2 "$cmd: --delivery is required"
  [[ "$OPT_DELIVERY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || rt_die 2 "$cmd: --delivery is not a delivery id"
  if [[ "$cmd" == recover ]]; then
    case "$OPT_DECISION" in
      retry|accept) ;;
      "") rt_die 2 "recover: --decision retry|accept is required" ;;
      *)  rt_die 2 "recover: --decision must be retry or accept" ;;
    esac
  fi
  rt_begin "$cmd"
  token_read "$OPT_TOKEN_FILE"
  lock_runner_try || rc=$?
  if (( rc == 1 )); then rt_die 4 "$cmd: a runner is still alive; stop it first"; fi
  (( rc == 0 )) || rt_die 6 "$cmd: cannot test the runner lock"
  lock_mutation_or_die "$cmd"
  control_check "$cmd"
  drec_locate "$OPT_DELIVERY" || rt_die 5 "$cmd: there is no delivery record $OPT_DELIVERY"
  [[ -f "$DREC_AT" ]] || rt_die 5 "$cmd: there is no delivery record $OPT_DELIVERY"
  drec_load "$DREC_AT" || rt_die 5 "$cmd: the record of delivery $OPT_DELIVERY is unreadable or of an unsupported shape; it was not changed"
}

delivery_save_or_die() {
  local rc=0
  drec_save || rc=$?
  if (( rc != 0 )); then rt_die 6 "$1: could not write the record of delivery $D_ID (it may or may not have changed; run status to see)"; fi
}

cmd_retry() {
  parse_opts retry token-file delivery -- "$@"
  delivery_control retry
  case "$D_STATE" in
    failed)
      D_STATE=pending; D_REASON=""
      delivery_save_or_die retry
      unlock_mutation
      echo "retried: delivery $D_ID is pending; the next run creates a new attempt"
      ;;
    pending)
      unlock_mutation
      echo "delivery $D_ID is already pending"
      ;;
    in_flight|uncertain)
      rt_die 5 "retry: delivery $D_ID has an unresolved attempt; use 'recover' once you have established that the consumer call finished"
      ;;
    *)
      rt_die 5 "retry: delivery $D_ID is $D_STATE; only a failed delivery can be retried"
      ;;
  esac
}

cmd_recover() {
  parse_opts recover token-file delivery decision -- "$@"
  delivery_control recover
  local n now
  case "$D_STATE" in
    in_flight|uncertain) ;;
    *) rt_die 5 "recover: delivery $D_ID is $D_STATE; only an unresolved (in flight or uncertain) delivery can be recovered" ;;
  esac
  if [[ "$D_STATE" == in_flight ]]; then
    # An abandoned in-flight attempt: the runner is stopped, so nothing records its result.
    drec_mark_uncertain result_not_recorded "the runner that started this attempt ended before recording its result; the consumer may or may not have finished"
  fi
  n=$(( ${#A_ID[@]} - 1 ))
  (( n >= 0 )) || rt_die 5 "recover: delivery $D_ID has no attempt to decide"
  now="\"$(now_utc)\""
  A_DEC[n]="$OPT_DECISION"; A_DECAT[n]="$now"
  if [[ "$OPT_DECISION" == accept ]]; then D_STATE=accepted; else D_STATE=pending; fi
  D_REASON=""
  delivery_save_or_die recover
  unlock_mutation
  if [[ "$OPT_DECISION" == accept ]]; then
    echo "recovered: delivery $D_ID is accepted on your say-so; no consumer was invoked"
  else
    echo "recovered: delivery $D_ID is pending; the next run creates a new attempt if no other attempt is unresolved"
  fi
}

# --- the runner --------------------------------------------------------------
RUNNER_ID=""
RUNNER_RECORDED=0
RUNNER_OUTCOME=""        # stopped | failed, set before a deliberate exit
RUNNER_ERR_CODE=""
RUNNER_ERR_MSG=""
RUNNER_STOP=0            # a stop request was seen
GH_SIGNALED=0
RUNNER_PAUSE_LOGGED=0

# The runner ignores SIGPIPE (cmd_run), so a lost output stream shows up as a
# failed write. Every line the runner prints is best-effort: the first failure
# points both streams at /dev/null for good (consumers started afterwards
# inherit that instead of a dead pipe) and sets RUNNER_OUTPUT_LOST; the cycle
# loop then records runner.last_error once.
RUNNER_OUTPUT_LOST=0
RUNNER_OUTPUT_RECORDED=0
# The builtin keeps the bytes of a failed write in its stdio buffer and flushes
# them into the next successful write, which could be a command substitution
# that captures stdout. Pointing both streams at /dev/null and then writing
# nothing through the builtin flushes that leftover into /dev/null.
runner_output_gone() { RUNNER_OUTPUT_LOST=1; exec >/dev/null 2>/dev/null; echo -n ''; return 0; }
runner_log() { echo "groundhog: $*" >&2 || runner_output_gone; return 0; }

# runner_record_output_lost — once, outside any lock: note in
# runner.last_error that the output stream went away. The runner keeps
# running; state stays "running" and a later clean stop keeps the error.
runner_record_output_lost() {
  (( RUNNER_OUTPUT_LOST && ! RUNNER_OUTPUT_RECORDED )) || return 0
  RUNNER_OUTPUT_RECORDED=1
  lock_mutation || return 0
  if rt_load && [[ "$R_RUNNER_ID" == "$RUNNER_ID" ]]; then
    S_RUNNER_ERROR='{"code":"output_lost","message":"the runner'"'"'s stdout or stderr was closed; it keeps running and no longer logs","path":null}'
    rt_save || true
  fi
  unlock_mutation
  return 0
}

# runner_fail EXIT_CODE CODE MESSAGE — record a structured error and exit
# nonzero. The EXIT trap writes runner.state=failed; ownership and pause stay.
runner_fail() {
  RUNNER_OUTCOME=failed
  RUNNER_ERR_CODE="$2"
  RUNNER_ERR_MSG="$3"
  runner_log "$3"
  exit "$1"
}

# EXIT trap: leave the state file saying what happened.
runner_on_exit() {
  local rc=$?
  trap '' INT TERM HUP
  if (( RUNNER_RECORDED )); then
    runner_finalize_inflight || true
    runner_record_exit "$rc" || true
  fi
  exit "$rc"
}

runner_record_exit() {
  local rc="$1" outcome="$RUNNER_OUTCOME" held=$MUT_HELD code message
  if [[ -z "$outcome" ]]; then
    if (( rc == 0 )); then outcome=stopped; else outcome=failed; fi
  fi
  if (( ! held )); then lock_mutation || return 1; fi
  if rt_load && [[ "$R_RUNNER_ID" == "$RUNNER_ID" ]]; then
    S_RUNNER_STATE="$outcome"
    if (( RUNNER_OUTPUT_RECORDED )) && [[ "$outcome" != failed ]]; then
      :  # keep the output_lost error already recorded
    elif [[ "$outcome" == failed ]]; then
      code="${RUNNER_ERR_CODE:-runner_exited}"
      message="${RUNNER_ERR_MSG:-the runner exited unexpectedly (status $rc)}"
      json_str "$code"; local c="$JSTR"
      json_str "$message"; S_RUNNER_ERROR="{\"code\":$c,\"message\":$JSTR,\"path\":null}"
    else
      S_RUNNER_ERROR=null
    fi
    R_RUNNER_ID=""; R_RUNNER_PID=""; R_RUNNER_START=""; R_STOPREQ=""
    rt_save || true
  fi
  unlock_mutation
  return 0
}

# runner_poll_stop — cheap, lock-free look for a stop request addressed to this
# runner (state.json is replaced atomically, so a read is always whole).
runner_poll_stop() {
  read_text "$RT_STATE" || return 1
  if [[ "$TEXT" == *"\"stop_requested_for\":\"$RUNNER_ID\""* ]]; then
    RUNNER_STOP=1
    return 0
  fi
  return 1
}

# runner_wait_until SECONDS-TARGET — sleep in one-second slices until
# $SECONDS reaches the target, a signal arrives or a stop is requested. The
# sleep runs with the lock fds closed so it can never keep a dead runner's
# locks alive, and `wait` returns the moment a trapped signal arrives.
runner_wait_until() {
  local target="$1" spid
  while (( SECONDS < target )); do
    if (( GH_SIGNALED || RUNNER_STOP )); then return 0; fi
    sleep 1 8>&- 9>&- &
    spid=$!
    wait "$spid" 2>/dev/null || true
    kill "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    if (( GH_SIGNALED )); then return 0; fi
    runner_poll_stop || true
  done
  return 0
}

# One cycle: reconcile deliveries, tick once if enabled, hand off pending
# deliveries. Cycles run strictly one after another.
runner_cycle() {
  runner_reconcile_deliveries
  runner_tick
  runner_handoff_pending
}

# runner_enter — the start of every admission: take the mutation lock, reload
# state, check the token and any stop request addressed to this runner. Returns
# 0 holding the lock; 1 without it (lock busy, signal, or stop requested, in
# which case RUNNER_STOP is set). A changed owner or unusable state ends the
# runner.
runner_enter() {
  local rc=0
  if (( GH_SIGNALED )); then RUNNER_STOP=1; return 1; fi
  lock_mutation || rc=$?
  if (( rc != 0 )); then
    runner_log "step skipped: the mutation lock is busy"
    return 1
  fi
  if ! rt_load; then
    unlock_mutation
    runner_fail 5 state_invalid "$RT_ERR; the runner stops and ownership is retained"
  fi
  if ! token_verify; then
    unlock_mutation
    runner_fail 3 owner_changed "the owner record no longer matches this runner's token; the runner stops"
  fi
  if [[ "$R_STOPREQ" == "$RUNNER_ID" ]]; then
    RUNNER_STOP=1; unlock_mutation; return 1
  fi
  return 0
}

# runner_reconcile_deliveries — complete or discard interrupted firings, turn
# abandoned in-flight attempts into uncertain, mark vanished pending paths
# missing, import legacy out/ entries. Runs whatever the pause bit says: it
# records facts and admits nothing.
runner_reconcile_deliveries() {
  runner_enter || return 0
  if ! recon_prepared; then
    unlock_mutation
    runner_fail 6 reconcile_failed "could not reconcile the delivery journal; the runner stops and ownership is retained"
  fi
  unlock_mutation
  # The rest holds the lock only in short slices (see recon_scan).
  if ! recon_scan || ! recon_apply; then
    recon_done_flush
    runner_fail 6 reconcile_failed "could not reconcile the delivery journal; the runner stops and ownership is retained"
  fi
  recon_done_flush
  return 0
}

# runner_tick — the firing admission. Under the mutation lock: revalidate the
# token, honor a stop request, honor the global pause, then tick once with the
# journaled tick.
runner_tick() {
  local status=0
  runner_enter || return 0
  if [[ "$S_PAUSED" == true ]]; then
    if (( ! RUNNER_PAUSE_LOGGED )); then runner_log "paused: nothing is admitted until resume"; RUNNER_PAUSE_LOGGED=1; fi
    unlock_mutation
    return 0
  fi
  RUNNER_PAUSE_LOGGED=0
  tick_runtime || status=$?
  unlock_mutation
  if (( status != 0 )); then
    runner_fail 6 tick_failed "tick failed (exit $status); ownership and pause are retained"
  fi
}

cmd_run() {
  parse_opts run token-file interval-seconds -- "$@"
  [[ -n "$OPT_TOKEN_FILE" ]] || rt_die 2 "run: --token-file is required"
  local interval=60
  if [[ -n "$OPT_INTERVAL" ]]; then
    [[ "$OPT_INTERVAL" =~ ^[1-9][0-9]{0,8}$ ]] || rt_die 2 "run: --interval-seconds must be a positive integer"
    interval="$OPT_INTERVAL"
  fi
  rt_begin run
  token_read "$OPT_TOKEN_FILE"

  local rc=0
  lock_runner_try || rc=$?
  if (( rc == 1 )); then rt_die 4 "run: another runner already holds this instance"; fi
  (( rc == 0 )) || rt_die 6 "run: cannot take the runner lock"

  trap 'GH_SIGNALED=1' INT TERM HUP
  # A supervisor that exits can close a pipe the runner writes to. Ignore
  # SIGPIPE so that costs the runner its log lines, not its life (or the
  # consumer's); the consumer helper restores the default for the child.
  trap '' PIPE
  trap runner_on_exit EXIT
  rand_hex 8 || rt_die 6 "run: cannot read random bytes"
  RUNNER_ID="r-$RAND"

  lock_mutation_or_die run
  control_check run
  # The configuration is validated and frozen before anything is ticked or
  # handed off; a change needs stop and run. Invalid is a visible failure, not
  # "no consumer".
  if ! runner_config_load; then
    unlock_mutation
    rt_die 2 "run: $RUNNER_CFG_ERR; nothing was ticked"
  fi
  if (( CFG_PRESENT )) && [[ -z "$GH_ISOLATE" ]]; then
    unlock_mutation
    rt_die 5 "run: this host has neither perl (POSIX::setsid) nor setsid(1), so it cannot start a consumer in its own session; nothing was ticked"
  fi
  if (( CFG_PRESENT )); then
    json_str "$CFG_DIGEST"; S_DIGEST="$JSTR"
  else
    S_DIGEST=null
  fi
  R_RUNNER_ID="$RUNNER_ID"; R_RUNNER_PID="$$"; R_RUNNER_START="$(proc_start_id $$)"; R_STOPREQ=""
  S_RUNNER_STATE=running; S_RUNNER_ERROR=null
  rt_save_or_die run
  RUNNER_RECORDED=1
  unlock_mutation
  runner_log "runner $RUNNER_ID started (interval ${interval}s)"

  local cycle_start next
  while :; do
    cycle_start=$SECONDS
    runner_cycle
    runner_record_output_lost
    if (( GH_SIGNALED || RUNNER_STOP )); then break; fi
    next=$((cycle_start + interval))
    while (( next <= SECONDS )); do next=$((next + interval)); done   # missed cycles are skipped
    runner_wait_until "$next"
    if (( GH_SIGNALED || RUNNER_STOP )); then break; fi
  done
  RUNNER_OUTCOME=stopped
  runner_log "runner $RUNNER_ID stopping; ownership and pause are retained"
  exit 0
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
    enroll)  shift; cmd_enroll  "$@" ;;
    run)     shift; cmd_run     "$@" ;;
    pause)   shift; cmd_setpause true  "$@" ;;
    resume)  shift; cmd_setpause false "$@" ;;
    stop)    shift; cmd_stop    "$@" ;;
    release) shift; cmd_release "$@" ;;
    retry)   shift; cmd_retry   "$@" ;;
    recover) shift; cmd_recover "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

main "$@"
