#!/usr/bin/env bash
# Schedule projection: every axis, once/ and every/, .paused subtrees, fired
# items, same-named items at different paths, and paths the grammar rejects.
# eligible_now must agree with the script's own `due` at every clock tested.
. "$(dirname "$0")/lib.sh"
export TZ=UTC

build_fixture() {
  new_instance
  gh init >/dev/null
  local w
  for w in daily/d-plain daily/09/d-nine daily/13/d-late daily/09-30/d-0930 daily/12-01/d-1201 \
           weekly/w-root weekly/sun/w-sun weekly/mon/w-mon weekly/sun/11/w-sun11 \
           monthly/m-root monthly/15/m-15 monthly/15/13/m-15-13 \
           yearly/y-root yearly/11-15/y-1115 yearly/03-15/y-0315 yearly/01-01/09/y-jan1-nine \
           once/o-root once/2026-11-14/o-past once/2026-11-15/o-today \
           once/2026-11-15/13-00/o-today-late once/2026-12-01/o-future \
           every/15m/e-15 every/3h/e-3h every/7m/e-7 \
           daily/twin weekly/sun/twin monthly/15/twin; do
    gh add "${w%/*}" "${w##*/}" >/dev/null
  done
  # Paused at the item, at a time folder, at a day folder and at an axis.
  mkdir -p "$GHD/schedule/daily/p-item.paused" \
           "$GHD/schedule/daily/09.paused/p-timed" \
           "$GHD/schedule/weekly/sun.paused/p-day" \
           "$GHD/schedule/weekly.paused/sun/p-axis" \
           "$GHD/schedule/once/2026-11-15.paused/p-once"
  # Not an id (space, accent): the grammar flags it, but walk_due still fires it.
  mkdir -p "$GHD/schedule/daily/odd name é"
  # Paths the schedule grammar rejects outright.
  mkdir -p "$GHD/schedule/bogus/x" "$GHD/schedule/every/loose-item" "$GHD/schedule/monthly/99/y"
  age_tree "$INST"
}

SCHED_PREFIX_CUT() { sed "s#^$GHD/##"; }

# cross_check LABEL — eligible_now in status == the set `due` prints.
cross_check() {
  local label="$1" f="$T_TMP/sched.json"
  status_to "$f"
  assert_json_valid "$f"
  jq_py where "$f" schedule eligible_now true path > "$T_TMP/elig.status"
  gh due | SCHED_PREFIX_CUT | LC_ALL=C sort > "$T_TMP/elig.due"
  if cmp -s "$T_TMP/elig.status" "$T_TMP/elig.due"; then t_ok
  else t_fail "$label: eligible_now matches due" "$(diff "$T_TMP/elig.status" "$T_TMP/elig.due" | head -8 | tr "\n" "|")"; fi
}

item() { jq_py find "$T_TMP/sched.json" schedule path "$1"; }
has_item() { [ "$(item "$1")" != "<missing>" ]; }
field() { # PATH FIELD → compact JSON
  python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(json.dumps(r[sys.argv[2]],ensure_ascii=False,separators=(",",":")))' "$(item "$1")" "$2"
}

# --- Sunday 2026-11-15 12:00 ---------------------------------------------------
build_fixture
set_clock "2026-11-15 12:00:00"
cross_check "Sun 12:00"

eligible="
schedule/daily/d-plain schedule/daily/09/d-nine schedule/daily/09-30/d-0930
schedule/weekly/sun/w-sun schedule/weekly/sun/11/w-sun11
schedule/monthly/15/m-15 schedule/yearly/11-15/y-1115
schedule/once/o-root schedule/once/2026-11-14/o-past schedule/once/2026-11-15/o-today
schedule/every/15m/e-15 schedule/every/3h/e-3h schedule/every/7m/e-7
schedule/daily/twin schedule/weekly/sun/twin schedule/monthly/15/twin
"
for p in $eligible; do
  assert_eq "$p is eligible" true "$(field "$p" eligible_now)"
  assert_eq "$p may fire" true "$(field "$p" firing_allowed)"
  assert_eq "$p has nothing blocking it" '[]' "$(field "$p" blocked_by)"
