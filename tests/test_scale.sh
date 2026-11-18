#!/usr/bin/env bash
# The delivery journal at scale: a live runner with 1,000 settled deliveries
# stays controllable (pause, resume, stop succeed within their wait), status
# stays quick and unchanged, terminal records are filed under
# runtime/deliveries/done/, the barrier still fails closed for an unreadable
# record there, and names that are not valid UTF-8 are not fired or imported.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support || ! have_isolation; then
  t_skip "this host has no lock helper, hash tool, durable-write tool or process-isolation helper; the consumer is not offered"
  t_finish
  exit $?
fi

out="$T_TMP/s.json"
FAST='echo x >> "$PWD/calls.txt"'
DONE="runtime/deliveries/done"
now_s() { python3 -I -c 'import time;print(time.time())'; }
secs() { python3 -I -c "print(round($2 - $1, 2))"; }
under() { python3 -I -c "import sys;sys.exit(0 if $1 < $2 else 1)"; }   # under SECONDS LIMIT
done_is() { [ "$(find "$GHD/$DONE" -maxdepth 1 -name 'd-*.json' 2>/dev/null | wc -l | tr -d ' ')" -ge "$1" ]; }
live_count() { find "$GHD/runtime/deliveries" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
# deliveries_sum FILE — checksum of status's deliveries array, order aside.
deliveries_sum() {
  python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(sorted(d["deliveries"],key=lambda x:x["id"] or ""),sort_keys=True))' "$1" | cksum
}

# make_records DIR N STATE [WITH_OUT] — N records d-00000000… in DIR, the way the
# runtime writes them; with WITH_OUT=1 each has its out/ directory.
make_records() {
  python3 -I - "$GHD" "$1" "$2" "$3" "${4:-1}" <<'PY'
import json, os, sys
ghd, sub, n, state, with_out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5] == "1"
d = os.path.join(ghd, sub)
os.makedirs(d, exist_ok=True)
for i in range(n):
    did = "d-%08x" % i
    name = "every-%05d" % i
    if with_out:
        os.makedirs(os.path.join(ghd, "out", name), exist_ok=True)
        with open(os.path.join(ghd, "out", name, "note.txt"), "w") as f:
            f.write("x")
    attempts = []
    if state == "accepted":
        attempts = [{"id": "a-" + did, "started_at": "2026-11-10T00:00:00Z", "finished_at": "2026-11-10T00:00:01Z",
                     "outcome": "accepted", "exit_code": 0, "signal": None, "error": None}]
    rec = {"schema_version": 1, "id": did, "path": "out/" + name, "origin": "runtime",
           "schedule_path": "schedule/every/15m/x", "occurrence": {"date": "2026-11-10", "slot": "%04d" % i},
           "state": state, "reason": None, "registered_at": "2026-11-10T00:00:00Z",
           "fired_marker": None, "attempts": attempts, "collisions": []}
    with open(os.path.join(d, did + ".json"), "w") as f:
        json.dump(rec, f, separators=(",", ":"))
        f.write("\n")
PY
}

# plain_consumer BODY — an enrolled instance with a consumer and no schedule items.
plain_consumer() {
  new_instance
  gh init >/dev/null
  enroll_ok || return 1
  consumer_script consumer.sh "$1"
  write_config /bin/sh "$CONS"
}

run_once() { # run for a moment, then stop
  start_runner --token-file "$TOK" --interval-seconds 1
  wait_for "the runner is up" 80 runner_is running
  sleep "${1:-1.5}"
  gh stop --token-file "$TOK" >/dev/null 2>&1
  wait_exit "the runner exited" 400 "$RUNNER_PID"
}

