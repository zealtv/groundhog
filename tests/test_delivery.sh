#!/usr/bin/env bash
# Handoff durability: a crash between in_flight and the recorded result, the
# instance-wide barrier, recover, stop waiting for the admitted call, detaching on signals, pause, and a
# slow consumer. Consumers are plain /bin/sh scripts; the ones that sleep are
# killed (by pid or process group) before each test ends.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support || ! have_isolation; then
  t_skip "this host has no lock helper, hash tool, durable-write tool or process-isolation helper; the consumer is not offered"
  t_finish
  exit $?
fi

out="$T_TMP/d.json"
# A consumer that records its pid, process group and inherited lock fds, counts
# the call, and then sleeps (exec, so its pid is the sleeper's).
SLEEPER='echo $$ > "$PWD/c.pid"
ps -o pgid= -p $$ | tr -d " " > "$PWD/c.pgid"
echo "fd8=$([ -e /dev/fd/8 ] && echo open || echo closed) fd9=$([ -e /dev/fd/9 ] && echo open || echo closed)" > "$PWD/c.fds"
echo x >> "$PWD/calls.txt"
exec sleep 30'
add_item() { mkdir -p "$GHD/schedule/daily/$1"; echo "note-$1" > "$GHD/schedule/daily/$1/note.txt"; }
track_consumer() { T_GROUPS="$T_GROUPS $(cat "$INST/c.pid")"; }
kill_consumer() { if pid_alive "$INST/c.pid"; then kill -9 "$(cat "$INST/c.pid")" 2>/dev/null || true; fi; sleep 0.3; }
attempts_of() { dget path "out/$1" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))'; }
state_of_id() { dget id "$1" state; }
id_state_is() { [ "$(state_of_id "$1")" = "\"$2\"" ]; }

