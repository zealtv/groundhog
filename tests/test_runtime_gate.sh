#!/usr/bin/env bash
# A host with no usable lock helper and no way to start a session (neither
# util-linux flock(1) nor perl, and no setsid(1)): handlers-v1 is not
# advertised, a delivery with a run is fired but never started (and status
# says why), retry refuses, and every other command works without locking.
# The host is simulated with a PATH that holds the ordinary tools but no
# flock, perl or setsid. Last, where util-linux flock(1) and setsid(1) exist
# (Linux), the same PATH plus those two and still no perl: the fallback path
# that starts runs with setsid(1).
. "$(dirname "$0")/lib.sh"
export TZ=UTC

bash_bin="$(command -v "$TEST_BASH")"
bare="$T_TMP/bare-path"
mkdir -p "$bare"
for tool in date cat cp mv rm mkdir rmdir touch find grep sort basename dirname tr sed ls awk head wc od sleep ps sync chmod stat cksum sha256sum shasum openssl env; do
  src="$(command -v "$tool" 2>/dev/null)" || continue
  ln -s "$src" "$bare/$tool"
done
for banned in perl flock setsid; do
  [ ! -e "$bare/$banned" ] || { t_fail "$banned leaked into the bare PATH"; }
done

new_instance
bare_gh() { PATH="$bare" "$bash_bin" "$GHD/groundhog.sh" "$@"; }
out="$T_TMP/g.json"

bare_gh capabilities --json > "$out"
assert_eq "no lock helper: only the capabilities that need nothing of the host are advertised" '["status-json-v2","next-due-v1","add-from-v1","pause-v2"]' "$(jget "$out" capabilities)"

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
assert_json_valid "$out"

# An item with a run fires, and its run waits: the record says fired, never started.
bare_gh add daily job >/dev/null
printf '#!/bin/sh\ntouch "%s/RAN"\n' "$T_TMP" > "$GHD/schedule/daily/job/run"; chmod +x "$GHD/schedule/daily/job/run"
rc=0; bare_gh tick >"$out.o" 2>"$out.e" || rc=$?
assert_eq "tick with a run but no way to start it exits 0" 0 "$rc"
assert_contains "...fires the item" "$(cat "$out.o")" "fired job ->"
assert_contains "...and says on stderr why its run waits" "$(cat "$out.e")" "cannot start"
sleep 0.5
assert_false "...and nothing ran" test -e "$T_TMP/RAN"
bare_gh status --json > "$out"
name="job-$(date +%Y-%m-%d)"
assert_eq "status shows the delivery pending" '"pending"' "$(jq_py dget "$out" path "out/$name" state)"
assert_contains "...with handlers_unavailable" "$(jget "$out" diagnostics)" '"handlers_unavailable"'
rc=0; bare_gh retry "$name" >/dev/null 2>"$out.e" || rc=$?
assert_eq "retry without a lock helper exits 5" 5 "$rc"
assert_contains "...and explains what is missing" "$(cat "$out.e")" "flock"
# pause and resume need nothing of the host.
assert_eq "pause works" 0 "$(rc_of bare_gh pause)"
bare_gh status --json > "$out"
assert_eq "...and status shows it" true "$(jget "$out" paused)"
assert_eq "resume works" 0 "$(rc_of bare_gh resume)"

# --- flock(1) and setsid(1), no perl ------------------------------------------------
fl="$(command -v flock 2>/dev/null || true)"; ss="$(command -v setsid 2>/dev/null || true)"
if [ -n "$fl" ] && [ -n "$ss" ] && "$fl" --version 2>&1 | grep -q util-linux; then
  for tool in flock setsid pgrep; do src="$(command -v "$tool" 2>/dev/null)" && ln -sf "$src" "$bare/$tool"; done
  new_instance
  bare_gh init >/dev/null
  bare_gh add daily job >/dev/null
  cat > "$GHD/schedule/daily/job/run" <<'RUN'
#!/bin/sh
echo "$GROUNDHOG_ATTEMPT_ID" > "$1/attempt"
# SIGINT (2) ignored? Bit 1 of SigIgn.
ign="$(sed -n 's/^SigIgn:[[:space:]]*//p' /proc/$$/status)"
if [ $(( 0x$ign & 2 )) -ne 0 ]; then echo ignored > "$1/sigint"; else echo default > "$1/sigint"; fi
RUN
  chmod +x "$GHD/schedule/daily/job/run"
  bare_gh capabilities --json > "$out"
  assert_contains "flock(1) and setsid(1) without perl: handlers-v1" "$(jget "$out" capabilities)" '"handlers-v1"'
  bare_gh tick >/dev/null 2>&1
  name="job-$(date +%Y-%m-%d)"
  wait_for "the run started through setsid(1) finished" 50 sh -c "grep -q '^exit ' '$GHD/out/$name/.groundhog-record'"
  assert_eq "...it got its attempt id" "$(sed -n 's/^start \([^ ]*\) .*/\1/p' "$GHD/out/$name/.groundhog-record")" "$(cat "$GHD/out/$name/attempt" 2>/dev/null)"
  assert_eq "...and SIGINT's default handling" default "$(cat "$GHD/out/$name/sigint" 2>/dev/null)"
  bare_gh status --json > "$out"
  assert_eq "...status reads it accepted" '"accepted"' "$(jq_py dget "$out" path "out/$name" state)"
else
  t_skip "no util-linux flock(1) and setsid(1) here; the setsid(1) fallback runs on Linux"
fi

t_finish
