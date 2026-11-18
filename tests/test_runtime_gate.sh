#!/usr/bin/env bash
# A host with no usable lock helper (neither util-linux flock(1) nor perl with
# Fcntl): the three runtime capabilities are not advertised, the new mutating
# commands refuse with a clear error, and every legacy command keeps working
# without touching runtime/. The host is simulated with a PATH that holds the
# ordinary tools but no flock and no perl.
. "$(dirname "$0")/lib.sh"
export TZ=UTC

bash_bin="$(command -v "$TEST_BASH")"
bare="$T_TMP/bare-path"
mkdir -p "$bare"
for tool in date cat cp mv rm mkdir rmdir touch find grep sort basename dirname tr sed ls awk head wc od sleep ps sync chmod stat cksum sha256sum shasum openssl env; do
  src="$(command -v "$tool" 2>/dev/null)" || continue
  ln -s "$src" "$bare/$tool"
done
for banned in perl flock; do
  [ ! -e "$bare/$banned" ] || { t_fail "$banned leaked into the bare PATH"; }
done

new_instance
bare_gh() { PATH="$bare" "$bash_bin" "$GHD/groundhog.sh" "$@"; }
out="$T_TMP/g.json"

bare_gh capabilities --json > "$out"
assert_eq "no lock helper: only the capabilities that need nothing of the host are advertised" '["status-json-v1","status-active-v1","next-due-v1","add-while-owned-v1"]' "$(jget "$out" capabilities)"

new_token_path
for c in "enroll --owner-label x --token-file $TOK" "run --token-file $TOK" "pause --token-file $TOK" \
         "resume --token-file $TOK" "stop --token-file $TOK" "release --token-file $TOK" \
         "discard --token-file $TOK --delivery d-x"; do
  rc=0; bare_gh $c >/dev/null 2>"$out.e" || rc=$?
  assert_eq "'${c%% *}' without a lock helper exits 5" 5 "$rc"
  assert_contains "'${c%% *}' explains what is missing" "$(cat "$out.e")" "flock"
done
assert_false "nothing was created for the refused commands" test -e "$GHD/runtime"
assert_false "no token file was written" test -e "$TOK"

# Argument errors still win over the host check, as for every command.
rc=0; bare_gh enroll --bogus >/dev/null 2>&1 || rc=$?
assert_eq "bad arguments still exit 2" 2 "$rc"

# Legacy commands work as before and create no runtime state.
bare_gh init >/dev/null
bare_gh add daily nudge >/dev/null
rc=0; bare_gh tick >"$out.o" 2>&1 || rc=$?
assert_eq "tick works without a lock helper" 0 "$rc"
assert_contains "...and fires" "$(cat "$out.o")" "fired nudge ->"
rc=0; bare_gh sweep 0 >/dev/null 2>&1 || rc=$?
assert_eq "sweep works" 0 "$rc"
rc=0; bare_gh drop nudge >/dev/null 2>&1 || rc=$?
assert_eq "drop works" 0 "$rc"
# add and add --from need nothing of the host: no lock helper, no od, no staging beyond cp and mv.
mkdir -p "$T_TMP/prep/sub"; echo go > "$T_TMP/prep/prompt.md"; echo x > "$T_TMP/prep/sub/n.txt"
rc=0; bare_gh add once/2030-01-01 fromdir --from "$T_TMP/prep" >"$out.o" 2>"$out.e" || rc=$?
assert_eq "add --from works without a lock helper" 0 "$rc"
assert_true "...and lands the whole directory" diff -r "$T_TMP/prep" "$GHD/schedule/once/2030-01-01/fromdir"
assert_eq "...leaving nothing staged" 0 "$(find "$GHD/runtime/staging" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "...and add --from of a missing directory still exits 2" 2 "$(rc=0; bare_gh add daily nope --from "$T_TMP/none" >/dev/null 2>&1 || rc=$?; echo $rc)"
bare_gh drop fromdir >/dev/null 2>&1
rmdir "$GHD/runtime/staging" "$GHD/runtime" 2>/dev/null
assert_false "legacy use created no runtime directory" test -e "$GHD/runtime"
bare_gh status --json > "$out"
assert_eq "status works" true "$(jget "$out" consistent)"

t_finish