# --- 1,000 settled deliveries: the runner stays controllable ----------------------
plain_consumer "$FAST"
make_records runtime/deliveries 1000 accepted
t0="$(now_s)"; status_to "$out"; t1="$(now_s)"
before_sum="$(deliveries_sum "$out")"
before_time="$(secs "$t0" "$t1")"
assert_eq "status lists all 1,000 records (old layout: all in deliveries/)" 1000 "$(jq_py where "$out" deliveries state '"accepted"' id | wc -l | tr -d ' ')"
start_runner --token-file "$TOK" --interval-seconds 3
wait_for "the runner is up" 80 runner_is running
# The first cycle reads all 1,000 records; the lock must stay free for the controls.
rc=0; t0="$(now_s)"; gh pause --token-file "$TOK" >/dev/null 2>&1 || rc=$?; t1="$(now_s)"
assert_eq "pause succeeds during the first reconcile of 1,000 records" 0 "$rc"
assert_true "...within its wait ($(secs "$t0" "$t1") s)" under "$(secs "$t0" "$t1")" 3
rc=0; gh resume --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "resume succeeds too" 0 "$rc"
wait_for "all 1,000 records filed under done/" 1500 done_is 1000
assert_eq "the live directory holds none of them any more" 0 "$(live_count)"
wait_for "...and done/ has its index" 100 test -s "$GHD/$DONE/index"
for i in 1 2 3 4 5; do
  rc=0; gh pause --token-file "$TOK" >/dev/null 2>&1 || rc=$?
  assert_eq "pause $i against the live runner succeeds" 0 "$rc"
  rc=0; gh resume --token-file "$TOK" >/dev/null 2>&1 || rc=$?
  assert_eq "resume $i succeeds" 0 "$rc"
  sleep 0.7
done
t0="$(now_s)"; status_to "$out"; t1="$(now_s)"
after_time="$(secs "$t0" "$t1")"
printf 'info: status with 1,000 deliveries: %s s before they were filed, %s s after\n' "$before_time" "$after_time" >&2
assert_eq "status prints the same deliveries once they are filed" "$before_sum" "$(deliveries_sum "$out")"
# Relative to the same host and load: filed records cost a small fraction of unfiled ones
# (about a sixth to a tenth on an idle host; the old layout would give a ratio of 1).
assert_true "...and costs under half as much as before (${after_time} s against ${before_time} s)" under "$after_time" "$(python3 -I -c "print($before_time / 2)")"
assert_eq "...consistent, no diagnostics" '[]' "$(jget "$out" diagnostics)"
rc=0; t0="$(now_s)"; gh stop --token-file "$TOK" >/dev/null 2>&1 || rc=$?; t1="$(now_s)"
assert_eq "stop succeeds against the live runner" 0 "$rc"
wait_exit "the runner exited" 100 "$RUNNER_PID"
assert_eq "...and handed nothing off (they were all settled)" 0 "$(lines "$INST/calls.txt")"

# --- without the index, status reads the same records the slow way ----------------
rm -f "$GHD/$DONE/index"
status_to "$out"
assert_eq "status without done/index lists the same deliveries" "$before_sum" "$(deliveries_sum "$out")"
run_once
assert_true "a run writes the index again" test -s "$GHD/$DONE/index"
status_to "$out"
assert_eq "...and status is unchanged" "$before_sum" "$(deliveries_sum "$out")"

# --- the lock is held in slices while many records need a write ---------------------
# 300 pending deliveries whose out/ directories are gone: each becomes missing,
# one write each. The controls must get in while that happens.
plain_consumer "$FAST"
gh pause --token-file "$TOK" >/dev/null 2>&1
make_records runtime/deliveries 300 pending 0
start_runner --token-file "$TOK" --interval-seconds 2
wait_for "the runner is up" 80 runner_is running
bad=0
for i in 1 2 3 4 5 6 7 8; do
  rc=0; gh resume --token-file "$TOK" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 0 ] || bad=$((bad + 1))
  rc=0; gh pause --token-file "$TOK" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 0 ] || bad=$((bad + 1))
  sleep 0.6
done
assert_eq "pause and resume never found the instance busy while 300 records were rewritten" 0 "$bad"
wait_for "all 300 became missing and were filed" 1800 done_is 300
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner exited" 100 "$RUNNER_PID"
status_to "$out"
assert_eq "...recorded as missing" 300 "$(jq_py where "$out" deliveries state '"missing"' id | wc -l | tr -d ' ')"
assert_eq "...none of them recreated" 0 "$(find "$GHD/out" -maxdepth 1 -name 'every-*' | wc -l | tr -d ' ')"