done
for p in schedule/daily/13/d-late schedule/daily/12-01/d-1201 schedule/weekly/w-root schedule/weekly/mon/w-mon \
         schedule/monthly/m-root schedule/monthly/15/13/m-15-13 schedule/yearly/y-root schedule/yearly/03-15/y-0315 \
         schedule/once/2026-11-15/13-00/o-today-late schedule/once/2026-12-01/o-future; do
  assert_eq "$p is not eligible" false "$(field "$p" eligible_now)"
  assert_eq "$p says why" '["not_due"]' "$(field "$p" blocked_by)"
  assert_eq "$p has no candidate marker" null "$(field "$p" fired_marker)"
done

# Cadence: structured, from the grammar walk, with root defaults marked.
cad() { # PATH EXPECTED-JSON
  assert_eq "cadence of $1" "$2" "$(field "$1" cadence)"
}
cad schedule/daily/d-plain       '{"axis":"daily","day":null,"date":null,"time":null,"interval":null,"defaulted":false}'
cad schedule/daily/09/d-nine     '{"axis":"daily","day":null,"date":null,"time":"09:00","interval":null,"defaulted":false}'
cad schedule/daily/09-30/d-0930  '{"axis":"daily","day":null,"date":null,"time":"09:30","interval":null,"defaulted":false}'
cad schedule/weekly/w-root       '{"axis":"weekly","day":"mon","date":null,"time":null,"interval":null,"defaulted":true}'
cad schedule/weekly/sun/w-sun    '{"axis":"weekly","day":"sun","date":null,"time":null,"interval":null,"defaulted":false}'
cad schedule/weekly/sun/11/w-sun11 '{"axis":"weekly","day":"sun","date":null,"time":"11:00","interval":null,"defaulted":false}'
cad schedule/monthly/m-root      '{"axis":"monthly","day":"1","date":null,"time":null,"interval":null,"defaulted":true}'
cad schedule/monthly/15/m-15     '{"axis":"monthly","day":"15","date":null,"time":null,"interval":null,"defaulted":false}'
cad schedule/monthly/15/13/m-15-13 '{"axis":"monthly","day":"15","date":null,"time":"13:00","interval":null,"defaulted":false}'
cad schedule/yearly/y-root       '{"axis":"yearly","day":null,"date":"01-01","time":null,"interval":null,"defaulted":true}'
cad schedule/yearly/11-15/y-1115 '{"axis":"yearly","day":null,"date":"11-15","time":null,"interval":null,"defaulted":false}'
cad schedule/yearly/01-01/09/y-jan1-nine '{"axis":"yearly","day":null,"date":"01-01","time":"09:00","interval":null,"defaulted":false}'
cad schedule/once/o-root         '{"axis":"once","day":null,"date":null,"time":null,"interval":null,"defaulted":true}'
cad schedule/once/2026-11-14/o-past '{"axis":"once","day":null,"date":"2026-11-14","time":null,"interval":null,"defaulted":false}'
cad schedule/once/2026-11-15/13-00/o-today-late '{"axis":"once","day":null,"date":"2026-11-15","time":"13:00","interval":null,"defaulted":false}'
cad schedule/every/15m/e-15      '{"axis":"every","day":null,"date":null,"time":null,"interval":"15m","defaulted":false}'
cad schedule/every/3h/e-3h       '{"axis":"every","day":null,"date":null,"time":null,"interval":"3h","defaulted":false}'
# Paused components keep their cadence; unrecognized-but-fired items have none.
cad schedule/daily/09.paused/p-timed '{"axis":"daily","day":null,"date":null,"time":"09:00","interval":null,"defaulted":false}'
cad schedule/weekly.paused/sun/p-axis '{"axis":"weekly","day":"sun","date":null,"time":null,"interval":null,"defaulted":false}'
cad schedule/once/2026-11-15.paused/p-once '{"axis":"once","day":null,"date":"2026-11-15","time":null,"interval":null,"defaulted":false}'
cad "schedule/daily/odd name é" null

