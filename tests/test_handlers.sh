#!/usr/bin/env bash
# An item's own run (capability handlers-v1): the record written into the
# .landing copy before the rename, the run-pending scan every tick makes, the
# wrapper in its own session holding the record's lock for the life of `run`,
# what `run` gets ($1, cwd, environment, stdin, the log), exit statuses, and
# the crash and interrupt cases: a free lock with an open start is interrupted
# and never re-run by itself. Every run here is a /bin/sh script that finishes
# by itself or is killed by its process group before the test ends.
. "$(dirname "$0")/lib.sh"

if ! have_handlers; then
  t_skip "this host cannot start runs (no lock helper, or no perl/setsid); see test_runtime_gate.sh"
  t_finish
  exit $?
fi

out="$T_TMP/h.json"
td="$(today)"
re_utc='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
starts() { rec_count "$1" start; }

# --- 1. the record at firing ------------------------------------------------------
new_instance; gh init >/dev/null
with_run daily job 'echo "out line"; echo "err line" >&2; exit 0'
gh add daily plain >/dev/null; echo hi > "$GHD/schedule/daily/plain/note.txt"
gh add daily noexec >/dev/null; printf '#!/bin/sh\ntouch "$1/ran"\n' > "$GHD/schedule/daily/noexec/run"
gh add once broken >/dev/null; ln -s ../../nowhere/run "$GHD/schedule/once/broken/run"
# Reserved files in a schedule item are replaced at firing, never delivered.
printf 'fired d-forged 2026-01-01T00:00:00Z run 2026-01-01 - schedule/daily/forged\nstart a-x 2026-01-01T00:00:00Z tick\n' > "$GHD/schedule/daily/plain/.groundhog-record"
echo "old log" > "$GHD/schedule/daily/plain/.groundhog-log"
src_sum="$(tree_hash "$GHD/schedule/daily/plain")"
tout="$(gh tick 2>"$T_TMP/tick.err")"; rc=$?
assert_eq "tick exits 0" 0 "$rc"
assert_contains "tick says it started the run" "$tout" "started out/job-$td (a-"
assert_true "the record's first line is the fired line" \
  grep -Eq "^fired d-[0-9a-f]{16} $re_utc run $td - schedule/daily/job\$" "$(rec "job-$td")"
assert_eq "...written once" 1 "$(rec_count "job-$td" fired)"
wait_for "the run exits" 50 exited "job-$td" 1
assert_true "the start line names the attempt and the tick" grep -Eq "^start a-[0-9a-f]{16} $re_utc tick\$" "$(rec "job-$td")"
aid="$(sed -n 's/^start \([^ ]*\) .*/\1/p' "$(rec "job-$td")")"
assert_true "the exit line names the same attempt and the status" grep -Eq "^exit $aid $re_utc 0\$" "$(rec "job-$td")"
assert_eq "the record is exactly fired, start, exit" "fired start exit" "$(cut -d' ' -f1 "$(rec "job-$td")" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "run's stdout and stderr went to the log" "out line|err line" "$(tr '\n' '|' < "$(log "job-$td")" | sed 's/|$//')"
assert_true "a plain item gets a record too, saying none" \
  grep -Eq "^fired d-[0-9a-f]{16} $re_utc none $td - schedule/daily/plain\$" "$(rec "plain-$td")"
