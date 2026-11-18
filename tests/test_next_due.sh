#!/usr/bin/env bash
# next_due: the additive schedule-record field naming when an item's next
# unfired occurrence begins (UTC), or null. It must agree with `due`, which is
# what a tick fires from: at next_due the item is due, a minute before it is not.
. "$(dirname "$0")/lib.sh"
export TZ=UTC

nd_item() { # PATH → next_due as compact JSON
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["schedule"]:
    if r["path"] == sys.argv[2]:
        print(json.dumps(r.get("next_due", "<absent>"), separators=(",", ":")))
        break
else:
    print("<missing>")' "$T_TMP/nd.json" "$1"
}
nd_pairs() { # path<TAB>next_due for every record with a next_due string
  python3 -I -c '
import json, sys
for r in json.load(open(sys.argv[1]))["schedule"]:
    if isinstance(r.get("next_due"), str):
        print(r["path"] + "\t" + r["next_due"])' "$T_TMP/nd.json"
}
mark() { mkdir -p "$(dirname "$GHD/$1")"; touch "$GHD/$1"; }
snap_nd() { status_to "$T_TMP/nd.json"; assert_json_valid "$T_TMP/nd.json"; }
expect() { # PATH EXPECTED-UTC|null
  local want="$2"
  [ "$want" = null ] || want="\"$want\""
  assert_eq "$1 next_due" "$want" "$(nd_item "$1")"
}
# utc_epoch STAMP — Unix time of a YYYY-MM-DDTHH:MM:SSZ stamp.
utc_epoch() {
  "$T_REAL_DATE" -u -d "$1" +%s 2>/dev/null \
    || "$T_REAL_DATE" -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
}
# clock_at EPOCH — set the test clock to that instant (as local wall time in $TZ).
clock_at() {
  local local_str
  local_str="$("$T_REAL_DATE" -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || "$T_REAL_DATE" -r "$1" '+%Y-%m-%d %H:%M:%S')"
  set_clock "$local_str"
}

# agrees_with_due LABEL — at each item's next_due the script's `due` lists it and a
# minute earlier it does not (the item fires on the first tick at or after next_due).
agrees_with_due() {
  local label="$1" pairs path nd e obs
  pairs="$(nd_pairs)"
  obs="$(jget "$T_TMP/nd.json" observed_at)"; obs="${obs//\"/}"
  while IFS=$'\t' read -r path nd; do
    [ -n "$path" ] || continue
    [ "$nd" = "$obs" ] && continue            # due now: nothing to step to
    e="$(utc_epoch "$nd")"
    clock_at "$e"
    if gh due | sed "s#^$GHD/##" | grep -qxF "$path"; then t_ok
    else t_fail "$label: $path is due at its next_due $nd"; fi
    clock_at "$((e - 60))"
    if gh due | sed "s#^$GHD/##" | grep -qxF "$path"; then t_fail "$label: $path is not yet due a minute before $nd"; else t_ok; fi
  done <<< "$pairs"
  set_clock "$CLOCK_NOW"
}

# --- Sunday 2026-11-15 12:00, UTC ------------------------------------------------
new_instance
gh init >/dev/null
for w in daily/d-plain daily/13/d-late daily/09/d-fired daily/00-05/d-early \
         weekly/w-root weekly/sun/11/w-sun-fired weekly/sun/14/w-sun14 \
         monthly/31/m-31 monthly/m-root monthly/15/13/m-15-13 monthly/15/m-15-fired \
         yearly/03-15/y-0315 yearly/y-root yearly/02-29/y-leap yearly/02-30/y-never \
         once/2026-11-15/13-00/o-late once/2026-12-01/o-future once/2026-11-15/09/o-fired \
         once/o-root once/2026-11-14/o-past \
         every/15m/e-15 every/1h/e-1h; do
  gh add "${w%/*}" "${w##*/}" >/dev/null 2>&1
done
mkdir -p "$GHD/schedule/daily/p-item.paused" "$GHD/schedule/weekly.paused/sun/p-axis" \
         "$GHD/schedule/daily/odd name é"
