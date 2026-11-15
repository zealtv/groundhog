#!/usr/bin/env bash
# The journal generation: every write to the delivery journal moves
# runtime/journal.gen, status (which takes no lock) reads it before and after its
# pass and reports consistent:false when it moved or is odd, and `revision`
# alone is not a change token for the journal. Writers that cannot be timed from
# outside are held with a perl shim (it blocks the fsync of one path) or run from
# the date shim's one-shot hook (a write part-way through a status pass).
. "$(dirname "$0")/lib.sh"
export TZ=UTC

if ! have_runtime_support || ! have_isolation; then
  t_skip "this host has no lock helper, hash tool, durable-write tool or process-isolation helper; the consumer is not offered"
  t_finish
  exit $?
fi

out="$T_TMP/c.json"
FAST='echo x >> "$PWD/calls.txt"'

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
put_prepared() { # ID OUT_NAME MARKER SCHED
  mkdir -p "$GHD/runtime/prepared"
  python3 -I - "$GHD/runtime/prepared/$1.json" "$1" "$2" "$3" "$4" <<'PY'
import datetime, json, sys
path, did, name, marker, sched = sys.argv[1:6]
rec = {"schema_version": 1, "id": did, "out_path": "out/" + name, "fired_marker": marker,
       "schedule_path": sched, "occurrence": {"date": datetime.date.today().isoformat(), "slot": None},
       "once": False, "source_generation": "", "created_at": "2026-11-15T00:00:00Z"}
with open(path, "w") as f:
    json.dump(rec, f, separators=(",", ":"))
    f.write("\n")
PY
}
run_once() { # run for a moment, then stop (the first cycle runs immediately)
  start_runner --token-file "$TOK" --interval-seconds 1
  wait_for "the runner is up" 80 runner_is running
  sleep "${1:-1.2}"
  gh stop --token-file "$TOK" >/dev/null 2>&1
  wait_exit "the runner exited" 50 "$RUNNER_PID"
}
jgen() { status_to "$out" || true; jget "$out" journal_generation; }
gen_file() { cat "$GHD/runtime/journal.gen" 2>/dev/null || echo absent; }
is_even() { [ $(( $1 % 2 )) -eq 0 ]; }
# moved DESC BEFORE — the generation is above BEFORE and even again.
moved() {
  local now
  now="$(jgen)"
  if [ "$now" -gt "$2" ] 2>/dev/null && is_even "$now"; then t_ok; else t_fail "$1" "journal_generation was $2, now $now"; fi
}
unmoved() { # DESC BEFORE
  local now
  now="$(jgen)"
  assert_eq "$1" "$2" "$now"
}

# --- status exposes the generation and stays read-only -----------------------------
new_instance; gh init >/dev/null
status_to "$out"
assert_eq "an instance without a journal reports generation 0" 0 "$(jget "$out" journal_generation)"
assert_eq "...consistent" true "$(jget "$out" consistent)"
assert_false "...and status created no journal.gen" test -e "$GHD/runtime/journal.gen"

# --- retry and recover move the generation, not the revision -------------------------
# They change a delivery's state without a state.json write, so `revision` alone
# cannot tell a client the journal changed.
fresh_consumer "$FAST"
mkdir -p "$GHD/out/p-fail" "$GHD/out/p-unc"
put_record d-fail p-fail failed failed
put_record d-unc p-unc uncertain unknown
status_to "$out"
rev0="$(jget "$out" revision)"; g0="$(jget "$out" journal_generation)"
assert_eq "hand-written records: generation 0, consistent" true "$(jget "$out" consistent)"
gh retry --token-file "$TOK" --delivery d-fail >/dev/null 2>&1
status_to "$out"
assert_eq "retry: the delivery is pending" '"pending"' "$(jq_py dget "$out" id d-fail state)"
assert_eq "retry: the revision did not move (state.json untouched)" "$rev0" "$(jget "$out" revision)"
moved "retry: the journal generation moved, and is even again" "$g0"
g1="$(jget "$out" journal_generation)"
gh recover --token-file "$TOK" --delivery d-unc --decision accept >/dev/null 2>&1
status_to "$out"
assert_eq "recover: the delivery is accepted" '"accepted"' "$(jq_py dget "$out" id d-unc state)"
assert_eq "recover: the revision did not move" "$rev0" "$(jget "$out" revision)"
moved "recover: the journal generation moved" "$g1"
assert_eq "...and status is consistent throughout" true "$(jget "$out" consistent)"
# a command that only reads, and one that refuses, leave it alone
g2="$(jget "$out" journal_generation)"
gh retry --token-file "$TOK" --delivery d-unc >/dev/null 2>&1 || true
unmoved "a refused retry does not move the generation" "$g2"

