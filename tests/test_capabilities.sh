#!/usr/bin/env bash
# `capabilities --json` and the argument rules the two new commands share.
. "$(dirname "$0")/lib.sh"

new_instance
out="$T_TMP/caps.json"

rc=0; gh capabilities --json > "$out" 2> "$out.err" || rc=$?
assert_eq "capabilities exits 0" 0 "$rc"
assert_eq "capabilities writes nothing to stderr" "" "$(cat "$out.err")"
assert_json_valid "$out"
assert_eq "protocol" '"groundhog-runtime"' "$(jget "$out" protocol)"
assert_eq "protocol_version is the integer 1" '1' "$(jget "$out" protocol_version)"
assert_eq "implementation_version is a string" 'str' \
  "$(jq_py get "$out" implementation_version | cut -c1 | sed 's/"/str/')"
# Advertise only what exists: this stitch implements status-json-v1 and nothing else.
assert_eq "capabilities lists exactly status-json-v1" '["status-json-v1"]' "$(jget "$out" capabilities)"

# It needs no initialized instance and creates nothing.
assert_eq "an uninitialized instance stays untouched" "groundhog.sh" "$(ls -A "$GHD")"

# Caller cwd selects nothing.
rc=0; (cd "$T_TMP" && "$TEST_BASH" "$GHD/groundhog.sh" capabilities --json > "$out.cwd") || rc=$?
assert_eq "works from another cwd" 0 "$rc"
assert_eq "same output from another cwd" "$(cat "$out")" "$(cat "$out.cwd")"

# Invalid arguments exit 2 with a diagnostic on stderr and nothing on stdout.
for args in "" "--json --json" "--human" "--json extra" "extra --json" "-j"; do
  rc=0
  # shellcheck disable=SC2086
  gh capabilities $args > "$out.o" 2> "$out.e" || rc=$?
  assert_eq "capabilities $args exits 2" 2 "$rc"
  assert_eq "capabilities $args prints no stdout" "" "$(cat "$out.o")"
  assert_contains "capabilities $args explains on stderr" "$(cat "$out.e")" "error:"
  rc=0
  # shellcheck disable=SC2086
  gh status $args > "$out.o" 2> "$out.e" || rc=$?
  assert_eq "status $args exits 2" 2 "$rc"
  assert_eq "status $args prints no stdout" "" "$(cat "$out.o")"
done
assert_eq "bad arguments created nothing" "groundhog.sh" "$(ls -A "$GHD")"

# The script must live in a .groundhog directory; status reports that as exit 2.
mkdir -p "$T_TMP/elsewhere"
cp "$GH_SCRIPT" "$T_TMP/elsewhere/groundhog.sh"
rc=0; "$TEST_BASH" "$T_TMP/elsewhere/groundhog.sh" status --json > "$out.o" 2> "$out.e" || rc=$?
assert_eq "status outside a .groundhog directory exits 2" 2 "$rc"
assert_eq "...with no stdout" "" "$(cat "$out.o")"
rc=0; "$TEST_BASH" "$T_TMP/elsewhere/groundhog.sh" due > /dev/null 2>&1 || rc=$?
assert_eq "legacy commands there still exit 1" 1 "$rc"

t_finish