# --- the barrier still fails closed for an unreadable terminal record ----------------
plain_consumer "$FAST"
make_records runtime/deliveries 3 accepted
run_once
assert_true "three accepted records are filed under done/" done_is 3
assert_eq "...and the live directory is empty" 0 "$(live_count)"
mkdir -p "$GHD/out/waiting"; echo w > "$GHD/out/waiting/f"
# A new pending delivery is handed off while every filed record is readable.
run_once 2.5
assert_eq "a pending delivery is handed off while done/ is sound" 1 "$(lines "$INST/calls.txt")"

barrier_case() { # DESC MUTATION [nodiag] — damage a filed record, add a pending delivery, run
  local desc="$1" mutate="$2" calls
  plain_consumer "$FAST"
  make_records runtime/deliveries 3 accepted
  run_once
  calls="$(lines "$INST/calls.txt")"
  $mutate
  mkdir -p "$GHD/out/waiting"; echo w > "$GHD/out/waiting/f"
  run_once 2.5
  assert_eq "$desc: the pending delivery is not handed off" "$calls" "$(lines "$INST/calls.txt")"
  assert_contains "$desc: the runner says admission is blocked" "$(cat "$RUN_ERR")" "blocked"
  status_to "$out"
  if [ "${3:-}" != nodiag ]; then
    assert_contains "$desc: status reports the record" "$(jget "$out" diagnostics)" "runtime/deliveries/done/d-0000000"
  fi
  chmod -R u+rw "$GHD/$DONE" 2>/dev/null || true
}
damage_truncate() { : > "$GHD/$DONE/d-00000001.json"; }
damage_garbage() { printf 'not json at all, and longer than it was' > "$GHD/$DONE/d-00000001.json"; }
damage_chmod() { chmod 000 "$GHD/$DONE/d-00000002.json"; }
damage_inflight() { # an unresolved record misfiled under done/
  python3 -I - "$GHD/$DONE/d-00000001.json" <<'PY'
import json, sys
p = sys.argv[1]
r = json.load(open(p)); r["state"] = "in_flight"
r["attempts"][0]["outcome"] = "in_flight"; r["attempts"][0]["finished_at"] = None
json.dump(r, open(p, "w"), separators=(",", ":"))
PY
}
damage_duplicate() { cp "$GHD/$DONE/d-00000001.json" "$GHD/runtime/deliveries/d-00000001.json"; }
barrier_case "a truncated record in done/" damage_truncate
barrier_case "a garbled record in done/" damage_garbage
barrier_case "a record in done/ that lost its read permission" damage_chmod
barrier_case "an unresolved record misfiled in done/" damage_inflight nodiag
barrier_case "a record present in deliveries/ and done/" damage_duplicate
assert_true "...and neither copy was overwritten" test -f "$GHD/runtime/deliveries/d-00000001.json"

# A listing of done/ that fails must not read as "nothing is filed": the filed
# deliveries' out/ entries would look unclaimed and be imported (and delivered)
# a second time. A find that fails is simulated with a shim on PATH.
plain_consumer "$FAST"
make_records runtime/deliveries 3 accepted
run_once
assert_true "three records are filed" done_is 3
mkdir -p "$T_TMP/failfind"
printf '#!/bin/sh\nexit 1\n' > "$T_TMP/failfind/find"; chmod +x "$T_TMP/failfind/find"
mkdir -p "$GHD/out/waiting"; echo w > "$GHD/out/waiting/f"
saved_path="$PATH"; PATH="$T_TMP/failfind:$PATH"
run_once 2.5
PATH="$saved_path"
assert_eq "a failing listing of done/ imports nothing" 0 "$(live_count)"
assert_eq "...and hands nothing off" 0 "$(lines "$INST/calls.txt")"
assert_contains "...and the runner says why" "$(cat "$RUN_ERR")" "could not list"
run_once 2.5
assert_eq "once the listing works the waiting entry is imported and handed off" 1 "$(lines "$INST/calls.txt")"

# A host without comm and join (both POSIX, so unusual): slower, never different.
plain_consumer "$FAST"
make_records runtime/deliveries 5 accepted
run_once
assert_true "five records are filed" done_is 5
mkdir -p "$GHD/out/stray-one"; echo s > "$GHD/out/stray-one/f"
status_to "$out"
with_tools="$(deliveries_sum "$out")"
nocomm="$T_TMP/nocomm-path"; mkdir -p "$nocomm"
for tool in date cat cp mv rm mkdir rmdir touch find grep sort basename dirname tr sed ls awk head wc od sleep ps sync chmod stat cksum sha256sum shasum openssl env perl flock; do
  src="$(command -v "$tool" 2>/dev/null)" || continue
  ln -s "$src" "$nocomm/$tool"