mark fired/2026-11-15/daily/09/d-fired
mark fired/2026-11-15/weekly/sun/11/w-sun-fired
mark fired/2026-11-15/monthly/15/m-15-fired
mark fired/2026-11-15/once/2026-11-15/09/o-fired
CLOCK_NOW="2026-11-15 12:00:00"
set_clock "$CLOCK_NOW"
age_tree "$INST"
h0="$(tree_hash "$GHD")"
snap_nd
assert_eq "status with next_due left the instance untouched" "$h0" "$(tree_hash "$GHD")"

# Due now (a tick would fire it): observed_at, an unfired past once item included.
for p in daily/d-plain daily/00-05/d-early once/o-root once/2026-11-14/o-past every/15m/e-15 every/1h/e-1h "daily/odd name é"; do
  expect "schedule/$p" 2026-11-15T12:00:00Z
done
# Later today.
expect schedule/daily/13/d-late 2026-11-15T13:00:00Z
expect schedule/once/2026-11-15/13-00/o-late 2026-11-15T13:00:00Z
expect schedule/monthly/15/13/m-15-13 2026-11-15T13:00:00Z
expect schedule/weekly/sun/14/w-sun14 2026-11-15T14:00:00Z
# Fired today: the next occurrence. A fired once item has none.
expect schedule/daily/09/d-fired 2026-11-16T09:00:00Z
expect schedule/weekly/sun/11/w-sun-fired 2026-11-22T11:00:00Z
expect schedule/monthly/15/m-15-fired 2026-12-15T00:00:00Z
expect schedule/once/2026-11-15/09/o-fired null
# Defaults at the axis root.
expect schedule/weekly/w-root 2026-11-16T00:00:00Z
expect schedule/monthly/m-root 2026-12-01T00:00:00Z
expect schedule/yearly/y-root 2027-01-01T00:00:00Z
# monthly/31 skips a 30-day month: there is no end-of-month fallback.
expect schedule/monthly/31/m-31 2026-12-31T00:00:00Z
# Yearly: a plain date, a leap day (next in 2028), a date that never exists.
expect schedule/yearly/03-15/y-0315 2027-03-15T00:00:00Z
expect schedule/yearly/02-29/y-leap 2028-02-29T00:00:00Z
expect schedule/yearly/02-30/y-never null
# A dated once item names its day; paused items have no next occurrence.
expect schedule/once/2026-12-01/o-future 2026-12-01T00:00:00Z
expect schedule/daily/p-item.paused null
expect schedule/weekly.paused/sun/p-axis null
agrees_with_due "Sun 12:00"

# --- every/ near midnight: the last slot is short -----------------------------------
new_instance
gh init >/dev/null
for w in every/7m/e-7 every/15m/e-15 every/3h/e-3h every/1h/e-1h; do gh add "${w%/*}" "${w##*/}" >/dev/null; done
age_tree "$INST"
CLOCK_NOW="2026-11-15 23:50:00"
set_clock "$CLOCK_NOW"
# Unfired current slots: due now.
snap_nd
expect schedule/every/7m/e-7 2026-11-15T23:50:00Z
# The current slots have fired: the next slot, or midnight when it was the last.
mark fired/2026-11-15/every/7m/e-7/23-48
mark fired/2026-11-15/every/15m/e-15/23-45
mark fired/2026-11-15/every/3h/e-3h/21-00
mark fired/2026-11-15/every/1h/e-1h/23-00
snap_nd
expect schedule/every/7m/e-7 2026-11-15T23:55:00Z     # 1435 = 205 * 7; 1439 ends the day
expect schedule/every/15m/e-15 2026-11-16T00:00:00Z
expect schedule/every/3h/e-3h 2026-11-16T00:00:00Z
expect schedule/every/1h/e-1h 2026-11-16T00:00:00Z
agrees_with_due "23:50 every/"
CLOCK_NOW="2026-11-15 23:57:00"
set_clock "$CLOCK_NOW"
mark fired/2026-11-15/every/7m/e-7/23-55
snap_nd
expect schedule/every/7m/e-7 2026-11-16T00:00:00Z     # the short last slot is over at midnight
agrees_with_due "23:57 every/7m"
# Not yet fired at 00:03 the next day: the 00:00 slot is due now.
CLOCK_NOW="2026-11-16 00:03:00"
set_clock "$CLOCK_NOW"
snap_nd
expect schedule/every/7m/e-7 2026-11-16T00:03:00Z

