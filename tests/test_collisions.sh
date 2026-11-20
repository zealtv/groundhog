#!/usr/bin/env bash
# Output collisions: every way two firings can claim one out/ name, and what the
# record, status and the lint/add notes say about each. The legacy no-overwrite
# rule stands (the later firing is marked fired but not delivered, so its run
# never runs); these tests pin that it is never silent where a record exists.
. "$(dirname "$0")/lib.sh"

out="$T_TMP/c.json"
dow="$(date +%a | tr '[:upper:]' '[:lower:]')"
td="$(today)"
ncoll() { jget "$out" diagnostics | grep -o '"code":"out_collision"' | wc -l | tr -d ' '; }

# --- 1. one name, three items (daily, weekly, one-shot), each with its own run ------
new_instance; gh init >/dev/null
for w in daily "weekly/$dow" once; do
  with_run "$w" foo "touch \"$T_TMP/ran-\$(cat \"\$1/which\")\""
  echo "$w" | tr / - > "$GHD/schedule/$w/foo/which"
done
err="$(gh tick 2>&1 >/dev/null)"
assert_contains "the later firings warn on stderr" "$err" "already exists in out/"
status_to "$out"
assert_eq "one delivery owns the name" 1 "$(jq_py where "$out" deliveries path "\"out/foo-$td\"" id | wc -l | tr -d ' ')"
assert_eq "...the first walked item won (the others left it untouched)" daily "$(cat "$GHD/out/foo-$td/which")"
assert_eq "...its record holds one collision line per later firing" 2 "$(rec_count "foo-$td" collision)"
assert_eq "...and status shows each as an out_collision" 2 "$(ncoll)"
assert_contains "...naming the weekly item" "$(jget "$out" diagnostics)" "schedule/weekly/$dow/foo"
assert_contains "...and the one-shot" "$(jget "$out" diagnostics)" "schedule/once/foo"
assert_contains "...saying its run never ran" "$(jget "$out" diagnostics)" "its run never ran"
assert_true "every occurrence is marked fired" test -e "$GHD/fired/$td/weekly/$dow/foo" -a -e "$GHD/fired/$td/once/foo" -a -e "$GHD/fired/$td/daily/foo"
assert_false "the one-shot's source is gone, only the diagnostic remains of it" test -e "$GHD/schedule/once/foo"
if have_handlers; then
  wait_for "the winner's run finished" 50 exited "foo-$td" 1
  assert_true "...the winner's run ran" test -e "$T_TMP/ran-daily"
  assert_false "...the losers' runs never did" test -e "$T_TMP/ran-weekly-$dow" -o -e "$T_TMP/ran-once"
  assert_eq "...and it ran once" 1 "$(rec_count "foo-$td" start)"
fi

# --- 2. lint and add say when two items would share an out name --------------------
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

# --- 3. the same id in two every/ buckets ----------------------------------------------
new_instance; gh init >/dev/null
gh add every/1h foo >/dev/null 2>&1; gh add every/30m foo >/dev/null 2>&1
set_clock "2026-11-15 14:05:00"      # both buckets have a slot at 14:00
gh tick >/dev/null 2>&1
clear_clock
status_to "$out"
assert_eq "every/1h and every/30m share the slot name: one delivery" 1 "$(jq_py col "$out" deliveries path | wc -l | tr -d ' ')"
assert_eq "...and the later bucket's firing is reported" 1 "$(ncoll)"
assert_contains "...with its slot" "$(jget "$out" diagnostics)" "slot 14-00"

# --- 4. the same name on different dates never collides ---------------------------------
new_instance; gh init >/dev/null
gh add daily foo >/dev/null
set_clock "2026-11-14 10:00:00"; gh tick >/dev/null
set_clock "2026-11-15 10:00:00"; gh tick >/dev/null
assert_eq "two days, two out names" "foo-2026-11-14 foo-2026-11-15" "$(ls "$GHD/out" | tr '\n' ' ' | sed 's/ $//')"
clear_clock

# --- 5. a non-directory squatting on the name -------------------------------------------
# No delivery can stand for a file, so status shows the entry as a diagnostic.
new_instance; gh init >/dev/null
gh add daily foo >/dev/null
ln -s /nonexistent/target "$GHD/out/foo-$td"
err="$(gh tick 2>&1 >/dev/null)"
status_to "$out"
assert_true "the occurrence is marked fired" test -e "$GHD/fired/$td/daily/foo"
assert_true "...the squatter is untouched" test -L "$GHD/out/foo-$td"
assert_contains "...tick warned" "$err" "already exists in out/"
assert_contains "...and status names the entry" "$(jget "$out" diagnostics)" out_entry_not_directory

# --- 6. a directory made by hand (no record) squatting on the name -----------------------
# There is no record to carry the collision: the stderr warning is all (the known gap).
new_instance; gh init >/dev/null
with_run daily foo 'touch "$1/ran"'
mkdir -p "$GHD/out/foo-$td"
err="$(gh tick 2>&1 >/dev/null)"
assert_contains "a hand-made squatter: tick warns" "$err" "already exists in out/"
assert_false "...writes no record into it" test -e "$(rec "foo-$td")"
sleep 0.5
assert_false "...and runs nothing" test -e "$GHD/out/foo-$td/ran"
assert_eq "...status lists the entry as unrecorded" '"unrecorded"' "$(dstate "foo-$td")"
assert_true "...and the occurrence is marked fired" test -e "$GHD/fired/$td/daily/foo"

# --- 7. re-arming an occurrence whose entry is still in out/ -----------------------------
new_instance; gh init >/dev/null
with_run daily foo 'echo once'
gh tick >/dev/null 2>&1
have_handlers && wait_for "the first run finished" 50 exited "foo-$td" 1
rm "$GHD/fired/$td/daily/foo"
gh tick >/dev/null 2>&1
status_to "$out"
assert_eq "re-arm: still one delivery for the name" 1 "$(jq_py where "$out" deliveries path "\"out/foo-$td\"" id | wc -l | tr -d ' ')"
assert_eq "...the refire is reported as a collision" 1 "$(ncoll)"
assert_contains "...as the same occurrence, with the delivery standing" "$(jget "$out" diagnostics)" "this delivery stands"
assert_not_contains "...not as a lost run" "$(jget "$out" diagnostics)" "its run never ran"
assert_true "...with the marker back" test -e "$GHD/fired/$td/daily/foo"
if have_handlers; then
  assert_eq "...and the delivery's run was not started again" 1 "$(rec_count "foo-$td" start)"
fi

t_finish
