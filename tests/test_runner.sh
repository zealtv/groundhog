#!/usr/bin/env bash
# The foreground runner: exclusion, cycles, pause, stop, signals, crash and
# failure. Runners always use scratch instances, short intervals and bounded
# waits, and every runner is stopped or killed before the test ends (the
# harness fails the test if one is left behind).
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support; then
  t_skip "this host has no lock helper, hash tool or durable-write tool; the runner is not offered"
  t_finish
  exit $?
fi

out="$T_TMP/r.json"
rev() { status_to "$out"; jget "$out" revision; }
fresh_owned() { # sets TOK; one due item, owned, unpaused, nothing run
  new_instance
  gh init >/dev/null
  gh add daily nudge >/dev/null
  enroll_ok
}

# --- two runners cannot own one instance -------------------------------------
fresh_owned
tok_a="$TOK"
start_runner --token-file "$TOK" --interval-seconds 1
a_pid="$RUNNER_PID"
wait_for "the first runner reports running" 80 runner_is running
wait_for "the first cycle fired the due item" 50 out_is 1
rc=0; gh run --token-file "$TOK" --interval-seconds 1 >/dev/null 2>"$out.e" || rc=$?
assert_eq "a second run with the same token fails busy (4)" 4 "$rc"
assert_contains "...and says another runner holds the instance" "$(cat "$out.e")" "another runner"
rc=0; gh release --token-file "$TOK" >/dev/null 2>"$out.e" || rc=$?
assert_eq "release while a runner is live fails busy (4)" 4 "$rc"
new_token_path
rc=0; gh enroll --owner-label rival --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "a rival cannot enroll an owned instance (3)" 3 "$rc"
rc=0; gh tick >/dev/null 2>&1 || rc=$?
assert_eq "a standalone tick is refused while the runner owns it (3)" 3 "$rc"
status_to "$out"
assert_eq "status shows one live runner" '"running"' "$(jget "$out" runner.state)"
assert_eq "...with no liveness diagnostics" "[]" "$(jget "$out" diagnostics)"
assert_false "...and wrote no token for the rival" test -e "$TOK"

# The secret and verifier stay out of the runner's argv, status and stderr.
secret="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$tok_a")"
verifier="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["owner"]["token_verifier"])' "$GHD/runtime/state.json")"
argv="$(ps -ww -o command= -p "$a_pid" 2>/dev/null || true)"
assert_contains "ps shows the runner (so the next checks mean something)" "$argv" "run"
assert_not_contains "the secret is not in the runner's argv" "$argv" "$secret"
assert_not_contains "the verifier is not in the runner's argv" "$argv" "${verifier#sha256:}"
assert_not_contains "the secret is not in the runner's stderr" "$(cat "$RUN_ERR")" "$secret"
assert_not_contains "status shows neither secret nor verifier" "$(cat "$out")" "$secret"
assert_not_contains "status shows no verifier" "$(cat "$out")" "${verifier#sha256:}"
TOK="$tok_a"

# stop: bounded, clean, ownership and pause retained.
gh pause --token-file "$TOK" >/dev/null 2>&1
before_pause="$(jget "$out" paused)"
t0=$SECONDS
rc=0; gh stop --token-file "$TOK" >/dev/null 2>"$out.e" || rc=$?
assert_eq "stop exits 0" 0 "$rc"
assert_true "stop returned within a few seconds" test "$((SECONDS - t0))" -le 5
wait_exit "the stopped runner exited" 50 "$a_pid"
assert_eq "the runner exits 0 after a stop" 0 "$WAIT_RC"
status_to "$out"
assert_eq "after stop: runner stopped" '"stopped"' "$(jget "$out" runner.state)"
assert_eq "after stop: ownership retained" 1 "$(jget "$out" owner.generation)"
assert_eq "after stop: pause untouched" true "$(jget "$out" paused)"
assert_true "the runner lock is free after stop" lock_is_free "$GHD/runtime/locks/runner.lock"

# stop with no live runner is idempotent and writes nothing the second time.
r1="$(rev)"
rc=0; gh stop --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "stop with no runner exits 0" 0 "$rc"
rc=0; gh stop --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "...and again" 0 "$rc"
assert_eq "an idle stop does not advance the revision" "$r1" "$(rev)"