# --- each runner write site moves it ------------------------------------------------
# One scenario per site, built so that site is the only journal write the runner
# makes in the pass (starting and stopping the runner writes state.json, not the
# journal).
# (1) import of a legacy out/ entry
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/out/legacy-one"; echo x > "$GHD/out/legacy-one/f"
g="$(jgen)"; run_once
moved "import: the generation moved" "$g"

# (2) a firing: prepared record, out/ entry, marker, delivery record
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"
g="$(jgen)"; run_once
status_to "$out"
assert_eq "firing: a delivery was recorded" 1 "$(jq_py where "$out" deliveries path "\"out/$NAME\"" id | wc -l | tr -d ' ')"
moved "firing: the generation moved" "$g"

# (3) reconciliation completes a prepared firing (the out/ entry exists, no record)
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/out/$NAME" "$GHD/fired/$(today)/daily"; echo x > "$GHD/out/$NAME/f"; touch "$GHD/fired/$(today)/daily/nudge"
put_prepared d-prep "$NAME" "fired/$(today)/daily/nudge" schedule/daily/nudge
g="$(jgen)"; run_once
moved "completing a prepared firing: the generation moved" "$g"
assert_false "...and the prepared record is gone" test -e "$GHD/runtime/prepared/d-prep.json"

# (4) reconciliation discards an unfinished firing (prepared record, staging copy)
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/runtime/staging/d-half/x"
put_prepared d-half "$NAME" "fired/$(today)/daily/nudge" schedule/daily/nudge
g="$(jgen)"; run_once
moved "discarding an unfinished firing: the generation moved" "$g"

# (4b) a prepared record with no staging copy, no out/ entry and no marker is dropped
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"; rm -rf "$GHD/schedule/daily/nudge"
put_prepared d-nothing "$NAME" "fired/$(today)/daily/nudge" schedule/daily/nudge
g="$(jgen)"; run_once
assert_false "(4b) the prepared record is gone" test -e "$GHD/runtime/prepared/d-nothing.json"
moved "dropping a prepared record that left nothing behind: the generation moved" "$g"

# (5) a prepared record set aside as blocked
fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/runtime/prepared"; printf 'not json' > "$GHD/runtime/prepared/d-garbage.json"
g="$(jgen)"; run_once
moved "blocking a prepared record: the generation moved" "$g"
assert_true "...it was set aside" test -e "$GHD/runtime/prepared/d-garbage.blocked"

# (6) a pending delivery whose path vanished is recorded missing
fresh_consumer "$FAST"; rm -rf "$GHD/schedule/daily/nudge"
put_record d-vanish gone-away pending
g="$(jgen)"; gh pause --token-file "$TOK" >/dev/null 2>&1; run_once
moved "marking a vanished path missing: the generation moved" "$g"
assert_eq "...it is missing" '"missing"' "$(jq_py dget "$out" id d-vanish state)"

