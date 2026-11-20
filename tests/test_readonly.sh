#!/usr/bin/env bash
# `capabilities` and `status` must change nothing: no directories, locks, markers,
# repairs, or reads of payload contents. Proved by hashing the tree around them.
. "$(dirname "$0")/lib.sh"
export TZ=UTC
set_clock "2026-11-15 12:00:00"

hash_around() { # DESC DIR — run both commands, hash before and after
  local desc="$1" dir="$2" before after
  before="$(tree_hash "$dir")"
  gh capabilities --json > "$T_TMP/ro.caps" 2>&1
  status_to "$T_TMP/ro.status"
  gh status --json > "$T_TMP/ro.status2" 2>&1
  after="$(tree_hash "$dir")"
  assert_eq "$desc: tree unchanged" "$before" "$after"
  assert_json_valid "$T_TMP/ro.status"
}

# 1. An uninitialized instance: only the script exists.
new_instance
age_tree "$INST"
hash_around "uninitialized instance" "$INST"
assert_eq "uninitialized: no directories appeared" "groundhog.sh" "$(ls -A "$GHD")"
assert_eq "uninitialized: schedule is empty" "[]" "$(jget "$T_TMP/ro.status" schedule)"
assert_eq "uninitialized: no deliveries" "[]" "$(jget "$T_TMP/ro.status" deliveries)"
assert_eq "uninitialized: no diagnostics" "[]" "$(jget "$T_TMP/ro.status" diagnostics)"

# 2. A busy instance: every axis, paused subtrees, fired markers, out/ entries,
# protocol 1's runtime files, and deliveries in every state, one of them with
# its record's lock held (status tests that lock without keeping it).
new_instance
gh init >/dev/null
for w in daily daily/09 weekly weekly/sun once every/15m yearly/11-15 monthly/15; do gh add "$w" probe >/dev/null; done
mkdir -p "$GHD/schedule/weekly.paused/mon/held" "$GHD/schedule/daily/stray name"
mkdir -p "$GHD/out/entry-a" "$GHD/out/entry-b.landing" "$GHD/runtime/deliveries" "$GHD/runtime/locks"
: > "$GHD/runtime/locks/mutation.lock"
gh tick >/dev/null 2>&1
cat > "$GHD/runtime/state.json" <<'JSON'
{"schema_version":1,"revision":4,"paused":false,"owner":null,"runner":{"state":"stopped","last_error":null},"config_digest":null}
JSON
cat > "$GHD/runtime/config.json" <<'JSON'
{"schema_version":1,"consumer":{"argv":["/bin/sh","/example/consume.sh"],"cwd":"..","env":{}}}
JSON
printf '{ truncated' > "$GHD/runtime/deliveries/d-bad.json"
f='fired d-1 2026-11-15T11:00:00Z run 2026-11-15 - schedule/daily/x'
for s in pending running accepted interrupted; do mkdir -p "$GHD/out/$s"; printf '%s\n' "$f" > "$GHD/out/$s/.groundhog-record"; done
printf 'start a-1 2026-11-15T11:00:01Z tick\n' | tee -a "$GHD/out/running/.groundhog-record" "$GHD/out/interrupted/.groundhog-record" >> "$GHD/out/accepted/.groundhog-record"
printf 'exit a-1 2026-11-15T11:00:02Z 0\n' >> "$GHD/out/accepted/.groundhog-record"
age_tree "$INST"
if have_lock_helper; then hold_lock "$GHD/out/running/.groundhog-record" 30; fi
hash_around "busy instance" "$INST"
for s in pending accepted interrupted; do
  assert_eq "busy: status read the $s record" "\"$s\"" "$(jq_py dget "$T_TMP/ro.status" path "out/$s" state)"
done
if have_lock_helper; then
  assert_eq "busy: a held record lock reads running" '"running"' "$(jq_py dget "$T_TMP/ro.status" path out/running state)"
  assert_true "...and status let the lock go again (the holder still has it)" lock_is_held "$GHD/out/running/.groundhog-record"
  kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
