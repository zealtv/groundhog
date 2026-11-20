#!/usr/bin/env bash
# `retry <delivery>`: start a delivery's run again, now, under the record's
# lock, with no token. Exit 0 started, 2 not a delivery of this instance,
# 3 paused, 4 busy (running, or the mutation lock is held), 5 nothing to run,
# 6 I/O failure. Every form of naming a delivery, every refusal, and two
# retries racing.
. "$(dirname "$0")/lib.sh"

if ! have_handlers; then
  t_skip "this host cannot start runs; see test_runtime_gate.sh for retry's refusal there"
  t_finish
  exit $?
fi

td="$(today)"
starts() { rec_count "$1" start; }
rc_err() { local rc=0; "$@" >"$T_TMP/r.out" 2>"$T_TMP/r.err" || rc=$?; echo "$rc"; }

# --- a failed run, retried --------------------------------------------------------
new_instance; gh init >/dev/null
with_run daily flaky 'echo "attempt $GROUNDHOG_ATTEMPT_ID of $GROUNDHOG_DELIVERY_ID"; [ -e "$1/fixed" ] || exit 2'
N="flaky-$td"
gh tick >/dev/null 2>&1
wait_for "the first run exits" 50 exited "$N" 1
assert_eq "the first run failed" '"failed"' "$(dstate "$N")"
touch "$GHD/out/$N/fixed"
assert_eq "retry of a failed delivery exits 0" 0 "$(rc_err gh retry "$N")"
assert_contains "...and says which attempt it started" "$(cat "$T_TMP/r.out")" "started out/$N (a-"
wait_for "the retry exits" 50 exited "$N" 2
snap
assert_eq "...now accepted" '"accepted"' "$(dget path "out/$N" state)"
assert_eq "...two attempts" 2 "$(jq_py dget "$T_TMP/dg.json" path "out/$N" attempts | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_eq "...the second by retry" '"retry"' "$(dget path "out/$N" attempts.1.by)"
assert_eq "...the first keeps its failure" 2 "$(dget path "out/$N" attempts.0.exit_status)"
DG_CACHED=0
a1="$(sed -n 1p "$(log "$N")")"; a2="$(sed -n 2p "$(log "$N")")"
assert_eq "both attempts share the delivery id" "${a1##* of }" "${a2##* of }"
assert_true "...and differ in attempt id" test "${a1%% of *}" != "${a2%% of *}"
assert_eq "the log holds both attempts' output" 2 "$(lines "$(log "$N")")"
assert_eq "the record holds one fired line, two starts and two exits" "1 2 2" "$(rec_count "$N" fired) $(starts "$N") $(rec_count "$N" exit)"
gh tick >/dev/null 2>&1
assert_eq "a tick after the retry starts nothing" 2 "$(starts "$N")"

# Every way to name it; an accepted delivery can be run again too.
for form in "out/$N" "$GHD/out/$N" "$GHD/out/$N/"; do
  assert_eq "retry '$form' exits 0" 0 "$(rc_err gh retry "$form")"
  n=$(( $(starts "$N") ))
  wait_for "...and that run exits" 50 exited "$N" "$n"
done
assert_eq "retry from another cwd, by name" 0 "$(cd "$T_TMP" && rc_err gh retry "$N")"
wait_for "...exits" 50 exited "$N" 6