# (7) admission and the recorded result of a consumer call
fresh_consumer "$FAST"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/out/handoff-one"; echo x > "$GHD/out/handoff-one/f"
put_record d-hand handoff-one pending
g="$(jgen)"; run_once 2
assert_eq "handoff: the consumer ran once" 1 "$(lines "$INST/calls.txt")"
status_to "$out"
assert_eq "...and the delivery is accepted" '"accepted"' "$(jq_py dget "$out" id d-hand state)"
moved "admission and result: the generation moved" "$g"
g_after_handoff="$(jgen)"
[ "$g_after_handoff" -ge $(( g + 4 )) ] && t_ok || t_fail "admit and record are separate writes" "from $g to $g_after_handoff"

# (8) filing a settled terminal record under done/ is the only write
fresh_consumer "$FAST"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/out/settled-one"; echo x > "$GHD/out/settled-one/f"
put_record d-settled settled-one accepted accepted
g="$(jgen)"; run_once
assert_true "filing: the record moved under done/" test -f "$GHD/runtime/deliveries/done/d-settled.json"
assert_false "...out of the live directory" test -e "$GHD/runtime/deliveries/d-settled.json"
moved "filing under done/: the generation moved" "$g"

# (9) sweep removes a settled record
gh release --token-file "$TOK" >/dev/null 2>&1       # sweep refuses an owned instance
g="$(jgen)"
age_tree "$GHD/out"; age_tree "$GHD/runtime/deliveries"
gh sweep 0 >/dev/null 2>&1
assert_false "sweep: the filed record was removed" test -e "$GHD/runtime/deliveries/done/d-settled.json"
moved "sweep removing a record: the generation moved" "$g"

# (9b) sweep removes the records of paths that are already gone, one write each
new_instance; gh init >/dev/null
put_record d-gone p-gone missing
put_record d-oldacc p-oldacc accepted accepted
g="$(jgen)"
age_tree "$GHD/runtime"
gh sweep 0 >/dev/null 2>&1
assert_false "sweep: the missing record was removed" test -e "$GHD/runtime/deliveries/d-gone.json"
assert_false "sweep: the accepted record of a removed path was removed" test -e "$GHD/runtime/deliveries/d-oldacc.json"
moved "sweep removing two records: the generation moved" "$g"
[ "$(jgen)" -ge $(( g + 4 )) ] && t_ok || t_fail "each removal is its own write" "from $g to $(jgen)"

# (10) the standalone tick attaches an out_collision to an existing record
new_instance; gh init >/dev/null
gh add daily nudge >/dev/null; echo hi > "$GHD/schedule/daily/nudge/note.txt"
NAME="nudge-$(today)"
mkdir -p "$GHD/out/$NAME"; echo theirs > "$GHD/out/$NAME/theirs.txt"
put_record d-own "$NAME" pending
mkdir -p "$GHD/runtime/locks"
g="$(jgen)"
gh tick >/dev/null 2>&1
status_to "$out"
assert_contains "standalone tick: the collision was attached to the record" "$(jget "$out" diagnostics)" out_collision
moved "standalone tick noting a collision: the generation moved" "$g"

# The index under done/ is a cache of what a record says; rewriting it changes
# nothing status shows, so it does not move the generation.
fresh_consumer "$FAST"; rm -rf "$GHD/schedule/daily/nudge"; rm -f "$GHD/runtime/config.json"
mkdir -p "$GHD/out/idx-one"; echo x > "$GHD/out/idx-one/f"
put_record d-idx idx-one accepted accepted
run_once
g="$(jgen)"
rm -f "$GHD/runtime/deliveries/done/index"
run_once
unmoved "rebuilding done/index leaves the generation alone" "$g"

