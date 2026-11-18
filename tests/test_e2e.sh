#!/usr/bin/env bash
# End to end, as an operator would use it: one readable walk over scratch
# instances. Each numbered part names the scenario; where a dedicated test file
# already proves the details, the part stays short and points there.
#
#   1  tick-only compatibility (never enrolled)          test_compat, test_schedule
#   2  upgrading the vendored script under tick-only use
#   3  enroll, recurring + overdue one-shot, no consumer  test_runner, test_schedule
#   4  same-name items at different schedule paths        test_collisions
#   5  ownership conflicts                                test_ownership
#   6  persistent pause                                   test_runner
#   7  a plain synchronous /bin/sh consumer, and failure  test_consumer
#   8  an asynchronous adapter with a separate worker
#   9  process shutdown with a consumer in flight         test_delivery
#  10  authorized non-interactive token reuse
#  11  stopped-but-owned, explicit release, re-enroll
#  12  install.sh starts and enrolls nothing
#  13  install.sh upgrades a copied, customised .groundhog/
#
# Every runner is stopped before its part ends; consumers are /bin/sh scripts.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support || ! have_isolation; then
  t_skip "this host lacks the lock, hash, durable-write or process-isolation tools; the runtime is not offered"
  t_finish
  exit $?
fi

out="$T_TMP/e.json"
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
run_bg() { start_runner --token-file "$TOK" --interval-seconds 1; wait_for "the runner is up" 80 runner_is running; }
stop_bg() { gh stop --token-file "$TOK" >/dev/null 2>&1; wait_exit "the runner exits after stop" 80 "$RUNNER_PID"; }
has_records() { [ "$(ls "$GHD/runtime/deliveries" 2>/dev/null | wc -l | tr -d ' ')" -ge "$1" ]; }
ndeliveries() { status_to "$out"; jq_py col "$out" deliveries path | wc -l | tr -d ' '; }
runtime_files() { (cd "$GHD/runtime" 2>/dev/null && find . -type f | LC_ALL=C sort | tr '\n' ' '); }
all_in_state() { # STATE — every delivery has it (and there is at least one)
  status_to "$out"
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))["deliveries"]
sys.exit(0 if d and all(x["state"]==sys.argv[2] for x in d) else 1)' "$out" "$1"
}
SUNDAY="2026-11-15 10:00:00"      # a Sunday, the 15th

# --- 1. tick-only: an instance that never enrolls behaves as it always did ----------
set_clock "$SUNDAY"
new_instance; gh init >/dev/null
gh add daily nudge >/dev/null; echo hi > "$GHD/schedule/daily/nudge/note.txt"
gh add once/2026-11-01 late >/dev/null 2>&1
gh tick > "$T_TMP/tick1.out" 2>&1
assert_eq "tick-only: a due item lands in out/" "hi" "$(cat "$GHD/out/nudge-2026-11-15/note.txt")"
assert_true "...an overdue one-shot fires on the next tick" test -d "$GHD/out/late-2026-11-15"
assert_false "...and its source is removed" test -e "$GHD/schedule/once/2026-11-01/late"
assert_true "...markers record both" test -e "$GHD/fired/2026-11-15/daily/nudge" -a -e "$GHD/fired/2026-11-15/once/2026-11-01/late"
assert_eq "...a second tick fires nothing" "" "$(gh tick 2>&1)"
assert_eq "...no state, config, owner or delivery record is written" "" "$(find "$GHD/runtime" -type f ! -name '*.lock' ! -name last_tick 2>/dev/null)"
status_to "$out"
assert_eq "...status reads it as unowned" null "$(jget "$out" owner)"
assert_eq "...and not paused" false "$(jget "$out" paused)"
assert_eq "...with the runner stopped" '"stopped"' "$(jget "$out" runner.state)"
assert_eq "...the passive entries show as unregistered deliveries" '"unregistered"' "$(jq_py dget "$out" path out/nudge-2026-11-15 reason)"
assert_eq "...run refuses without a token (nothing enrolls by itself)" 2 "$(rc_of gh run)"
assert_false "...and still no owner" test -e "$GHD/runtime/state.json"
clear_clock