# Identity is the schedule-relative path; item_id is only the leaf.
assert_eq "twin at daily/ has id twin" '"twin"' "$(field schedule/daily/twin item_id)"
assert_eq "twin at weekly/sun/ has id twin" '"twin"' "$(field schedule/weekly/sun/twin item_id)"
assert_eq "twin at monthly/15/ has id twin" '"twin"' "$(field schedule/monthly/15/twin item_id)"
assert_eq "same-named items are distinct records" 3 \
  "$(jq_py col "$T_TMP/sched.json" schedule item_id | grep -c '^"twin"$')"
assert_eq "the three twins have three different markers" 3 \
  "$(for p in schedule/daily/twin schedule/weekly/sun/twin schedule/monthly/15/twin; do field "$p" fired_marker; done | sort -u | wc -l | tr -d ' ')"
assert_eq "marker mirrors the schedule path" '"fired/2026-11-15/weekly/sun/twin"' "$(field schedule/weekly/sun/twin fired_marker)"
assert_eq "every/ marker carries the slot" '"fired/2026-11-15/every/15m/e-15/12-00"' "$(field schedule/every/15m/e-15 fired_marker)"
assert_eq "every/3h slot" '"fired/2026-11-15/every/3h/e-3h/12-00"' "$(field schedule/every/3h/e-3h fired_marker)"
assert_eq "every/7m slot is the latest at or before now" '"fired/2026-11-15/every/7m/e-7/11-54"' "$(field schedule/every/7m/e-7 fired_marker)"
assert_eq "once/ marker mirrors its path" '"fired/2026-11-15/once/2026-11-14/o-past"' "$(field schedule/once/2026-11-14/o-past fired_marker)"

# Paused components.
assert_eq "paused item" '["schedule/daily/p-item.paused"]' "$(field schedule/daily/p-item.paused paused_by)"
assert_eq "paused item is not eligible" false "$(field schedule/daily/p-item.paused eligible_now)"
assert_eq "paused item says subtree_paused" '["subtree_paused"]' "$(field schedule/daily/p-item.paused blocked_by)"
assert_eq "paused time folder" '["schedule/daily/09.paused"]' "$(field schedule/daily/09.paused/p-timed paused_by)"
assert_eq "paused day folder" '["schedule/weekly/sun.paused"]' "$(field schedule/weekly/sun.paused/p-day paused_by)"
assert_eq "paused axis" '["schedule/weekly.paused"]' "$(field schedule/weekly.paused/sun/p-axis paused_by)"
assert_eq "paused once date" '["schedule/once/2026-11-15.paused"]' "$(field schedule/once/2026-11-15.paused/p-once paused_by)"
assert_eq "paused items have no marker" null "$(field schedule/weekly.paused/sun/p-axis fired_marker)"
assert_eq "unpaused items list no pause" '[]' "$(field schedule/daily/d-plain paused_by)"

# The grammar-rejected names surface as diagnostics; the one walk_due fires is
# still an item, because status must say what tick would do.
assert_true "odd name is listed because tick would fire it" has_item "schedule/daily/odd name é"
assert_eq "odd name is eligible" true "$(field "schedule/daily/odd name é" eligible_now)"
codes="$(jq_py col "$T_TMP/sched.json" diagnostics code | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
assert_contains "unrecognized paths are diagnosed" "$codes" '"schedule_unrecognized_path"'
unrec="$(jq_py where "$T_TMP/sched.json" diagnostics code '"schedule_unrecognized_path"' path | tr '\n' '|')"
for p in "schedule/bogus|" "schedule/every/loose-item|" "schedule/monthly/99|" "schedule/daily/odd name é|"; do
  assert_contains "diagnosed: $p" "$unrec" "$p"