done
assert_false "the reduced PATH has no comm" test -e "$nocomm/comm"
assert_false "...and no join" test -e "$nocomm/join"
PATH="$nocomm" "$TEST_BASH" "$GHD/groundhog.sh" status --json > "$out" 2>"$out.err" || true
assert_eq "status without comm and join lists the same deliveries" "$with_tools" "$(deliveries_sum "$out")"
assert_eq "...and prints nothing on stderr" "" "$(cat "$out.err")"
assert_eq "...including the unregistered entry" 1 "$(jq_py where "$out" deliveries reason '"unregistered"' path | wc -l | tr -d ' ')"
rm -rf "$GHD/out/stray-one"

# ...and with exactly one filed record: an empty join result must not read as
# one line that matches the one listed file (it once did, and dropped the record).
plain_consumer "$FAST"
make_records runtime/deliveries 1 accepted
run_once
assert_true "one record is filed" done_is 1
status_to "$out"
with_tools="$(deliveries_sum "$out")"
PATH="$nocomm" "$TEST_BASH" "$GHD/groundhog.sh" status --json > "$out" 2>"$out.err" || true
assert_eq "status without join lists the one filed record all the same" "$with_tools" "$(deliveries_sum "$out")"
assert_eq "...and prints nothing on stderr" "" "$(cat "$out.err")"

# release refuses on an unreadable filed record (unreadable evidence is never "resolved")
plain_consumer "$FAST"
make_records runtime/deliveries 2 accepted
run_once
rc=0; gh release --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "release succeeds with sound filed records" 0 "$rc"
plain_consumer "$FAST"
make_records runtime/deliveries 2 accepted
run_once
: > "$GHD/$DONE/d-00000001.json"
rc=0; gh release --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "release refuses with an unreadable filed record (5)" 5 "$rc"

# --- retry and recover find a filed record and refuse it by state ---------------------
plain_consumer "$FAST"
make_records runtime/deliveries 1 accepted
run_once
rc=0; gh retry --token-file "$TOK" --delivery d-00000000 >"$T_TMP/r.out" 2>"$T_TMP/r.err" || rc=$?
assert_eq "retry of a filed accepted record exits 5" 5 "$rc"
assert_contains "...saying what state it is in" "$(cat "$T_TMP/r.err")" "accepted"
rc=0; gh retry --token-file "$TOK" --delivery d-nothere >/dev/null 2>"$T_TMP/r.err" || rc=$?
assert_eq "retry of an unknown id exits 5" 5 "$rc"
assert_contains "...saying there is no such record" "$(cat "$T_TMP/r.err")" "no delivery record"

# --- sweep reaches filed records ------------------------------------------------------
new_instance; gh init >/dev/null
make_records runtime/deliveries/done 3 accepted
mkdir -p "$GHD/out/keep-me"
age_tree "$GHD/out"; age_tree "$GHD/runtime"
gh sweep 1 >"$T_TMP/sw.out" 2>&1
assert_eq "sweep removes the accepted entries" 0 "$(find "$GHD/out" -mindepth 1 -maxdepth 1 -name 'every-*' | wc -l | tr -d ' ')"
assert_eq "...together with their filed records" 0 "$(find "$GHD/$DONE" -maxdepth 1 -name 'd-*.json' | wc -l | tr -d ' ')"
assert_true "...and leaves an entry no record claims" test -d "$GHD/out/keep-me"

