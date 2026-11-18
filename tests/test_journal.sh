#!/usr/bin/env bash
# The delivery journal: reconciliation on run (legacy out import, missing paths,
# out collisions, interrupted firings), sweep protection and the real
# unresolved-attempt check of release. Hand-written records stand in for crashes
# that cannot be timed from outside; consumers are plain /bin/sh scripts.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support || ! have_isolation; then
  t_skip "this host has no lock helper, hash tool, durable-write tool or process-isolation helper; the consumer is not offered"
  t_finish
  exit $?
fi

out="$T_TMP/j.json"
FAST='echo x >> "$PWD/calls.txt"'
add_item() { mkdir -p "$GHD/schedule/daily/$1"; echo "note-$1" > "$GHD/schedule/daily/$1/note.txt"; }

# put_record ID OUT_NAME STATE [ATTEMPT_OUTCOME [MARKER]] — a delivery record
# the way the runtime writes one (for states a test cannot reach from outside).
put_record() {
  mkdir -p "$GHD/runtime/deliveries"
  python3 -I - "$GHD/runtime/deliveries/$1.json" "$1" "$2" "$3" "${4:-}" "${5:-}" <<'PY'
import json, sys
path, did, name, state, outcome, marker = sys.argv[1:7]
attempts = []
if outcome:
    attempts.append({"id": "a-" + did, "started_at": "2026-11-10T00:00:00Z",
                     "finished_at": None if outcome in ("in_flight", "unknown") else "2026-11-10T00:00:01Z",
                     "outcome": outcome, "exit_code": 7 if outcome == "failed" else None,
                     "signal": None, "error": None})
rec = {"schema_version": 1, "id": did, "path": "out/" + name, "origin": "runtime",
       "schedule_path": "schedule/daily/x", "occurrence": {"date": "2026-11-10", "slot": None},
       "state": state, "reason": None, "registered_at": "2026-11-10T00:00:00Z",
       "fired_marker": marker or None, "attempts": attempts, "collisions": []}
with open(path, "w") as f:
    json.dump(rec, f, separators=(",", ":"))
    f.write("\n")
PY
}
# put_prepared ID OUT_NAME MARKER SCHED ONCE GEN — a prepared firing record.
put_prepared() {
  mkdir -p "$GHD/runtime/prepared"
  python3 -I - "$GHD/runtime/prepared/$1.json" "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import datetime, json, sys
path, did, name, marker, sched, once, gen = sys.argv[1:8]
rec = {"schema_version": 1, "id": did, "out_path": "out/" + name, "fired_marker": marker,
       "schedule_path": sched, "occurrence": {"date": datetime.date.today().isoformat(), "slot": None},
       "once": once == "true", "source_generation": gen, "created_at": "2026-11-15T00:00:00Z"}
with open(path, "w") as f:
    json.dump(rec, f, separators=(",", ":"))
    f.write("\n")
PY
}
gen_of() { python3 -I -c 'import os,sys;s=os.stat(sys.argv[1]);print("%d %d" % (s.st_ino, int(s.st_mtime)))' "$1"; }
run_once() { # run for a moment, then stop (the first cycle runs immediately)
  start_runner --token-file "$TOK" --interval-seconds 1
  wait_for "the runner is up" 80 runner_is running
  sleep "${1:-1.2}"
  gh stop --token-file "$TOK" >/dev/null 2>&1
  wait_exit "the runner exited" 50 "$RUNNER_PID"
}