# --- 2. upgrading the vendored script under a tick-only instance ----------------------
OLD=252b705     # the last commit before any runtime code
if git -C "$T_REPO_DIR" cat-file -e "$OLD:.groundhog/groundhog.sh" 2>/dev/null; then
  new_instance
  git -C "$T_REPO_DIR" show "$OLD:.groundhog/groundhog.sh" > "$GHD/groundhog.sh"
  gh init >/dev/null; gh add daily nudge >/dev/null; echo hi > "$GHD/schedule/daily/nudge/note.txt"
  set_clock "$SUNDAY"
  gh tick >/dev/null 2>&1
  before="$(cd "$GHD" && find out fired schedule | LC_ALL=C sort | cksum)"
  assert_eq "old script: legacy copy has no status command" 1 "$(rc_of gh status --json)"
  mkdir -p "$T_TMP/host2"; mv "$GHD" "$T_TMP/host2/.groundhog" 2>/dev/null; GHD="$T_TMP/host2/.groundhog"; INST="$T_TMP/host2"
  bash "$T_REPO_DIR/install.sh" "$INST" >/dev/null 2>&1
  assert_eq "upgrade: schedule, out and fired are unchanged" "$before" "$(cd "$GHD" && find out fired schedule | LC_ALL=C sort | cksum)"
  assert_eq "...the new script answers status" 0 "$(rc_of gh status --json)"
  status_to "$out"
  assert_eq "...unowned" null "$(jget "$out" owner)"
  assert_eq "...the old firing is not fired again" "" "$(gh tick 2>&1)"
  assert_eq "...nothing was enrolled, configured or recorded" "" "$(find "$GHD/runtime" -type f ! -name '*.lock' ! -name last_tick 2>/dev/null)"
  clear_clock
else
  t_skip "the pre-runtime script ($OLD) is not in this checkout's history"
fi

# --- 3. enroll, then recurring and overdue one-shot delivery, with no consumer --------
set_clock "$SUNDAY"
new_instance; gh init >/dev/null
gh add daily nudge >/dev/null;               echo n > "$GHD/schedule/daily/nudge/note.txt"
gh add weekly/sun/09 standup >/dev/null;     echo s > "$GHD/schedule/weekly/sun/09/standup/note.txt"
gh add once/2026-11-01 late >/dev/null;      echo l > "$GHD/schedule/once/2026-11-01/late/note.txt"
gh add once/2026-11-20 future >/dev/null;    echo f > "$GHD/schedule/once/2026-11-20/future/note.txt"
gh add daily/22 evening >/dev/null;          echo e > "$GHD/schedule/daily/22/evening/note.txt"
enroll_ok "e2e-session"
assert_eq "enroll takes ownership and starts nothing" '"stopped"' "$(status_to "$out"; jget "$out" runner.state)"
assert_eq "...owner label recorded" '"e2e-session"' "$(jget "$out" owner.label)"
assert_eq "...generation 1" 1 "$(jget "$out" owner.generation)"
run_bg
wait_for "three deliveries registered" 100 has_records 3
sleep 1.5       # a further cycle: nothing may be added or re-fired
status_to "$out"
assert_eq "recurring daily, weekly-from-09 and the overdue one-shot were delivered" 3 "$(ndeliveries)"
assert_true "...the not-yet-due items were not" test ! -e "$GHD/out/evening-2026-11-15" -a ! -e "$GHD/out/future-2026-11-15"
assert_true "...the future one-shot is still scheduled" test -d "$GHD/schedule/once/2026-11-20/future"
assert_false "...the overdue one-shot's source is gone" test -e "$GHD/schedule/once/2026-11-01/late"
assert_eq "no consumer: every delivery waits as pending" '"no_consumer"' "$(jq_py dget "$out" path out/nudge-2026-11-15 reason)"
assert_eq "...with no attempt made" "[]" "$(jq_py dget "$out" path out/nudge-2026-11-15 attempts)"
assert_eq "...and consumer.configured false" false "$(jget "$out" consumer.configured)"