# --- a crash between in_flight and the result ---------------------------------
fresh_consumer "$SLEEPER"
add_item other
other_name="other-$(today)"
runner_pgid=""
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the consumer started" 100 file_has "$INST/calls.txt"
track_consumer
runner_pgid="$(ps -o pgid= -p "$RUNNER_PID" | tr -d ' ')"
assert_eq "the consumer is the leader of its own process group" "$(cat "$INST/c.pid")" "$(cat "$INST/c.pgid")"
assert_true "...which is not the runner's group" test "$(cat "$INST/c.pgid")" != "$runner_pgid"
assert_eq "...and inherited neither lock fd" "fd8=closed fd9=closed" "$(cat "$INST/c.fds")"
t0=$SECONDS
status_to "$out"
assert_true "status does not wait for a running consumer" test "$((SECONDS - t0))" -le 2
assert_eq "exactly one delivery is in flight" 1 "$(jq_py where "$out" deliveries state '"in_flight"' id | wc -l | tr -d ' ')"
inflight_id="$(jq_py where "$out" deliveries state '"in_flight"' id)"
pending_id="$(jq_py where "$out" deliveries state '"pending"' id)"
assert_true "...and the other is pending (serial: one consumer call at a time)" test -n "$pending_id"
assert_eq "an attempt in flight with a live runner reads in_flight" '"in_flight"' "$(dget id "$inflight_id" attempts.0.outcome)"
assert_eq "the pending delivery has no attempt" "[]" "$(dget id "$pending_id" attempts)"
assert_true "no second consumer starts while one is in flight" test "$(lines "$INST/calls.txt")" -eq 1
# The runner's cycles go on ticking while the barrier holds.
add_item third
kill -9 "$RUNNER_PID"; wait "$RUNNER_PID" 2>/dev/null || true
assert_true "kill -9 of the runner leaves the consumer running" pid_alive "$INST/c.pid"
assert_true "...the runner lock is free (the consumer inherited no lock)" lock_is_free "$GHD/runtime/locks/runner.lock"
assert_true "...and the mutation lock" lock_is_free "$GHD/runtime/locks/mutation.lock"
assert_eq "...the delivery reads in_flight on disk" '"in_flight"' "$(state_of_id "$inflight_id" | tr -d '\n')"
assert_eq "...with outcome unknown (a read never repairs)" '"unknown"' "$(dget id "$inflight_id" attempts.0.outcome)"
assert_eq "...and status did not turn it into uncertain" '"in_flight"' "$(state_of_id "$inflight_id")"
# The next explicit run reconciles it to uncertain, without replay.
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "next run reconciles the abandoned attempt to uncertain" 100 id_state_is "$inflight_id" uncertain
assert_eq "...attempt outcome unknown" '"unknown"' "$(dget id "$inflight_id" attempts.0.outcome)"
assert_eq "...with a structured error" '"result_not_recorded"' "$(dget id "$inflight_id" attempts.0.error.code)"
assert_eq "...never replayed" 1 "$(lines "$INST/calls.txt")"
wait_for "ticks still materialize new deliveries while the barrier holds" 100 state_is "third-$(today)" pending
sleep 2.2
assert_eq "the barrier blocks every other delivery" '"pending"' "$(state_of_id "$pending_id")"
assert_eq "...nothing new was invoked" 1 "$(lines "$INST/calls.txt")"
assert_contains "...and the runner says why" "$(cat "$RUN_ERR")" "blocked"
rc=0; gh recover --token-file "$TOK" --delivery "$inflight_id" --decision accept >/dev/null 2>&1 || rc=$?
assert_eq "recover with a live runner fails busy (4)" 4 "$rc"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
assert_eq "...and left the delivery uncertain" '"uncertain"' "$(state_of_id "$inflight_id")"
# A new configuration does not bypass the unresolved invocation.
consumer_script consumer2.sh 'echo y >> "$PWD/calls2.txt"'
write_config /bin/sh "$CONS"
start_runner --token-file "$TOK" --interval-seconds 1
sleep 3
assert_eq "a changed configuration cannot bypass the barrier" 0 "$(lines "$INST/calls2.txt")"
assert_eq "...the delivery results were not reset" '"uncertain"' "$(state_of_id "$inflight_id")"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
# release and the operator commands refuse.
rc=0; gh release --token-file "$TOK" >/dev/null 2>"$out.e" || rc=$?
assert_eq "release refuses while an attempt is unresolved (5)" 5 "$rc"
assert_contains "...and says ownership is retained" "$(cat "$out.e")" "retained"
status_to "$out"
assert_eq "...owner still there" 1 "$(jget "$out" owner.generation)"
rc=0; gh retry --token-file "$TOK" --delivery "$inflight_id" >/dev/null 2>"$out.e" || rc=$?
assert_eq "retry of an uncertain delivery exits 5 (use recover)" 5 "$rc"
assert_contains "...and points at recover" "$(cat "$out.e")" "recover"
rc=0; gh recover --token-file "$TOK" --delivery "$inflight_id" >/dev/null 2>&1 || rc=$?
assert_eq "recover without --decision exits 2" 2 "$rc"
rc=0; gh recover --token-file "$TOK" --delivery "$inflight_id" --decision maybe >/dev/null 2>&1 || rc=$?
assert_eq "recover with an unknown decision exits 2" 2 "$rc"
rc=0; gh recover --token-file "$TOK" --delivery "$pending_id" --decision accept >/dev/null 2>&1 || rc=$?
assert_eq "recover of a delivery that is not unresolved exits 5" 5 "$rc"
assert_eq "...and left it pending" '"pending"' "$(state_of_id "$pending_id")"
tok_real="$TOK"; new_token_path
rc=0; gh recover --token-file "$TOK" --delivery "$inflight_id" --decision accept >/dev/null 2>&1 || rc=$?
assert_eq "recover with a missing token file exits 2" 2 "$rc"
TOK="$tok_real"
# The operator establishes that the original invocation finished, then decides.
kill_consumer
assert_false "(the original consumer call has finished)" pid_alive "$INST/c.pid"
rc=0; gh recover --token-file "$TOK" --delivery "$inflight_id" --decision accept >/dev/null 2>"$out.e" || rc=$?
assert_eq "recover --decision accept exits 0" 0 "$rc"
assert_eq "...the delivery is accepted" '"accepted"' "$(state_of_id "$inflight_id")"
assert_eq "...with the decision recorded on the attempt" '"accept"' "$(dget id "$inflight_id" attempts.0.decision)"
assert_eq "...and when" 'str' "$(dget id "$inflight_id" attempts.0.decided_at | cut -c1 | sed 's/"/str/')"
assert_eq "...the attempt outcome is still what was observed (unknown)" '"unknown"' "$(dget id "$inflight_id" attempts.0.outcome)"
assert_eq "...no consumer was invoked by recovery" 0 "$(lines "$INST/calls2.txt")"
assert_true "...the payload stays" test -d "$GHD/out/nudge-$(today)" -o -d "$GHD/out/$other_name"
# With the barrier lifted the next run admits the others, one at a time.
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "after recovery the pending deliveries are handed off" 150 lines_eq "$INST/calls2.txt" 2
wait_for "...and accepted" 100 id_state_is "$pending_id" accepted
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
rc=0; gh release --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "release succeeds once nothing is unresolved" 0 "$rc"