# --- an unfinished or unreadable generation is reported ------------------------------
fresh_consumer "$FAST"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/runtime"
printf '%018d\n' 7 > "$GHD/runtime/journal.gen"
status_to "$out"
assert_eq "an odd generation: consistent is false" false "$(jget "$out" consistent)"
assert_contains "...with journal_write_in_progress" "$(jget "$out" diagnostics)" journal_write_in_progress
assert_eq "...reporting the number as read" 7 "$(jget "$out" journal_generation)"
gh sweep 14 >/dev/null 2>&1        # takes the mutation lock: nobody is writing, so it settles
assert_eq "the next command that takes the lock settles it" "$(printf '%018d' 8)" "$(gen_file)"
status_to "$out"
assert_eq "...and status is consistent again" true "$(jget "$out" consistent)"
printf 'garbage' > "$GHD/runtime/journal.gen"
status_to "$out"
assert_eq "an unreadable generation: consistent is false" false "$(jget "$out" consistent)"
assert_contains "...with journal_generation_unreadable" "$(jget "$out" diagnostics)" journal_generation_unreadable
assert_eq "...and generation 0" 0 "$(jget "$out" journal_generation)"
mkdir -p "$GHD/out/after-garbage"; echo x > "$GHD/out/after-garbage/f"
put_record d-ag after-garbage failed failed
gh retry --token-file "$TOK" --delivery d-ag >/dev/null 2>&1
assert_eq "a journal write replaces it with a number" "$(printf '%018d' 2)" "$(gen_file)"
status_to "$out"
assert_eq "...consistent again" true "$(jget "$out" consistent)"

# --- a prepared firing's out/ entry is not an unregistered delivery -------------------
fresh_consumer "$FAST"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/out/$NAME" "$GHD/out/stray-entry"; echo x > "$GHD/out/$NAME/f"; echo x > "$GHD/out/stray-entry/f"
status_to "$out"
assert_eq "without a prepared record the entry shows as legacy_out/unregistered" '"unregistered"' "$(jq_py dget "$out" path "out/$NAME" reason)"
put_prepared d-claim "$NAME" "fired/$(today)/daily/nudge" schedule/daily/nudge
status_to "$out"
assert_eq "a prepared record claims its out path: not listed as unregistered" '<missing>' "$(jq_py dget "$out" path "out/$NAME" reason)"
assert_eq "...an unrelated entry still is" '"unregistered"' "$(jq_py dget "$out" path out/stray-entry reason)"
assert_eq "...and status is consistent" true "$(jget "$out" consistent)"

# --- a writer held part-way through a write: status never shows a coherent view ----------
if ! command -v perl >/dev/null 2>&1 || ! perl -MIO::Handle -e 'exit 0' >/dev/null 2>&1; then
  t_skip "the held-writer cases need perl for fsync, to put a shim in front of"
else
  REAL_PERL="$(command -v perl)"
  PSHIM="$T_TMP/pshim"; HOLD="$T_TMP/hold"; REACHED="$T_TMP/reached"; HOLD_GLOB=""
  mkdir -p "$PSHIM"
  cat > "$PSHIM/perl" <<SHIM
#!/bin/sh
# Test shim: blocks the fsync of one path (HOLD_GLOB, read from the hold file)
# until the hold file is removed, then does what perl always does.
case "\$*" in
  *IO::Handle*)
    if [ -f "$HOLD" ]; then
      for last; do :; done
      read -r glob < "$HOLD"
      case "\$last" in
        \$glob) : > "$REACHED"; while [ -f "$HOLD" ]; do sleep 0.05; done ;;
      esac
    fi
    ;;
