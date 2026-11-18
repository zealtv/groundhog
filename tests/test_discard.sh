#!/usr/bin/env bash
# `discard --token-file PATH --delivery ID` (capability discard-v1, accepted
# 2026-11-18): the owner disposes of a delivery no consumer took. It needs a
# stopped runner and a valid token, discards `pending` with reason no_consumer
# and no other state, removes the out/ entry and records the delivery as
# `missing` with reason `discarded`, and leaves the fired marker, the attempts
# and the handoff barrier alone. Real runs make the no_consumer deliveries;
# hand-written records stand in for states a test cannot reach from outside.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support; then
  t_skip "this host has no lock helper, hash tool or durable-write tool; the runner commands are not offered"
  t_finish
  exit $?
fi

out="$T_TMP/dc.json"
rc_of() { local rc=0; "$@" >"$T_TMP/rc.out" 2>"$T_TMP/rc.err" || rc=$?; echo "$rc"; }
age_dirs() { age_tree "$GHD/out"; age_tree "$GHD/fired"; age_tree "$GHD/runtime"; }
dfield() { jq_py dget "$out" id "$1" "$2"; }       # a field of the delivery with id $1
rec_hash() { tree_hash "$GHD/runtime/deliveries"; }

# put_record ID OUT_NAME STATE REASON [ATTEMPT_OUTCOME [MARKER]] — as in test_owner_sweep.sh,
# with a reason (empty for none).
put_record() {
  mkdir -p "$GHD/runtime/deliveries"
  python3 -I - "$GHD/runtime/deliveries/$1.json" "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" <<'PY'
import json, sys
path, did, name, state, reason, outcome, marker = sys.argv[1:8]
attempts = []
if outcome:
    attempts.append({"id": "a-" + did, "started_at": "2026-11-10T00:00:00Z",
                     "finished_at": None if outcome in ("in_flight", "unknown") else "2026-11-10T00:00:01Z",
                     "outcome": outcome, "exit_code": 7 if outcome == "failed" else None,
                     "signal": None, "error": None})
rec = {"schema_version": 1, "id": did, "path": "out/" + name, "origin": "runtime",
       "schedule_path": "schedule/daily/x", "occurrence": {"date": "2026-11-10", "slot": None},
       "state": state, "reason": reason or None, "registered_at": "2026-11-10T00:00:00Z",
       "fired_marker": marker or None, "attempts": attempts, "collisions": []}
with open(path, "w") as f:
    json.dump(rec, f, separators=(",", ":"))
    f.write("\n")
PY
}

owned_instance() { new_instance; gh init >/dev/null; enroll_ok; }

# A real instance: two items fire into out/ with no consumer configured, so two
# deliveries sit pending with reason no_consumer; the runner is then stopped.
two_unconsumed() {
  owned_instance
  mkdir -p "$GHD/schedule/daily/nudge" "$GHD/schedule/daily/other"
  echo note > "$GHD/schedule/daily/nudge/note.txt"; echo note > "$GHD/schedule/daily/other/note.txt"
  gh resume --token-file "$TOK" >/dev/null 2>&1
  start_runner --token-file "$TOK" --interval-seconds 1
  wait_for "the runner is up" 80 runner_is running
  wait_for "both firings became deliveries" 80 out_is 2
  wait_for "...and were registered" 80 registered "nudge-$(today)"
  wait_for "...both" 80 registered "other-$(today)"
}
stop_runner() {
  gh stop --token-file "$TOK" >/dev/null 2>&1
  wait_exit "the runner exited" 50 "$RUNNER_PID"
}
NUDGE="nudge-$(today)"; OTHER="other-$(today)"

# --- the capability ---------------------------------------------------------------------
new_instance
gh capabilities --json > "$out"
assert_contains "capabilities lists discard-v1" "$(jget "$out" capabilities)" '"discard-v1"'

