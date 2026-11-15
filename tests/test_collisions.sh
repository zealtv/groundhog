#!/usr/bin/env bash
# Output collisions: every way two firings can claim one out/ name, and what the
# status and the lint/add notes say about each. The contract accepts the legacy
# no-overwrite rule (the later firing is recorded but not delivered); these tests
# pin that it is never silent.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support; then
  t_skip "this host lacks the runner's tools"
  t_finish
  exit $?
fi

out="$T_TMP/c.json"
run_once() { # run for a moment, then stop (the first cycle runs immediately)
  start_runner --token-file "$TOK" --interval-seconds 1
  wait_for "the runner is up" 80 runner_is running
  sleep "${1:-1.5}"
  gh stop --token-file "$TOK" >/dev/null 2>&1
  wait_exit "the runner exited" 50 "$RUNNER_PID"
}
dow="$(date +%a | tr '[:upper:]' '[:lower:]')"
td="$(today)"
diag_has() { jget "$out" diagnostics | grep -q "$1"; }

# --- 1. a standalone tick on a previously supervised instance -------------------
# (released, then ticked by hand: the collision used to reach stderr only)
new_instance; gh init >/dev/null
gh add daily foo >/dev/null; echo d > "$GHD/schedule/daily/foo/n.txt"
enroll_ok; gh resume --token-file "$TOK" >/dev/null
run_once
gh release --token-file "$TOK" >/dev/null 2>&1
gh add "weekly/$dow" foo >/dev/null 2>&1; echo w > "$GHD/schedule/weekly/$dow/foo/n.txt"
err="$(gh tick 2>&1 >/dev/null)"
assert_contains "the standalone tick still warns on stderr" "$err" "already exists in out/"
assert_eq "...and did not overwrite the delivery" d "$(cat "$GHD/out/foo-$td/n.txt")"
status_to "$out"
assert_true "status now carries the out_collision for it" diag_has out_collision
assert_contains "...naming the schedule item that lost" "$(jget "$out" diagnostics)" "schedule/weekly/$dow/foo"
assert_eq "...against the one delivery that owns the name" 1 "$(jq_py where "$out" deliveries path "\"out/foo-$td\"" id | wc -l | tr -d ' ')"

# --- 2. an out path reused after the first delivery vanished ----------------------
# An old record for the path is missing; a collision on the reused name belongs to
# the live delivery, not to that record (a sweep of the missing one would take the
# evidence with it). The old record is hand-written with the smallest possible id,
# so a lookup that takes the first match finds it first.
new_instance; gh init >/dev/null
gh add daily foo >/dev/null; echo d > "$GHD/schedule/daily/foo/n.txt"
mkdir -p "$GHD/schedule/weekly/$dow/foo" "$GHD/runtime/deliveries"
echo w > "$GHD/schedule/weekly/$dow/foo/n.txt"
old=d-0000000000000000
printf '{"schema_version":1,"id":"%s","path":"out/foo-%s","origin":"runtime","schedule_path":"schedule/daily/foo","occurrence":{"date":"%s","slot":null},"state":"missing","reason":"path_missing","registered_at":"2026-11-10T00:00:00Z","fired_marker":null,"attempts":[],"collisions":[]}\n' "$old" "$td" "$td" > "$GHD/runtime/deliveries/$old.json"
enroll_ok; gh resume --token-file "$TOK" >/dev/null
run_once 2
status_to "$out"
assert_eq "path reuse: the old generation stays missing" '"missing"' "$(jq_py dget "$out" id "$old" state)"
oldrec="$GHD/runtime/deliveries/$old.json"; [ -f "$oldrec" ] || oldrec="$GHD/runtime/deliveries/done/$old.json"   # the runner files a missing record under done/
assert_eq "...and keeps no collision" '[]' "$(grep -o '"collisions":\[[^]]*\]' "$oldrec" | sed 's/"collisions"://')"
assert_true "...the live delivery's record holds the weekly item's collision" \
  sh -c "grep -l 'weekly/$dow/foo' '$GHD'/runtime/deliveries/*.json | grep -v $old >/dev/null"
assert_contains "...and status reports it" "$(jget "$out" diagnostics)" out_collision

# --- 3. a reused path whose older record is accepted: one handoff, not two --------
# (the consumer took the first delivery away; the name fires again later)
new_instance; gh init >/dev/null
gh add daily foo >/dev/null; echo d > "$GHD/schedule/daily/foo/n.txt"
mkdir -p "$GHD/runtime/deliveries"
old=d-0000000000000000
printf '{"schema_version":1,"id":"%s","path":"out/foo-%s","origin":"runtime","schedule_path":"schedule/daily/foo","occurrence":{"date":"%s","slot":null},"state":"accepted","reason":null,"registered_at":"2026-11-10T00:00:00Z","fired_marker":null,"attempts":[],"collisions":[]}\n' "$old" "$td" "$td" > "$GHD/runtime/deliveries/$old.json"
enroll_ok; gh resume --token-file "$TOK" >/dev/null
consumer_script consumer.sh 'echo "$GROUNDHOG_DELIVERY_ID" >> "$PWD/calls.txt"'
write_config /bin/sh "$CONS"
run_once 3
assert_eq "reused path: the new delivery is handed off exactly once" 1 "$(lines "$INST/calls.txt")"
assert_eq "...the old accepted record is untouched" '"accepted"' "$(jq_py dget "$(status_to "$out"; echo "$out")" id "$old" state)"