# --- status --active: settled records are counted, and the time stays bounded -------
# Every delivery leaves a record and status lists all of them; two weeks of one
# `every/1m` item pass 8 MiB of output. status --active (capability status-active-v1)
# lists the deliveries that can still change (pending, in_flight, failed, uncertain)
# and counts the accepted and missing ones. Fixtures, written as the runner leaves
# them and not by running one: SETTLED records filed under done/ with a trusted index,
# four active records in deliveries/, and one settled record the index has no line for.
SETTLED=5000
make_filed() { # N — see above; nine in ten settled records are accepted, the rest missing (no out/ entry)
  python3 -I - "$GHD" "$1" <<'PY'
import json, os, sys
ghd, n = sys.argv[1], int(sys.argv[2])
US = "\x1f"
rt = os.path.join(ghd, "runtime", "deliveries")
done = os.path.join(rt, "done")
os.makedirs(done, exist_ok=True)
os.makedirs(os.path.join(ghd, "out"), exist_ok=True)
def record(i, state, attempts):
    return {"schema_version": 1, "id": "d-%08x" % i, "path": "out/item-%05d" % i, "origin": "runtime",
            "schedule_path": "schedule/every/1m/x", "occurrence": {"date": "2026-11-10", "slot": "%04d" % i},
            "state": state, "reason": None, "registered_at": "2026-11-10T00:00:00Z",
            "fired_marker": None, "attempts": attempts, "collisions": []}
def attempt(i, outcome):
    return {"id": "a-%08x" % i, "started_at": "2026-11-10T00:00:00Z",
            "finished_at": None if outcome == "in_flight" else "2026-11-10T00:00:01Z",
            "outcome": outcome, "exit_code": 0 if outcome == "accepted" else None, "signal": None, "error": None}
def write(d, rec):
    if rec["state"] != "missing":
        os.makedirs(os.path.join(ghd, rec["path"]), exist_ok=True)
        open(os.path.join(ghd, rec["path"], "note.txt"), "w").write("x")
    with open(os.path.join(d, rec["id"] + ".json"), "w") as f:
        json.dump(rec, f, separators=(",", ":")); f.write("\n")
lines = ["groundhog-done-index 1"]
for i in range(n):
    state = "missing" if i % 10 == 0 else "accepted"
    rec = record(i, state, [] if state == "missing" else [attempt(i, "accepted")])
    write(done, rec)
    st = os.stat(os.path.join(done, rec["id"] + ".json"))
    view = {"id": rec["id"], "path": rec["path"], "origin": "runtime", "schedule_path": rec["schedule_path"],
            "occurrence": rec["occurrence"], "state": state, "reason": None, "attempts": rec["attempts"], "execution": "unknown"}
    lines.append(US.join(["./" + rec["id"] + ".json", str(st.st_ino), str(st.st_size), str(int(st.st_mtime)),
                          "%o" % (st.st_mode & 0o7777), state, rec["path"], json.dumps(view, separators=(",", ":"))]))
lines.sort()
open(os.path.join(done, "index"), "w").write("\n".join(lines) + "\n")
write(done, record(n, "accepted", [attempt(n, "accepted")]))     # the index has no line for this one
for k, (state, outcome) in enumerate([("pending", None), ("in_flight", "in_flight"), ("failed", "failed"), ("uncertain", "unknown")]):
    i = 0x900000 + k
    write(rt, record(i, state, [] if outcome is None else [attempt(i, outcome)]))
PY
}
active_ids() { # FILE — ids of the deliveries listed in FILE that are not settled, sorted
  python3 -I -c 'import json,sys;print(" ".join(sorted(d["id"] for d in json.load(open(sys.argv[1]))["deliveries"] if d["state"] not in ("accepted","missing"))))' "$1"
}
count_state() { # FILE STATE — deliveries listed in FILE in STATE
  python3 -I -c 'import json,sys;print(sum(1 for d in json.load(open(sys.argv[1]))["deliveries"] if d["state"]==sys.argv[2]))' "$1" "$2"
}
has_key() { python3 -I -c 'import json,sys;print("yes" if sys.argv[2] in json.load(open(sys.argv[1])) else "no")' "$1" "$2"; }
without_keys() { # FILE KEY… — the document minus those keys, canonical
  python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));[d.pop(k,None) for k in sys.argv[2:]];print(json.dumps(d,sort_keys=True))' "$@"
}

