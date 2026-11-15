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
assert_eq "uninitialized: consistent" "true" "$(jget "$T_TMP/ro.status" consistent)"

# 2. A busy instance: every axis, paused subtrees, fired markers, out/ entries,
# runtime state, a configured consumer and delivery records.
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
cat > "$GHD/runtime/deliveries/d-1.json" <<'JSON'
{"schema_version":1,"id":"d-1","path":"out/entry-a","state":"pending","reason":"no_consumer"}
JSON
printf '{ truncated' > "$GHD/runtime/deliveries/d-bad.json"
age_tree "$INST"
hash_around "busy instance" "$INST"
assert_true "busy: the probe actually reached the delivery records" \
  test "$(jq_py find "$T_TMP/ro.status" deliveries id d-1)" != "<missing>"

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
age_tree "$INST"
hash_around "payload guard" "$INST"
assert_false "no payload was executed" test -e "$T_TMP/EXECUTED"
assert_false "no payload was evaluated" test -e "$T_TMP/EVALUATED"
assert_not_contains "no payload text reached the output" "$(cat "$T_TMP/ro.status")" "secret payload text"
assert_eq "the item with unreadable payload files is still listed" '"schedule/daily/guarded"' \
  "$(jget "$T_TMP/ro.status" schedule.0.path)"
chmod -R u+rwx "$payload" "$GHD/out/delivered-payload"

# 4. A malformed runtime tree is reported, never repaired or overwritten.
new_instance
mkdir -p "$GHD/runtime/deliveries"
printf 'not json at all' > "$GHD/runtime/state.json"
printf '[1,2' > "$GHD/runtime/config.json"
printf '{"schema_version":1,"id":"wrong-name"}' > "$GHD/runtime/deliveries/d-9.json"
age_tree "$INST"
hash_around "malformed runtime files" "$INST"

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