esac
exec "$REAL_PERL" "\$@"
SHIM
  chmod +x "$PSHIM/perl"

  held_writer() { # DESC GLOB — a retry blocked at the fsync of GLOB
    local desc="$1" glob="$2" before
    fresh_consumer "$FAST"; rm -rf "$GHD/schedule/daily/nudge"
    mkdir -p "$GHD/out/p-held"; echo x > "$GHD/out/p-held/f"
    put_record d-held p-held failed failed
    before="$(jgen)"
    rm -f "$REACHED"
    printf '%s\n' "${glob//@GHD@/$GHD}" > "$HOLD"
    PATH="$PSHIM:$PATH" gh retry --token-file "$TOK" --delivery d-held >/dev/null 2>&1 &
    HELD_PID=$!
    T_PIDS="$T_PIDS $HELD_PID"
    wait_for "$desc: the writer reached the hold" 100 test -e "$REACHED"
    status_to "$out"
    assert_eq "$desc: status reports consistent:false" false "$(jget "$out" consistent)"
    assert_contains "$desc: ...naming the unfinished write" "$(jget "$out" diagnostics)" journal_write_in_progress
    rm -f "$HOLD"
    wait_exit "$desc: the writer finished" 100 "$HELD_PID"
    status_to "$out"
    assert_eq "$desc: afterwards the view is coherent" true "$(jget "$out" consistent)"
    assert_eq "$desc: ...and shows the finished write" '"pending"' "$(jq_py dget "$out" id d-held state)"
    moved "$desc: ...under a new generation" "$before"
  }
  # Before the record is replaced: the temp file is being made durable.
  held_writer "writer before the record is replaced" "@GHD@/runtime/deliveries/.d-held.json.*.tmp"
  # After the record is replaced, before the generation is closed: the directory sync.
  held_writer "writer after the record is replaced" "@GHD@/runtime/deliveries"
  firing_done() { ! ls "$GHD"/runtime/prepared/*.json >/dev/null 2>&1; }
  # A firing: the out/ entry exists before the delivery record does (the finding
  # behind this file). Hold the runner at the sync of out/ itself.
  fresh_consumer "$FAST"; rm -f "$GHD/runtime/config.json"
  rm -f "$REACHED"
  printf '%s\n' "$GHD/out" > "$HOLD"
  PATH="$PSHIM:$PATH" start_runner --token-file "$TOK" --interval-seconds 1
  wait_for "the firing reached the hold" 100 test -e "$REACHED"
  status_to "$out"
  assert_true "mid-firing: the out/ entry exists" test -d "$GHD/out/$NAME"
  assert_eq "mid-firing: status reports consistent:false" false "$(jget "$out" consistent)"
  assert_contains "mid-firing: ...naming the unfinished write" "$(jget "$out" diagnostics)" journal_write_in_progress
  assert_eq "mid-firing: the entry is not shown as an unregistered delivery" '<missing>' "$(jq_py dget "$out" path "out/$NAME" reason)"
  rm -f "$HOLD"
  wait_for "the firing finished" 100 firing_done
  gh stop --token-file "$TOK" >/dev/null 2>&1
  wait_exit "the runner exited" 50 "$RUNNER_PID"
  status_to "$out"
  assert_eq "after the firing: coherent" true "$(jget "$out" consistent)"
  assert_eq "...one delivery for the entry" 1 "$(jq_py where "$out" deliveries path "\"out/$NAME\"" id | wc -l | tr -d ' ')"
  assert_eq "...and it is a runtime delivery" '"runtime"' "$(jq_py dget "$out" path "out/$NAME" origin)"
fi


# --- a write that lands during a status pass is caught by the second read ------------------
# The date shim's one-shot hook runs a retry after status has read the first
# generation and before it reads the second.
set_clock "2026-11-15 12:00:00"
fresh_consumer "$FAST"; rm -rf "$GHD/schedule/daily/nudge"
mkdir -p "$GHD/out/p-race"; echo x > "$GHD/out/p-race/f"
put_record d-race p-race failed failed
before="$(jgen)"
cat > "$T_SHIM/hook" <<HOOK
"$TEST_BASH" "$GHD/groundhog.sh" retry --token-file "$TOK" --delivery d-race >/dev/null 2>&1
HOOK
status_to "$out"
assert_false "the hook ran (it was consumed)" test -e "$T_SHIM/hook"
assert_eq "a write during the pass: consistent is false" false "$(jget "$out" consistent)"
assert_contains "...with journal_changed_during_read" "$(jget "$out" diagnostics)" journal_changed_during_read
assert_eq "...the generation reported is the one the pass began with" "$before" "$(jget "$out" journal_generation)"
status_to "$out"
assert_eq "a refresh is coherent" true "$(jget "$out" consistent)"
assert_eq "...shows the new state" '"pending"' "$(jq_py dget "$out" id d-race state)"
moved "...under a later generation" "$before"

t_finish