done
assert_false "bogus is not an item" has_item schedule/bogus/x
assert_eq "grammar problems do not make the snapshot inconsistent" true "$(jget "$T_TMP/sched.json" consistent)"

# --- the same moment after tick: fired items, one-shots gone ------------------
before_markers="$(jq_py where "$T_TMP/sched.json" schedule eligible_now true fired_marker | LC_ALL=C sort)"
gh tick >/dev/null 2>&1
status_to "$T_TMP/sched.json"
assert_json_valid "$T_TMP/sched.json"
for p in schedule/daily/d-plain schedule/weekly/sun/twin schedule/every/7m/e-7 "schedule/daily/odd name é"; do
  assert_eq "$p is fired after tick" true "$(field "$p" fired)"
  assert_eq "$p is no longer eligible" false "$(field "$p" eligible_now)"
  assert_eq "$p says already_fired" '["already_fired"]' "$(field "$p" blocked_by)"
  m="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["fired_marker"])' "$(item "$p")")"
  assert_true "$p: the marker status named exists on disk" test -e "$GHD/$m"
done
assert_eq "tick wrote exactly the markers status predicted" \
  "$before_markers" "$(find "$GHD/fired" -type f | sed "s#^$GHD/##" | LC_ALL=C sort)"
for p in schedule/once/o-root schedule/once/2026-11-14/o-past schedule/once/2026-11-15/o-today; do
  assert_false "$p was removed by its one-shot firing" has_item "$p"
done
assert_true "future one-shots stay" has_item schedule/once/2026-12-01/o-future
cross_check "Sun 12:00 after tick"
assert_eq "nothing is eligible once everything fired" "" "$(cat "$T_TMP/elig.status")"

# --- other moments, each against `due` ---------------------------------------
for clock in "2026-11-16 08:59:00" "2026-11-16 09:30:00" "2026-01-01 00:05:00" "2026-12-01 23:50:00" \
             "2026-02-28 23:59:00" "2028-02-29 10:00:00" "2026-03-15 09:30:00" "2026-11-15 00:00:00"; do
  build_fixture
  set_clock "$clock"
  cross_check "$clock"
done

# Monday: the weekly default and weekly/mon items wake up.
build_fixture
set_clock "2026-11-16 09:30:00"
status_to "$T_TMP/sched.json"
assert_eq "Monday: weekly root item is eligible" true "$(field schedule/weekly/w-root eligible_now)"
assert_eq "Monday: weekly/mon item is eligible" true "$(field schedule/weekly/mon/w-mon eligible_now)"
assert_eq "Monday: weekly/sun item is not" false "$(field schedule/weekly/sun/w-sun eligible_now)"
# The 1st of the month and Jan 1.
build_fixture
set_clock "2026-01-01 00:05:00"
status_to "$T_TMP/sched.json"
assert_eq "Jan 1: yearly root item is eligible" true "$(field schedule/yearly/y-root eligible_now)"
assert_eq "Jan 1: monthly root item is eligible" true "$(field schedule/monthly/m-root eligible_now)"
assert_eq "Jan 1 00:05: a 09:00 yearly item waits" false "$(field schedule/yearly/01-01/09/y-jan1-nine eligible_now)"

# --- local time schedules; observed_at is UTC ---------------------------------
export TZ=Pacific/Auckland
build_fixture
set_clock "2026-11-16 08:30:00"        # Monday in Auckland, still Sunday 19:30Z
status_to "$T_TMP/sched.json"
assert_eq "observed_at is UTC RFC 3339" '"2026-11-15T19:30:00Z"' "$(jget "$T_TMP/sched.json" observed_at)"
assert_eq "scheduling uses local time (Monday there)" true "$(field schedule/weekly/w-root eligible_now)"
assert_eq "local date names the marker" '"fired/2026-11-16/weekly/w-root"' "$(field schedule/weekly/w-root fired_marker)"
cross_check "Auckland Monday"
export TZ=UTC

clear_clock
t_finish