assert_eq "...the forged record did not travel: one line" 1 "$(lines "$(rec "plain-$td")")"
assert_false "...nor did the old log" test -e "$(log "plain-$td")"
assert_eq "...the payload itself is delivered" hi "$(cat "$GHD/out/plain-$td/note.txt")"
assert_eq "...and the schedule item is untouched" "$src_sum" "$(tree_hash "$GHD/schedule/daily/plain")"
assert_true "a run that is not executable means none" rec_has "noexec-$td" ' none '
assert_contains "...and the tick warns about it" "$(cat "$T_TMP/tick.err")" "schedule/daily/noexec/run is not an executable file"
assert_true "a broken run link in a once item means none too" rec_has "broken-$td" ' none '
assert_contains "...with a warning" "$(cat "$T_TMP/tick.err")" "schedule/once/broken/run is not an executable file"
assert_false "...and the one-shot's source is consumed" test -e "$GHD/schedule/once/broken"
snap
assert_eq "status: the job accepted" '"accepted"' "$(dget path "out/job-$td" state)"
assert_eq "...exit_status 0" 0 "$(dget path "out/job-$td" exit_status)"
assert_eq "...run true" true "$(dget path "out/job-$td" run)"
assert_eq "...one attempt, by tick" '"tick"' "$(dget path "out/job-$td" attempts.0.by)"
assert_eq "...whose id is the start line's" "\"$aid\"" "$(dget path "out/job-$td" attempts.0.id)"
assert_eq "...the delivery id is the record's" "\"$(cut -d' ' -f2 < "$(rec "job-$td")" | head -1)\"" "$(dget path "out/job-$td" id)"
assert_eq "...the log is named" "\"out/job-$td/.groundhog-log\"" "$(dget path "out/job-$td" log)"
assert_eq "...the occurrence" "{\"date\":\"$td\",\"slot\":null}" "$(dget path "out/job-$td" occurrence)"
assert_eq "the plain item is delivered" '"delivered"' "$(dget path "out/plain-$td" state)"
assert_eq "...with no run and no attempts" "false []" "$(dget path "out/plain-$td" run) $(dget path "out/plain-$td" attempts)"
assert_eq "...and no log" null "$(dget path "out/plain-$td" log)"
assert_contains "status flags the non-executable run" "$(jget "$T_TMP/dg.json" diagnostics)" "\"run_not_executable\",\"message\":\"out/noexec-$td/run"
assert_contains "...and the broken link" "$(jget "$T_TMP/dg.json" diagnostics)" "out/broken-$td/run was not an executable file"
DG_CACHED=0
sleep 0.3
assert_false "the non-executable run never ran" test -e "$GHD/out/noexec-$td/ran"
gh tick >/dev/null 2>&1
assert_eq "a later tick does not run an accepted delivery again" 1 "$(starts "job-$td")"

# every/ records its slot.
new_instance; gh init >/dev/null
set_clock "2026-11-15 14:05:00"
gh add every/15m beat >/dev/null
gh tick >/dev/null 2>&1
clear_clock
assert_true "an every/ firing records its slot" rec_has "beat-2026-11-15-14-00" '^fired d-[0-9a-f]+ [^ ]+ none 2026-11-15 14-00 schedule/every/15m/beat$'
assert_eq "...and status shows it" '{"date":"2026-11-15","slot":"14-00"}' "$(dget path out/beat-2026-11-15-14-00 occurrence)"

# --- 2. what run gets ---------------------------------------------------------------
new_instance; gh init >/dev/null
GROUNDHOG_DELIVERY_ID=leaked; export GROUNDHOG_DELIVERY_ID
with_run daily env '
{
  echo "arg=$1"
  echo "argc=$#"
  echo "cwd=$(pwd -P)"
  echo "instance=$GROUNDHOG_INSTANCE"
  echo "delivery=$GROUNDHOG_DELIVERY_ID"
  echo "attempt=$GROUNDHOG_ATTEMPT_ID"
  if read -r line; then echo "stdin=data"; else echo "stdin=eof"; fi
  if [ -e /dev/fd/7 ]; then echo "fd7=open"; else echo "fd7=closed"; fi
  if [ -e /dev/fd/9 ]; then echo "fd9=open"; else echo "fd9=closed"; fi
  echo "pgid=$(ps -o pgid= -p $$ | tr -d " ")"
} > "$1/seen"'
echo "not for run" | gh tick >/dev/null 2>&1
unset GROUNDHOG_DELIVERY_ID
wait_for "the env run exits" 50 exited "env-$td" 1
seen() { sed -n "s/^$1=//p" "$GHD/out/env-$td/seen"; }
assert_eq "\$1 is the absolute delivery path" "$GHD/out/env-$td" "$(seen arg)"
assert_eq "...and the only argument" 1 "$(seen argc)"
assert_eq "cwd is the project (the directory holding .groundhog/)" "$INST" "$(seen cwd)"
assert_eq "GROUNDHOG_INSTANCE is the instance directory" "$GHD" "$(seen instance)"
assert_eq "GROUNDHOG_DELIVERY_ID is the record's delivery id" "$(cut -d' ' -f2 < "$(rec "env-$td")" | head -1)" "$(seen delivery)"
assert_eq "GROUNDHOG_ATTEMPT_ID is the start line's attempt id" "$(sed -n 's/^start \([^ ]*\) .*/\1/p' "$(rec "env-$td")")" "$(seen attempt)"
assert_eq "stdin is empty, not the tick's" eof "$(seen stdin)"
assert_eq "run does not hold the record's lock fd" closed "$(seen fd7)"
assert_eq "...nor the mutation lock's" closed "$(seen fd9)"
mypgid="$(ps -o pgid= -p $$ | tr -d ' ')"
assert_true "run is in a process group of its own" test "$(seen pgid)" != "$mypgid"