# --- 4. lint and add say when two items would share an out name --------------------
new_instance; gh init >/dev/null
gh add daily/09 foo >/dev/null 2>&1
err="$(gh add daily/17 foo 2>&1 >/dev/null)"; rc=$?
assert_eq "add of a second foo succeeds" 0 "$rc"
assert_contains "...and notes the clash on stderr" "$err" "item id 'foo' exists at 2 schedule paths"
assert_contains "...naming both paths" "$err" "schedule/daily/09/foo, schedule/daily/17/foo"
assert_eq "...stdout stays the path alone" "$GHD/schedule/weekly/$dow/foo" "$(gh add weekly/$dow foo 2>/dev/null)"
gh add daily bar >/dev/null
assert_eq "an id used once draws no note" "" "$(gh add monthly bar2 2>&1 >/dev/null)"
lerr="$(gh lint 2>&1 >/dev/null)"; lrc=0; gh lint >/dev/null 2>&1 || lrc=$?
lout="$(gh lint 2>/dev/null)"
assert_contains "lint notes the shared id on stderr" "$lerr" "item id 'foo' exists at 3 schedule paths"
assert_not_contains "...once, for foo only" "$lerr" "'bar'"
assert_eq "...and its stdout and exit status are unchanged" "schedule is clean 0" "$lout $lrc"

# --- 5. the runner: one name, three items (daily, weekly, one-shot) ---------------
new_instance; gh init >/dev/null
for w in daily "weekly/$dow" once; do gh add "$w" foo >/dev/null 2>&1; echo "$w" > "$GHD/schedule/$w/foo/n.txt"; done
enroll_ok; gh resume --token-file "$TOK" >/dev/null
run_once 2
status_to "$out"
assert_eq "one delivery owns the name" 1 "$(jq_py where "$out" deliveries path "\"out/foo-$td\"" id | wc -l | tr -d ' ')"
assert_eq "...the first walked item won (the others left it untouched)" daily "$(cat "$GHD/out/foo-$td/n.txt")"
assert_eq "...one out_collision per later firing" 2 "$(jget "$out" diagnostics | grep -o '"code":"out_collision"' | wc -l | tr -d ' ')"
assert_true "...every occurrence is marked fired" test -e "$GHD/fired/$td/weekly/$dow/foo" -a -e "$GHD/fired/$td/once/foo" -a -e "$GHD/fired/$td/daily/foo"
assert_false "...and the one-shot's source is gone, only the diagnostic remains of it" test -e "$GHD/schedule/once/foo"
assert_contains "...which names it" "$(jget "$out" diagnostics)" "schedule/once/foo"

# --- 6. the same id in two every/ buckets --------------------------------------------
new_instance; gh init >/dev/null
gh add every/1h foo >/dev/null 2>&1; gh add every/30m foo >/dev/null 2>&1
enroll_ok; gh resume --token-file "$TOK" >/dev/null
set_clock "2026-11-15 14:05:00"      # both buckets have a slot at 14:00
run_once 2
clear_clock
status_to "$out"
assert_eq "every/1h and every/30m share the slot name: one delivery" 1 "$(jq_py col "$out" deliveries path | wc -l | tr -d ' ')"
assert_contains "...and the later bucket's firing is reported" "$(jget "$out" diagnostics)" out_collision

# --- 7. the same name on different dates never collides -------------------------------
new_instance; gh init >/dev/null
gh add daily foo >/dev/null
set_clock "2026-11-14 10:00:00"; gh tick >/dev/null
set_clock "2026-11-15 10:00:00"; gh tick >/dev/null
assert_eq "two days, two out names" "foo-2026-11-14 foo-2026-11-15" "$(ls "$GHD/out" | tr '\n' ' ' | sed 's/ $//')"
clear_clock

# --- 8. a non-directory squatting on the name -----------------------------------------
# The firing is recorded and not delivered (legacy no-overwrite). No delivery can
# stand for a file, so the status shows the entry as a diagnostic, and the runner
# logs the collision.
new_instance; gh init >/dev/null
gh add daily foo >/dev/null
ln -s /nonexistent/target "$GHD/out/foo-$td"
enroll_ok; gh resume --token-file "$TOK" >/dev/null
run_once 2
status_to "$out"
assert_true "the occurrence is marked fired" test -e "$GHD/fired/$td/daily/foo"
assert_true "...the squatter is untouched" test -L "$GHD/out/foo-$td"
assert_contains "...status names the entry" "$(jget "$out" diagnostics)" out_entry_not_directory
assert_contains "...and the runner logged the collision" "$(cat "$RUN_ERR")" "out_collision"

# --- 9. re-arming an occurrence whose entry is still in out/ ---------------------------
new_instance; gh init >/dev/null
gh add daily foo >/dev/null; echo d > "$GHD/schedule/daily/foo/n.txt"
enroll_ok; gh resume --token-file "$TOK" >/dev/null
run_once
rm "$GHD/fired/$td/daily/foo"
run_once
status_to "$out"
assert_eq "re-arm: still one delivery for the name" 1 "$(jq_py where "$out" deliveries path "\"out/foo-$td\"" id | wc -l | tr -d ' ')"
assert_contains "...and the refire is reported as a collision" "$(jget "$out" diagnostics)" out_collision
assert_true "...with the marker back" test -e "$GHD/fired/$td/daily/foo"

t_finish