# --- refusals ---------------------------------------------------------------------
new_instance; gh init >/dev/null
with_run daily long 'i=0; while [ $i -lt 100 ] && [ ! -e "$1/go" ]; do sleep 0.1; i=$((i+1)); done'
gh add daily plain >/dev/null
gh tick >/dev/null 2>&1
L="long-$td"
wait_for "the long run is up" 50 test -s "$GHD/out/$L/pid"
mkdir -p "$GHD/out/byhand" "$GHD/out/badrec" "$GHD/out/norun" "$GHD/out/x.landing" "$T_TMP/elsewhere/$L"
printf '#!/bin/sh\nexit 0\n' > "$GHD/out/byhand/run"; chmod +x "$GHD/out/byhand/run"
printf 'not a record\n' > "$GHD/out/badrec/.groundhog-record"
printf 'fired d-1 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/norun\n' > "$GHD/out/norun/.groundhog-record"
: > "$GHD/out/afile"
before="$(cat "$(rec "$L")")"
assert_eq "retry with no argument exits 2" 2 "$(rc_err gh retry)"
assert_eq "retry with two arguments exits 2" 2 "$(rc_err gh retry "$L" extra)"
assert_eq "an unknown name exits 2" 2 "$(rc_err gh retry nope)"
assert_eq "a file in out/ exits 2" 2 "$(rc_err gh retry afile)"
assert_eq "a .landing copy exits 2" 2 "$(rc_err gh retry x.landing)"
assert_eq "a path that climbs out exits 2" 2 "$(rc_err gh retry "out/../schedule")"
assert_eq "a same-named directory outside out/ exits 2" 2 "$(rc_err gh retry "$T_TMP/elsewhere/$L")"
assert_eq "a running delivery exits 4" 4 "$(rc_err gh retry "$L")"
assert_contains "...saying it is running" "$(cat "$T_TMP/r.err")" "is running"
assert_eq "...and wrote nothing to its record" "$before" "$(cat "$(rec "$L")")"
assert_eq "a delivery with no run exits 5" 5 "$(rc_err gh retry "plain-$td")"
assert_eq "a payload put in out/ by hand exits 5" 5 "$(rc_err gh retry byhand)"
assert_contains "...saying it never runs" "$(cat "$T_TMP/r.err")" "never runs"
assert_eq "a malformed record exits 5" 5 "$(rc_err gh retry badrec)"
assert_eq "a record whose run is gone exits 5" 5 "$(rc_err gh retry norun)"
assert_eq "...and none of them started anything" "0 0 0" "$(starts "plain-$td") $(starts norun) $(lines "$GHD/out/byhand/.groundhog-record")"
touch "$GHD/out/$L/go"
wait_for "the long run exits" 50 exited "$L" 1

# Paused: exit 3, and nothing starts.
gh pause >/dev/null
assert_eq "retry while paused exits 3" 3 "$(rc_err gh retry "$L")"
assert_contains "...saying so" "$(cat "$T_TMP/r.err")" "paused"
assert_eq "...nothing started" 1 "$(starts "$L")"
gh resume >/dev/null

# A held mutation lock: exit 4 after the wait.
hold_lock "$GHD/runtime/locks/mutation.lock" 30
assert_eq "retry against a held mutation lock exits 4" 4 "$(rc_err gh retry "$L")"
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
# Another holder of the record's lock: exit 4, record untouched.
hold_lock "$(rec "$L")" 30
assert_eq "retry while another process holds the record's lock exits 4" 4 "$(rc_err gh retry "$L")"
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
assert_eq "...nothing started" 1 "$(starts "$L")"

# --- an interrupted delivery, and two retries racing --------------------------------
new_instance; gh init >/dev/null
with_run daily job 'i=0; while [ $i -lt 100 ] && [ ! -e "$1/go" ]; do sleep 0.1; i=$((i+1)); done; rm -f "$1/go"'
J="job-$td"
gh tick >/dev/null 2>&1
wait_for "the run is up" 50 test -s "$GHD/out/$J/pid"
kill_run "$J" KILL
wait_for "...killed, its lock is free" 50 lock_is_free "$(rec "$J")"
assert_eq "it reads interrupted" '"interrupted"' "$(dstate "$J")"
for k in 1 2 3; do ( rc=0; gh retry "$J" >/dev/null 2>&1 || rc=$?; echo "$rc" > "$T_TMP/rr.$k" ) & done
wait
assert_eq "three racing retries: one starts, the others find it busy" "0 4 4" "$(cat "$T_TMP"/rr.* | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "...one new attempt" 2 "$(starts "$J")"
touch "$GHD/out/$J/go"
wait_for "the retried run exits" 50 exited "$J" 1
assert_eq "...and it is accepted" '"accepted"' "$(dstate "$J")"

# A pending delivery (fired, never started) can be started by retry; no tick starts it again.
mkdir -p "$GHD/out/pend"; printf '#!/bin/sh\necho x >> "$1/count"\n' > "$GHD/out/pend/run"; chmod +x "$GHD/out/pend/run"
printf 'fired d-2 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/pend\n' > "$(rec pend)"
gh pause >/dev/null; gh resume >/dev/null
assert_eq "retry of a pending delivery exits 0" 0 "$(rc_err gh retry pend)"
wait_for "...it ran" 50 exited pend 1
gh tick >/dev/null 2>&1
sleep 0.3
assert_eq "...once" 1 "$(lines "$GHD/out/pend/count")"

t_finish