# --- 3. exit statuses, a slow run, and the lock --------------------------------------
new_instance; gh init >/dev/null
with_run daily bad 'exit 7'
with_run daily slow 'touch "$1/begun"; i=0; while [ $i -lt 100 ] && [ ! -e "$1/go" ]; do sleep 0.1; i=$((i+1)); done; echo finished'
t0=$SECONDS
gh tick >/dev/null 2>&1
assert_true "tick returned while the slow run still runs (it does not wait)" test $((SECONDS - t0)) -le 5
wait_for "the slow run began" 50 test -e "$GHD/out/slow-$td/begun"
wait_for "the bad run exits" 50 exited "bad-$td" 1
snap
assert_eq "exit 7 is failed" '"failed"' "$(dget path "out/bad-$td" state)"
assert_eq "...with exit_status 7" 7 "$(dget path "out/bad-$td" exit_status)"
assert_eq "the slow run is running" '"running"' "$(dget path "out/slow-$td" state)"
assert_eq "...with an open attempt" null "$(dget path "out/slow-$td" attempts.0.finished_at)"
DG_CACHED=0
assert_true "...its record's lock is held" lock_is_held "$(rec "slow-$td")"
gh tick >/dev/null 2>&1
assert_eq "a tick while it runs starts nothing more" 1 "$(starts "slow-$td")"
touch "$GHD/out/slow-$td/go"
wait_for "the slow run exits" 50 exited "slow-$td" 1
wait_for "...and its lock goes with the wrapper" 50 lock_is_free "$(rec "slow-$td")"
assert_eq "...accepted" '"accepted"' "$(dstate "slow-$td")"

# A signal to the wrapper alone waits for run: the lock and the exit line stay right.
new_instance; gh init >/dev/null
with_run daily hold 'i=0; while [ $i -lt 100 ] && [ ! -e "$1/go" ]; do sleep 0.1; i=$((i+1)); done; exit 3'
gh tick >/dev/null 2>&1
wait_for "the run is up" 50 test -s "$GHD/out/hold-$td/pid"
w="$(wrapper_of "hold-$td")"
assert_true "the wrapper is its own process group's leader" test "$(ps -o pgid= -p "$w" | tr -d ' ')" = "$w"
kill -TERM "$w" 2>/dev/null; kill -HUP "$w" 2>/dev/null; kill -INT "$w" 2>/dev/null
sleep 0.5
assert_eq "after TERM, HUP and INT to the wrapper it is still running" '"running"' "$(dstate "hold-$td")"
touch "$GHD/out/hold-$td/go"
wait_for "the run exits" 50 exited "hold-$td" 1
assert_eq "...and its own status is recorded" 3 "$(dget path "out/hold-$td" exit_status)"

# --- 4. interrupted: never re-run by itself ---------------------------------------------
new_instance; gh init >/dev/null
with_run daily long 'sleep 30'
gh tick >/dev/null 2>&1
wait_for "the long run is up" 50 test -s "$GHD/out/long-$td/pid"
kill_run "long-$td" KILL
wait_for "the session is gone" 50 sh -c "! kill -0 $(cat "$GHD/out/long-$td/pid") 2>/dev/null"
wait_for "...and the lock is free" 50 lock_is_free "$(rec "long-$td")"
snap
assert_eq "a free lock with an open start is interrupted" '"interrupted"' "$(dget path "out/long-$td" state)"
assert_eq "...with no exit_status" null "$(dget path "out/long-$td" exit_status)"
DG_CACHED=0
gh tick >/dev/null 2>&1; gh tick >/dev/null 2>&1
assert_eq "later ticks never start it again" 1 "$(starts "long-$td")"

