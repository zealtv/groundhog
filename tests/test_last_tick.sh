#!/usr/bin/env bash
# The last-tick record: runtime/last_tick, and status's additive last_tick field
# ({at, source}, null when never recorded). Liveness only.
. "$(dirname "$0")/lib.sh"

if ! have_lock_helper; then
  t_skip "this host has no lock helper, so no tick is recorded"
  t_finish
  exit $?
fi

out="$T_TMP/lt.json"
re_at='^"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"$'
is_utc() { [[ "$1" =~ $re_at ]]; }

# --- before any tick: null, and status writes nothing ---------------------------
new_instance
gh init >/dev/null
gh add daily nudge >/dev/null
age_tree "$GHD"
h0="$(tree_hash "$GHD")"
status_to "$out"
assert_json_valid "$out"
assert_eq "status before any tick: last_tick is null" null "$(jget "$out" last_tick)"
assert_eq "...and status left the instance untouched" "$h0" "$(tree_hash "$GHD")"

# --- a standalone tick ------------------------------------------------------------
gh tick >/dev/null 2>&1
status_to "$out"
assert_json_valid "$out"
assert_eq "a standalone tick records source standalone" '"standalone"' "$(jget "$out" last_tick.source)"
is_utc "$(jget "$out" last_tick.at)" && t_ok || t_fail "last_tick.at is a UTC time" "$(jget "$out" last_tick.at)"
assert_eq "the record is one line of time and source" 1 "$(wc -l < "$GHD/runtime/last_tick" | tr -d ' ')"
assert_false "no temp file is left behind" sh -c "ls -a '$GHD/runtime' | grep -q 'last_tick.*tmp'"

# A tick that fires nothing still records (the item already fired today).
rm -f "$GHD/runtime/last_tick"
gh tick >/dev/null 2>&1
assert_eq "...nothing new fired" 1 "$(out_count)"
assert_true "a tick that fires nothing still records" test -s "$GHD/runtime/last_tick"

# --- damaged or foreign records read as null; status never fails -----------------
for bad in "" "garbage" "2026-11-17T10:00:00Z" "2026-11-17T10:00:00Z somebody" "2026-11-17T10:00:00Z runner extra"; do
  printf '%s' "$bad" > "$GHD/runtime/last_tick"
  rc=0; status_to "$out" || rc=$?
  assert_eq "status exits 0 over a damaged record ($bad)" 0 "$rc"
  assert_eq "...and reports null ($bad)" null "$(jget "$out" last_tick)"
done
rm -f "$GHD/runtime/last_tick"; mkdir "$GHD/runtime/last_tick"
rc=0; status_to "$out" || rc=$?
assert_eq "status exits 0 when last_tick is a directory" 0 "$rc"
assert_eq "...and reports null" null "$(jget "$out" last_tick)"
rmdir "$GHD/runtime/last_tick"

# --- a paused standalone tick counts -----------------------------------------------
new_instance
gh init >/dev/null
gh add daily nudge >/dev/null
gh pause >/dev/null
status_to "$out"
assert_eq "paused, no tick yet: null" null "$(jget "$out" last_tick)"
gh tick >/dev/null 2>&1
assert_eq "the paused tick fired nothing" 0 "$(out_count)"
status_to "$out"
assert_eq "a paused standalone tick is recorded" '"standalone"' "$(jget "$out" last_tick.source)"

# --- a tick that fails records nothing --------------------------------------------------
new_instance
gh init >/dev/null
mkdir -p "$GHD/runtime/locks"
hold_lock "$GHD/runtime/locks/mutation.lock" 30
rc=0; gh tick >/dev/null 2>&1 || rc=$?
assert_eq "a tick that cannot take the mutation lock exits 4" 4 "$rc"
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
status_to "$out"
assert_eq "...and leaves no record" null "$(jget "$out" last_tick)"

# --- the run loop's ticks, paused or not ---------------------------------------------
new_instance
gh init >/dev/null
gh add daily nudge >/dev/null
gh pause >/dev/null
start_loop --interval-seconds 1
lt_runner() { status_to "$out"; [ "$(jget "$out" last_tick.source)" = '"runner"' ]; }
wait_for "a paused loop's tick is recorded" 60 lt_runner
assert_eq "...and fired nothing" 0 "$(out_count)"
at1="$(jget "$out" last_tick.at)"
is_utc "$at1" && t_ok || t_fail "loop last_tick.at is a UTC time" "$at1"
moved() { status_to "$out"; [ "$(jget "$out" last_tick.at)" != "$at1" ]; }
wait_for "later ticks move the time" 80 moved
gh resume >/dev/null 2>&1
wait_for "after resume the loop fires" 60 out_is 1
assert_eq "an unpaused loop tick keeps source runner" '"runner"' "$(jget "$out" last_tick.source)"
kill -INT "$LOOP_PID" 2>/dev/null
wait_exit "the loop exits on SIGINT" 50 "$LOOP_PID"
assert_eq "...with status 0" 0 "$WAIT_RC"
status_to "$out"
assert_eq "the record outlives the loop" '"runner"' "$(jget "$out" last_tick.source)"

t_finish