# --- recover with decision retry ----------------------------------------------
fresh_consumer "$SLEEPER"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the consumer started" 100 file_has "$INST/calls.txt"
track_consumer
kill -9 "$RUNNER_PID"; wait "$RUNNER_PID" 2>/dev/null || true
rid="$(did "$NAME")"
# recover reconciles an abandoned in-flight attempt itself.
kill_consumer
consumer_script consumer.sh 'echo again >> "$PWD/calls.txt"'
rc=0; gh recover --token-file "$TOK" --delivery "$rid" --decision retry >/dev/null 2>"$out.e" || rc=$?
assert_eq "recover --decision retry on an abandoned in-flight attempt exits 0" 0 "$rc"
assert_eq "...the delivery is pending again" '"pending"' "$(dstate "$NAME")"
assert_eq "...the attempt keeps the decision" '"retry"' "$(dget id "$rid" attempts.0.decision)"
assert_eq "...and its unknown outcome" '"unknown"' "$(dget id "$rid" attempts.0.outcome)"
assert_eq "...no consumer was invoked by recovery" 1 "$(lines "$INST/calls.txt")"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the next run creates a new attempt" 100 state_is "$NAME" accepted
assert_eq "...same delivery id" "$rid" "$(did "$NAME")"
assert_eq "...two attempts" 2 "$(attempts_of "$NAME")"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# --- stop waits for the admitted call, records its result, then the runner exits
# Admission closes at the stop request (the second delivery stays pending), the
# call already admitted finishes and records, and only then does stop return.
fresh_consumer 'echo x >> "$PWD/calls.txt"; sleep 4; echo done > "$PWD/finished.txt"'
add_item other
other_name="other-$(today)"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the consumer started" 100 file_has "$INST/calls.txt"
t0=$SECONDS
rc=0; gh stop --token-file "$TOK" >"$out.o" 2>"$out.e" || rc=$?
assert_eq "stop exits 0 after waiting for the consumer" 0 "$rc"
assert_true "...it waited for the call (it does not detach)" test "$((SECONDS - t0))" -ge 2
assert_true "...the consumer had finished when stop returned" test -f "$INST/finished.txt"
assert_eq "...stdout still says only stopped" "stopped" "$(cat "$out.o")"
assert_contains "...stop said it was waiting on a delivery" "$(cat "$out.e")" "waiting on a delivery"
assert_contains "...and that SIGTERM on the runner detaches now" "$(cat "$out.e")" "SIGTERM"
wait_exit "the runner exited" 50 "$RUNNER_PID"
assert_eq "...exit 0" 0 "$WAIT_RC"
assert_contains "...the runner said it kept waiting" "$(cat "$RUN_ERR")" "waiting for the consumer"
status_to "$out"
assert_eq "the admitted delivery is accepted, recorded before the runner exited" 1 "$(jq_py where "$out" deliveries state '"accepted"' id | wc -l | tr -d ' ')"
assert_eq "...the other stays pending: admission closed at the request" 1 "$(jq_py where "$out" deliveries state '"pending"' id | wc -l | tr -d ' ')"
assert_eq "...no second call was made" 1 "$(lines "$INST/calls.txt")"
assert_eq "...runner stopped" '"stopped"' "$(jget "$out" runner.state)"
assert_true "...runner lock free" lock_is_free "$GHD/runtime/locks/runner.lock"
assert_true "...mutation lock free" lock_is_free "$GHD/runtime/locks/mutation.lock"
rc=0; gh release --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "release can follow: nothing is unresolved" 0 "$rc"