# --- pause persists across restart; a paused run ticks nothing ----------------
rm -rf "$GHD/out"/* "$GHD/fired"/*
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "restarted runner reports running" 80 runner_is running
sleep 2.5
assert_eq "a paused run ticks nothing across several cycles" 0 "$(out_count)"
assert_contains "...and says it is paused" "$(cat "$RUN_ERR")" "paused"
status_to "$out"
assert_eq "run did not clear the pause" true "$(jget "$out" paused)"
gh resume --token-file "$TOK" >/dev/null 2>&1
wait_for "after resume the next cycle fires" 60 out_is 1
r_before="$(rev)"
gh pause --token-file "$TOK" >/dev/null 2>&1
rm -rf "$GHD/out"/* "$GHD/fired"/*
sleep 2.2
assert_eq "after pause the runner admits nothing" 0 "$(out_count)"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
assert_true "revision advanced with each protocol write" test "$(rev)" -gt "$r_before"

# --- release needs a stopped runner, keeps pause ------------------------------
rc=0; gh release --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "release after stop exits 0" 0 "$rc"
status_to "$out"
assert_eq "...owner gone" null "$(jget "$out" owner)"
assert_eq "...pause retained" true "$(jget "$out" paused)"
assert_true "...locks free" lock_is_free "$GHD/runtime/locks/runner.lock"

# --- no secret reaches a child's argv or environment --------------------------
# Shims on PATH log the argv and environment of every tool the script starts
# (hashing, perl, date, sleep, ...) through enroll, run and control commands.
fresh_owned_shimmed() {
  new_instance
  gh init >/dev/null
  gh add daily nudge >/dev/null
  rm -f "$T_TMP/argv.log" "$T_TMP/env.log"
  mkdir -p "$T_TMP/spy"
  local n real
  for n in date shasum sha256sum openssl perl od tr sleep cp mv mkdir touch; do
    real="$(command -v "$n" 2>/dev/null)" || continue
    case "$real" in "$T_TMP/spy"/*) continue ;; esac
    cat > "$T_TMP/spy/$n" <<SPY
#!/bin/sh
printf '%s\\n' "$n \$*" >> "$T_TMP/argv.log"
env >> "$T_TMP/env.log"
exec "$real" "\$@"
SPY
    chmod +x "$T_TMP/spy/$n"
  done
}
fresh_owned_shimmed
new_token_path
PATH="$T_TMP/spy:$PATH" gh enroll --owner-label spy --token-file "$TOK" >/dev/null 2>&1
secret="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$TOK")"
verifier="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["owner"]["token_verifier"])' "$GHD/runtime/state.json")"
PATH="$T_TMP/spy:$PATH" start_runner --token-file "$TOK" --interval-seconds 1
wait_for "shimmed runner running" 80 runner_is running
wait_for "shimmed runner fired" 60 out_is 1
PATH="$T_TMP/spy:$PATH" gh pause --token-file "$TOK" >/dev/null 2>&1
PATH="$T_TMP/spy:$PATH" gh resume --token-file "$TOK" >/dev/null 2>&1
PATH="$T_TMP/spy:$PATH" gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "shimmed runner exited" 50 "$RUNNER_PID"
assert_true "the spies saw the script's children" test -s "$T_TMP/argv.log"
assert_contains "the spies saw sleep slices from the runner" "$(cat "$T_TMP/argv.log")" "sleep 1"
assert_contains "the environment log is real" "$(cat "$T_TMP/env.log")" "PATH="
assert_not_contains "the secret never appears in a child's argv" "$(cat "$T_TMP/argv.log")" "$secret"
assert_not_contains "the secret never appears in a child's environment" "$(cat "$T_TMP/env.log")" "$secret"
assert_not_contains "the verifier never appears in a child's argv" "$(cat "$T_TMP/argv.log")" "${verifier#sha256:}"
assert_not_contains "the verifier never appears in a child's environment" "$(cat "$T_TMP/env.log")" "${verifier#sha256:}"
assert_not_contains "the token path never appears in a child's environment" "$(cat "$T_TMP/env.log")" "$TOK"

# --- a crash keeps ownership and pause, and frees the lock --------------------
fresh_owned
gh pause --token-file "$TOK" >/dev/null 2>&1
start_runner --token-file "$TOK" --interval-seconds 60
c_pid="$RUNNER_PID"
wait_for "runner running" 80 runner_is running
sleep 1.2   # long enough for the runner to be inside its sleep slice
assert_false "while the runner lives, its lock is held" lock_is_free "$GHD/runtime/locks/runner.lock"
kill -9 "$c_pid"
wait "$c_pid" 2>/dev/null || true
assert_true "kill -9 frees the runner lock at once (no child kept it alive)" lock_is_free "$GHD/runtime/locks/runner.lock"
assert_true "...and the mutation lock" lock_is_free "$GHD/runtime/locks/mutation.lock"
status_to "$out"
assert_eq "after a crash the owner is retained" 1 "$(jget "$out" owner.generation)"
assert_eq "after a crash the pause is retained" true "$(jget "$out" paused)"
assert_eq "after a crash the runner is shown as unknown, not running" '"unknown"' "$(jget "$out" runner.state)"
assert_contains "...with a diagnostic" "$(jget "$out" diagnostics)" runner_not_observed
assert_eq "...and the state is still consistent" true "$(jget "$out" consistent)"
# The same token restarts it; run does not clear the pause.
start_runner --token-file "$TOK" --interval-seconds 60
wait_for "a new run after a crash works with the token" 80 runner_is running
status_to "$out"
assert_eq "same owner generation after the restart" 1 "$(jget "$out" owner.generation)"
assert_eq "pause still set after the restart" true "$(jget "$out" paused)"
assert_eq "the new runner has no diagnostics" "[]" "$(jget "$out" diagnostics)"
# stop reconciles nothing odd and exits the new runner.
rc=0; gh stop --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "stop of the restarted runner exits 0" 0 "$rc"
wait_exit "restarted runner exited" 50 "$RUNNER_PID"

# A crash with no new run: stop settles the stale record.
fresh_owned
start_runner --token-file "$TOK" --interval-seconds 60
wait_for "runner running" 80 runner_is running
kill -9 "$RUNNER_PID"; wait "$RUNNER_PID" 2>/dev/null || true
rc=0; gh stop --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "stop after a crash exits 0" 0 "$rc"
status_to "$out"
assert_eq "...and records the runner as stopped" '"stopped"' "$(jget "$out" runner.state)"
assert_eq "...diagnostics clear" "[]" "$(jget "$out" diagnostics)"
rc=0; gh release --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "release after a crash and stop exits 0" 0 "$rc"

# --- signals: clean exit, ownership and pause retained ------------------------
for sig in TERM INT HUP; do
  fresh_owned
  gh pause --token-file "$TOK" >/dev/null 2>&1
  start_runner --token-file "$TOK" --interval-seconds 60
  wait_for "runner running ($sig)" 80 runner_is running
  sleep 0.3
  t0=$SECONDS
  kill -"$sig" "$RUNNER_PID"
  wait_exit "SIG$sig ended the runner promptly" 40 "$RUNNER_PID"
  assert_eq "SIG$sig: the runner exits 0" 0 "$WAIT_RC"
  assert_true "SIG$sig did not wait out the interval" test "$((SECONDS - t0))" -le 4
  status_to "$out"
  assert_eq "SIG$sig: runner stopped" '"stopped"' "$(jget "$out" runner.state)"
  assert_eq "SIG$sig: ownership retained" 1 "$(jget "$out" owner.generation)"
  assert_eq "SIG$sig: pause retained" true "$(jget "$out" paused)"
  assert_true "SIG$sig: locks free" lock_is_free "$GHD/runtime/locks/runner.lock"
  assert_contains "SIG$sig: said so on stderr" "$(cat "$RUN_ERR")" "stopping"
done

# --- startup validation fails visibly without ticking -------------------------
fresh_owned
printf '{"schema_version":1,"consumer":{"argv":["relative"],"cwd":".."}}' > "$GHD/runtime/config.json"
rc=0; gh run --token-file "$TOK" --interval-seconds 1 >"$out.o" 2>"$out.e" || rc=$?
assert_eq "run with an invalid config exits 2" 2 "$rc"
assert_contains "...and names the problem" "$(cat "$out.e")" "config.json"
assert_eq "...ticked nothing" 0 "$(out_count)"
assert_true "...left the runner lock free" lock_is_free "$GHD/runtime/locks/runner.lock"
status_to "$out"
assert_eq "...and did not mark a runner running" '"stopped"' "$(jget "$out" runner.state)"

# --- a failing tick is a visible runner failure; ownership and pause stay -----
fresh_owned
mkdir -p "$T_TMP/failcp"
printf '#!/bin/sh\necho "shim: cp failed" >&2\nexit 1\n' > "$T_TMP/failcp/cp"
chmod +x "$T_TMP/failcp/cp"
set -m
PATH="$T_TMP/failcp:$PATH" "$TEST_BASH" "$GHD/groundhog.sh" run --token-file "$TOK" --interval-seconds 1 >"$out.o" 2>"$out.e" &
RUNNER_PID=$!
set +m
T_PIDS="$T_PIDS $RUNNER_PID"
wait_exit "the runner gave up after the failed tick" 50 "$RUNNER_PID"
assert_eq "a tick failure ends the runner with exit 6" 6 "$WAIT_RC"
status_to "$out"
assert_eq "runner state is failed" '"failed"' "$(jget "$out" runner.state)"
assert_eq "last_error is structured" '"tick_failed"' "$(jget "$out" runner.last_error.code)"
assert_eq "ownership retained" 1 "$(jget "$out" owner.generation)"
assert_true "the lock is free" lock_is_free "$GHD/runtime/locks/runner.lock"
rc=0; gh stop --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "stop after a failure exits 0" 0 "$rc"
status_to "$out"
assert_eq "stop keeps the failure visible" '"failed"' "$(jget "$out" runner.state)"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "a fresh run clears the failure" 80 runner_is running
status_to "$out"
assert_eq "last_error cleared" null "$(jget "$out" runner.last_error)"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# --- a stale stop request does not stop a later runner ------------------------
fresh_owned
gh pause --token-file "$TOK" >/dev/null 2>&1
start_runner --token-file "$TOK" --interval-seconds 60
wait_for "runner running" 80 runner_is running
kill -9 "$RUNNER_PID"; wait "$RUNNER_PID" 2>/dev/null || true
python3 -I - "$GHD/runtime/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["runner"]["stop_requested_for"] = d["runner"]["id"]   # a request left by a dead runner's era
json.dump(d, open(p, "w"), separators=(",", ":"))
open(p, "a").write("\n")
PY
start_runner --token-file "$TOK" --interval-seconds 60
wait_for "a new runner starts despite the old request" 80 runner_is running
sleep 1.5
assert_true "...and keeps running" kill -0 "$RUNNER_PID"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

t_finish