# --- discarding what no consumer took -------------------------------------------------
two_unconsumed
D1="$(did "$NUDGE")"; D2="$(did "$OTHER")"
stop_runner
status_to "$out"
assert_eq "a runner without a consumer leaves the first delivery pending" '"pending"' "$(dfield "$D1" state)"
assert_eq "...for want of a consumer" '"no_consumer"' "$(dfield "$D1" reason)"
marker_dir="$GHD/fired/$(today)"
assert_true "the occurrence has a fired marker" test -d "$marker_dir"
markers_before="$(tree_hash "$GHD/fired")"
owner_before="$(jget "$out" owner)"; rev_before="$(jget "$out" revision)"; paused_before="$(jget "$out" paused)"
other_rec_before="$(cat "$GHD/runtime/deliveries/$D2.json")"
other_out_before="$(tree_hash "$GHD/out/$OTHER")"
rc=0; gh discard --token-file "$TOK" --delivery "$D1" >"$out.o" 2>"$out.e" || rc=$?
assert_eq "discard exits 0 on an owned instance with a stopped runner" 0 "$rc"
assert_contains "...and says what it did" "$(cat "$out.o")" "discarded"
assert_false "the out/ entry is gone" test -e "$GHD/out/$NUDGE"
assert_true "...the other delivery's entry is untouched" test -d "$GHD/out/$OTHER"
assert_eq "...byte for byte" "$other_out_before" "$(tree_hash "$GHD/out/$OTHER")"
assert_true "the schedule item stays" test -f "$GHD/schedule/daily/nudge/note.txt"
status_to "$out"
assert_eq "the record is missing" '"missing"' "$(dfield "$D1" state)"
assert_eq "...with reason discarded" '"discarded"' "$(dfield "$D1" reason)"
assert_eq "the other delivery is still pending/no_consumer" '"pending"' "$(dfield "$D2" state)"
assert_eq "...and still has its reason" '"no_consumer"' "$(dfield "$D2" reason)"
assert_eq "the other delivery's record is unchanged" "$other_rec_before" "$(cat "$GHD/runtime/deliveries/$D2.json")"
assert_eq "fired markers are as they were" "$markers_before" "$(tree_hash "$GHD/fired")"
assert_eq "the owner is unchanged" "$owner_before" "$(jget "$out" owner)"
assert_eq "...so are the revision and the pause (a discard writes no runtime state)" "$rev_before/$paused_before" "$(jget "$out" revision)/$(jget "$out" paused)"
assert_eq "...and the token still works" 0 "$(rc_of gh pause --token-file "$TOK")"
assert_eq "...and resume" 0 "$(rc_of gh resume --token-file "$TOK")"
assert_eq "status stays consistent" 'true' "$(jget "$out" consistent)"

# Repeating it changes nothing and exits 0.
h="$(rec_hash)"
rc=0; gh discard --token-file "$TOK" --delivery "$D1" >"$out.o" 2>"$out.e" || rc=$?
assert_eq "discarding it again exits 0" 0 "$rc"
assert_contains "...and says it is already discarded" "$(cat "$out.o")" "already discarded"
assert_eq "...changing no record" "$h" "$(rec_hash)"

# The runner does not bring it back, files the record, and the occurrence does not fire again.
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the runner is up" 80 runner_is running
wait_for "the settled record is filed under done/" 100 test -e "$GHD/runtime/deliveries/done/$D1.json"
sleep 2
assert_false "the entry did not come back" test -e "$GHD/out/$NUDGE"
status_to "$out"
assert_eq "...and the item did not fire again: still two records in all" 2 "$(find "$GHD/runtime/deliveries" -name 'd-*.json' | wc -l | tr -d ' ')"
assert_eq "the discarded record is still missing/discarded after the runner filed it" '"discarded"' "$(dfield "$D1" reason)"
gh status --json --active > "$out.a" 2>/dev/null
assert_eq "--active counts it in settled.missing" 1 "$(jq_py get "$out.a" settled.missing)"
assert_eq "...and leaves it out of the list" 0 "$(jq_py where "$out.a" deliveries id "\"$D1\"" id | wc -l | tr -d ' ')"
assert_eq "...while the other delivery stays listed" '"pending"' "$(jq_py dget "$out.a" id "$D2" state)"
assert_eq "a live runner: 4" 4 "$(rc_of gh discard --token-file "$TOK" --delivery "$D2")"
assert_contains "...says to stop it" "$(cat "$T_TMP/rc.err")" "stop"
assert_true "...and removed nothing" test -d "$GHD/out/$OTHER"
stop_runner
rc=0; gh discard --token-file "$TOK" --delivery "$D1" >"$out.o" 2>"$out.e" || rc=$?
assert_eq "a discarded delivery already filed under done/ exits 0 too" 0 "$rc"
assert_contains "...and says so" "$(cat "$out.o")" "already discarded"

# The owner's sweep sees it as any missing record: it leaves once old enough; the
# unconsumed delivery that was not discarded stays.
age_dirs
assert_eq "sweep --token-file 0 exits 0" 0 "$(rc_of gh sweep --token-file "$TOK" 0)"
assert_false "the discarded record is swept" test -e "$GHD/runtime/deliveries/done/$D1.json" -o -e "$GHD/runtime/deliveries/$D1.json"
assert_true "the pending/no_consumer delivery stays" test -d "$GHD/out/$OTHER" -a -e "$GHD/runtime/deliveries/$D2.json"
assert_true "...and so does the fired date it keeps referenced" test -d "$GHD/fired/$(today)"
assert_eq "now it can be discarded too" 0 "$(rc_of gh discard --token-file "$TOK" --delivery "$D2")"
age_dirs
assert_eq "...and swept" 0 "$(rc_of gh sweep --token-file "$TOK" 0)"
assert_false "the last record and entry are gone" test -e "$GHD/out/$OTHER" -o -e "$GHD/runtime/deliveries/$D2.json" -o -e "$GHD/runtime/deliveries/done/$D2.json"
assert_false "...and the fired date is no longer protected, so it is swept" test -d "$GHD/fired/$(today)"
assert_eq "a swept delivery is no record any more: 5" 5 "$(rc_of gh discard --token-file "$TOK" --delivery "$D2")"