# A kill -9 of the wrapper alone: interrupted, though run itself goes on (the
# lock is the wrapper's). Check before retrying.
with_run daily orphan 'i=0; while [ $i -lt 100 ] && [ ! -e "$1/go" ]; do sleep 0.1; i=$((i+1)); done'
gh tick >/dev/null 2>&1
wait_for "the orphan's run is up" 50 test -s "$GHD/out/orphan-$td/pid"
kill -9 "$(wrapper_of "orphan-$td")"
wait_for "...its lock is free" 50 lock_is_free "$(rec "orphan-$td")"
assert_eq "a wrapper killed alone reads interrupted" '"interrupted"' "$(dstate "orphan-$td")"
assert_true "...while its run is still alive" kill -0 "$(cat "$GHD/out/orphan-$td/pid")"
touch "$GHD/out/orphan-$td/go"
wait_for "...until it ends by itself" 50 sh -c "! kill -0 $(cat "$GHD/out/orphan-$td/pid") 2>/dev/null"

# A torn start line still counts as a start: it fails closed, never pending.
mkdir -p "$GHD/out/torn"
printf '#!/bin/sh\ntouch "$1/ran"\n' > "$GHD/out/torn/run"; chmod +x "$GHD/out/torn/run"
printf 'fired d-7 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/torn\nstart a-1 2026-11-1exit a-1 2026-11-15T10:00:02Z 0\n' > "$(rec torn)"
gh tick >/dev/null 2>&1
sleep 0.3
assert_eq "a torn start line reads interrupted" '"interrupted"' "$(dstate torn)"
assert_false "...and the tick did not start it" test -e "$GHD/out/torn/ran"
assert_eq "...status shows the attempt with what it could not read as null" null "$(dget path out/torn attempts.0.started_at)"

# A crash between the start line and the wrapper looks the same.
mkdir -p "$GHD/out/half"
printf '#!/bin/sh\ntouch "$1/ran"\n' > "$GHD/out/half/run"; chmod +x "$GHD/out/half/run"
printf 'fired d-1 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/half\nstart a-1 2026-11-15T10:00:01Z tick\n' > "$(rec half)"
gh tick >/dev/null 2>&1
sleep 0.3
assert_eq "a start the wrapper never took up is interrupted" '"interrupted"' "$(dstate half)"
assert_false "...and the tick did not run it" test -e "$GHD/out/half/ran"

# --- 5. fired, not yet run: any tick catches up ---------------------------------------------
# A tick that died after the rename (before its scan) leaves exactly this: a
# record that says fired and never started.
new_instance; gh init >/dev/null
mkdir -p "$GHD/out/left" "$GHD/out/byhand" "$GHD/out/left-2.landing"
for d in left byhand left-2.landing; do printf '#!/bin/sh\ntouch "$1/ran"\n' > "$GHD/out/$d/run"; chmod +x "$GHD/out/$d/run"; done
printf 'fired d-2 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/left\n' > "$(rec left)"
printf 'fired d-3 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/left\n' > "$GHD/out/left-2.landing/.groundhog-record"
snap
assert_eq "status: fired and never started is pending" '"pending"' "$(dget path out/left state)"
assert_eq "...a payload put in out/ by hand is unrecorded" '"unrecorded"' "$(dget path out/byhand state)"
assert_eq "...and a .landing copy is not a delivery" '<missing>' "$(dget path out/left-2.landing state)"
DG_CACHED=0
gh tick >/dev/null 2>&1
wait_for "the next tick ran the pending delivery" 50 test -e "$GHD/out/left/ran"
sleep 0.3
assert_false "...never the payload placed by hand" test -e "$GHD/out/byhand/ran"
assert_false "...nor the half-made .landing copy" test -e "$GHD/out/left-2.landing/ran"

# A record whose lock someone else holds is left to them, and started once it is free.
new_instance; gh init >/dev/null
mkdir -p "$GHD/out/held"
printf '#!/bin/sh\ntouch "$1/ran"\n' > "$GHD/out/held/run"; chmod +x "$GHD/out/held/run"
printf 'fired d-4 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/held\n' > "$(rec held)"
hold_lock "$(rec held)" 30
gh tick >/dev/null 2>&1
assert_eq "a tick leaves a delivery whose lock is held" 0 "$(starts held)"
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
gh tick >/dev/null 2>&1
wait_for "...and starts it once the lock is free" 50 test -e "$GHD/out/held/ran"
assert_eq "...once" 1 "$(starts held)"

