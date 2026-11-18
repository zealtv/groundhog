#!/usr/bin/env bash
# The owner's sweep: `sweep --token-file PATH [days]` on an owned instance. It
# needs a stopped runner and a valid token, removes what the passive sweep
# removes (accepted and missing records with their out/ entries, and unreferenced
# fired dates), and keeps every pending, failed, in-flight and uncertain
# delivery, pending/no_consumer ones included. Hand-written records stand in for
# states a test cannot reach from outside; one real run makes a no_consumer one.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support; then
  t_skip "this host has no lock helper, hash tool or durable-write tool; the runner commands are not offered"
  t_finish
  exit $?
fi

out="$T_TMP/os.json"
rc_of() { local rc=0; "$@" >"$T_TMP/rc.out" 2>"$T_TMP/rc.err" || rc=$?; echo "$rc"; }
age_dirs() { age_tree "$GHD/out"; age_tree "$GHD/fired"; age_tree "$GHD/runtime"; }

# put_record ID OUT_NAME STATE [ATTEMPT_OUTCOME [MARKER]] — as in test_journal.sh.
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

# A fresh owned instance: the owner enrolled, no runner started.
owned_instance() {
  new_instance; gh init >/dev/null; enroll_ok
}

# --- what the owner's sweep removes and keeps -----------------------------------------
owned_instance
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
status_to "$out"
owner_before="$(jget "$out" owner)"; rev_before="$(jget "$out" revision)"
assert_eq "without the token, an owned instance still refuses sweep (3)" 3 "$(rc_of gh sweep 0)"
assert_true "...and removed nothing" test -d "$GHD/out/p-acc" -a -e "$GHD/runtime/deliveries/d-acc.json"
rc=0; gh sweep --token-file "$TOK" 0 > "$out.o" 2> "$out.e" || rc=$?
assert_eq "sweep --token-file exits 0 on an owned instance with a stopped runner" 0 "$rc"
for n in p-pend p-fail p-unc p-fly; do
  assert_true "keeps unsettled out/$n" test -d "$GHD/out/$n"
done
assert_true "...and their records" test -e "$GHD/runtime/deliveries/d-pend.json" -a -e "$GHD/runtime/deliveries/d-fail.json" -a -e "$GHD/runtime/deliveries/d-unc.json" -a -e "$GHD/runtime/deliveries/d-fly.json"
assert_contains "...reports the skipped pending entry" "$(cat "$out.o")" "skipped out p-pend (pending)"
assert_contains "...failed" "$(cat "$out.o")" "skipped out p-fail (failed)"
assert_contains "...uncertain" "$(cat "$out.o")" "skipped out p-unc (uncertain)"
assert_contains "...in flight" "$(cat "$out.o")" "skipped out p-fly (in_flight)"
assert_true "...an entry no record claims" test -d "$GHD/out/p-unreg"
assert_contains "...reported as unregistered" "$(cat "$out.o")" "skipped out p-unreg (unregistered)"
assert_false "accepted entries are swept" test -e "$GHD/out/p-acc" -o -e "$GHD/out/p-acc2"
assert_false "...with their records" test -e "$GHD/runtime/deliveries/d-acc.json" -o -e "$GHD/runtime/deliveries/d-acc2.json"
assert_false "an accepted record whose path is long gone is swept" test -e "$GHD/runtime/deliveries/d-oldacc.json"
assert_false "a terminal missing record is swept" test -e "$GHD/runtime/deliveries/d-gone.json"
assert_false "an abandoned .landing entry is swept" test -e "$GHD/out/half.landing"
assert_true "the fired marker an unsettled delivery references survives" test -e "$GHD/fired/2026-11-01/daily/pend"
assert_contains "...and is reported" "$(cat "$out.o")" "skipped fired 2026-11-01"
assert_false "unreferenced fired dates are swept" test -e "$GHD/fired/2026-11-03" -o -e "$GHD/fired/2026-11-02"
status_to "$out"
assert_eq "the owner is unchanged" "$owner_before" "$(jget "$out" owner)"
assert_eq "...so is the revision (a sweep writes no state)" "$rev_before" "$(jget "$out" revision)"
assert_eq "...and the token still works" 0 "$(rc_of gh pause --token-file "$TOK")"
assert_eq "sweep never turns an accepted item into pending" 0 "$(jq_py where "$out" deliveries state '"accepted"' id | wc -l | tr -d ' ')"
assert_eq "...nor into anything else: four unsettled records remain" 4 "$(find "$GHD/runtime/deliveries" -maxdepth 1 -name 'd-*.json' | wc -l | tr -d ' ')"

# --- the age, and the default ---------------------------------------------------------
owned_instance
mkdir -p "$GHD/out/old-acc" "$GHD/out/new-acc"
put_record d-old old-acc accepted accepted
put_record d-new new-acc accepted accepted
age_tree "$GHD/out/old-acc"; age_tree "$GHD/runtime/deliveries/d-old.json"
rc=0; gh sweep --token-file "$TOK" 7 >/dev/null 2>&1 || rc=$?
assert_eq "an age with the token: exits 0" 0 "$rc"
assert_false "an accepted entry older than the age is swept" test -e "$GHD/out/old-acc" -o -e "$GHD/runtime/deliveries/d-old.json"
assert_true "a younger one stays, with its record" test -d "$GHD/out/new-acc" -a -e "$GHD/runtime/deliveries/d-new.json"
rc=0; gh sweep 3 --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "days may come before the option" 0 "$rc"
assert_true "...a recent entry stays at the default and at 3 days" test -d "$GHD/out/new-acc"
rc=0; gh sweep --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "no days: the default of 14" 0 "$rc"
assert_true "...a recent entry stays at the default age" test -d "$GHD/out/new-acc"