# --- legacy out entries are imported by run, never by status --------------------
new_instance; gh init >/dev/null
mkdir -p "$GHD/out/old-one" "$GHD/out/older-two.landing"
echo legacy > "$GHD/out/old-one/note.txt"; echo partial > "$GHD/out/older-two.landing/x"
echo stray > "$GHD/out/stray.txt"
status_to "$out"
assert_eq "status shows the legacy entry unregistered, without an id" 'null' "$(jq_py dget "$out" path out/old-one id)"
assert_eq "...pending/unregistered" '"unregistered"' "$(jq_py dget "$out" path out/old-one reason)"
assert_false "...and wrote no records (status never registers)" test -e "$GHD/runtime/deliveries"
enroll_ok
consumer_script consumer.sh "$FAST"
run_once
status_to "$out"
assert_eq "run imports the entry as a delivery with an id" 'str' "$(jq_py dget "$out" path out/old-one id | cut -c1 | sed 's/"/str/')"
assert_eq "...origin legacy_out" '"legacy_out"' "$(jq_py dget "$out" path out/old-one origin)"
assert_eq "...unknown occurrence" 'null' "$(jq_py dget "$out" path out/old-one occurrence)"
assert_eq "...unknown schedule path" 'null' "$(jq_py dget "$out" path out/old-one schedule_path)"
assert_eq "...pending" '"pending"' "$(jq_py dget "$out" path out/old-one state)"
assert_eq "...reason no_consumer (no config yet)" '"no_consumer"' "$(jq_py dget "$out" path out/old-one reason)"
assert_eq "...never marked handed off" "[]" "$(jq_py dget "$out" path out/old-one attempts)"
assert_eq ".landing is ignored (no delivery for it)" '<missing>' "$(jq_py dget "$out" path out/older-two.landing id)"
assert_true "...and left in place" test -d "$GHD/out/older-two.landing"
assert_contains "a stray file in out/ is diagnosed, not imported" "$(jget "$out" diagnostics)" out_entry_not_directory
imported_id="$(jq_py dget "$out" path out/old-one id | tr -d '"')"
# a later configuration plus run makes it eligible
write_config /bin/sh "$CONS"
run_once 2
assert_eq "after configuring a consumer the imported delivery is handed off" '"accepted"' "$(dstate old-one)"
assert_eq "...under the same delivery id" "$imported_id" "$(did old-one)"
assert_eq "...exactly once" 1 "$(lines "$INST/calls.txt")"
assert_eq "...the original out path is kept" '"out/old-one"' "$(dget path out/old-one path)"
status_to "$out"
assert_eq "...and a second import did not duplicate it" 1 "$(jq_py where "$out" deliveries path '"out/old-one"' id | wc -l | tr -d ' ')"

# --- a pending path that vanished becomes missing, never recreated --------------
fresh_consumer "$FAST"
mkdir -p "$GHD/out/gone-one"
gh pause --token-file "$TOK" >/dev/null 2>&1
run_once
assert_eq "paused run imports the entry as pending" '"pending"' "$(dstate gone-one)"
gone_id="$(did gone-one)"
rm -rf "$GHD/out/gone-one"
gh resume --token-file "$TOK" >/dev/null 2>&1
run_once 2
assert_eq "a pending delivery whose path vanished becomes missing" '"missing"' "$(dstate gone-one)"
assert_eq "...with a reason" '"path_missing"' "$(dget id "$gone_id" reason)"
assert_false "...the path is not recreated" test -e "$GHD/out/gone-one"
assert_eq "...nothing was handed off for it" "[]" "$(dget id "$gone_id" attempts)"
rc=0; gh retry --token-file "$TOK" --delivery "$gone_id" >/dev/null 2>&1 || rc=$?
assert_eq "...retry cannot revive a missing delivery (5)" 5 "$rc"

# --- an existing out/ name: no second delivery, an out_collision diagnostic -------
fresh_consumer "$FAST"
mkdir -p "$GHD/out/$NAME"; echo "someone else" > "$GHD/out/$NAME/theirs.txt"
mkdir -p "$GHD/schedule/once/oneshot"; echo once > "$GHD/schedule/once/oneshot/note.txt"
mkdir -p "$GHD/out/oneshot-$(today)"; echo "theirs" > "$GHD/out/oneshot-$(today)/theirs.txt"
run_once 2.5
status_to "$out"
assert_eq "one delivery per out path" 1 "$(jq_py where "$out" deliveries path "\"out/$NAME\"" id | wc -l | tr -d ' ')"
assert_eq "...it is the imported legacy entry, not an invented firing" '"legacy_out"' "$(jq_py dget "$out" path "out/$NAME" origin)"
assert_eq "...and no source identity is claimed" 'null' "$(jq_py dget "$out" path "out/$NAME" schedule_path)"
assert_false "...the colliding payload was not overwritten" test -e "$GHD/out/$NAME/note.txt"
assert_true "...and its content is intact" test -f "$GHD/out/$NAME/theirs.txt"
assert_contains "status carries an out_collision diagnostic" "$(jget "$out" diagnostics)" out_collision
assert_contains "...naming the path" "$(jget "$out" diagnostics)" "out/$NAME"
assert_contains "...and the schedule item" "$(jget "$out" diagnostics)" "schedule/daily/nudge"
assert_true "the occurrence was still recorded as fired" test -e "$GHD/fired/$(today)/daily/nudge"
assert_false "one-shots keep the legacy removal after the firing" test -e "$GHD/schedule/once/oneshot"
assert_contains "...and the diagnostic covers it too" "$(jget "$out" diagnostics)" "schedule/once/oneshot"
assert_eq "the colliding entries were handed to the consumer once each" 2 "$(lines "$INST/calls.txt")"