# --- 6. ticks racing ---------------------------------------------------------------------
# Several ticks (and a loop) at once: every firing happens once and every run starts once.
new_instance; gh init >/dev/null
i=1; while [ "$i" -le 8 ]; do with_run daily "r$i" 'echo x >> "$1/count"; sleep 0.5'; i=$((i + 1)); done
mkdir -p "$GHD/out/pend"; printf '#!/bin/sh\necho x >> "$1/count"\n' > "$GHD/out/pend/run"; chmod +x "$GHD/out/pend/run"
printf 'fired d-5 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/pend\n' > "$(rec pend)"
start_loop --interval-seconds 1
pids=""
for k in 1 2 3 4; do ( gh tick >/dev/null 2>&1; echo $? > "$T_TMP/race.$k" ) & pids="$pids $!"; done
wait $pids
kill -TERM "$LOOP_PID" 2>/dev/null; wait_exit "the loop stops" 80 "$LOOP_PID"
alldone() { local d; for d in "$GHD"/out/r* "$GHD/out/pend"; do exited "${d##*/}" 1 || return 1; done; }
wait_for "every run finished" 80 alldone
bad=0; for d in "$GHD"/out/r* "$GHD/out/pend"; do
  [ "$(lines "$d/count")" = 1 ] && [ "$(starts "${d##*/}")" = 1 ] && [ "$(rec_count "${d##*/}" fired)" = 1 ] || { bad=$((bad + 1)); printf 'raced: %s\n' "$d" >&2; }
done
assert_eq "racing ticks: each delivery fired once and ran once" 0 "$bad"
assert_eq "...nine deliveries, no collisions" "9 0" "$(out_count) $(cat "$GHD"/out/*/.groundhog-record | grep -c '^collision' || true)"
ok=0; for k in 1 2 3 4; do r="$(cat "$T_TMP/race.$k")"; [ "$r" = 0 ] || [ "$r" = 4 ] || ok=1; done
assert_eq "...each racing tick exited 0, or 4 for a busy mutation lock" 0 "$ok"

# --- 7. a run that moves or removes its own delivery --------------------------------------
new_instance; gh init >/dev/null
with_run daily mover 'mv "$1" "$1.taken"'
with_run daily remover 'rm -rf "$1"'
gh tick >/dev/null 2>&1
wait_for "the mover's exit lands in the moved record" 50 exited "mover-$td.taken" 1
assert_eq "...which status reads at its new name" '"accepted"' "$(dstate "mover-$td.taken")"
wait_for "the remover's delivery is gone" 50 sh -c "! test -e '$GHD/out/remover-$td'"
sleep 0.3
assert_eq "...and nothing is left of it" "" "$(ls "$GHD/out" | grep remover || true)"

# --- 8. a run that cannot run ----------------------------------------------------------------
new_instance; gh init >/dev/null
with_run daily vanish 'exit 0'
mkdir -p "$GHD/out/gone-run"
printf 'fired d-6 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/gone\n' > "$(rec gone-run)"
gh tick >/dev/null 2>&1
wait_for "a run that is gone exits 127" 50 exited gone-run 1
assert_eq "...recorded as failed" '"failed"' "$(dstate gone-run)"
assert_eq "...with 127" 127 "$(dget path out/gone-run exit_status)"
wait_for "the other run still ran" 50 exited "vanish-$td" 1

# --- 9. a firing that fails costs only that item ------------------------------------------
# An unreadable file in an item that sorts first, and an item without owner write.
new_instance; gh init >/dev/null
gh add daily aaa-bad >/dev/null; echo secret > "$GHD/schedule/daily/aaa-bad/locked.txt"; chmod 000 "$GHD/schedule/daily/aaa-bad/locked.txt"
gh add daily ro >/dev/null; echo r > "$GHD/schedule/daily/ro/n.txt"; chmod 555 "$GHD/schedule/daily/ro"
with_run daily zzz 'echo ran >> "$1/count"'
mkdir -p "$GHD/out/pend"; printf '#!/bin/sh\necho ran >> "$1/count"\n' > "$GHD/out/pend/run"; chmod +x "$GHD/out/pend/run"
printf 'fired d-8 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/pend\n' > "$(rec pend)"
rc=0; gh tick >"$T_TMP/t9.out" 2>"$T_TMP/t9.err" || rc=$?
assert_eq "a tick with a firing that fails exits 1" 1 "$rc"
assert_contains "...naming the item on stderr" "$(cat "$T_TMP/t9.err")" "firing schedule/daily/aaa-bad failed"
assert_contains "...but fires the items after it" "$(cat "$T_TMP/t9.out")" "fired zzz ->"
assert_true "...an item without owner write fires, with its record" rec_has "ro-$td" '^fired '
wait_for "...and the runs still start" 50 sh -c "test -s '$GHD/out/zzz-$td/count' && test -s '$GHD/out/pend/count'"
snap
assert_contains "status shows firing_failed" "$(jget "$T_TMP/dg.json" diagnostics)" '"firing_failed"'
assert_contains "...for that item" "$(jget "$T_TMP/dg.json" diagnostics)" '"path":"schedule/daily/aaa-bad"'
assert_true "...and the tick still counts as a tick" test -s "$GHD/runtime/last_tick"
DG_CACHED=0
rc=0; gh tick >/dev/null 2>&1 || rc=$?
assert_eq "the next tick fails the same way, and only that way" 1 "$rc"
chmod 644 "$GHD/schedule/daily/aaa-bad/locked.txt"
rc=0; gh tick >/dev/null 2>&1 || rc=$?
assert_eq "once the file is readable the tick exits 0" 0 "$rc"
assert_true "...fires the item" test -e "$GHD/out/aaa-bad-$td/locked.txt"
assert_false "...and clears firing_failed" test -e "$GHD/runtime/firing_failed"
chmod -R u+w "$GHD/schedule/daily/ro" "$GHD/out"

# --- 10. a script rewritten in place under a waiting wrapper runs nothing twice -------------
new_instance; gh init >/dev/null
with_run daily once-only 'echo ran >> "$1/count"; i=0; while [ $i -lt 100 ] && [ ! -e "$1/go" ]; do sleep 0.1; i=$((i+1)); done'
gh tick >/dev/null 2>&1
wait_for "the run is up" 50 test -s "$GHD/out/once-only-$td/pid"
printf '\n# grown in place\nmain "$@"\n' >> "$GHD/groundhog.sh"
touch "$GHD/out/once-only-$td/go"
wait_for "the run exits" 50 exited "once-only-$td" 1
sleep 1
assert_eq "the grown script did not run the wrapper again" "1 1 1" "$(lines "$GHD/out/once-only-$td/count") $(starts "once-only-$td") $(rec_count "once-only-$td" exit)"

# --- 11. an instance reached through a symlink: $1 and cwd are canonical ------------------
new_instance; gh init >/dev/null
with_run daily where '{ echo "arg=$1"; echo "cwd=$(pwd)"; echo "inst=$GROUNDHOG_INSTANCE"; } > "$1/seen"'
ln -s "$INST" "$T_TMP/via-link"
"$TEST_BASH" "$T_TMP/via-link/.groundhog/groundhog.sh" tick >/dev/null 2>&1
wait_for "the run exits" 50 exited "where-$td" 1
assert_eq "\$1 is under GROUNDHOG_INSTANCE, spelled canonically" "$GHD/out/where-$td" "$(sed -n 's/^arg=//p' "$GHD/out/where-$td/seen")"
assert_eq "...as is the cwd" "$INST" "$(sed -n 's/^cwd=//p' "$GHD/out/where-$td/seen")"
assert_eq "...and GROUNDHOG_INSTANCE" "$GHD" "$(sed -n 's/^inst=//p' "$GHD/out/where-$td/seen")"

# --- 12. an item that is a symlink to a directory: nothing is written through it ------------
new_instance; gh init >/dev/null
mkdir -p "$T_TMP/target-dir"; echo t > "$T_TMP/target-dir/n.txt"
mkdir -p "$GHD/schedule/daily"; ln -s "$T_TMP/target-dir" "$GHD/schedule/daily/linked"
before="$(tree_hash "$T_TMP/target-dir")"
gh tick >/dev/null 2>&1
assert_eq "firing a linked item writes nothing into its target" "$before" "$(tree_hash "$T_TMP/target-dir")"
assert_eq "...and the delivery (the link) reads unrecorded" '"unrecorded"' "$(dstate "linked-$td")"

t_finish
