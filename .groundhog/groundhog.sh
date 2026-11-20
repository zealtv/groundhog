#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage:
  groundhog.sh init
  groundhog.sh add <when> <item-id> [--from DIR]
  groundhog.sh tick
  groundhog.sh due
  groundhog.sh list
  groundhog.sh lint
  groundhog.sh drop <item-id>
  groundhog.sh out
  groundhog.sh sweep [days]
  groundhog.sh pause
  groundhog.sh resume
  groundhog.sh retry <delivery>
  groundhog.sh run [--interval-seconds N]
  groundhog.sh capabilities --json
  groundhog.sh status --json [--next-due]

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
  - three names inside an item are reserved: an executable `run` is started
    for each delivery that holds one, `.groundhog-record` is the delivery's
    record (written fresh at firing) and `.groundhog-log` its run's output
  - tick fires what is due, then starts every delivery whose record says
    fired and never started; pause stops both until resume
  - retry starts a delivery's run again (exit 4 while it is running)
  - run is a plain loop: tick, then wait, until a signal
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

# Selector → minutes-since-midnight, in SEL_MINS (no subshell: walk_due asks
# this for every directory, and status asks walk_due many times). Nonzero exit
# means "not a time selector."
SEL_MINS=0
selector_minutes() {
  if is_hh "$1"; then SEL_MINS=$((10#$1 * 60)); return 0; fi
  if is_hm "$1"; then
    local hh="${1%-*}" mm="${1#*-}"
    SEL_MINS=$((10#$hh * 60 + 10#$mm))
    return 0
  fi
  return 1
}
# Yearly-root variant: HH-MM there would collide with MM-DD shape, so forbid it.
selector_minutes_hh_only() {
  is_hh "$1" || return 1
  SEL_MINS=$((10#$1 * 60))
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

# civil_days YYYY-MM-DD — CD is the day number (days since 1970-01-01) of a
# proleptic Gregorian date; civil_date N — CDATE is the date of day number N.
# Pure arithmetic, no `date`, so a probe of any day costs no process.
civil_days() {
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2})) era yoe doy doe
  (( m <= 2 )) && y=$((y - 1))
  era=$(( (y >= 0 ? y : y - 399) / 400 ))
  yoe=$(( y - era * 400 ))
  doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  CD=$(( era * 146097 + doe - 719468 ))
}
civil_date() {
  local z=$(( $1 + 719468 )) era doe yoe y doy mp d m
  era=$(( (z >= 0 ? z : z - 146096) / 146097 ))
  doe=$(( z - era * 146097 ))
  yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
  y=$(( yoe + era * 400 ))
  doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
  mp=$(( (5 * doy + 2) / 153 ))
  d=$(( doy - (153 * mp + 2) / 5 + 1 ))
  m=$(( mp < 10 ? mp + 3 : mp - 9 ))
  (( m <= 2 )) && y=$((y + 1))
  printf -v CDATE '%04d-%02d-%02d' "$y" "$m" "$d"
}
# civil_fields YYYY-MM-DD — CF_DOW (mon..sun), CF_DOM (1..31), CF_MD (MM-DD).
civil_fields() {
  local names=(thu fri sat sun mon tue wed)
  civil_days "$1"
  CF_DOW="${names[$(( ((CD % 7) + 7) % 7 ))]}"
  CF_DOM=$((10#${1:8:2}))
  CF_MD="${1:5:5}"
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
  if [[ -n "${WD_PROBE_DATE:-}" ]]; then
    # A probe (status's next_due): the same walk, asked about the local moment
    # WD_PROBE_DATE (YYYY-MM-DD) at WD_PROBE_MIN minutes after midnight.
    civil_fields "$WD_PROBE_DATE"
    now_t="$WD_PROBE_DATE"; now_d="$CF_DOW"; now_dom_v="$CF_DOM"; now_md_v="$CF_MD"
    now_min_total="$WD_PROBE_MIN"
  else
    now_t="$(now_today)"
    now_d="$(now_dow)"
    now_dom_v="$(now_dom)"
    now_hh_v="$(now_hh)"
    now_mm_v="$(now_mm)"
    now_md_v="$(now_md)"
    now_min_total=$(( now_hh_v * 60 + now_mm_v ))
  fi

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
      name="${entry##*/}"
      is_paused "$name" && continue
      if "$time_fn" "$name"; then
        mins="$SEL_MINS"
        (( now_min_total >= mins )) || continue
        local sub sub_name
        for sub in "$entry"/*; do
          [[ -d "$sub" ]] || continue
          sub_name="${sub##*/}"
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
      name="${entry##*/}"
      is_paused "$name" && continue
      "$sub_check" "$name" && continue
      if "$time_fn" "$name"; then
        mins="$SEL_MINS"
        (( now_min_total >= mins )) || continue
        local sub sub_name
        for sub in "$entry"/*; do
          [[ -d "$sub" ]] || continue
          sub_name="${sub##*/}"
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
      bucket_name="${bucket##*/}"
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
        item_name="${item##*/}"
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
      name="${entry##*/}"
      is_paused "$name" && continue
      if is_hh "$name" || is_hm "$name"; then
        for sub in "$entry"/*; do
          [[ -d "$sub" ]] || continue
          sub_name="${sub##*/}"
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
      d="${date_dir##*/}"
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
  local from=""
  if (( $# > 2 )); then
    # More than <when> <item-id>: only the exact pair `--from DIR` is valid.
    # An older script ignores the extras and would make an empty item.
    if (( $# != 4 )) || [[ "$3" != --from ]]; then
      rt_die 2 "add: expected <when> <item-id> [--from DIR]"
    fi
    from="$4"
    rt_paths
    add_from "$1" "$2" "$from"
    return
  fi
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

ADD_STAGE=""
add_cleanup() {
  [[ -z "$ADD_STAGE" ]] || rm -rf -- "$ADD_STAGE"
}

# add_from WHEN ID DIR — `add <when> <item-id> --from DIR`: copy the prepared
# directory DIR next to the schedule (runtime/staging/add-*), then rename it to
# schedule/<when>/<id> under the mutation lock, so a tick sees the item whole or
# not at all. The checks plain add makes run first, and DIR is copied, never moved.
add_from() {
  local when="$1" id="$2" dir="$3" real path n=0
  [[ -n "$when" ]] || rt_die 1 "add requires <when> and <item-id>"
  [[ -n "$id" ]]   || rt_die 1 "add requires <item-id>"
  when="${when%/}"
  validate_when "$when"
  is_id "$id" || die "invalid item id '$id' (use letters, digits, ., _, -; cannot collide with axis tokens or date/hour shapes)"
  path="$SCHED/$when/$id"
  [[ ! -e "$path" ]] || die "item already exists: $path"
  [[ -n "$dir" && -d "$dir" ]] || rt_die 2 "add: --from needs an existing directory"
  real="$(cd -- "$dir" 2>/dev/null && pwd -P)" || rt_die 2 "add: cannot read the --from directory"

  mkdir -p "$RT_DIR/staging" 2>/dev/null || rt_die 6 "add: cannot create $RT_DIR/staging"
  trap add_cleanup EXIT
  while :; do
    ADD_STAGE="$RT_DIR/staging/add-$$-$RANDOM$RANDOM"
    [[ -e "$ADD_STAGE" || -L "$ADD_STAGE" ]] || break
    n=$((n + 1))
    (( n < 20 )) || { ADD_STAGE=""; rt_die 6 "add: cannot name a staging directory"; }
  done
  cp -R -- "$real" "$ADD_STAGE" 2>/dev/null || rt_die 6 "add: cannot copy $dir"

  passive_enter add
  ensure_dirs
  # Checked again under the lock: another add may have landed since.
  [[ ! -e "$path" && ! -L "$path" ]] || die "item already exists: $path"
  mkdir -p "$SCHED/$when" 2>/dev/null || rt_die 6 "add: cannot create $SCHED/$when"
  mv -- "$ADD_STAGE" "$path" 2>/dev/null || rt_die 6 "add: cannot move the item into place"
  ADD_STAGE=""
  LINT_INCLUDE_PAUSED=0
  lint_scan
  note_shared_names "$id"
  echo "$path"
}

# Translate a source schedule path into its fired-marker path.
# The marker mirrors the schedule subtree, so two distinct items
# with the same name (e.g. weekly/sat/foo and monthly/25/foo) get
# distinct markers and neither is silently swallowed.
# fired_marker_set SRC DATE [SLOT] puts that path in FMARK without a subshell;
# fired_marker_for prints it.
FMARK=""
fired_marker_set() {
  local src="$1" now_t="$2" slot="${3:-}"
  local rel="${src#"$SCHED"/}"
  if [[ -n "$slot" ]]; then
    FMARK="$FIRED/$now_t/$rel/$slot"
  else
    FMARK="$FIRED/$now_t/$rel"
  fi
}
fired_marker_for() {
  fired_marker_set "$@"
  printf '%s\n' "$FMARK"
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

# tick: fire what is due, then start every delivery whose record says fired
# and never started. Serialized with the other writers by the mutation lock,
# and a no-op while the instance is paused (the pause gates both halves). A
# firing that fails costs only that item: the rest fire, the runs still
# start, and the tick exits 1 (status shows firing_failed).
TICK_SOURCE=standalone
cmd_tick() {
  local rc=0
  require_root
  passive_enter tick
  if [[ "$PASSIVE_PAUSED" == true ]]; then
    echo "tick: the instance is paused; nothing fired or started" >&2
    last_tick_record "$TICK_SOURCE"
    return 0
  fi
  tick_body || rc=$?
  handlers_scan
  last_tick_record "$TICK_SOURCE"
  return "$rc"
}

# tick_body — fire every due item (fire_one), note each that fails in
# runtime/firing_failed (removed again by a tick in which none fails), and
# return 1 if any did.
tick_body() {
  ensure_dirs
  local now_t name src is_once slot failed=""
  now_t="$(now_today)"
  while IFS=$'\t' read -r name src is_once slot; do
    [[ -n "$name" ]] || continue
    if ! fire_one "$name" "$src" "$is_once" "$slot" "$now_t"; then
      echo "error: tick: firing ${src#"$GH_DIR"/} failed; it is tried again on the next tick" >&2
      failed+="$(now_utc) ${src#"$GH_DIR"/}"$'\n'
    fi
  done < <(walk_due)
  if [[ -n "$failed" ]]; then
    { mkdir -p "$GH_DIR/runtime" && printf '%s' "$failed" > "$GH_DIR/runtime/firing_failed"; } 2>/dev/null || true
    return 1
  fi
  rm -f -- "$GH_DIR/runtime/firing_failed" 2>/dev/null || true
}

# fire_one NAME SRC IS_ONCE SLOT DATE — one due item. A firing copies the item
# to out/<name>.landing, replaces any reserved files the copy brought with a
# fresh record (the fired line), renames it into out/, then writes the fired
# marker. The record is in place before the delivery is visible, so a crash at
# any point leaves either nothing in out/ or a delivery that says "fired, never
# started", which the next tick starts. The marker comes last: a crash just
# before it leaves the delivery without a marker, and the next tick records
# that occurrence as a collision with its own delivery (shown, harmless).
# Called in a condition, so every step checks its own failure.
fire_one() {
  local name="$1" src="$2" is_once="$3" slot="$4" now_t="$5" dst tmp marker src_rel handler parent
  if [[ -n "$slot" ]]; then dst="$OUT/${name}-${now_t}-${slot}"; else dst="$OUT/${name}-${now_t}"; fi
  src_rel="${src#"$GH_DIR"/}"
  marker="$(fired_marker_for "$src" "$now_t" "$slot")"
  if [[ -e "$marker" ]]; then
    :  # fired/ says this already fired today — leave it alone
  elif [[ -e "$dst" || -L "$dst" ]]; then
    printf 'warning: %s already exists in out/; recording firing without overwrite\n' "$(basename "$dst")" >&2
    mkdir -p "$(dirname "$marker")" && touch "$marker" || return 1
    note_collision "$dst" "$src_rel" "$now_t" "$slot"
  else
    tmp="${dst}.landing"
    if [[ -e "$tmp" || -L "$tmp" ]]; then
      [[ -L "$tmp" ]] || chmod -R u+w "$tmp" 2>/dev/null
      rm -rf -- "$tmp" || return 1
    fi
    cp -R -- "$src" "$tmp" || return 1
    # A link to a directory is copied as the link: write nothing through it
    # (it gets no record, so it never runs).
    if [[ ! -L "$tmp" ]]; then
      chmod -R u+w "$tmp" || return 1     # an item without owner write still takes its record
      rm -rf -- "${tmp:?}/$REC_NAME" "${tmp:?}/$LOG_NAME" || return 1
      handler=none
      if [[ -f "$tmp/$RUN_NAME" && -x "$tmp/$RUN_NAME" ]]; then
        handler=run
      elif [[ -e "$tmp/$RUN_NAME" || -L "$tmp/$RUN_NAME" ]]; then
        echo "warning: $src_rel/$RUN_NAME is not an executable file, so the delivery is not run" >&2
      fi
      rand_hex 8
      printf 'fired d-%s %s %s %s %s %s\n' "$RAND" "$(now_utc)" "$handler" "$now_t" "${slot:--}" "$src_rel" > "$tmp/$REC_NAME" || return 1
    fi
    mv -- "$tmp" "$dst" || return 1
    mkdir -p "$(dirname "$marker")" && touch "$marker" || return 1
    printf 'fired %s -> %s\n' "$name" "$dst"
  fi
  if [[ "$is_once" == "1" ]]; then
    rm -rf -- "$src" || return 1
    # Walk up removing now-empty schedule dirs (e.g. <date>/<HH-MM>/, then <date>/),
    # but never the once axis root itself.
    parent="$(dirname "$src")"
    while [[ "$parent" != "$SCHED/once" && "$parent" == "$SCHED/once/"* ]]; do
      rmdir "$parent" 2>/dev/null || break
      parent="$(dirname "$parent")"
    done
  fi
  return 0
}

# note_collision DST SRC_REL DATE SLOT — the later occurrence lost its out/
# name: append a collision line to the record of the delivery that holds the
# name, so status shows it. An entry with no record (made by hand) keeps the
# stderr warning only.
note_collision() {
  [[ -d "$1" && ! -L "$1" && -f "$1/$REC_NAME" ]] || return 0
  printf 'collision %s %s %s %s\n' "$(now_utc)" "$3" "${4:--}" "$2" >> "$1/$REC_NAME" 2>/dev/null \
    || echo "warning: could not record the collision in out/${1##*/}/$REC_NAME" >&2
  return 0
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
# When we hit a valid item-id, we stop descending (lint never looks inside an item).
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

# A recognized item: remember it (and what pauses it); lint never looks inside.
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

# sweep [days] — remove out/ entries and fired/ dates older than DAYS (14 by
# default; age is the directory's mtime). A delivery whose run is pending or
# running stays, whatever its age, and is reported; failed and interrupted ones
# age out like any other. Deleting a delivery by hand is the way to dismiss it:
# fired/ still remembers the occurrence, so nothing fires again.
cmd_sweep() {
  require_root
  passive_enter sweep
  ensure_dirs
  local days="${1:-14}" entry name
  (( $# <= 1 )) || rt_die 2 "sweep: expected at most one <days>"
  [[ "$days" =~ ^[0-9]+$ ]] || die "sweep <days> must be a non-negative integer"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry##*/}"
    if [[ "$name" != *.landing && ! -L "$entry" ]] && rec_load "$entry/$REC_NAME"; then
      rec_state "$entry/$REC_NAME"
      case "$R_STATE" in
        pending|running) printf 'skipped out %s (%s)\n' "$name" "$R_STATE"; continue ;;
      esac
    fi
    rm -rf -- "$entry"
    printf 'swept out %s\n' "$name"
  done < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" | LC_ALL=C sort)
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    rm -rf -- "$entry"
    printf 'swept fired %s\n' "${entry##*/}"
  done < <(find "$FIRED" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" | LC_ALL=C sort)
}

# ---------------------------------------------------------------------------
# Read-only inspection: `capabilities --json` and `status --json`.
#
# Nothing below may create, repair, lock, tick or rewrite anything. It stats
# directory names (the schedule grammar, via lint_scan and walk_due), reads the
# small files under runtime/ and each delivery's own record (the one file in a
# delivery that Groundhog writes; nothing else in a payload is read), tests a
# record's lock without holding it, and prints one JSON object. No jq or
# python: JSON is written by the small helpers here, which also run under
# macOS's stock bash 3.2 (no associative arrays, mapfile or ${var,,}).
# ---------------------------------------------------------------------------

GH_PROTOCOL="groundhog-runtime"
# 2: an item's own `run`, the per-delivery record, tokenless pause and retry
# replaced protocol 1's owner, runner, consumer and delivery journal.
GH_PROTOCOL_VERSION=2
# Informational only; clients must not branch on it.
GH_IMPLEMENTATION_VERSION="dev"
# What needs nothing of the host. cmd_capabilities adds handlers-v1 where
# rt_detect finds a lock helper and a way to start a run in its own session.
GH_CAPABILITIES=("status-json-v2" "next-due-v1" "add-from-v1" "pause-v2")

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

# --- delivery records ----------------------------------------------------------
# Every firing leaves one append-only record, out/<name>/.groundhog-record, made
# fresh in the .landing copy. One line per event, fields separated by single
# spaces, the free-text schedule path last; each append is one short write:
#   fired <delivery-id> <utc> run|none <date> <slot|-> <schedule-path>
#   start <attempt-id> <utc> tick|retry
#   exit <attempt-id> <utc> <status>
#   collision <utc> <date> <slot|-> <schedule-path>
# The fired line is always first. `run` in it means the item held an
# executable `run` when it fired. A start is only ever written, and its exit
# only ever appended, by a holder of the record's lock (flock(2) on the record
# itself), and the wrapper holds that lock for as long as `run` lives. So a
# free lock with an open start means the run was interrupted. Readers ignore
# lines they do not know.
REC_NAME=".groundhog-record"
LOG_NAME=".groundhog-log"
RUN_NAME="run"
R_ID=""; R_AT=""; R_HANDLER=""; R_DATE=""; R_SLOT=""; R_SCHED=""; R_NSTART=0
R_STATE=""; R_EXIT=""
A_ID=(); A_AT=(); A_BY=(); A_END=(); A_EXIT=(); R_COLL=()
RE_UTC='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# rf_pop — the next space-separated field of RL into RF (no subshell).
RL=""; RF=""
rf_pop() {
  RF="${RL%% *}"
  if [[ "$RL" == *" "* ]]; then RL="${RL#* }"; else RL=""; fi
}

# rec_load FILE — parse a record into R_* and the attempt arrays. Returns 1
# when FILE is not a readable regular file or does not start with a fired line.
rec_load() {
  local line kw first=1 i id at
  R_ID=""; R_AT=""; R_HANDLER=""; R_DATE=""; R_SLOT=""; R_SCHED=""; R_NSTART=0
  A_ID=(); A_AT=(); A_BY=(); A_END=(); A_EXIT=(); R_COLL=()
  read_text "$1" || return 1
  [[ "$TEXT" == fired\ * ]] || return 1
  while IFS= read -r line; do
    RL="$line"; rf_pop; kw="$RF"
    if (( first )); then
      first=0
      rf_pop; R_ID="$RF"; rf_pop; R_AT="$RF"; rf_pop; R_HANDLER="$RF"
      rf_pop; R_DATE="$RF"; rf_pop; R_SLOT="$RF"; R_SCHED="$RL"
      [[ "$R_ID" =~ ^d-[A-Za-z0-9]+$ && "$R_AT" =~ $RE_UTC && ( "$R_HANDLER" == run || "$R_HANDLER" == none ) ]] || return 1
      is_ymd "$R_DATE" || return 1
      [[ "$R_SLOT" == - ]] || is_hm "$R_SLOT" || return 1
      [[ -n "$R_SCHED" ]] || return 1
      continue
    fi
    case "$kw" in
      start)
        # Every start line counts, so a torn one fails closed (running or
        # interrupted, never pending); fields that do not parse are empty.
        rf_pop; id="$RF"; rf_pop; at="$RF"; rf_pop
        [[ "$id" =~ ^a-[A-Za-z0-9]+$ ]] || id=""
        [[ "$at" =~ $RE_UTC ]] || at=""
        A_ID+=("$id"); A_AT+=("$at"); A_BY+=("$RF"); A_END+=(""); A_EXIT+=("")
        R_NSTART=$((R_NSTART + 1))
        ;;
      exit)
        rf_pop; id="$RF"; rf_pop; at="$RF"; rf_pop
        [[ -n "$id" && "$at" =~ $RE_UTC && "$RF" =~ ^[0-9]{1,3}$ ]] || continue
        for (( i = R_NSTART - 1; i >= 0; i-- )); do
          if [[ "${A_ID[i]}" == "$id" ]]; then A_END[i]="$at"; A_EXIT[i]="$RF"; break; fi
        done
        ;;
      collision)
        rf_pop; at="$RF"; rf_pop; id="$RF"; rf_pop
        R_COLL+=("$at$US$id$US$RF$US$RL")
        ;;
    esac
  done <<< "$TEXT"
  return 0
}

# rec_probe FILE — is the record's lock free right now? 0 free, 1 held, 2 no
# answer. It takes a shared lock for an instant and lets it go, so readers never
# collide with each other; it writes nothing.
rec_probe() {
  local rc=0
  case "$GH_LOCK_HELPER" in
    flock) flock -s -n "$1" true 2>/dev/null || rc=$? ;;
    perl)  perl -MFcntl=:flock -e 'open(my $f, "<", $ARGV[0]) or exit 2; flock($f, LOCK_SH|LOCK_NB) or exit 1; exit 0' "$1" 2>/dev/null || rc=$? ;;
    *)     rc=2 ;;
  esac
  (( rc <= 1 )) || rc=2
  return "$rc"
}

# rec_state FILE — after rec_load: R_STATE and R_EXIT (the last attempt's exit
# status, empty while none). delivered: no run; pending: a run that never
# started; running: the record's lock is held; accepted / failed: the last run
# exited 0 / nonzero; interrupted: the last start has no exit and the lock is
# free. A lock that cannot be tested reads as held.
rec_state() {
  local n=$R_NSTART
  R_EXIT=""
  if [[ "$R_HANDLER" != run ]]; then R_STATE=delivered; return 0; fi
  if (( n == 0 )); then R_STATE=pending; return 0; fi
  R_EXIT="${A_EXIT[n-1]}"
  if [[ -n "$R_EXIT" ]]; then
    if (( R_EXIT == 0 )); then R_STATE=accepted; else R_STATE=failed; fi
    return 0
  fi
  rt_detect
  if rec_probe "$1"; then R_STATE=interrupted; else R_STATE=running; fi
}

DELIVERIES=()
PENDING_N=0

# delivery_json DIR REL — the delivery at DIR (REL is out/<name>) as JSON, in JR.
delivery_json() {
  local d="$1" rel="$2" rec="$1/$REC_NAME" att="" i id at by end ex log=null path_json
  json_str "$rel"; path_json="$JSTR"
  if [[ -L "$d" || ! -e "$rec" && ! -L "$rec" ]]; then
    JR="{\"path\":$path_json,\"id\":null,\"state\":\"unrecorded\",\"fired_at\":null,\"schedule_path\":null,\"occurrence\":null,\"run\":false,\"exit_status\":null,\"attempts\":[],\"log\":null}"
    return 0
  fi
  if ! rec_load "$rec"; then
    diag_add record_malformed "$rel/$REC_NAME is not a readable record that starts with a fired line; the delivery never runs" "$rel/$REC_NAME"
    JR="{\"path\":$path_json,\"id\":null,\"state\":\"unrecorded\",\"fired_at\":null,\"schedule_path\":null,\"occurrence\":null,\"run\":false,\"exit_status\":null,\"attempts\":[],\"log\":null}"
    return 0
  fi
  rec_state "$rec"
  [[ "$R_STATE" == pending ]] && PENDING_N=$((PENDING_N + 1))
  for (( i = 0; i < R_NSTART; i++ )); do
    id=null; [[ -n "${A_ID[i]}" ]] && id="\"${A_ID[i]}\""
    at=null; [[ -n "${A_AT[i]}" ]] && at="\"${A_AT[i]}\""
    by=null; [[ "${A_BY[i]}" == tick || "${A_BY[i]}" == retry ]] && by="\"${A_BY[i]}\""
    end=null; ex=null
    if [[ -n "${A_EXIT[i]}" ]]; then end="\"${A_END[i]}\""; ex=$((10#${A_EXIT[i]})); fi
    att+="${att:+,}{\"id\":$id,\"started_at\":$at,\"by\":$by,\"finished_at\":$end,\"exit_status\":$ex}"
  done
  ex=null; [[ -n "$R_EXIT" ]] && ex=$((10#$R_EXIT))
  if [[ -e "$d/$LOG_NAME" ]]; then json_str "$rel/$LOG_NAME"; log="$JSTR"; fi
  local id_json sched_json slot_json run=false
  json_str "$R_ID"; id_json="$JSTR"
  json_str "$R_SCHED"; sched_json="$JSTR"
  slot_json=null; [[ "$R_SLOT" != - ]] && slot_json="\"$R_SLOT\""
  [[ "$R_HANDLER" == run ]] && run=true
  if [[ "$run" == false && ( -e "$d/$RUN_NAME" || -L "$d/$RUN_NAME" ) ]]; then
    diag_add run_not_executable "$rel/$RUN_NAME was not an executable file when it fired (no execute bit, or a broken link), so the delivery was not run" "$rel/$RUN_NAME"
  fi
  JR="{\"path\":$path_json,\"id\":$id_json,\"state\":\"$R_STATE\",\"fired_at\":\"$R_AT\",\"schedule_path\":$sched_json,\"occurrence\":{\"date\":\"$R_DATE\",\"slot\":$slot_json},\"run\":$run,\"exit_status\":$ex,\"attempts\":[$att],\"log\":$log}"
  local c parts=() what
  for c in ${R_COLL[@]+"${R_COLL[@]}"}; do
    IFS="$US" read -r -a parts <<< "$c"
    what="${parts[3]:-a schedule item}${parts[1]:+ on ${parts[1]}}"
    [[ "${parts[2]:-}" != - && -n "${parts[2]:-}" ]] && what+=" slot ${parts[2]}"
    if [[ "${parts[1]:-}" == "$R_DATE" && "${parts[2]:-}" == "$R_SLOT" && "${parts[3]:-}" == "$R_SCHED" ]]; then
      diag_add out_collision "$rel: the same occurrence fired again (re-armed, or a tick ended before its marker); this delivery stands" "$rel"
    else
      diag_add out_collision "$rel already existed when $what fired; that occurrence was marked fired and not delivered, so its run never ran" "$rel"
    fi
  done
}

inspect_deliveries() {
  local entry name
  shopt -s nullglob
  for entry in "$OUT"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    [[ "$name" == *.landing ]] && continue
    if [[ ! -d "$entry" ]]; then
      diag_add out_entry_not_directory "out/$name is not a directory, so it is not listed as a delivery" "out/$name"
      continue
    fi
    delivery_json "$entry" "out/$name"
    DELIVERIES+=("$JR")
  done
  shopt -u nullglob
  if (( PENDING_N > 0 )) && ! handlers_supported; then
    diag_add handlers_unavailable "$PENDING_N deliveries have a run that this host cannot start ($GH_HANDLERS_MISSING); see README.md" ""
  fi
  local line
  if read_text "$GH_DIR/runtime/firing_failed"; then
    while IFS= read -r line; do
      [[ "$line" == *" "* ]] || continue
      diag_add firing_failed "the tick at ${line%% *} could not fire ${line#* } (see that tick's stderr); every tick tries it again" "${line#* }"
    done <<< "$TEXT"
  fi
  if [[ -e "$GH_DIR/runtime/config.json" || -L "$GH_DIR/runtime/config.json" ]]; then
    diag_add config_ignored "runtime/config.json is present but ignored: protocol 2 has no consumer configuration, and an item's own run replaces it" "runtime/config.json"
  fi
  if [[ -e "$GH_DIR/runtime/state.json" || -L "$GH_DIR/runtime/state.json" ]]; then
    diag_add state_ignored "runtime/state.json is from protocol 1 and ignored: ownership is gone, and a pause recorded there no longer applies (run pause to pause)" "runtime/state.json"
  fi
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

# --- next_due ---------------------------------------------------------------
# next_due asks the script's own walk_due, not a second scheduler, when an item
# next becomes due. walk_due can be probed at any local moment (WD_PROBE_DATE,
# WD_PROBE_MIN); an item's next occurrence is the earliest probe at which
# walk_due emits it under a fired-marker key (date, slot) that does not exist.
# Callers read the probe through nd_probe, and the answer reads as UTC.

NOW_EPOCH_FLAVOUR=""
# nd_date_gnu — true when `date` takes -d @EPOCH (GNU); else BSD -r EPOCH.
nd_date_gnu() {
  if [[ -z "$NOW_EPOCH_FLAVOUR" ]]; then
    if date -d @0 >/dev/null 2>&1; then NOW_EPOCH_FLAVOUR=gnu; else NOW_EPOCH_FLAVOUR=bsd; fi
  fi
  [[ "$NOW_EPOCH_FLAVOUR" == gnu ]]
}

# nd_fields_of EPOCH — EF_DATE, EF_MIN (minutes after local midnight), EF_OFF
# (UTC offset in seconds): the local view of an instant.
nd_fields_of() {
  local out hh mm z sign
  if nd_date_gnu; then out="$(date -d "@$1" '+%Y-%m-%d %H %M %z')"; else out="$(date -r "$1" '+%Y-%m-%d %H %M %z')"; fi
  read -r EF_DATE hh mm z <<< "$out"
  EF_MIN=$(( 10#$hh * 60 + 10#$mm ))
  sign=1; [[ "${z:0:1}" == - ]] && sign=-1
  EF_OFF=$(( sign * (10#${z:1:2} * 3600 + 10#${z:3:2} * 60) ))
}

# nd_off_noon DATE — NDO is the UTC offset (seconds) at about local noon of DATE.
# Each date costs one `date`; answers are kept for the run.
OC_KEY=()
OC_VAL=()
nd_off_noon() {
  local i
  for (( i = 0; i < ${#OC_KEY[@]}; i++ )); do
    if [[ "${OC_KEY[i]}" == "$1" ]]; then NDO="${OC_VAL[i]}"; return 0; fi
  done
  civil_days "$1"
  nd_fields_of $(( CD * 86400 + 43200 - ND_OFFREF ))
  NDO="$EF_OFF"
  OC_KEY+=("$1"); OC_VAL+=("$NDO")
}

# nd_utc EPOCH — NDU is the UTC time as YYYY-MM-DDTHH:MM:SSZ, by arithmetic.
nd_utc() {
  local days=$(( $1 / 86400 )) rem=$(( $1 % 86400 ))
  civil_date "$days"
  printf -v NDU '%sT%02d:%02d:%02dZ' "$CDATE" $(( rem / 3600 )) $(( rem % 3600 / 60 )) $(( rem % 60 ))
}

# nd_local_start DATE MIN — ND_EPOCH is the first instant on local DATE whose
# local time is at or after minute MIN (the "at or after" threshold of the
# README), so a skipped wall-clock time (spring forward) gives the instant the
# clock jumps and a repeated one (fall back) gives its first pass.
nd_local_start() {
  local d="$1" m="$2" hh mm out e e2 off0 tries=0 o1 o2
  # Quick path, for the common day: when the UTC offset is the same at noon the
  # day before and noon the day after, no clock change falls on this day (they
  # come months apart), and the instant is plain arithmetic.
  civil_days "$d"; local base=$(( CD * 86400 + m * 60 ))
  civil_date $(( CD - 1 )); nd_off_noon "$CDATE"; o1="$NDO"
  civil_date $(( CD + 1 )); nd_off_noon "$CDATE"; o2="$NDO"
  if (( o1 == o2 )); then ND_EPOCH=$(( base - o1 )); return 0; fi
  printf -v hh '%02d' $(( m / 60 )); printf -v mm '%02d' $(( m % 60 ))
  if nd_date_gnu; then
    out="$(date -d "$d $hh:$mm:00" +%s 2>/dev/null)" || out=""
  else
    out="$(date -j -f '%Y-%m-%d %H:%M:%S' "$d $hh:$mm:00" +%s 2>/dev/null)" || out=""
  fi
  if [[ -z "$out" ]]; then
    # A time that does not exist here: start from noon, which always does.
    if nd_date_gnu; then out="$(date -d "$d 12:00:00" +%s)"; else out="$(date -j -f '%Y-%m-%d %H:%M:%S' "$d 12:00:00" +%s)"; fi
    out=$(( out - (720 - m) * 60 ))
  fi
  e="$out"
  nd_fields_of "$e"
  # Settle on the first instant that reads at or after (d, m).
  while [[ "$EF_DATE" < "$d" || ( "$EF_DATE" == "$d" && $EF_MIN -lt $m ) ]]; do
    (( ++tries > 130 )) && break
    e=$(( e + 60 )); nd_fields_of "$e"
  done
  while (( tries++ < 260 )); do
    nd_fields_of $(( e - 60 ))
    [[ "$EF_DATE" > "$d" || ( "$EF_DATE" == "$d" && $EF_MIN -ge $m ) ]] || break
    e=$(( e - 60 ))
  done
  # A repeated hour (fall back): the same reading came a UTC-offset change
  # earlier, and the first pass is the one a tick would have seen.
  nd_fields_of "$e"; off0="$EF_OFF"
  nd_fields_of $(( e - 86400 ))
  if (( EF_OFF != off0 )); then
    e2=$(( e + off0 - EF_OFF ))
    nd_fields_of "$e2"
    if [[ "$EF_DATE" == "$d" ]] && (( EF_MIN >= m && e2 < e )); then
      nd_fields_of $(( e2 - 60 ))
      [[ "$EF_DATE" < "$d" || ( "$EF_DATE" == "$d" && $EF_MIN -lt $m ) ]] && e="$e2"
    fi
  fi
  ND_EPOCH="$e"
}

# nd_probe DATE MIN — walk_due's rows at that local moment are PR_ROWS[PR_FROM
# .. PR_TO-1]. Answers are kept for the run: items share most of their probes.
PR_ROWS=()
PR_FROM=0
PR_TO=0
PC_KEY=()
PC_FROM=()
PC_TO=()
nd_probe() {
  local key="$1 $2" i text
  local rows=()
  for (( i = 0; i < ${#PC_KEY[@]}; i++ )); do
    if [[ "${PC_KEY[i]}" == "$key" ]]; then PR_FROM="${PC_FROM[i]}"; PR_TO="${PC_TO[i]}"; return 0; fi
  done
  WD_PROBE_DATE="$1"; WD_PROBE_MIN="$2"
  text="$(walk_due)"
  WD_PROBE_DATE=""; WD_PROBE_MIN=""
  PR_FROM=${#PR_ROWS[@]}
  if [[ -n "$text" ]]; then
    IFS=$'\n' read -r -d '' -a rows <<< "$text" || true
    PR_ROWS+=("${rows[@]}")
  fi
  PR_TO=${#PR_ROWS[@]}
  PC_KEY+=("$key"); PC_FROM+=("$PR_FROM"); PC_TO+=("$PR_TO")
}

# nd_has ITEM_PATH DATE — true when the last probe emitted the item and the
# fired marker its (date, slot) would have does not exist: the item would fire.
nd_has() {
  local p="$1" j row rest slot
  for (( j = PR_FROM; j < PR_TO; j++ )); do
    row="${PR_ROWS[j]}"
    [[ "$row" == *$'\t'"$p"$'\t'* ]] || continue
    rest="${row#*$'\t'"$p"$'\t'}"       # <is-once>[<TAB><slot>]
    slot=""
    [[ "$rest" == *$'\t'* ]] && slot="${rest#*$'\t'}"
    fired_marker_set "$p" "$2" "$slot"
    [[ ! -e "$FMARK" ]]
    return
  done
  return 1
}

# nd_at ITEM DATE MIN — probe, then nd_has.
nd_at() {
  nd_probe "$2" "$3"
  nd_has "${item_paths[$1]}" "$2"
}

# nd_try ITEM DATE — if the item would fire on DATE, at or after now when DATE
# is today, set ND_UTC[ITEM] to the start of that occurrence and succeed. The
# start is the least minute at which walk_due emits the item under a marker
# that does not exist; that stays emitted once it starts (a threshold, or an
# every/ slot), so it can be bisected. The cadence's own time is only the
# first guess, to save probes.
nd_try() {
  local i="$1" d="$2" lo=0 hi=1439 t=0 cad="${item_cads[$1]}" mid
  [[ "$d" == "$ND_TODAY" ]] && lo=$(( ND_NOWMIN + 1 ))
  (( lo <= hi )) || return 1
  nd_at "$i" "$d" "$hi" || return 1
  if [[ "$cad" == *"${US}time="* ]]; then
    t="${cad##*"${US}time="}"; t="${t%%"$US"*}"
    selector_minutes "$t" && t="$SEL_MINS" || t=0
  fi
  (( t < lo )) && t="$lo"
  (( t > hi )) && t="$hi"
  if nd_at "$i" "$d" "$t"; then
    # The guess holds: it is the start unless the item already held a minute earlier.
    if (( t == lo )) || ! nd_at "$i" "$d" $(( t - 1 )); then lo="$t"; hi="$t"; else hi=$(( t - 1 )); fi
  else
    lo=$(( t + 1 ))
  fi
  while (( lo < hi )); do
    mid=$(( (lo + hi) / 2 ))
    if nd_at "$i" "$d" "$mid"; then hi="$mid"; else lo=$(( mid + 1 )); fi
  done
  nd_local_start "$d" "$lo"
  nd_utc "$ND_EPOCH"
  ND_UTC[i]="$NDU"
}

# nd_resolve IDX… — fill ND_UTC for the items whose next occurrence has not
# fired. walk_due decides every answer; the cadence only proposes which days
# to ask about (an item's own day of week, day of month or date, so a yearly
# item costs a few probes, not a scan of the year), and an item the grammar
# does not recognize proposes none.
nd_resolve() {
  local i cad part axis dow dom md ymd day y mo d cd0 cdy
  local hh mm z sign
  read -r ND_TODAY hh mm z <<< "$(date '+%Y-%m-%d %H %M %z')"
  ND_NOWMIN=$(( 10#$hh * 60 + 10#$mm ))
  sign=1; [[ "${z:0:1}" == - ]] && sign=-1
  ND_OFFREF=$(( sign * (10#${z:1:2} * 3600 + 10#${z:3:2} * 60) ))
  civil_days "$ND_TODAY"; cd0="$CD"
  for i in "$@"; do
    cad="${item_cads[i]}"
    axis=""; dow=""; dom=""; md=""; ymd=""
    local parts=()
    IFS="$US" read -r -a parts <<< "$cad"
    for part in ${parts[@]+"${parts[@]}"}; do
      case "$part" in
        axis=*) axis="${part#axis=}" ;; dow=*) dow="${part#dow=}" ;;
        dom=*) dom="${part#dom=}" ;; md=*) md="${part#md=}" ;; ymd=*) ymd="${part#ymd=}" ;;
      esac
    done
    case "$axis" in
      daily|every)
        for (( day = 0; day <= 1; day++ )); do
          civil_date $(( cd0 + day ))
          nd_try "$i" "$CDATE" && break
        done ;;
      weekly)
        [[ -n "$dow" ]] || dow=mon
        for (( day = 0; day <= 7; day++ )); do
          civil_date $(( cd0 + day )); d="$CDATE"
          civil_fields "$d"
          [[ "$CF_DOW" == "$dow" ]] || continue
          nd_try "$i" "$d" && break
        done ;;
      monthly)
        [[ -n "$dom" ]] || dom=1
        y="${ND_TODAY:0:4}"; mo=$(( 10#${ND_TODAY:5:2} ))
        for (( day = 0; day < 15; day++ )); do
          printf -v d '%04d-%02d-%02d' "$y" "$mo" "$dom"
          civil_days "$d"; civil_date "$CD"
          if [[ "$CDATE" == "$d" && ! "$d" < "$ND_TODAY" ]]; then nd_try "$i" "$d" && break; fi
          if (( ++mo > 12 )); then mo=1; y=$(( y + 1 )); fi
        done ;;
      yearly)
        [[ -n "$md" ]] || md=01-01
        for (( y = ${ND_TODAY:0:4}; y <= ${ND_TODAY:0:4} + 8; y++ )); do
          d="$y-$md"
          civil_days "$d"; civil_date "$CD"
          [[ "$CDATE" == "$d" && ! "$d" < "$ND_TODAY" ]] || continue   # 02-30, or 02-29 in a common year
          nd_try "$i" "$d" && break
        done ;;
      once)
        [[ -z "$ymd" || "$ymd" < "$ND_TODAY" ]] || nd_try "$i" "$ymd" ;;
    esac
  done
}

inspect_schedule() {
  local now_t due_text name src is_once slot k p rel marker marker_rel due_idx i
  local paused_list part paused_json bb fired eligible allowed marker_json
  local item_paths=() item_pauses=() due_src=() due_slot=() due_once=() found o
  local parts=() item_cads=() cad_json nd_json nd_part nd_pending=()
  ND_UTC=(); PR_ROWS=(); PC_KEY=(); PC_FROM=(); PC_TO=(); OC_KEY=(); OC_VAL=()
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
    due_once+=("$is_once")
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
    [[ "$ST_PAUSED" == true ]] && bb+="${bb:+,}\"instance_paused\""

    eligible=false
    (( due_idx >= 0 )) && [[ "$fired" == false ]] && eligible=true
    allowed=false
    [[ -z "$bb" ]] && allowed=true

    # next_due, only under status --next-due: null for a paused item and for
    # a once item that has fired; the observed time for an item that would
    # fire on a tick now; the rest are asked of walk_due below.
    nd_part=""
    if (( STATUS_NEXT_DUE )); then
      nd_json=null
      if [[ -n "${item_pauses[k]}" ]]; then :
      elif [[ "$eligible" == true ]]; then json_str "$OBSERVED_AT"; nd_json="$JSTR"
      elif [[ "$fired" == true && "${due_once[due_idx]}" == 1 ]]; then :
      else nd_pending+=("$k"); nd_json="@$k@"
      fi
      nd_part=",\"next_due\":$nd_json"
    fi

    cadence_json "${item_cads[k]}"; cad_json="$JR"
    json_str "$rel"; local path_json="$JSTR"
    json_str "${p##*/}"; local id_json="$JSTR"
    SCHEDULE+=("{\"path\":$path_json,\"item_id\":$id_json,\"cadence\":$cad_json,\"paused_by\":[$paused_json],\"eligible_now\":$eligible,\"fired_marker\":$marker_json,\"fired\":$fired,\"firing_allowed\":$allowed,\"blocked_by\":[$bb]$nd_part}")
  done
  if (( ${#nd_pending[@]} > 0 )); then
    nd_resolve "${nd_pending[@]}"
    for k in "${nd_pending[@]}"; do
      if [[ -n "${ND_UTC[k]:-}" ]]; then json_str "${ND_UTC[k]}"; nd_json="$JSTR"; else nd_json=null; fi
      SCHEDULE[k]="${SCHEDULE[k]%@$k@\}}$nd_json}"
    done
  fi
  LINT_INCLUDE_PAUSED=0
}

# json_array NAME… helper: join an array's elements with commas into JR.
join_by_comma() {
  # One expansion, not a loop of appends: appending to a growing string copies
  # it each time, which made a list of thousands of deliveries take seconds.
  local IFS=,
  JR="$*"
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
  if handlers_supported; then GH_CAPABILITIES+=("handlers-v1"); fi
  for c in "${GH_CAPABILITIES[@]}"; do
    json_str "$c"
    caps+="${caps:+,}$JSTR"
  done
  json_str "$GH_IMPLEMENTATION_VERSION"
  printf '{"protocol":"%s","protocol_version":%s,"implementation_version":%s,"capabilities":[%s]}\n' \
    "$GH_PROTOCOL" "$GH_PROTOCOL_VERSION" "$JSTR" "$caps"
}

# last_tick_peek — read runtime/last_tick without writing: LAST_TICK is the JSON
# object {"at":…,"source":…}, or null when the file is absent or not exactly a
# UTC time and a known source.
LAST_TICK=null
last_tick_peek() {
  local f="$GH_DIR/runtime/last_tick"
  LAST_TICK=null
  if read_text "$f"; then
    TEXT="${TEXT%$'\n'}"
    if [[ "$TEXT" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\ (runner|standalone)$ ]]; then
      LAST_TICK="{\"at\":\"${BASH_REMATCH[1]}\",\"source\":\"${BASH_REMATCH[2]}\"}"
    fi
  fi
}

# status --json [--next-due]: one JSON object for the instance as it stands.
# --next-due (next-due-v1) adds next_due to each schedule record.
ST_PAUSED=false
STATUS_NEXT_DUE=0
cmd_status() {
  local arg rest=() seen_nd=0
  for arg in "$@"; do
    if [[ "$arg" == --next-due ]]; then
      if (( seen_nd )); then echo "error: status: --next-due given more than once" >&2; exit 2; fi
      seen_nd=1; STATUS_NEXT_DUE=1
    else
      rest+=("$arg")
    fi
  done
  json_only_args status ${rest[@]+"${rest[@]}"}
  GH_BAD_INSTALL_EXIT=2
  resolve_paths
  INSTANCE="$(canonical_dir "$GH_DIR")"
  OBSERVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -e "$GH_DIR/runtime/paused" ]] && ST_PAUSED=true

  last_tick_peek
  inspect_deliveries
  inspect_schedule
  if (( JSON_LOSSY )); then
    diag_add path_not_utf8 "some names are not valid UTF-8; invalid bytes are shown as U+FFFD" ""
  fi

  local instance_json observed_json schedule deliveries diags
  json_str "$INSTANCE"; instance_json="$JSTR"
  json_str "$OBSERVED_AT"; observed_json="$JSTR"
  join_by_comma ${SCHEDULE[@]+"${SCHEDULE[@]}"};   schedule="$JR"
  join_by_comma ${DELIVERIES[@]+"${DELIVERIES[@]}"}; deliveries="$JR"
  join_by_comma ${DIAGS[@]+"${DIAGS[@]}"};          diags="$JR"
  printf '{"protocol":"%s","protocol_version":%s,"instance":%s,"observed_at":%s,"paused":%s,"last_tick":%s,"schedule":[%s],"deliveries":[%s],"diagnostics":[%s]}\n' \
    "$GH_PROTOCOL" "$GH_PROTOCOL_VERSION" "$instance_json" "$observed_json" \
    "$ST_PAUSED" "$LAST_TICK" "$schedule" "$deliveries" "$diags"
}
# ---------------------------------------------------------------------------
# Runtime: the locks, the instance pause, and the runs of deliveries.
#
# Everything here is optional state under .groundhog/runtime/ plus each
# delivery's own record. Locks are flock(2) advisory locks. A flock(2) lock
# belongs to an open file description: this shell opens the file on a numbered
# fd and a short-lived helper (util-linux flock(1), else perl) takes the lock on
# that inherited fd. The lock outlives the helper, passes to any child that
# inherits the fd, and goes away when the last holder of the description dies,
# so a crash frees it and no PID is ever consulted. fd 9 is the mutation lock
# (runtime/locks/mutation.lock, held by every writer for the length of its
# command); fd 7 is a delivery's record, whose lock the handler wrapper holds
# for the life of `run`. Every long-lived child is started without fd 9, and
# `run` itself without fd 7. Lock files are never deleted.
# ---------------------------------------------------------------------------

GH_LOCK_HELPER=""      # flock | perl | empty (no locking available)
GH_ISOLATE=""          # perl | setsid | empty (no way to start a run in its own session)
GH_PERL_BIN=""
GH_SETSID_BIN=""
GH_HANDLERS_MISSING="" # what the host lacks for handlers-v1
GH_RT_DETECTED=0
GH_SIGNALED=0
PASSIVE_PAUSED=false

# rt_detect — decide what this host can do. Nothing is created or run beyond
# version probes, so `capabilities` stays read-only.
rt_detect() {
  (( GH_RT_DETECTED )) && return 0
  GH_RT_DETECTED=1
  local v
  if command -v flock >/dev/null 2>&1; then
    v="$(flock --version 2>&1 || true)"
    [[ "$v" == *util-linux* ]] && GH_LOCK_HELPER=flock
  fi
  if [[ -z "$GH_LOCK_HELPER" ]] && command -v perl >/dev/null 2>&1 \
     && perl -MFcntl=:flock -e 'exit 0' >/dev/null 2>&1; then
    GH_LOCK_HELPER=perl
  fi
  # A run starts in a session of its own, so Ctrl-C on a tick loop or the end
  # of a terminal cannot reach it. Bash cannot do that by itself without job
  # control: perl's POSIX::setsid (preferred; perl is the lock helper on macOS)
  # or setsid(1) does it.
  if command -v perl >/dev/null 2>&1 && perl -MPOSIX -e 'exit 0' >/dev/null 2>&1; then
    GH_ISOLATE=perl
    GH_PERL_BIN="$(command -v perl)"
  elif command -v setsid >/dev/null 2>&1; then
    GH_ISOLATE=setsid
    GH_SETSID_BIN="$(command -v setsid)"
  fi
  [[ -n "$GH_LOCK_HELPER" ]] || GH_HANDLERS_MISSING="flock(1) from util-linux or perl with Fcntl"
  [[ -n "$GH_ISOLATE" ]] || GH_HANDLERS_MISSING+="${GH_HANDLERS_MISSING:+, }perl with POSIX or setsid(1)"
  return 0
}

# handlers_supported — can this host start runs (capability handlers-v1)?
handlers_supported() { rt_detect; [[ -z "$GH_HANDLERS_MISSING" ]]; }

rt_die() { echo "error: $2" >&2; exit "$1"; }

RT_DIR=""; RT_LOCKS=""

rt_paths() {
  RT_DIR="$GH_DIR/runtime"
  RT_LOCKS="$RT_DIR/locks"
  INSTANCE="$(canonical_dir "$GH_DIR")"
}

# --- locks -------------------------------------------------------------------
# lock_open FD FILE — open FILE (created if absent) on FD for appending. 0, or 2.
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

# lock_mutation — take the mutation lock, waiting up to about three seconds.
# 0 / 1 busy / 2 error. Held until the command exits.
lock_mutation() {
  local tries=0 rc
  lock_open 9 "$RT_LOCKS/mutation.lock" || return 2
  while :; do
    rc=0
    lock_try 9 || rc=$?
    if (( rc == 0 )); then return 0; fi
    if (( rc != 1 )); then exec 9>&-; return 2; fi
    tries=$((tries + 1))
    if (( tries >= 30 )); then exec 9>&-; return 1; fi
    sleep 0.1 9>&-
  done
}

# passive_enter CMD — the start of every writer (init, add, drop, sweep, tick,
# pause, resume, retry): where locking exists, take the mutation lock (exit 4
# if it stays busy, 6 if it cannot be taken), then note the instance pause.
# Without locking the command runs unlocked, as Groundhog always has.
passive_enter() {
  local rc=0
  rt_paths
  rt_detect
  if [[ -n "$GH_LOCK_HELPER" ]]; then
    mkdir -p "$RT_LOCKS" 2>/dev/null || rt_die 6 "$1: cannot create $RT_LOCKS"
    lock_mutation || rc=$?
    case "$rc" in
      0) ;;
      1) rt_die 4 "$1: the instance is busy (another writer holds the mutation lock)" ;;
      *) rt_die 6 "$1: cannot take the mutation lock" ;;
    esac
  fi
  PASSIVE_PAUSED=false
  if [[ -e "$RT_DIR/paused" ]]; then PASSIVE_PAUSED=true; fi
}

# --- small tools -------------------------------------------------------------
# rand_hex BYTES — RAND is that many random bytes in hex. Ids only need to be
# unique, so without /dev/urandom and od it falls back to $RANDOM.
RAND=""
rand_hex() {
  RAND="$(od -An -N"$1" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || RAND=""
  if [[ ! "$RAND" =~ ^[0-9a-f]+$ || ${#RAND} -ne $(( $1 * 2 )) ]]; then
    printf -v RAND '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" $(( $$ & 65535 )) "$RANDOM"
  fi
}
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- the last tick ---------------------------------------------------------------
# runtime/last_tick holds one line, "<UTC time> <source>", where source is
# "runner" (a tick of the `run` loop) or "standalone" (a `tick` call). Every
# tick that completes writes it, paused or not. It is liveness only: it names
# no caller and grants nothing. The write is a temp file and a rename (no
# fsync: a lost record only makes the tick look older), and never fails the
# tick. status reads it without writing and treats anything unreadable as
# "never recorded". Hosts without a lock helper record nothing.
last_tick_record() {
  [[ -n "$RT_DIR" && -n "$GH_LOCK_HELPER" ]] || return 0
  mkdir -p "$RT_DIR" 2>/dev/null || return 0
  local f="$RT_DIR/last_tick" tmp="$RT_DIR/.last_tick.$$.tmp"
  if printf '%s %s\n' "$(now_utc)" "$1" > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$f" 2>/dev/null; then :; else rm -f "$tmp" 2>/dev/null; fi
  return 0
}

# --- pause ---------------------------------------------------------------------
# The instance pause is the file runtime/paused. While it exists, tick fires
# nothing and starts nothing, and retry refuses. Runs already started go on.
# It needs no token: anyone who can write the instance can pause it. Taken
# under the mutation lock, so once `pause` returns no tick is mid-way.
cmd_setpause() { # true|false ARGS…
  local want="$1" cmd=pause
  [[ "$want" == false ]] && cmd=resume
  shift
  (( $# == 0 )) || rt_die 2 "$cmd takes no arguments"
  require_root
  passive_enter "$cmd"
  mkdir -p "$RT_DIR" 2>/dev/null || rt_die 6 "$cmd: cannot create $RT_DIR"
  if [[ "$want" == true ]]; then
    if [[ ! -e "$RT_DIR/paused" ]]; then
      now_utc > "$RT_DIR/paused" 2>/dev/null || rt_die 6 "pause: cannot write $RT_DIR/paused"
    fi
    echo "paused"
  else
    rm -f -- "$RT_DIR/paused" 2>/dev/null || rt_die 6 "resume: cannot remove $RT_DIR/paused"
    echo "resumed"
  fi
}

# --- runs ----------------------------------------------------------------------
# handlers_scan — after the firings, under the mutation lock: start every
# delivery whose record says it has a run and never started. One that another
# process is starting (its lock is held) is left to it.
handlers_scan() {
  local f d n=0
  while IFS= read -r f; do
    d="${f%/*}"
    [[ -n "$f" && -d "$d" && ! -L "$d" && "$d" != *.landing ]] || continue
    rec_load "$f" || continue
    [[ "$R_HANDLER" == run ]] && (( R_NSTART == 0 )) || continue
    if ! handlers_supported; then n=$((n + 1)); continue; fi
    handler_start "$d" tick || true
  done < <(run_pending_records)
  if (( n > 0 )); then
    echo "warning: $n deliveries have a run, but this host cannot start one ($GH_HANDLERS_MISSING)" >&2
  fi
  return 0
}

# run_pending_records — the records in out/ whose fired line says run and
# that hold no start line, one per line. One find and one awk read them all,
# so a tick does not parse every finished delivery in bash; rec_load checks
# each hit again.
run_pending_records() {
  [[ -d "$OUT" ]] || return 0
  find "$OUT" -mindepth 2 -maxdepth 2 -name "$REC_NAME" -type f -exec awk '
    FNR == 1 { if (f != "" && ok && !st) print f; f = FILENAME; st = 0; ok = ($0 ~ /^fired [^ ]+ [^ ]+ run /); next }
    /^start / { st = 1 }
    END { if (f != "" && ok && !st) print f }' {} + 2>/dev/null || true
}

# handler_start DIR BY — start DIR's run once, BY tick or retry. Take the
# record's lock (fd 7), read the record again under it, append the start line,
# and hand the lock to the wrapper, which holds it until `run` exits. Returns 0
# started (HS_AID is the attempt id), 4 busy (the lock is held), 5 nothing to
# start (no run, or a tick finds it already started), 6 I/O failure. A crash
# after the start line and before the wrapper leaves a free lock with an open
# start: interrupted, never re-run by itself.
HS_AID=""
handler_start() {
  local d="$1" by="$2" rec="$1/$REC_NAME" rc=0
  lock_open 7 "$rec" || return 6
  lock_try 7 || rc=$?
  if (( rc != 0 )); then exec 7>&-; (( rc == 1 )) && return 4; return 6; fi
  if ! rec_load "$rec" || [[ "$R_HANDLER" != run ]] || { [[ "$by" == tick ]] && (( R_NSTART > 0 )); }; then
    exec 7>&-; return 5
  fi
  rand_hex 8; HS_AID="a-$RAND"
  if ! { exec 6>>"$d/$LOG_NAME"; } 2>/dev/null; then exec 7>&-; return 6; fi
  if ! printf 'start %s %s %s\n' "$HS_AID" "$(now_utc)" "$by" >&7 2>/dev/null; then
    exec 6>&- 7>&-; return 6
  fi
  (
    case "$GH_ISOLATE" in
      perl)
        # setsid(2) makes the wrapper its own session and process group
        # leader, before anything else, so a Ctrl-C meant for the ticker
        # cannot reach it. A background job of a non-interactive shell starts
        # with SIGINT and SIGQUIT ignored, and a bash started with a signal
        # ignored cannot restore it, so perl restores them next.
        exec "$GH_PERL_BIN" -MPOSIX -e 'POSIX::setsid() or do { print STDERR "groundhog: setsid failed: $!\n"; POSIX::_exit(126) }; $SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; $SIG{PIPE} = "DEFAULT"; exec { $ARGV[0] } @ARGV; print STDERR "groundhog: cannot start the wrapper: $!\n"; POSIX::_exit(127)' \
          -- "$BASH" "$GH_DIR/groundhog.sh" _handle "$d" "$R_ID" "$HS_AID"
        ;;
      setsid)
        # Resets SIGINT under bash 5 when the ticker itself had it at its
        # default; bash 3.2, or a ticker started with it ignored, passes the
        # ignored SIGINT on to the run (perl, preferred above, always resets).
        trap - INT QUIT PIPE
        exec "$GH_SETSID_BIN" "$BASH" "$GH_DIR/groundhog.sh" _handle "$d" "$R_ID" "$HS_AID"
        ;;
    esac
    exit 126
  ) 9>&- </dev/null >&6 2>&6 6>&- &
  exec 6>&- 7>&-
  printf 'started %s (%s)\n' "out/${d##*/}" "$HS_AID" 2>/dev/null || true
  return 0
}

# _handle DIR DELIVERY_ID ATTEMPT_ID — the wrapper, in its own session, with
# the record's lock on fd 7 and stdout and stderr on the delivery's log. It
# runs DIR/run with $1 = DIR, cwd = the project (the directory holding
# .groundhog/), no stdin, and the three GROUNDHOG_* values, then appends the
# exit status. `run` gets neither fd 7 nor fd 9, so the lock lives exactly as
# long as the wrapper, and the wrapper as long as `run`.
cmd_handle() {
  local d="${1:-}" did="${2:-}" aid="${3:-}" rc=0
  { : >&7; } 2>/dev/null || die "_handle is started by tick and retry only"
  resolve_paths
  INSTANCE="$(canonical_dir "$GH_DIR")" || INSTANCE="$GH_DIR"
  d="$INSTANCE/out/${d##*/}"    # $1 and cwd spelled canonically, whatever path the ticker used
  # A signal to the wrapper alone waits for `run`, so the lock and the exit
  # line still come out right; `run` itself keeps the default handling. To
  # stop a run, signal its process group (the wrapper's pid).
  trap ':' INT TERM HUP
  if [[ ! -e "$d/$RUN_NAME" ]]; then
    echo "groundhog: $d/$RUN_NAME is gone" >&2; rc=127     # bash 3.2 would say 1
  elif [[ ! -f "$d/$RUN_NAME" || ! -x "$d/$RUN_NAME" ]]; then
    echo "groundhog: $d/$RUN_NAME is not an executable file" >&2; rc=126
  elif cd -- "$INSTANCE/.." 2>/dev/null; then
    GROUNDHOG_INSTANCE="$INSTANCE" GROUNDHOG_DELIVERY_ID="$did" GROUNDHOG_ATTEMPT_ID="$aid" \
      "$d/$RUN_NAME" "$d" 7>&- </dev/null || rc=$?
  else
    rc=126
  fi
  printf 'exit %s %s %s\n' "$aid" "$(now_utc)" "$rc" >&7
}

# retry DELIVERY — start a delivery's run again, now, whatever its last run
# did. DELIVERY is the out/ name, out/<name>, or the delivery's absolute path.
# No token. Exit 0 started, 2 not a delivery of this instance, 3 paused,
# 4 busy (it is running, or a writer holds the mutation lock), 5 nothing to
# run (no record, no run, or a host that cannot start one), 6 I/O failure.
cmd_retry() {
  (( $# == 1 )) && [[ -n "$1" ]] || rt_die 2 "retry: expected <delivery>"
  GH_BAD_INSTALL_EXIT=2
  require_root
  local arg="${1%/}" name d rc=0
  case "$arg" in
    /*)
      [[ "$(canonical_dir "$(dirname -- "$arg")" 2>/dev/null)" == "$(canonical_dir "$OUT" 2>/dev/null)" ]] \
        || rt_die 2 "retry: $1 is not a delivery in this instance's out/"
      name="${arg##*/}" ;;
    out/*) name="${arg#out/}" ;;
    *) name="$arg" ;;
  esac
  [[ -n "$name" && "$name" != */* && "$name" != . && "$name" != .. && "$name" != *.landing ]] \
    || rt_die 2 "retry: $1 is not a delivery in this instance's out/"
  d="$OUT/$name"
  [[ -d "$d" && ! -L "$d" ]] || rt_die 2 "retry: there is no delivery out/$name"
  handlers_supported || rt_die 5 "retry: this host cannot start a run ($GH_HANDLERS_MISSING)"
  passive_enter retry
  [[ "$PASSIVE_PAUSED" == false ]] || rt_die 3 "retry: the instance is paused; resume it first"
  rec_load "$d/$REC_NAME" || rt_die 5 "retry: out/$name has no record Groundhog made (placed by hand or imported), so it never runs"
  [[ "$R_HANDLER" == run ]] || rt_die 5 "retry: out/$name has no run"
  [[ -f "$d/$RUN_NAME" && -x "$d/$RUN_NAME" ]] || rt_die 5 "retry: out/$name/$RUN_NAME is missing or not executable"
  # A status or sweep testing the lock holds it for an instant: try thrice.
  local tries=0
  while :; do
    rc=0; handler_start "$d" retry || rc=$?
    (( rc == 4 && ++tries < 3 )) || break
    sleep 0.1 9>&-
  done
  case "$rc" in
    0) ;;
    4) rt_die 4 "retry: out/$name is running" ;;
    5) rt_die 5 "retry: out/$name has nothing to run" ;;
    *) rt_die 6 "retry: cannot start out/$name" ;;
  esac
}

# --- the loop ------------------------------------------------------------------
# run [--interval-seconds N] — a plain tick loop for a terminal pane or a
# service: tick, then wait until N seconds (default 60) after that tick
# started, until SIGINT, SIGTERM or SIGHUP, which end it with exit 0 after the
# tick in progress. Each tick runs in a subshell, so a failing tick is logged
# and the loop goes on. It takes no lock of its own: two loops, or a loop and
# cron, simply both tick. Runs it started live on in their own sessions.
cmd_run() {
  local interval=60 seen=0 next tpid rc spid
  while (( $# )); do
    case "$1" in
      --interval-seconds)
        (( ! seen )) || rt_die 2 "run: --interval-seconds given more than once"
        (( $# >= 2 )) && [[ "$2" =~ ^[1-9][0-9]{0,8}$ ]] || rt_die 2 "run: --interval-seconds must be a positive integer"
        interval="$2"; seen=1; shift 2 ;;
      *) rt_die 2 "run: unknown option or argument '$1'" ;;
    esac
  done
  require_root
  trap 'GH_SIGNALED=1' INT TERM HUP
  echo "groundhog: ticking every ${interval}s until interrupted" >&2
  while :; do
    next=$((SECONDS + interval))
    ( TICK_SOURCE=runner; cmd_tick ) </dev/null &
    tpid=$!
    rc=0
    while :; do
      rc=0; wait "$tpid" 2>/dev/null || rc=$?
      kill -0 "$tpid" 2>/dev/null || break   # a signal ends `wait` early; the tick goes on
    done
    (( rc == 0 )) || echo "groundhog: tick exited $rc" >&2
    while (( ! GH_SIGNALED && SECONDS < next )); do
      sleep 1 9>&- &
      spid=$!
      wait "$spid" 2>/dev/null || true
      kill "$spid" 2>/dev/null || true
      wait "$spid" 2>/dev/null || true
    done
    (( ! GH_SIGNALED )) || break
  done
  echo "groundhog: stopped" >&2
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
    pause)  shift; cmd_setpause true  "$@" ;;
    resume) shift; cmd_setpause false "$@" ;;
    retry)  shift; cmd_retry "$@" ;;
    run)    shift; cmd_run   "$@" ;;
    _handle) shift; cmd_handle "$@" ;;
    capabilities) shift; cmd_capabilities "$@" ;;
    status) shift; cmd_status "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

# exit on main's own line: bash reads a script as it runs it, so when main
# returns it exits without reading on. A copy rewritten in place while a
# wrapper or loop waits never has its new bytes run by the old process.
main "$@"; exit $?