# --- interrupted firings are reconciled by the next run --------------------------
# (a) crash during the staging copy: nothing exposed, the occurrence fires afresh.
fresh_consumer "$FAST"; write_config /bin/sh "$CONS"; rm -f "$GHD/runtime/config.json"
mkdir -p "$GHD/runtime/staging/d-partial/half"
put_prepared d-partial "$NAME" "fired/$(today)/daily/nudge" schedule/daily/nudge false ""
run_once
status_to "$out"
assert_false "(a) the unfinished staging copy is discarded" test -e "$GHD/runtime/staging/d-partial"
assert_false "(a) ...and its prepared record" test -e "$GHD/runtime/prepared/d-partial.json"
assert_eq "(a) the occurrence fired afresh: one delivery" 1 "$(jq_py where "$out" deliveries path "\"out/$NAME\"" id | wc -l | tr -d ' ')"
assert_true "(a) ...complete in out/" test -f "$GHD/out/$NAME/note.txt"
assert_true "(a) ...with a marker" test -e "$GHD/fired/$(today)/daily/nudge"
assert_true "(a) ...and not the abandoned id" test "$(did "$NAME")" != "d-partial"
assert_eq "(a) no consumer: pending/no_consumer" '"no_consumer"' "$(dget path "out/$NAME" reason)"

# (b) crash after the out rename, before the marker and the record.
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"
mkdir -p "$GHD/out/$NAME"; cp "$GHD/schedule/daily/nudge/note.txt" "$GHD/out/$NAME/"
put_prepared d-renamed "$NAME" "fired/$(today)/daily/nudge" schedule/daily/nudge false ""
run_once
status_to "$out"
assert_eq "(b) the prepared firing is completed under its own id" "d-renamed" "$(did "$NAME" | tr -d '"')"
assert_eq "(b) ...origin runtime, with the journaled schedule path" '"schedule/daily/nudge"' "$(dget id d-renamed schedule_path)"
assert_eq "(b) ...and the journaled occurrence" "\"$(today)\"" "$(dget id d-renamed occurrence.date)"
assert_true "(b) ...the marker exists now" test -e "$GHD/fired/$(today)/daily/nudge"
assert_false "(b) ...the prepared record is gone" test -e "$GHD/runtime/prepared/d-renamed.json"
assert_eq "(b) ...and no duplicate delivery was made" 1 "$(jq_py where "$out" deliveries path "\"out/$NAME\"" id | wc -l | tr -d ' ')"

# (c) crash between the marker and the one-shot removal: only the original
# source is removed. Paused, so the plain tick (which, as in the legacy script,
# removes a one-shot whose marker exists) stays out of it.
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"
mkdir -p "$GHD/schedule/once/uno" "$GHD/schedule/once/dos"
echo 1 > "$GHD/schedule/once/uno/note.txt"; echo 2 > "$GHD/schedule/once/dos/note.txt"
for n in uno dos; do mkdir -p "$GHD/out/$n-$(today)"; cp "$GHD/schedule/once/$n/note.txt" "$GHD/out/$n-$(today)/"; mkdir -p "$GHD/fired/$(today)/once"; touch "$GHD/fired/$(today)/once/$n"; done
put_prepared d-uno "uno-$(today)" "fired/$(today)/once/uno" schedule/once/uno true "$(gen_of "$GHD/schedule/once/uno")"
put_prepared d-dos "dos-$(today)" "fired/$(today)/once/dos" schedule/once/dos true "1 1"      # the source was replaced since
gh pause --token-file "$TOK" >/dev/null 2>&1
run_once
assert_false "(c) the one-shot that was fired is removed" test -e "$GHD/schedule/once/uno"
assert_true "(c) a replacement one-shot (another generation) is left alone" test -d "$GHD/schedule/once/dos"
assert_contains "(c) ...and the runner says so" "$(cat "$RUN_ERR")" "changed since"
assert_eq "(c) both firings are deliveries" '"pending"' "$(dstate "uno-$(today)")"

# (c2) The same crash with the instance running (not paused). The firing wrote
# the generation of the source it copied into the marker; the journaled tick that
# follows removes only a source of that generation. A replacement one-shot (as
# the operator might put there the same day) stays, a marker with no recorded
# generation keeps the legacy removal, and a firing that really happens records
# the generation.
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"
mkdir -p "$GHD/fired/$(today)/once"
for n in uno dos tres; do
  mkdir -p "$GHD/schedule/once/$n" "$GHD/out/$n-$(today)"
  echo "$n" > "$GHD/schedule/once/$n/note.txt"; cp "$GHD/schedule/once/$n/note.txt" "$GHD/out/$n-$(today)/"
  put_record "d-$n" "$n-$(today)" pending "" "fired/$(today)/once/$n"