# --- monthly/31 where the month is short, from inside it -----------------------------
new_instance
gh init >/dev/null
gh add monthly/31 m-31 >/dev/null
gh add monthly/30/09 m-30 >/dev/null
age_tree "$INST"
set_clock "2026-02-10 08:00:00"
snap_nd
expect schedule/monthly/31/m-31 2026-03-31T00:00:00Z
expect schedule/monthly/30/09/m-30 2026-03-30T09:00:00Z
set_clock "2026-12-31 10:00:00"      # the 31st itself, and fired
mark fired/2026-12-31/monthly/31/m-31
snap_nd
expect schedule/monthly/31/m-31 2027-01-31T00:00:00Z

# --- a later time zone: the answer is UTC, the rule is local --------------------------
export TZ=Pacific/Auckland
new_instance
gh init >/dev/null
gh add daily/07-45 nudge >/dev/null
age_tree "$INST"
set_clock "2026-11-16 07:00:00"      # Auckland is UTC+13 in November
snap_nd
expect schedule/daily/07-45/nudge 2026-11-15T18:45:00Z
export TZ=UTC

# --- DST ----------------------------------------------------------------------------
export TZ=America/New_York
if [ "$(TZ=America/New_York "$T_REAL_DATE" -d '2026-01-15 12:00' '+%z' 2>/dev/null || TZ=America/New_York "$T_REAL_DATE" -j -f '%Y-%m-%d %H:%M' '2026-01-15 12:00' '+%z')" = "-0500" ]; then
  new_instance
  gh init >/dev/null
  gh add daily/02 d-two >/dev/null
  gh add daily/01-30 d-0130 >/dev/null
  gh add daily/04 d-four >/dev/null
  age_tree "$INST"
  # Spring forward, Sunday 2026-03-08: 02:00 EST jumps to 03:00 EDT. daily/02 reads
  # at or after its threshold, so it becomes due when the clock jumps: 07:00Z.
  CLOCK_NOW="2026-03-08 00:30:00"
  set_clock "$CLOCK_NOW"
  snap_nd
  expect schedule/daily/02/d-two 2026-03-08T07:00:00Z
  expect schedule/daily/04/d-four 2026-03-08T08:00:00Z     # 04:00 EDT
  agrees_with_due "spring forward, 00:30"
  # From the day before: the same instant.
  CLOCK_NOW="2026-03-07 12:00:00"
  set_clock "$CLOCK_NOW"
  mark fired/2026-03-07/daily/02/d-two
  snap_nd
  expect schedule/daily/02/d-two 2026-03-08T07:00:00Z
  # The day after, 02:00 exists again (EDT, 06:00Z).
  CLOCK_NOW="2026-03-08 12:00:00"
  set_clock "$CLOCK_NOW"
  mark fired/2026-03-08/daily/02/d-two
  snap_nd
  expect schedule/daily/02/d-two 2026-03-09T06:00:00Z
  # Fall back, Sunday 2026-11-01: 01:30 happens twice; a tick sees the first (EDT, 05:30Z).
  CLOCK_NOW="2026-11-01 00:10:00"
  set_clock "$CLOCK_NOW"
  snap_nd
  expect schedule/daily/01-30/d-0130 2026-11-01T05:30:00Z
else
  t_skip "this host has no America/New_York time zone data"
fi
export TZ=UTC

# --- held: an owned instance still reads observed_at -----------------------------------
if have_runtime_support; then
  new_instance
  gh init >/dev/null
  gh add daily nudge >/dev/null
  gh add daily/23 late >/dev/null
  age_tree "$INST"
  set_clock "2026-11-15 12:00:00"
  enroll_ok
  snap_nd
  assert_eq "an owned instance does not allow firing" false "$(python3 -I -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["schedule"][0]["firing_allowed"]).lower())' "$T_TMP/nd.json")"
  expect schedule/daily/nudge 2026-11-15T12:00:00Z
  expect schedule/daily/23/late 2026-11-15T23:00:00Z
else
  t_skip "no runner support on this host (the held case needs an owner)"
fi

clear_clock
t_finish