# A call that fails is recorded failed, the same way.
fresh_consumer 'echo x >> "$PWD/calls.txt"; sleep 3; exit 7'
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the consumer started" 100 file_has "$INST/calls.txt"
rc=0; gh stop --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "stop exits 0 after a failing consumer" 0 "$rc"
wait_exit "the runner exited" 50 "$RUNNER_PID"
assert_eq "...exit 0" 0 "$WAIT_RC"
assert_eq "the delivery is failed, with the exit status" '"failed"' "$(dstate "$NAME")"
assert_eq "...attempt exit 7" 7 "$(dget path "out/$NAME" attempts.0.exit_code)"

# With nothing in flight, stop is prompt and says nothing about waiting.
fresh_consumer 'echo x >> "$PWD/calls.txt"'
start_runner --token-file "$TOK" --interval-seconds 30
wait_for "the call was accepted" 100 state_is "$NAME" accepted
t0=$SECONDS
rc=0; gh stop --token-file "$TOK" >"$out.o" 2>"$out.e" || rc=$?
assert_eq "stop with nothing in flight exits 0" 0 "$rc"
assert_true "...promptly" test "$((SECONDS - t0))" -le 3
assert_eq "...silent on stderr" "" "$(cat "$out.e")"
wait_exit "the runner exited" 50 "$RUNNER_PID"

# A signal still detaches at once, also while stop is waiting: the delivery is
# uncertain and the consumer keeps running.
fresh_consumer "$SLEEPER"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the consumer started" 100 file_has "$INST/calls.txt"
track_consumer
gh stop --token-file "$TOK" >"$out.o" 2>"$out.e" &
stop_pid=$!
wait_for "stop says it is waiting on a delivery" 100 grep -q "waiting on a delivery" "$out.e"
assert_true "stop is still waiting (the consumer runs for 30 s)" kill -0 "$stop_pid"
assert_true "...the consumer is running" pid_alive "$INST/c.pid"
kill -TERM "$RUNNER_PID"
wait_exit "SIGTERM detached the runner at once" 50 "$RUNNER_PID"
assert_eq "...exit 0" 0 "$WAIT_RC"
wait_exit "...and stop returned" 50 "$stop_pid"
assert_eq "...exit 0" 0 "$WAIT_RC"
assert_true "the detached consumer is still running" pid_alive "$INST/c.pid"
assert_eq "the delivery is uncertain, not accepted" '"uncertain"' "$(dstate "$NAME")"
assert_eq "...with the detach recorded" '"consumer_detached"' "$(dget path "out/$NAME" attempts.0.error.code)"
assert_eq "...outcome unknown" '"unknown"' "$(dget path "out/$NAME" attempts.0.outcome)"
assert_true "...runner lock free" lock_is_free "$GHD/runtime/locks/runner.lock"
assert_true "...mutation lock free" lock_is_free "$GHD/runtime/locks/mutation.lock"
status_to "$out"
assert_eq "...runner stopped" '"stopped"' "$(jget "$out" runner.state)"
rc=0; gh release --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "the detach did not resolve it: release still refuses" 5 "$rc"
kill_consumer

# --- SIGINT and SIGTERM: detach, the consumer survives, its group is separate --
for sig in INT TERM; do
  fresh_consumer "$SLEEPER"
  start_runner --token-file "$TOK" --interval-seconds 1
  wait_for "the consumer started ($sig)" 100 file_has "$INST/calls.txt"
  track_consumer
  if [ "$sig" = INT ]; then
    # What Ctrl-C does: SIGINT to the runner's whole (foreground) process group.
    kill -INT -- "-$RUNNER_PID"
  else
    kill -TERM "$RUNNER_PID"
  fi
  wait_exit "SIG$sig ended the runner" 50 "$RUNNER_PID"
  assert_eq "SIG$sig: the runner exits 0" 0 "$WAIT_RC"
  assert_true "SIG$sig: the consumer survived" pid_alive "$INST/c.pid"
  assert_eq "SIG$sig: it leads its own group, apart from the runner's" "$(cat "$INST/c.pid")" "$(cat "$INST/c.pgid")"
  assert_eq "SIG$sig: the delivery is uncertain" '"uncertain"' "$(dstate "$NAME")"
  assert_true "SIG$sig: locks free" lock_is_free "$GHD/runtime/locks/runner.lock"
  assert_contains "SIG$sig: the runner said it detached" "$(cat "$RUN_ERR")" "detaching"
  kill_consumer