plain_consumer "$FAST"
make_filed "$SETTLED"
ACCEPTED_N=$((SETTLED - SETTLED / 10 + 1)); MISSING_N=$((SETTLED / 10))
t0="$(now_s)"; status_to "$out"; t1="$(now_s)"
full_time="$(secs "$t0" "$t1")"
full_bytes="$(wc -c < "$out" | tr -d ' ')"
assert_eq "status lists every delivery by default" "$((SETTLED + 5))" "$(jq_py where "$out" deliveries origin '"runtime"' id | wc -l | tr -d ' ')"
assert_eq "...with no settled count in the document" no "$(has_key "$out" settled)"
assert_eq "...consistent, no diagnostics" '[]' "$(jget "$out" diagnostics)"
assert_true "...within bounds for $((SETTLED + 5)) records (${full_time} s)" under "$full_time" 25
default_active="$(active_ids "$out")"

act="$T_TMP/active.json"
rc=0; t0="$(now_s)"; gh status --json --active > "$act" 2> "$act.err" || rc=$?; t1="$(now_s)"
active_time="$(secs "$t0" "$t1")"
active_bytes="$(wc -c < "$act" | tr -d ' ')"
printf 'info: status with %s settled deliveries (%s): default %s s, %s bytes; --active %s s, %s bytes\n' \
  "$((SETTLED + 1))" "$TEST_BASH" "$full_time" "$full_bytes" "$active_time" "$active_bytes" >&2
assert_eq "status --json --active exits 0" 0 "$rc"
assert_eq "...with nothing on stderr" "" "$(cat "$act.err")"
assert_json_valid "$act"
assert_eq "...it lists exactly the deliveries that can still change" "d-00900000 d-00900001 d-00900002 d-00900003" "$(active_ids "$act")"
assert_eq "...the ones the default output also shows as active" "$default_active" "$(active_ids "$act")"
assert_eq "...and no settled one" 0 "$(( $(count_state "$act" accepted) + $(count_state "$act" missing) ))"
assert_eq "...it counts the accepted ones, with the one the index lacked" "$ACCEPTED_N" "$(jget "$act" settled.accepted)"
assert_eq "...and the missing ones" "$MISSING_N" "$(jget "$act" settled.missing)"
assert_eq "...consistent, no diagnostics" '[]' "$(jget "$act" diagnostics)"
assert_true "...its output stays small ($active_bytes bytes against $full_bytes)" test "$active_bytes" -lt 20000
assert_true "...its time stays bounded (${active_time} s)" under "$active_time" 15
assert_true "...and is under the default's (${active_time} s against ${full_time} s)" under "$active_time" "$full_time"
assert_eq "...everything else in the document is as in the default output" \
  "$(without_keys "$out" observed_at deliveries)" "$(without_keys "$act" observed_at deliveries settled)"
assert_eq "--active may come before --json" "$ACCEPTED_N" \
  "$(gh status --active --json | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["settled"]["accepted"])')"
for args in "--active" "--json --active --active"; do
  rc=0
  # shellcheck disable=SC2086
  gh status $args > "$act.o" 2> "$act.e" || rc=$?
  assert_eq "status $args exits 2" 2 "$rc"
  assert_eq "...with no stdout" "" "$(cat "$act.o")"
done

# A record in both directories, and an out/ entry no record claims, still show.
cp "$GHD/runtime/deliveries/d-00900000.json" "$GHD/$DONE/d-00900000.json"
mkdir "$GHD/out/stray-entry"
gh status --json --active > "$act" 2>/dev/null || true
assert_contains "a record in both deliveries/ and done/ shows under --active" "$(jget "$act" diagnostics)" "also exists in runtime/deliveries/"
assert_eq "an out/ entry no record claims is still listed, and the ones settled records claim are not" "out/stray-entry" "$(python3 -I -c 'import json,sys;print(" ".join(d["path"] for d in json.load(open(sys.argv[1]))["deliveries"] if d["origin"]=="legacy_out"))' "$act")"
rm -f "$GHD/$DONE/d-00900000.json"; rmdir "$GHD/out/stray-entry"

# The index decides what is trusted: a filed record it does not vouch for is parsed even
# under --active, so damage to it still shows and it is not counted as accepted.
printf '%s' '{"schema_version":1,"id":"d-00000001"' > "$GHD/$DONE/d-00000001.json"
gh status --json --active > "$act" 2>/dev/null || true
assert_contains "a damaged filed record shows under --active too" "$(jget "$act" diagnostics)" delivery_record_malformed
assert_eq "...status is then not consistent" false "$(jget "$act" consistent)"
assert_eq "...and the record is not counted" "$((ACCEPTED_N - 1))" "$(jget "$act" settled.accepted)"