# --- a pending delivery with no consumer stays ----------------------------------------
owned_instance
mkdir -p "$GHD/schedule/daily/nudge"; echo note > "$GHD/schedule/daily/nudge/note.txt"
gh resume --token-file "$TOK" >/dev/null 2>&1
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the runner is up" 80 runner_is running
wait_for "the firing became a delivery" 80 out_is 1
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner exited" 50 "$RUNNER_PID"
status_to "$out"
assert_eq "a runner without a consumer leaves the delivery pending" '"pending"' "$(jq_py dget "$out" path "out/nudge-$(today)" state)"
assert_eq "...for want of a consumer" '"no_consumer"' "$(jq_py dget "$out" path "out/nudge-$(today)" reason)"
age_dirs
rc=0; gh sweep --token-file "$TOK" 0 > "$out.o" 2> "$out.e" || rc=$?
assert_eq "sweeping it exits 0" 0 "$rc"
assert_true "the pending/no_consumer entry stays" test -d "$GHD/out/nudge-$(today)"
assert_contains "...and is reported as skipped" "$(cat "$out.o")" "skipped out nudge-$(today) (pending)"
status_to "$out"
assert_eq "...its record is still pending/no_consumer" '"no_consumer"' "$(jq_py dget "$out" path "out/nudge-$(today)" reason)"

# --- refusals leave everything as it was ----------------------------------------------
owned_instance
mkdir -p "$GHD/out/p-acc"; put_record d-acc p-acc accepted accepted
# a live runner (it may file the accepted record under done/, so the baseline comes after it stops)
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the runner is up" 80 runner_is running
assert_eq "a live runner: 4" 4 "$(rc_of gh sweep --token-file "$TOK" 0)"
assert_contains "...says to stop it" "$(cat "$T_TMP/rc.err")" "stop"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner exited" 50 "$RUNNER_PID"
age_dirs
snapshot="$(tree_hash "$GHD/out")$(tree_hash "$GHD/runtime/deliveries")"
unchanged() { [ "$snapshot" = "$(tree_hash "$GHD/out")$(tree_hash "$GHD/runtime/deliveries")" ]; }
# tokens that do not control this instance
real="$TOK"
save_inst="$INST"; save_ghd="$GHD"
new_instance; gh init >/dev/null; enroll_ok; foreign="$TOK"
INST="$save_inst"; GHD="$save_ghd"; TOK="$real"
assert_eq "another instance's token: 3" 3 "$(rc_of gh sweep --token-file "$foreign" 0)"
assert_eq "a missing token file: 2" 2 "$(rc_of gh sweep --token-file "$T_TMP/no-such-token" 0)"
assert_eq "--token-file without a value: 2" 2 "$(rc_of gh sweep 0 --token-file)"
assert_eq "an unknown option: 2" 2 "$(rc_of gh sweep --token-file "$TOK" --force)"
assert_eq "days that are no number: 2" 2 "$(rc_of gh sweep --token-file "$TOK" soon)"
assert_eq "two days: 2" 2 "$(rc_of gh sweep --token-file "$TOK" 1 2)"
assert_eq "--token-file twice: 2" 2 "$(rc_of gh sweep --token-file "$TOK" --token-file "$TOK")"
assert_true "none of those removed anything" unchanged
# unreadable evidence stops the sweep
printf 'not json' > "$GHD/runtime/deliveries/d-bad.json"; age_dirs
snapshot="$(tree_hash "$GHD/out")$(tree_hash "$GHD/runtime/deliveries")"
assert_eq "an unreadable record: 5" 5 "$(rc_of gh sweep --token-file "$TOK" 0)"
assert_contains "...says nothing was swept" "$(cat "$T_TMP/rc.err")" "nothing was swept"
assert_true "...and nothing was removed" unchanged
rm -f "${GHD:?}/runtime/deliveries/d-bad.json"
# a stale token, after release and a new owner
gh release --token-file "$TOK" >/dev/null 2>&1
stale="$TOK"
assert_eq "an unowned instance rejects the old token: 3" 3 "$(rc_of gh sweep --token-file "$stale" 0)"
enroll_ok second-owner
assert_eq "a stale token under a new owner: 3" 3 "$(rc_of gh sweep --token-file "$stale" 0)"
age_dirs
assert_eq "the new owner's token sweeps" 0 "$(rc_of gh sweep --token-file "$TOK" 0)"
assert_false "...and the accepted entry is gone" test -e "$GHD/out/p-acc"

# --- the passive sweep is unchanged ---------------------------------------------------
new_instance; gh init >/dev/null
mkdir -p "$GHD/out/legacy"; age_dirs
assert_eq "an unowned instance without a token sweeps as before" 0 "$(rc_of gh sweep 0)"
assert_false "...removing the old entry" test -e "$GHD/out/legacy"
assert_eq "a bad days without a token still exits 1" 1 "$(rc_of gh sweep soon)"

t_finish