# --- only pending/no_consumer ---------------------------------------------------------
owned_instance
for n in p-pend p-pend-none p-fail p-unc p-fly p-acc p-nc-ok; do mkdir -p "$GHD/out/$n"; echo "$n" > "$GHD/out/$n/f"; done
put_record d-pend-other p-pend pending waiting_for_something
put_record d-pend-none p-pend-none pending ""
put_record d-fail p-fail failed ""  failed
put_record d-unc p-unc uncertain result_not_recorded unknown
put_record d-fly p-fly in_flight "" in_flight
put_record d-acc p-acc accepted "" accepted
put_record d-gone p-gone missing path_missing
put_record d-ok p-nc-ok pending no_consumer
age_dirs
snapshot="$(tree_hash "$GHD/out")$(rec_hash)"
unchanged() { [ "$snapshot" = "$(tree_hash "$GHD/out")$(rec_hash)" ]; }
for id in d-pend-other d-pend-none d-fail d-unc d-fly d-acc d-gone; do
  assert_eq "$id is not discarded: 5" 5 "$(rc_of gh discard --token-file "$TOK" --delivery "$id")"
  assert_contains "...and the message names what can be" "$(cat "$T_TMP/rc.err")" "no_consumer"
done
assert_true "none of those changed an entry or a record" unchanged
assert_eq "an id with no record: 5" 5 "$(rc_of gh discard --token-file "$TOK" --delivery d-nothing)"
assert_contains "...says there is no such record" "$(cat "$T_TMP/rc.err")" "no delivery record"
mkdir -p "$GHD/out/unregistered"
assert_eq "an out/ entry no record claims cannot be named by id: 5" 5 "$(rc_of gh discard --token-file "$TOK" --delivery unregistered)"
assert_true "...and it stays" test -d "$GHD/out/unregistered"
printf 'not json' > "$GHD/runtime/deliveries/d-bad.json"
snapshot="$(tree_hash "$GHD/out")$(rec_hash)"
assert_eq "an unreadable record: 5" 5 "$(rc_of gh discard --token-file "$TOK" --delivery d-bad)"
assert_contains "...says it was not changed" "$(cat "$T_TMP/rc.err")" "not changed"
assert_true "...and nothing changed" unchanged
rm -f "${GHD:?}/runtime/deliveries/d-bad.json"
snapshot="$(tree_hash "$GHD/out")$(rec_hash)"

# Argument and token errors.
real="$TOK"; save_inst="$INST"; save_ghd="$GHD"
new_instance; gh init >/dev/null; enroll_ok; foreign="$TOK"
INST="$save_inst"; GHD="$save_ghd"; TOK="$real"
assert_eq "another instance's token: 3" 3 "$(rc_of gh discard --token-file "$foreign" --delivery d-ok)"
assert_eq "a missing token file: 2" 2 "$(rc_of gh discard --token-file "$T_TMP/no-such-token" --delivery d-ok)"
assert_eq "no --token-file: 2" 2 "$(rc_of gh discard --delivery d-ok)"
assert_eq "no --delivery: 2" 2 "$(rc_of gh discard --token-file "$TOK")"
assert_eq "--delivery without a value: 2" 2 "$(rc_of gh discard --token-file "$TOK" --delivery)"
assert_eq "an id that is no id (a path): 2" 2 "$(rc_of gh discard --token-file "$TOK" --delivery ../d-ok)"
assert_eq "an id with a slash: 2" 2 "$(rc_of gh discard --token-file "$TOK" --delivery out/p-nc-ok)"
assert_eq "an id with a leading dot: 2" 2 "$(rc_of gh discard --token-file "$TOK" --delivery .hidden)"
assert_eq "an unknown option: 2" 2 "$(rc_of gh discard --token-file "$TOK" --delivery d-ok --force)"
assert_eq "--decision is not an option of discard: 2" 2 "$(rc_of gh discard --token-file "$TOK" --delivery d-ok --decision accept)"
assert_eq "a stray argument: 2" 2 "$(rc_of gh discard --token-file "$TOK" --delivery d-ok d-ok)"
assert_eq "--delivery twice: 2" 2 "$(rc_of gh discard --token-file "$TOK" --delivery d-ok --delivery d-ok)"
assert_eq "--token-file twice: 2" 2 "$(rc_of gh discard --token-file "$TOK" --token-file "$TOK" --delivery d-ok)"
assert_true "none of those changed anything" unchanged
assert_true "...the discardable entry is still there" test -d "$GHD/out/p-nc-ok"