done
gen_of "$GHD/schedule/once/uno" > "$GHD/fired/$(today)/once/uno"      # the generation that fired
echo "1 1" > "$GHD/fired/$(today)/once/dos"                           # a source since replaced
: > "$GHD/fired/$(today)/once/tres"                                    # no generation recorded
mkdir -p "$GHD/schedule/once/solo"; echo solo > "$GHD/schedule/once/solo/note.txt"
solo_gen="$(gen_of "$GHD/schedule/once/solo")"
run_once
assert_false "(c2) unpaused: the one-shot that fired is removed" test -e "$GHD/schedule/once/uno"
assert_true "(c2) unpaused: a replacement one-shot (another generation) is not removed" test -d "$GHD/schedule/once/dos"
assert_contains "(c2) ...and the runner says so" "$(cat "$RUN_ERR")" "replaced since"
assert_false "(c2) a marker without a recorded generation keeps the legacy removal" test -e "$GHD/schedule/once/tres"
assert_false "(c2) a one-shot that fires now is removed after its firing" test -e "$GHD/schedule/once/solo"
assert_eq "(c2) ...and its marker records the generation that was copied" "$solo_gen" "$(cat "$GHD/fired/$(today)/once/solo")"
assert_eq "(c2) ...the replacement is left once per runner, not once per cycle" 1 "$(grep -c 'replaced since' "$RUN_ERR")"
assert_eq "(c2) a recurring item's marker stays empty" 0 "$(wc -c < "$GHD/fired/$(today)/daily/nudge" | tr -d ' ')"

# (d) conflicting or corrupt evidence is reported and blocks, never guessed at.
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"
mkdir -p "$GHD/fired/$(today)/daily"; touch "$GHD/fired/$(today)/daily/nudge"      # marker, but no out entry
put_prepared d-conflict "$NAME" "fired/$(today)/daily/nudge" schedule/daily/nudge false ""
mkdir -p "$GHD/runtime/prepared"; printf 'not json at all' > "$GHD/runtime/prepared/d-garbage.json"
run_once
status_to "$out"
assert_eq "(d) nothing is fired for the blocked occurrence" 0 "$(out_count)"
assert_true "(d) the conflicting record is set aside" test -e "$GHD/runtime/prepared/d-conflict.blocked"
assert_true "(d) the corrupt record too" test -e "$GHD/runtime/prepared/d-garbage.blocked"
assert_contains "(d) status shows a reconciliation error" "$(jget "$out" diagnostics)" firing_reconciliation_error
assert_contains "(d) ...with the path" "$(jget "$out" diagnostics)" "runtime/prepared/d-conflict.blocked"

# --- sweep keeps everything unsettled and removes accepted entries --------------
new_instance; gh init >/dev/null
age_dirs() { age_tree "$GHD/out"; age_tree "$GHD/fired"; age_tree "$GHD/runtime"; }
for n in p-pend p-fail p-unc p-fly p-acc p-acc2 p-unreg; do mkdir -p "$GHD/out/$n"; echo "$n" > "$GHD/out/$n/f"; done
mkdir -p "$GHD/out/half.landing"; echo x > "$GHD/out/half.landing/f"
mkdir -p "$GHD/fired/2026-11-01/daily" "$GHD/fired/2026-11-02/daily" "$GHD/fired/2026-11-03/daily"
touch "$GHD/fired/2026-11-01/daily/pend" "$GHD/fired/2026-11-02/daily/acc" "$GHD/fired/2026-11-03/daily/other"
put_record d-pend p-pend pending "" fired/2026-11-01/daily/pend
put_record d-fail p-fail failed failed
put_record d-unc p-unc uncertain unknown
put_record d-fly p-fly in_flight in_flight
put_record d-acc p-acc accepted accepted fired/2026-11-02/daily/acc
put_record d-acc2 p-acc2 accepted accepted
put_record d-gone p-gone missing
put_record d-oldacc p-oldacc accepted accepted            # accepted, and its path is already gone
age_dirs
rc=0; gh sweep 0 > "$out.o" 2> "$out.e" || rc=$?
assert_eq "sweep exits 0" 0 "$rc"
for n in p-pend p-fail p-unc p-fly; do
  assert_true "sweep keeps unsettled out/$n" test -d "$GHD/out/$n"