# --- 4. same-name items at different schedule paths ------------------------------------
# (test_collisions has every way two firings can claim one name; here, the walk.)
stop_bg
mkdir -p "$GHD/schedule/weekly/sun/foo" "$GHD/schedule/monthly/15/foo"
echo w > "$GHD/schedule/weekly/sun/foo/note.txt"; echo m > "$GHD/schedule/monthly/15/foo/note.txt"
run_bg
wait_for "foo registered" 100 registered "foo-2026-11-15"
sleep 1
status_to "$out"
assert_true "each schedule path has its own fired marker" test -e "$GHD/fired/2026-11-15/weekly/sun/foo" -a -e "$GHD/fired/2026-11-15/monthly/15/foo"
assert_eq "one delivery owns out/foo-2026-11-15" 1 "$(jq_py where "$out" deliveries path '"out/foo-2026-11-15"' id | wc -l | tr -d ' ')"
assert_contains "the second firing is reported, not silent" "$(jget "$out" diagnostics)" out_collision
assert_contains "...naming the path it lost to" "$(jget "$out" diagnostics)" "schedule/monthly/15/foo"
assert_contains "...and what status says about the two items" "$(jget "$out" schedule)" '"item_id":"foo"'

# --- 5. ownership conflicts ---------------------------------------------------------------
real_tok="$TOK"; new_token_path; other_tok="$TOK"; TOK="$real_tok"
assert_eq "a rival enroll while owned: 3" 3 "$(rc_of gh enroll --owner-label rival --token-file "$other_tok")"
assert_false "...and wrote no token" test -e "$other_tok"
for c in tick init drop sweep; do
  case "$c" in drop) a=nudge ;; *) a="" ;; esac
  assert_eq "$c while owned: 3" 3 "$(rc_of gh $c $a)"
done
# add works while owned (test_add.sh); a far-future once item leaves the later parts' deliveries alone.
assert_eq "add while owned: 0" 0 "$(rc_of gh add once/2099-01-01 extra)"
rmdir "$GHD/schedule/once/2099-01-01/extra" "$GHD/schedule/once/2099-01-01"
assert_eq "a second run, even with the same token: 4" 4 "$(rc_of gh run --token-file "$real_tok" --interval-seconds 1)"
# a token from another instance does not control this one
save_inst="$INST"; save_ghd="$GHD"
new_instance; gh init >/dev/null; enroll_ok; foreign="$TOK"
INST="$save_inst"; GHD="$save_ghd"
assert_eq "another instance's token: 3" 3 "$(rc_of gh pause --token-file "$foreign")"
assert_eq "...and the pause was not set" false "$(status_to "$out"; jget "$out" paused)"
TOK="$real_tok"

# --- 6. persistent pause --------------------------------------------------------------------
assert_eq "pause with the owner's token: 0" 0 "$(rc_of gh pause --token-file "$TOK")"
mkdir -p "$GHD/schedule/daily/while-paused"; echo p > "$GHD/schedule/daily/while-paused/note.txt"
sleep 2.5
assert_false "a due item does not fire while paused" test -e "$GHD/out/while-paused-2026-11-15"
stop_bg
assert_eq "pause survives stop" true "$(status_to "$out"; jget "$out" paused)"
run_bg
sleep 2
assert_false "...and a restarted runner (run never clears it) still fires nothing" test -e "$GHD/out/while-paused-2026-11-15"
assert_eq "...the owner is unchanged" 1 "$(status_to "$out"; jget "$out" owner.generation)"
gh resume --token-file "$TOK" >/dev/null
wait_for "the item fires after resume" 100 test -d "$GHD/out/while-paused-2026-11-15"
stop_bg

# --- 7. a plain synchronous consumer; failure and retry -------------------------------------
# The script is not executable and runs under an explicit /bin/sh.
printf '%s\n' 'case "$1" in */foo-*) exit 7 ;; esac' \
  'cat "$1/note.txt" > "$PWD/copy-$(basename "$1").txt"' > "$INST/copy-note.sh"
