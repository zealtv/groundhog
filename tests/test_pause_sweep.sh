#!/usr/bin/env bash
# The instance pause (capability pause-v2: no token) gates firings and run
# starts alike, and leaves runs already going alone; `sweep` keeps pending and
# running deliveries whatever their age; and `run` is a plain tick loop whose
# runs outlive it.
. "$(dirname "$0")/lib.sh"

td="$(today)"
starts() { rec_count "$1" start; }
out="$T_TMP/p.json"

# --- pause and resume ------------------------------------------------------------
new_instance; gh init >/dev/null
assert_eq "pause exits 0" 0 "$(rc_of gh pause)"
assert_true "...and leaves runtime/paused" test -f "$GHD/runtime/paused"
assert_eq "pause again is fine" 0 "$(rc_of gh pause)"
status_to "$out"; assert_eq "status says paused" true "$(jget "$out" paused)"
assert_eq "resume exits 0" 0 "$(rc_of gh resume)"
assert_false "...and removes it" test -e "$GHD/runtime/paused"
assert_eq "resume again is fine" 0 "$(rc_of gh resume)"
status_to "$out"; assert_eq "status says not paused" false "$(jget "$out" paused)"
assert_eq "pause takes no arguments (protocol 1's --token-file exits 2)" 2 "$(rc_of gh pause --token-file /nonexistent)"
assert_eq "resume takes none either" 2 "$(rc_of gh resume x)"
assert_false "...and neither changed anything" test -e "$GHD/runtime/paused"

if have_handlers; then
  # --- paused: nothing fires and nothing starts; resume catches up ---------------------
  new_instance; gh init >/dev/null
  with_run daily job 'echo ran >> "$1/count"'
  mkdir -p "$GHD/out/pend"; printf '#!/bin/sh\necho ran >> "$1/count"\n' > "$GHD/out/pend/run"; chmod +x "$GHD/out/pend/run"
  printf 'fired d-1 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/pend\n' > "$(rec pend)"
  gh pause >/dev/null
  err="$(gh tick 2>&1 >/dev/null)"
  assert_contains "a paused tick says so" "$err" "paused"
  sleep 0.3
  assert_eq "...fires nothing" 1 "$(out_count)"
  assert_eq "...and starts nothing" 0 "$(starts pend)"
  status_to "$out"
  assert_contains "the schedule says instance_paused" "$(jq_py find "$out" schedule path schedule/daily/job)" '"instance_paused"'
  gh resume >/dev/null
  gh tick >/dev/null 2>&1
  wait_for "after resume the tick fires and starts both" 50 sh -c "test -s '$GHD/out/job-$td/count' && test -s '$GHD/out/pend/count'"

  # --- a run already going is left alone ------------------------------------------------
  new_instance; gh init >/dev/null
  with_run daily slow 'i=0; while [ $i -lt 100 ] && [ ! -e "$1/go" ]; do sleep 0.1; i=$((i+1)); done; exit 0'
  gh tick >/dev/null 2>&1
  wait_for "the run is up" 50 test -s "$GHD/out/slow-$td/pid"
  gh pause >/dev/null
  assert_eq "pausing leaves the run running" '"running"' "$(dstate "slow-$td")"
  touch "$GHD/out/slow-$td/go"
  wait_for "...which finishes and is recorded while paused" 50 exited "slow-$td" 1
  assert_eq "...accepted" '"accepted"' "$(dstate "slow-$td")"
  gh resume >/dev/null

  # --- pause waits for a tick in progress ------------------------------------------------
  new_instance; gh init >/dev/null
  mkdir -p "$GHD/runtime/locks"
  hold_lock "$GHD/runtime/locks/mutation.lock" 30
  assert_eq "pause against a held mutation lock exits 4" 4 "$(rc_of gh pause)"
  assert_false "...and does not pause" test -e "$GHD/runtime/paused"
  kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
fi

# --- sweep ----------------------------------------------------------------------------
new_instance; gh init >/dev/null
f='fired d-1 2026-11-01T10:00:00Z run 2026-11-01 - schedule/daily/x'
for s in pending running accepted failed interrupted delivered unrecorded; do mkdir -p "$GHD/out/$s"; done
for s in pending running accepted failed interrupted; do printf '%s\n' "$f" > "$(rec "$s")"; done
printf 'fired d-2 2026-11-01T10:00:00Z none 2026-11-01 - schedule/daily/x\n' > "$(rec delivered)"
for s in running accepted failed interrupted; do printf 'start a-1 2026-11-01T10:00:01Z tick\n' >> "$(rec "$s")"; done
printf 'exit a-1 2026-11-01T10:00:02Z 0\n' >> "$(rec accepted)"
printf 'exit a-1 2026-11-01T10:00:02Z 1\n' >> "$(rec failed)"
mkdir -p "$GHD/out/old.landing" "$GHD/fired/2026-11-01/daily" "$GHD/out/young"
printf '%s\n' "$f" > "$(rec young)"
age_tree "$GHD/out"; age_tree "$GHD/fired"
touch "$GHD/out/young"
if have_lock_helper; then hold_lock "$(rec running)" 30; fi
sout="$(gh sweep 14 2>&1)"
for s in pending running; do
  have_lock_helper || [ "$s" != running ] || continue
  assert_true "sweep keeps an old $s delivery" test -d "$GHD/out/$s"
  assert_contains "...and says so" "$sout" "skipped out $s ($s)"
done
for s in accepted failed interrupted delivered unrecorded old.landing; do
  assert_false "sweep removes an old $s delivery" test -e "$GHD/out/$s"
done
assert_true "...but not a young pending one" test -d "$GHD/out/young"
assert_false "...and removes the old fired date" test -e "$GHD/fired/2026-11-01"
assert_contains "...reporting it" "$sout" "swept fired 2026-11-01"
if have_lock_helper; then kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null; fi
assert_eq "sweep with a bad <days> exits 1" 1 "$(rc_of gh sweep x)"
# Deleting a delivery by hand is dismissal: fired/ remembers, nothing fires again.
new_instance; gh init >/dev/null
gh add daily once-a-day >/dev/null
gh tick >/dev/null 2>&1
rm -rf "$GHD/out/once-a-day-$td"
gh tick >/dev/null 2>&1
assert_eq "a dismissed delivery does not come back today" 0 "$(out_count)"

# --- the run loop ------------------------------------------------------------------------
new_instance; gh init >/dev/null
assert_eq "run with a stray argument exits 2" 2 "$(rc_of gh run --token-file x)"
assert_eq "run with a bad interval exits 2" 2 "$(rc_of gh run --interval-seconds 0)"
assert_eq "run with the interval twice exits 2" 2 "$(rc_of gh run --interval-seconds 1 --interval-seconds 2)"
if have_handlers; then
  with_run every/1m beat 'sleep 30'
  start_loop --interval-seconds 1
  wait_for "the loop fires the item and starts its run" 80 sh -c "ls '$GHD'/out/beat-*/pid >/dev/null 2>&1"
  B="$(ls "$GHD/out" | grep '^beat-' | head -1)"
  kill -INT -- "-$LOOP_PID" 2>/dev/null     # Ctrl-C reaches the loop's whole process group
  wait_exit "the loop ends on Ctrl-C" 80 "$LOOP_PID"
  assert_eq "...with exit 0" 0 "$WAIT_RC"
  assert_contains "...saying so" "$(cat "$LOOP_ERR")" "stopped"
  assert_eq "the run it started outlives it" '"running"' "$(dstate "$B")"
  kill_run "$B"
  wait_for "...until its own session is signalled" 50 exited "$B" 1
fi

t_finish