# A stale token, after release and a new owner (a fresh instance: the one above holds
# unresolved attempts, which plain release refuses).
owned_instance
mkdir -p "$GHD/out/p-nc-ok" "$GHD/out/p-other"
put_record d-ok p-nc-ok pending no_consumer
put_record d-other p-other pending ""
gh release --token-file "$TOK" >/dev/null 2>&1
stale="$TOK"
assert_eq "an unowned instance rejects the old token: 3" 3 "$(rc_of gh discard --token-file "$stale" --delivery d-ok)"
enroll_ok second-owner
assert_eq "a stale token under a new owner: 3" 3 "$(rc_of gh discard --token-file "$stale" --delivery d-ok)"
assert_true "...and nothing was discarded" test -d "$GHD/out/p-nc-ok"
assert_eq "the new owner's token discards it" 0 "$(rc_of gh discard --token-file "$TOK" --delivery d-ok)"
assert_false "...and removed the entry" test -e "$GHD/out/p-nc-ok"
assert_true "...while the other entry stays" test -d "$GHD/out/p-other"

# --- a crash between the two steps ---------------------------------------------------
owned_instance
mkdir -p "$GHD/out/p-half"
put_record d-half p-half pending no_consumer
rm -rf "${GHD:?}/out/p-half"          # the payload went, the record did not
assert_eq "a pending/no_consumer record whose entry is already gone: discard finishes it" 0 "$(rc_of gh discard --token-file "$TOK" --delivery d-half)"
status_to "$out"
assert_eq "...as missing/discarded" '"missing"/"discarded"' "$(dfield d-half state)/$(dfield d-half reason)"
# If a run got there first, the record says path_missing, which is no business of discard.
put_record d-run p-run missing path_missing
assert_eq "a record the runner already made missing/path_missing: 5" 5 "$(rc_of gh discard --token-file "$TOK" --delivery d-run)"

# --- an entry that is a symlink is removed, never followed ---------------------------
owned_instance
mkdir -p "$T_TMP/elsewhere"; echo keep > "$T_TMP/elsewhere/precious"
mkdir -p "$GHD/out"; ln -s "$T_TMP/elsewhere" "$GHD/out/p-link"
put_record d-link p-link pending no_consumer
assert_eq "a symlinked entry: discard exits 0" 0 "$(rc_of gh discard --token-file "$TOK" --delivery d-link)"
assert_false "...the link is gone" test -e "$GHD/out/p-link" -o -L "$GHD/out/p-link"
assert_true "...its target is untouched" test -f "$T_TMP/elsewhere/precious"

# --- the handoff barrier stays; a consumer configured since the last run does not stop it --
owned_instance
mkdir -p "$GHD/out/p-unc" "$GHD/out/p-nc"
echo u > "$GHD/out/p-unc/f"; echo n > "$GHD/out/p-nc/f"
put_record d-unc p-unc uncertain result_not_recorded unknown
put_record d-nc p-nc pending no_consumer
assert_eq "plain release refuses with the unresolved attempt (the barrier)" 5 "$(rc_of gh release --token-file "$TOK")"
unc_before="$(cat "$GHD/runtime/deliveries/d-unc.json")"
assert_eq "discard works while the barrier stands" 0 "$(rc_of gh discard --token-file "$TOK" --delivery d-nc)"
assert_eq "...the unresolved delivery's record is byte for byte as it was" "$unc_before" "$(cat "$GHD/runtime/deliveries/d-unc.json")"
assert_true "...and its entry" test -f "$GHD/out/p-unc/f"
assert_eq "...the barrier still blocks plain release" 5 "$(rc_of gh release --token-file "$TOK")"
assert_eq "...and recover still settles the unresolved one" 0 "$(rc_of gh recover --token-file "$TOK" --delivery d-unc --decision accept)"
mkdir -p "$GHD/out/p-nc2"; put_record d-nc2 p-nc2 pending no_consumer
consumer_script consumer.sh 'exit 0'
write_config /bin/sh "$CONS"
assert_eq "a consumer configured since the record was written does not stop an explicit discard" 0 "$(rc_of gh discard --token-file "$TOK" --delivery d-nc2)"
assert_false "...and the consumer was not invoked (its entry is simply gone)" test -e "$GHD/out/p-nc2"

# --- it is a command of the owner only: no passive form ------------------------------
new_instance; gh init >/dev/null
mkdir -p "$GHD/out/p-x"; put_record d-x p-x pending no_consumer
assert_eq "without --token-file there is no passive discard: 2" 2 "$(rc_of gh discard --delivery d-x)"
assert_true "...and the entry stays" test -d "$GHD/out/p-x"

t_finish