write_config /bin/sh "$INST/copy-note.sh"
run_bg
wait_for "everything but foo is accepted" 150 sh -c "status_json=\$('$TEST_BASH' '$GHD/groundhog.sh' status --json); case \"\$status_json\" in *'\"state\":\"failed\"'*) exit 0 ;; *) exit 1 ;; esac"
sleep 1.5
status_to "$out"
assert_eq "a synchronous script's exit 0 is the acknowledgement" '"accepted"' "$(jq_py dget "$out" path out/nudge-2026-11-15 state)"
assert_eq "...execution stays unknown" '"unknown"' "$(jq_py dget "$out" path out/nudge-2026-11-15 execution)"
assert_eq "...the work happened in the configured cwd" "n" "$(cat "$INST/copy-nudge-2026-11-15.txt")"
assert_eq "...the delivery is unchanged" "n" "$(cat "$GHD/out/nudge-2026-11-15/note.txt")"
assert_eq "a nonzero exit is failed" '"failed"' "$(jq_py dget "$out" path out/foo-2026-11-15 state)"
assert_eq "...with the exit code" 7 "$(jq_py dget "$out" path out/foo-2026-11-15 attempts.0.exit_code)"
sleep 2.5
assert_eq "...and later cycles do not retry it" 1 "$(jq_py dget "$out" path out/foo-2026-11-15 attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
foo_id="$(did foo-2026-11-15)"
assert_eq "retry needs a stopped runner (busy: 4)" 4 "$(rc_of gh retry --token-file "$TOK" --delivery "$foo_id")"
stop_bg
printf 'cat "$1/note.txt" > "$PWD/copy-$(basename "$1").txt"\n' > "$INST/copy-note.sh"      # the operator fixes the script
assert_eq "retry: failed -> pending, same id" 0 "$(rc_of gh retry --token-file "$TOK" --delivery "$foo_id")"
run_bg
wait_for "the retried delivery is accepted" 100 sh -c "'$TEST_BASH' '$GHD/groundhog.sh' status --json | grep -q '\"state\":\"failed\"' && exit 1; exit 0"
sleep 1.5
stop_bg
status_to "$out"
assert_eq "...under the same delivery id" "$foo_id" "$(did foo-2026-11-15)"
assert_eq "...with the first attempt kept in its history" 2 "$(jq_py dget "$out" path out/foo-2026-11-15 attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
assert_true "every delivery is accepted now" all_in_state accepted

