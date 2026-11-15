#!/usr/bin/env bash
# The runner's output streams: a supervisor that closes the pipe it gave `run`
# must cost the runner its log lines, not its life or its consumer's. Also: a
# consumer survives its supervisor's exit when the output is a regular file.
# Consumers are /bin/sh scripts that finish by themselves.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support || ! have_isolation; then
  t_skip "this host has no lock helper, hash tool, durable-write tool or process-isolation helper; the runner is not offered"
  t_finish
  exit $?
fi

out="$T_TMP/s.json"
# Sleeps, writes nothing to the streams, records that it ran and how it saw SIGPIPE.
CONSUMER='sleep 3
echo done > "$PWD/c.done"'
# Sends itself SIGPIPE: with the default disposition it dies; an ignored one survives.
SIGCHECK='kill -PIPE $$
echo survived > "$PWD/c.survived"'
runner_pid_of() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["runner"]["pid"])' "$GHD/runtime/state.json"; }
has_done() { [ -s "$INST/c.done" ]; }
delivery_accepted() { status_to "$out"; [ "$(jq_py where "$out" deliveries state '"accepted"' id | wc -l | tr -d ' ')" = 1 ]; }
lost_recorded() { status_to "$out"; [ "$(jget "$out" runner.last_error.code)" = '"output_lost"' ]; }
in_flight() { status_to "$out"; [ "$(jq_py where "$out" deliveries state '"in_flight"' id | wc -l | tr -d ' ')" = 1 ]; }

# --- the supervisor closes the pipe while a consumer runs ----------------------
fresh_consumer "$CONSUMER"
set -m
( "$TEST_BASH" "$GHD/groundhog.sh" run --token-file "$TOK" --interval-seconds 1 2>&1 >/dev/null | { read -r _first; } ) &
SUP_PID=$!
set +m
T_PIDS="$T_PIDS $SUP_PID"
wait_for "the runner is up" 80 runner_is running
RP="$(runner_pid_of)"
T_PIDS="$T_PIDS $RP"
wait_for "the consumer is in flight" 80 in_flight
assert_true "...the runner is alive after its output stream closed" kill -0 "$RP"
wait_for "the consumer finished its work" 100 has_done
wait_for "the runner recorded the consumer's result (accepted)" 100 delivery_accepted
assert_true "...the runner is still alive" kill -0 "$RP"
wait_for "the runner recorded output_lost" 50 lost_recorded
status_to "$out"
assert_eq "...while its state stays running" '"running"' "$(jget "$out" runner.state)"
assert_eq "...the delivery's attempt records exit code 0" "0" "$(dget path "out/$NAME" attempts.0.exit_code)"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner stops cleanly on request (not a signal death)" 80 "$RP"
status_to "$out"
assert_eq "...state stopped" '"stopped"' "$(jget "$out" runner.state)"
assert_eq "...and the output_lost error stays recorded" '"output_lost"' "$(jget "$out" runner.last_error.code)"

# --- the consumer gets the default SIGPIPE disposition ------------------------
fresh_consumer "$SIGCHECK"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "the consumer died of its own SIGPIPE (recorded failed)" 100 state_is "$NAME" failed
assert_false "the consumer did not survive SIGPIPE (it is not ignored)" test -e "$INST/c.survived"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner stops" 80 "$RUNNER_PID"

# --- only stdout closed: the `fired` line is best-effort too ---------------------
fresh_consumer "$CONSUMER"
set -m
( "$TEST_BASH" "$GHD/groundhog.sh" run --token-file "$TOK" --interval-seconds 1 2>/dev/null | { :; } ) &
set +m
wait_for "the runner is up" 80 runner_is running
RP="$(runner_pid_of)"
T_PIDS="$T_PIDS $RP"
wait_for "the consumer finished its work" 100 has_done
wait_for "the runner recorded the result (accepted)" 100 delivery_accepted
assert_true "the runner is still alive" kill -0 "$RP"
wait_for "the runner recorded output_lost" 50 lost_recorded
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner stops" 80 "$RP"

# --- output to a regular file: the consumer outlives its supervisor ---------------
fresh_consumer "$CONSUMER"
LOG="$T_TMP/sup.log"
( set -m; "$TEST_BASH" "$GHD/groundhog.sh" run --token-file "$TOK" --interval-seconds 1 >"$LOG" 2>&1 &
  echo $! > "$T_TMP/sup.pid" )
wait_for "the runner is up" 80 runner_is running
RP="$(runner_pid_of)"
T_PIDS="$T_PIDS $RP"
wait_for "the consumer is in flight" 80 in_flight
assert_true "the supervising shell has already exited" test -s "$T_TMP/sup.pid"
wait_for "the consumer finished its work" 100 has_done
wait_for "the runner recorded the result (accepted)" 100 delivery_accepted
status_to "$out"
assert_eq "no output_lost: the file outlived the supervisor" "null" "$(jget "$out" runner.last_error)"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner stops" 80 "$RP"
assert_contains "the log file holds the runner's lines" "$(cat "$LOG")" "started"

# --- install.sh replaces the script by rename --------------------------------------
host="$T_TMP/host"; mkdir -p "$host"
"$TEST_BASH" "$T_REPO_DIR/install.sh" "$host" >/dev/null 2>&1
ino1="$(ls -i "$host/.groundhog/groundhog.sh" | awk '{print $1}')"
"$TEST_BASH" "$T_REPO_DIR/install.sh" "$host" >/dev/null 2>&1
ino2="$(ls -i "$host/.groundhog/groundhog.sh" | awk '{print $1}')"
assert_true "a second install gives the script a new inode (a live process keeps the old file)" test "$ino1" != "$ino2"
assert_true "...the installed script is executable" test -x "$host/.groundhog/groundhog.sh"
assert_eq "...and matches the source" "" "$(cmp "$T_REPO_DIR/.groundhog/groundhog.sh" "$host/.groundhog/groundhog.sh" 2>&1)"
assert_eq "...leaving no temp file behind" "" "$(ls -A "$host/.groundhog" | grep '^\.groundhog\.sh\.' || true)"

t_finish