done
assert_true "...and their records" test -e "$GHD/runtime/deliveries/d-pend.json" -a -e "$GHD/runtime/deliveries/d-fail.json" -a -e "$GHD/runtime/deliveries/d-unc.json" -a -e "$GHD/runtime/deliveries/d-fly.json"
assert_contains "...and reports the skipped pending entry" "$(cat "$out.o")" "skipped out p-pend (pending)"
assert_contains "...failed" "$(cat "$out.o")" "skipped out p-fail (failed)"
assert_contains "...uncertain" "$(cat "$out.o")" "skipped out p-unc (uncertain)"
assert_contains "...in flight" "$(cat "$out.o")" "skipped out p-fly (in_flight)"
assert_true "...and an entry no record claims (unregistered)" test -d "$GHD/out/p-unreg"
assert_contains "...reported too" "$(cat "$out.o")" "skipped out p-unreg (unregistered)"
assert_false "accepted entries are swept" test -e "$GHD/out/p-acc"
assert_false "...with their record" test -e "$GHD/runtime/deliveries/d-acc.json"
assert_false "...the other accepted one too" test -e "$GHD/out/p-acc2" -o -e "$GHD/runtime/deliveries/d-acc2.json"
assert_false "an accepted record whose path is long gone is swept" test -e "$GHD/runtime/deliveries/d-oldacc.json"
assert_false "a terminal missing record is swept" test -e "$GHD/runtime/deliveries/d-gone.json"
assert_false "an abandoned .landing entry is swept as before" test -e "$GHD/out/half.landing"
assert_true "the fired marker an unsettled delivery references survives" test -e "$GHD/fired/2026-11-01/daily/pend"
assert_contains "...and is reported" "$(cat "$out.o")" "skipped fired 2026-11-01"
assert_false "unreferenced fired dates are swept" test -e "$GHD/fired/2026-11-03" -o -e "$GHD/fired/2026-11-02"
status_to "$out"
assert_eq "sweep never turns an accepted item into pending" 0 "$(jq_py where "$out" deliveries state '"accepted"' id | wc -l | tr -d ' ')"
# unreadable evidence stops the sweep before anything is removed
printf 'not json' > "$GHD/runtime/deliveries/d-bad.json"
mkdir -p "$GHD/out/p-acc3"; put_record d-acc3 p-acc3 accepted accepted; age_dirs
rc=0; gh sweep 0 > "$out.o" 2> "$out.e" || rc=$?
assert_true "an unreadable delivery record makes sweep refuse" test "$rc" -ne 0
assert_true "...and nothing was removed" test -d "$GHD/out/p-acc3"

# --- release checks the attempts for real ----------------------------------------
release_after() { # DESC EXPECTED-RC — record states come from the caller
  local rc=0
  gh release --token-file "$TOK" >/dev/null 2>"$out.e" || rc=$?
  assert_eq "$1" "$2" "$rc"
}
new_instance; gh init >/dev/null; enroll_ok
mkdir -p "$GHD/out/r1"; put_record d-r1 r1 uncertain unknown
release_after "release refuses with an uncertain delivery" 5
rm -f "$GHD/runtime/deliveries/d-r1.json"; put_record d-r2 r1 in_flight in_flight
release_after "release refuses with an in-flight delivery" 5
rm -f "$GHD/runtime/deliveries/d-r2.json"; put_record d-r3 r1 failed in_flight
release_after "release refuses when any attempt is still in flight" 5
rm -f "$GHD/runtime/deliveries/d-r3.json"; printf '{"schema_version":1}' > "$GHD/runtime/deliveries/d-r4.json"
release_after "release refuses on an unreadable record (unreadable is not resolved)" 5
rm -f "$GHD/runtime/deliveries/d-r4.json"
put_record d-r5 r1 failed failed; put_record d-r6 r1 pending; put_record d-r7 r1 accepted accepted; put_record d-r8 r1 missing
release_after "release succeeds with only settled attempts (failed, pending, accepted, missing)" 0
status_to "$out"
assert_eq "...ownership gone" null "$(jget "$out" owner)"
assert_eq "...records intact" 4 "$(jget "$out" deliveries | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"

# --- capabilities: all seven where the host allows ---------------------------------
new_instance
gh capabilities --json > "$out"
assert_eq "all ten capabilities are offered" '["status-json-v1","status-active-v1","next-due-v1","ownership-v1","runner-v1","pause-v1","sweep-owner-v1","consumer-v1","delivery-v1","release-unresolved-v1"]' "$(jget "$out" capabilities)"

t_finish