# With no index at all every filed record is parsed, as before; the answer is the same.
plain_consumer "$FAST"
make_filed 150
rm -f "$GHD/$DONE/index"
gh status --json > "$out" 2>/dev/null
gh status --json --active > "$act" 2>/dev/null
assert_eq "without done/index, --active lists the same active deliveries" "$(active_ids "$out")" "$(active_ids "$act")"
assert_eq "...counts the accepted ones" "$((150 - 15 + 1))" "$(jget "$act" settled.accepted)"
assert_eq "...and the missing ones" 15 "$(jget "$act" settled.missing)"
assert_eq "...consistent, no diagnostics" '[]' "$(jget "$act" diagnostics)"

# --- names that are not valid UTF-8 are not fired or imported (finding 9) ----------------
# The predicate itself, on every host: extract it from the script.
sed -n '/^json_str() {/,/^}/p;/^utf8_valid() {/,/^}/p' "$GH_SCRIPT" > "$T_TMP/utf8fn.sh"
utf8_probe() { # printf FORMAT of the name → valid|invalid
  "$TEST_BASH" -c '. "$1"; JSON_LOSSY=0; JSTR=""; v="$(printf "$2")"; if utf8_valid "$v"; then echo valid; else echo invalid; fi' _ "$T_TMP/utf8fn.sh" "$1"
}
assert_eq "utf8_valid: plain ASCII" valid "$(utf8_probe 'plain-name')"
assert_eq "utf8_valid: accented letters" valid "$(utf8_probe 'caf\303\251')"
assert_eq "utf8_valid: a three-byte character" valid "$(utf8_probe '\346\227\245\346\234\254')"
assert_eq "utf8_valid: a four-byte character" valid "$(utf8_probe '\360\237\231\202')"
assert_eq "utf8_valid: a lone high byte" invalid "$(utf8_probe 'bad\377name')"
assert_eq "utf8_valid: a truncated sequence" invalid "$(utf8_probe 'cut\343\201')"
assert_eq "utf8_valid: an overlong slash" invalid "$(utf8_probe 'x\300\257y')"
assert_eq "utf8_valid: a surrogate" invalid "$(utf8_probe 'x\355\240\200y')"
assert_eq "utf8_valid: past U+10FFFF" invalid "$(utf8_probe 'x\364\220\200\200y')"
assert_eq "utf8_valid leaves the lossy flag alone" "0" "$("$TEST_BASH" -c '. "$1"; JSON_LOSSY=0; JSTR=keep; utf8_valid "$(printf "a\377b")" || true; echo "$JSON_LOSSY"' _ "$T_TMP/utf8fn.sh")"

# The real thing, where the file system allows such names (Linux; APFS refuses them).
fresh_consumer "$FAST"
badout="$GHD/out/$(printf 'bad\377name')"
if mkdir "$badout" 2>/dev/null && [ -d "$badout" ]; then
  echo x > "$badout/f"
  badsched="$GHD/schedule/daily/$(printf 'bad\377item')"
  mkdir -p "$badsched"; echo y > "$badsched/f"
  status_to "$out"
  assert_contains "status reports the out/ entry instead of listing it" "$(jget "$out" diagnostics)" out_entry_name_not_utf8
  assert_eq "...it is not listed as a delivery" 0 "$(jq_py where "$out" deliveries origin '"legacy_out"' id | wc -l | tr -d ' ')"
  assert_contains "status reports the schedule item" "$(jget "$out" diagnostics)" schedule_name_not_utf8
  run_once 3.5
  assert_eq "the runner created no record for the out/ entry, cycle after cycle" 0 "$(live_count)"
  assert_eq "...and the consumer was not called for it" 0 "$(lines "$INST/calls.txt")"
  assert_true "...the entry is left in place" test -d "$badout"
  assert_contains "...and the runner says why" "$(cat "$RUN_ERR")" "not valid UTF-8"
  assert_false "the bad schedule item was not fired" test -e "$GHD/out/$(printf 'bad\377item')-$(today)"
  assert_true "...while the sound item still was" test -d "$GHD/out/$NAME"
else
  t_skip "this file system refuses names that are not valid UTF-8; only the predicate was tested"
fi

t_finish