done

# --- pause ----------------------------------------------------------------------
# A paused runner hands off nothing, pending stays pending; resume releases it.
fresh_consumer 'echo x >> "$PWD/calls.txt"'
mkdir -p "$GHD/out/waiting"                 # a delivery that predates the pause (legacy, imported by run)
gh pause --token-file "$TOK" >/dev/null 2>&1
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the paused runner registered the delivery" 100 registered waiting
sleep 2.5
assert_eq "paused: pending stays pending" '"pending"' "$(dstate waiting)"
assert_eq "paused: the consumer was not invoked" 0 "$(lines "$INST/calls.txt")"
assert_eq "paused: nothing new was fired" 1 "$(out_count)"
gh resume --token-file "$TOK" >/dev/null 2>&1
wait_for "after resume the pending delivery is handed off" 100 state_is waiting accepted
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# A call admitted before the pause finishes and records; nothing new is admitted.
fresh_consumer 'echo start >> "$PWD/calls.txt"; sleep 2; echo end >> "$PWD/calls.txt"'
add_item other
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the first consumer started" 100 file_has "$INST/calls.txt"
t0=$SECONDS
rc=0; gh pause --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "pause during a running consumer exits 0" 0 "$rc"
assert_true "...without waiting for it" test "$((SECONDS - t0))" -le 2
any_accepted() { [ "$(dget state accepted id)" != "<missing>" ]; }
wait_for "the admitted call finished and recorded" 100 any_accepted
sleep 2.5
assert_eq "no second call was admitted under the pause" "start end" "$(tr '\n' ' ' < "$INST/calls.txt" | sed 's/ $//')"
status_to "$out"
assert_eq "one delivery accepted" 1 "$(jq_py where "$out" deliveries state '"accepted"' id | wc -l | tr -d ' ')"
assert_eq "...one still pending" 1 "$(jq_py where "$out" deliveries state '"pending"' id | wc -l | tr -d ' ')"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# --- a slow consumer delays only its own instance; cycles never overlap ---------
fresh_consumer 'echo start >> "$PWD/log.txt"; sleep 3; echo end >> "$PWD/log.txt"'
add_item second
slow_inst="$INST"; slow_ghd="$GHD"; slow_tok="$TOK"
start_runner --token-file "$TOK" --interval-seconds 1
slow_pid="$RUNNER_PID"
fresh_consumer 'echo fast >> "$PWD/log.txt"'
fast_inst="$INST"; fast_ghd="$GHD"; fast_tok="$TOK"
start_runner --token-file "$TOK" --interval-seconds 1
fast_pid="$RUNNER_PID"
wait_for "the fast instance is accepted while the slow one is busy" 80 state_is "$NAME" accepted
INST="$slow_inst"; GHD="$slow_ghd"; TOK="$slow_tok"
assert_eq "...the slow consumer is still running" "start" "$(tr '\n' ' ' < "$INST/log.txt" | sed 's/ $//')"
t0=$SECONDS
status_to "$out"
assert_true "status of the busy instance is prompt" test "$((SECONDS - t0))" -le 2
sleep 1
assert_eq "cycles do not overlap: still one call in flight" "start" "$(tr '\n' ' ' < "$INST/log.txt" | sed 's/ $//')"
wait_for "the slow instance finishes both deliveries one after the other" 150 lines_eq "$INST/log.txt" 4
assert_eq "...strictly serialized" "start end start end" "$(tr '\n' ' ' < "$INST/log.txt" | sed 's/ $//')"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "slow runner exited" 50 "$slow_pid"
INST="$fast_inst"; GHD="$fast_ghd"; TOK="$fast_tok"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "fast runner exited" 50 "$fast_pid"

t_finish