# --- 8. an asynchronous adapter: durable acceptance, a separate worker -----------------------
# The adapter copies the job into its own spool and exits 0; a worker (here a
# function, later and apart) drains the spool. Same configuration shape as part 7.
new_instance; gh init >/dev/null
gh add daily nudge >/dev/null; echo job-1 > "$GHD/schedule/daily/nudge/note.txt"
enroll_ok
SPOOL="$INST/spool"; mkdir -p "$SPOOL"
cat > "$INST/adapter.sh" <<EOF
#!/bin/sh
set -eu
d="\$1"
mkdir -p "$SPOOL/\$GROUNDHOG_DELIVERY_ID.tmp"
cp -R "\$d/." "$SPOOL/\$GROUNDHOG_DELIVERY_ID.tmp/"
mv "$SPOOL/\$GROUNDHOG_DELIVERY_ID.tmp" "$SPOOL/\$GROUNDHOG_DELIVERY_ID.job"
exit 0
EOF
chmod +x "$INST/adapter.sh"
write_config "$INST/adapter.sh"
run_bg
wait_for "the adapter's delivery is accepted" 100 sh -c "'$TEST_BASH' '$GHD/groundhog.sh' status --json | grep -q '\"state\":\"accepted\"'"
stop_bg
status_to "$out"
aid="$(did "nudge-$(today)")"
assert_eq "async: accepted once the job is durably in the spool" '"accepted"' "$(dstate "nudge-$(today)")"
assert_true "...the job is waiting there, not yet worked" test -f "$SPOOL/$aid.job/note.txt" -a ! -e "$SPOOL/$aid.done"
assert_eq "...execution is still unknown" '"unknown"' "$(dget id "$aid" execution)"
rm -rf "$GHD/out/nudge-$(today)"     # independent work must not need the original delivery
worker() { local j; for j in "$SPOOL"/*.job; do [ -d "$j" ] || continue; cat "$j/note.txt" > "${j%.job}.done"; rm -rf "$j"; done; }
worker
assert_eq "the worker, run separately, drains the spool from its own copy" "job-1" "$(cat "$SPOOL/$aid.done")"

# --- 9. signal shutdown with a consumer in flight (stop would wait for it) --------------------------------------------
new_instance; gh init >/dev/null
gh add daily nudge >/dev/null; echo z > "$GHD/schedule/daily/nudge/note.txt"
enroll_ok
consumer_script slow.sh 'echo $$ > "$PWD/slow.pid"; sleep 20'
write_config /bin/sh "$CONS"
run_bg
wait_for "the consumer is running" 100 pid_alive "$INST/slow.pid"
T_GROUPS="$T_GROUPS $(cat "$INST/slow.pid")"
kill -TERM "$RUNNER_PID"
wait_exit "SIGTERM ends the runner" 80 "$RUNNER_PID"
assert_true "the signal detached from it without killing it" pid_alive "$INST/slow.pid"
status_to "$out"
assert_eq "...the delivery is uncertain, never accepted by shutdown" '"uncertain"' "$(dstate "nudge-$(today)")"
assert_eq "...ownership is kept" 1 "$(jget "$out" owner.generation)"
assert_eq "release is refused while an attempt is unresolved: 5" 5 "$(rc_of gh release --token-file "$TOK")"
did9="$(did "nudge-$(today)")"
kill "$(cat "$INST/slow.pid")" 2>/dev/null; sleep 0.3            # the operator establishes it has finished
assert_eq "recover accept records the decision (no consumer invoked)" 0 "$(rc_of gh recover --token-file "$TOK" --delivery "$did9" --decision accept)"
assert_eq "...accepted, with the outcome still unknown" '"accepted"' "$(dget id "$did9" state)"
# SIGTERM to a bare runner: exit 0, ownership and pause kept
gh pause --token-file "$TOK" >/dev/null
run_bg
kill -TERM "$RUNNER_PID"
wait_exit "SIGTERM ends the runner" 80 "$RUNNER_PID"
assert_eq "...with status 0" 0 "$WAIT_RC"
status_to "$out"
assert_eq "...owned, stopped and still paused" '1 "stopped" true' "$(jget "$out" owner.generation) $(jget "$out" runner.state) $(jget "$out" paused)"

# --- 10. authorized non-interactive token reuse -----------------------------------------------
# No shared shell state: each command below is a fresh process that only has the token file.
new_instance; gh init >/dev/null; gh add daily nudge >/dev/null; enroll_ok
tok10="$TOK"; owner_before="$(status_to "$out"; jget "$out" owner.id)"
svc() { env -i PATH="$PATH" HOME="$HOME" "$TEST_BASH" "$GHD/groundhog.sh" "$@"; }
assert_eq "a second process with the token file: pause" 0 "$(rc_of svc pause --token-file "$tok10")"
assert_eq "...resume" 0 "$(rc_of svc resume --token-file "$tok10")"
set -m; env -i PATH="$PATH" HOME="$HOME" "$TEST_BASH" "$GHD/groundhog.sh" run --token-file "$tok10" --interval-seconds 1 >/dev/null 2>&1 &
RUNNER_PID=$!; set +m; T_PIDS="$T_PIDS $RUNNER_PID"
wait_for "the service's runner is up" 80 runner_is running
assert_eq "...a third process stops it" 0 "$(rc_of svc stop --token-file "$tok10")"
wait_exit "the service's runner exited" 50 "$RUNNER_PID"
assert_eq "...ownership kept (no release needed to run again)" "$owner_before" "$(status_to "$out"; jget "$out" owner.id)"
set -m; env -i PATH="$PATH" HOME="$HOME" "$TEST_BASH" "$GHD/groundhog.sh" run --token-file "$tok10" --interval-seconds 1 >/dev/null 2>&1 &
RUNNER_PID=$!; set +m; T_PIDS="$T_PIDS $RUNNER_PID"
wait_for "...and it restarts with the same token, same owner, no re-enroll" 80 runner_is running
assert_eq "...generation unchanged" 1 "$(status_to "$out"; jget "$out" owner.generation)"
TOK="$tok10"; stop_bg

# --- 11. stopped-but-owned, explicit release, re-enroll ----------------------------------------
gh pause --token-file "$TOK" >/dev/null
new_token_path; rival="$TOK"; TOK="$tok10"
assert_eq "stopped but owned: a rival enroll still gets 3" 3 "$(rc_of gh enroll --owner-label rival --token-file "$rival")"
assert_eq "...nothing there ever transfers ownership (status keeps the owner)" "$owner_before" "$(status_to "$out"; jget "$out" owner.id)"
assert_eq "release by the token holder: 0" 0 "$(rc_of gh release --token-file "$TOK")"
status_to "$out"
assert_eq "...no owner, runner stopped" 'null "stopped"' "$(jget "$out" owner) $(jget "$out" runner.state)"
assert_eq "...the pause is kept" true "$(jget "$out" paused)"
assert_eq "...the released token authorizes nothing: 3" 3 "$(rc_of gh resume --token-file "$TOK")"
assert_eq "...and a new enroll gets generation 2" 2 "$(gh enroll --owner-label next --token-file "$rival" >/dev/null 2>&1; status_to "$out"; jget "$out" owner.generation)"
assert_eq "...the old token stays dead" 3 "$(rc_of gh pause --token-file "$TOK")"

# --- 12. install.sh starts and enrolls nothing --------------------------------------------------
host="$T_TMP/host12"; mkdir -p "$host"
bash "$T_REPO_DIR/install.sh" "$host" >/dev/null 2>&1
assert_true "install lays down the script and README" test -x "$host/.groundhog/groundhog.sh" -a -f "$host/.groundhog/README.md"
assert_eq "...and no runtime state of any kind (only the lock files init takes)" "" "$(find "$host/.groundhog/runtime" -type f ! -name '*.lock' ! -name last_tick 2>/dev/null)"
assert_eq "...no process was left running" "" "$(pgrep -f "$host/.groundhog/groundhog.sh" || true)"
GHD="$host/.groundhog"; status_to "$out"
assert_eq "...status: unowned, unpaused, stopped" 'null false "stopped"' "$(jget "$out" owner) $(jget "$out" paused) $(jget "$out" runner.state)"

# --- 13. install.sh upgrades a copied, customised .groundhog/ -----------------------------------
host="$T_TMP/host13"; mkdir -p "$host"
cp -R "$T_REPO_DIR/.groundhog" "$host/.groundhog"
printf 'older script\n' > "$host/.groundhog/groundhog.sh"
printf 'older readme\n' > "$host/.groundhog/README.md"
printf 'older contract\n' > "$host/.groundhog/docs/runtime-contract.md"
mkdir -p "$host/.groundhog/runtime"
printf 'schedule item\n' > "$host/.groundhog/schedule/daily/job.md"
printf 'output\n' > "$host/.groundhog/out/result-2026-01-01"
mkdir -p "$host/.groundhog/fired/2026-01-01"
printf 'fired\n' > "$host/.groundhog/fired/2026-01-01/job"
printf 'runtime note\n' > "$host/.groundhog/runtime/custom.txt"
host_files() { (cd "$host/.groundhog" && find . -type f ! -name "*.lock" ! -path ./groundhog.sh ! -path ./README.md ! -path ./docs/runtime-contract.md -exec cksum {} + | LC_ALL=C sort); }
before13="$(host_files)"
bash "$T_REPO_DIR/install.sh" "$host" >/dev/null 2>&1
assert_eq "upgrade leaves schedule, out, fired and runtime contents byte for byte" "$before13" "$(host_files)"
assert_eq "...refreshes the script" "" "$(cmp "$T_REPO_DIR/.groundhog/groundhog.sh" "$host/.groundhog/groundhog.sh" 2>&1)"
assert_eq "...refreshes the README" "" "$(cmp "$T_REPO_DIR/.groundhog/README.md" "$host/.groundhog/README.md" 2>&1)"
assert_eq "...refreshes the runtime contract" "" "$(cmp "$T_REPO_DIR/.groundhog/docs/runtime-contract.md" "$host/.groundhog/docs/runtime-contract.md" 2>&1)"
assert_true "...and the script stays executable" test -x "$host/.groundhog/groundhog.sh"
after13a="$(cd "$host/.groundhog" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
bash "$T_REPO_DIR/install.sh" "$host" >/dev/null 2>&1
assert_eq "a second upgrade changes no file" "$after13a" "$(cd "$host/.groundhog" && find . -type f -exec cksum {} + | LC_ALL=C sort)"

# The installer run inside its own checkout (source and destination the same file) works.
self13="$T_TMP/self13"; mkdir -p "$self13"
cp -R "$T_REPO_DIR/.groundhog" "$T_REPO_DIR/install.sh" "$self13/"
(cd "$self13" && bash ./install.sh . >/dev/null 2>&1); rc=$?
assert_eq "install.sh . inside a checkout exits 0" 0 "$rc"
assert_eq "...and leaves the script as it was" "" "$(cmp "$T_REPO_DIR/.groundhog/groundhog.sh" "$self13/.groundhog/groundhog.sh" 2>&1)"

t_finish