fi

# 3. Payload contents are never read or evaluated. Every payload file below
# would leave evidence if it were executed, sourced or opened.
new_instance
gh init >/dev/null
gh add daily guarded >/dev/null
payload="$GHD/schedule/daily/guarded"
printf '#!/bin/sh\ntouch "%s/EXECUTED"\n' "$T_TMP" > "$payload/run.sh"
chmod +x "$payload/run.sh"
printf '$(touch "%s/EVALUATED")\n`touch "%s/EVALUATED"`\n' "$T_TMP" "$T_TMP" > "$payload/prompt.md"
mkdir -p "$payload/sealed"
printf 'secret payload text\n' > "$payload/sealed/inner.txt"
printf 'secret payload text\n' > "$payload/unreadable.txt"
chmod 000 "$payload/unreadable.txt" "$payload/sealed"
mkdir -p "$GHD/out/delivered-payload"
printf 'secret payload text\n' > "$GHD/out/delivered-payload/data.txt"
chmod 000 "$GHD/out/delivered-payload/data.txt"
# A delivery whose run is pending: status reports it and never starts it.
printf '#!/bin/sh\ntouch "%s/EXECUTED"\n' "$T_TMP" > "$GHD/out/delivered-payload/run"
chmod +x "$GHD/out/delivered-payload/run"
printf 'fired d-2 2026-11-15T11:00:00Z run 2026-11-15 - schedule/daily/guarded\n' > "$GHD/out/delivered-payload/.groundhog-record"
age_tree "$INST"
hash_around "payload guard" "$INST"
assert_false "no payload was executed" test -e "$T_TMP/EXECUTED"
assert_false "no payload was evaluated" test -e "$T_TMP/EVALUATED"
assert_not_contains "no payload text reached the output" "$(cat "$T_TMP/ro.status")" "secret payload text"
assert_eq "the item with unreadable payload files is still listed" '"schedule/daily/guarded"' \
  "$(jget "$T_TMP/ro.status" schedule.0.path)"
assert_eq "the delivery with a run reads pending" '"pending"' "$(jq_py dget "$T_TMP/ro.status" path out/delivered-payload state)"
chmod -R u+rwx "$payload" "$GHD/out/delivered-payload"

# 4. Malformed files are reported, never repaired or overwritten.
new_instance
mkdir -p "$GHD/runtime/deliveries" "$GHD/out/odd" "$GHD/out/empty"
printf 'not json at all' > "$GHD/runtime/state.json"
printf '[1,2' > "$GHD/runtime/config.json"
printf 'start a-1 2026-11-15T11:00:01Z tick\n' > "$GHD/out/odd/.groundhog-record"
: > "$GHD/out/empty/.groundhog-record"
age_tree "$INST"
hash_around "malformed files" "$INST"
assert_eq "a record without a fired line reads unrecorded" '"unrecorded"' "$(jq_py dget "$T_TMP/ro.status" path out/odd state)"
assert_contains "...with a record_malformed diagnostic" "$(jget "$T_TMP/ro.status" diagnostics)" '"record_malformed"'
assert_contains "an ignored config.json is flagged" "$(jget "$T_TMP/ro.status" diagnostics)" '"config_ignored"'
assert_contains "an ignored state.json is flagged" "$(jget "$T_TMP/ro.status" diagnostics)" '"state_ignored"' 

# 5. Read-only also holds when the instance directory itself cannot be written.
new_instance
gh init >/dev/null
gh add daily quiet >/dev/null
age_tree "$INST"
chmod -R a-w "$INST"
rc=0; status_to "$T_TMP/ro.locked" || rc=$?
assert_eq "status works in a read-only tree" 0 "$rc"
assert_json_valid "$T_TMP/ro.locked"
rc=0; gh capabilities --json >/dev/null 2>&1 || rc=$?
assert_eq "capabilities works in a read-only tree" 0 "$rc"
chmod -R u+rwx "$INST"

clear_clock
t_finish
