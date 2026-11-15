#!/usr/bin/env bash
# Instance identity and runner liveness: the state's binding to its directory
# survives moves (while unowned) and path spelling, fails closed and visible
# (while owned), and the runner start id does not depend on TZ.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support; then
  t_skip "this host has no lock helper, hash tool or durable-write tool; the runner commands are not offered"
  t_finish
  exit $?
fi

out="$T_TMP/b.json"

# move_instance — move the current instance to a fresh directory.
move_instance() {
  T_COUNTER=$((T_COUNTER + 1))
  local to="$T_TMP/moved$T_COUNTER"
  mv "$INST" "$to"
  INST="$to"; GHD="$to/.groundhog"
}

# --- a released instance can move ----------------------------------------------
new_instance
gh init >/dev/null
gh add daily nudge >/dev/null
enroll_ok
gh release --token-file "$TOK" >/dev/null 2>&1
assert_true "the released state still names the old directory" grep -q "\"instance\":\"$GHD\"" "$GHD/runtime/state.json"
move_instance
rc=0; gh tick >/dev/null 2>"$out.e" || rc=$?
assert_eq "moved and released: tick works" 0 "$rc"
assert_eq "...and fired the due item" 1 "$(find "$GHD/out" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
rc=0; gh add daily other >/dev/null 2>&1 || rc=$?
assert_eq "moved and released: add works" 0 "$rc"
status_to "$out"
assert_eq "moved and released: status is consistent" true "$(jget "$out" consistent)"
assert_eq "...with no diagnostics" "[]" "$(jget "$out" diagnostics)"
new_token_path
rc=0; gh enroll --owner-label again --token-file "$TOK" >/dev/null 2>"$out.e" || rc=$?
assert_eq "moved and released: enroll works" 0 "$rc"
assert_true "...and rebinds the state to the new directory" grep -q "\"instance\":\"$GHD\"" "$GHD/runtime/state.json"
rc=0; gh pause --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "...and the new owner controls it" 0 "$rc"

# --- an owned instance that moved fails closed, and says so ---------------------
new_instance
gh init >/dev/null
enroll_ok
old_tok="$TOK"
move_instance
for c in "tick" "add daily x"; do
  rc=0; gh $c >/dev/null 2>"$out.e" || rc=$?
  assert_eq "moved and owned: '${c%% *}' exits 5" 5 "$rc"
  assert_contains "...naming the binding" "$(cat "$out.e")" "bound to a different instance"
done
# The token file also names the old directory, so token commands stop earlier,
# at the foreign-token check (3), before the state is read.
rc=0; gh pause --token-file "$old_tok" >/dev/null 2>&1 || rc=$?
assert_eq "moved and owned: pause with the old token exits 3" 3 "$rc"
new_token_path
rc=0; gh enroll --owner-label rival --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "moved and owned: enroll exits 5" 5 "$rc"
status_to "$out"
assert_json_valid "$out"
assert_eq "moved and owned: status is inconsistent" false "$(jget "$out" consistent)"
assert_contains "...with state_bound_elsewhere" "$(jget "$out" diagnostics)" state_bound_elsewhere
assert_eq "...still showing the owner" '"test-session"' "$(jget "$out" owner.label)"
# Offline repair (README): edit the binding in the state and in the token file.
sed "s#\"instance\":\"[^\"]*\"#\"instance\":\"$GHD\"#" "$GHD/runtime/state.json" > "$T_TMP/repaired"
cp "$T_TMP/repaired" "$GHD/runtime/state.json"
sed "s#\"instance\":\"[^\"]*\"#\"instance\":\"$GHD\"#" "$old_tok" > "$T_TMP/repaired.tok"
cp "$T_TMP/repaired.tok" "$old_tok"
status_to "$out"
assert_eq "after the documented repair: consistent" true "$(jget "$out" consistent)"
rc=0; gh pause --token-file "$old_tok" >/dev/null 2>&1 || rc=$?
assert_eq "...and the owner's token works again" 0 "$rc"

# --- a case-variant path on a case-insensitive file system ---------------------
new_instance
mkdir -p "$T_TMP/caseprobe"
if [ -d "$T_TMP/CASEPROBE" ] && [ "$(cd "$T_TMP/CASEPROBE" && /bin/pwd -P)" = "$T_TMP/caseprobe" ]; then
  gh init >/dev/null
  enroll_ok
  upper="$T_TMP/$(basename "$INST" | tr a-z A-Z)/.groundhog/groundhog.sh"
  assert_true "the upper-case spelling reaches the script" test -f "$upper"
  rc=0; "$TEST_BASH" "$upper" pause --token-file "$TOK" >/dev/null 2>"$out.e" || rc=$?
  assert_eq "case variant: pause with the enrolled token works" 0 "$rc"
  "$TEST_BASH" "$upper" status --json > "$out" 2>/dev/null
  assert_eq "case variant: status reports the on-disk spelling" "\"$GHD\"" "$(jget "$out" instance)"
  assert_eq "case variant: consistent" true "$(jget "$out" consistent)"
  rc=0; "$TEST_BASH" "$upper" release --token-file "$TOK" >/dev/null 2>&1 || rc=$?
  assert_eq "case variant: release works" 0 "$rc"
  rc=0; "$TEST_BASH" "$upper" tick >/dev/null 2>&1 || rc=$?
  assert_eq "case variant: tick works after release" 0 "$rc"
else
  t_skip "this file system is case-sensitive; no case-variant path to test"
fi

# --- a live runner reads running under any TZ ------------------------------------
new_instance
gh init >/dev/null
gh add daily nudge >/dev/null
enroll_ok
saved_tz="${TZ-}"; had_tz=0; [ -n "${TZ+x}" ] && had_tz=1
export TZ=Asia/Kolkata
start_runner --token-file "$TOK" --interval-seconds 1
if [ "$had_tz" -eq 1 ]; then export TZ="$saved_tz"; else unset TZ; fi
wait_for "the runner reports running (same TZ)" 80 runner_is running
for z in America/Los_Angeles UTC Pacific/Auckland; do
  status_to "$out" 2>/dev/null || true
  TZ="$z" "$TEST_BASH" "$GHD/groundhog.sh" status --json > "$out" 2>/dev/null
  assert_eq "status under TZ=$z: runner running" '"running"' "$(jget "$out" runner.state)"
  assert_eq "status under TZ=$z: no diagnostics" "[]" "$(jget "$out" diagnostics)"
done
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner stops" 80 "$RUNNER_PID"

t_finish
