#!/usr/bin/env bash
# Consumer configuration and invocation: validation, the argv/cwd/env/stdin
# contract, what a consumer inherits, exit-status acceptance and failure, and
# retry. Consumers are plain /bin/sh scripts that write marker files; every
# runner is stopped or killed before its test ends.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support || ! have_isolation; then
  t_skip "this host has no lock helper, hash tool, durable-write tool or process-isolation helper; the consumer is not offered"
  t_finish
  exit $?
fi

out="$T_TMP/c.json"
secret_of() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$1"; }

# --- invalid configuration is a visible failure, never "no consumer" ----------
good_exe="$T_TMP/good.sh"; printf '#!/bin/sh\nexit 0\n' > "$good_exe"; chmod +x "$good_exe"
plain_file="$T_TMP/plain.txt"; printf 'x\n' > "$plain_file"
bad_config() { # DESC JSON
  new_instance; gh init >/dev/null; gh add daily nudge >/dev/null; enroll_ok
  mkdir -p "$GHD/runtime"; printf '%s\n' "$2" > "$GHD/runtime/config.json"
  local rc=0
  gh run --token-file "$TOK" --interval-seconds 1 >"$out.o" 2>"$out.e" || rc=$?
  assert_eq "$1: run exits 2" 2 "$rc"
  assert_contains "$1: stderr names the config" "$(cat "$out.e")" "config.json"
  assert_contains "$1: nothing was ticked" "$(cat "$out.e")" "nothing was ticked"
  assert_eq "$1: out/ stays empty" 0 "$(out_count)"
  assert_true "$1: no runner lock left" lock_is_free "$GHD/runtime/locks/runner.lock"
  status_to "$out"
  assert_eq "$1: status says configured" true "$(jget "$out" consumer.configured)"
  assert_eq "$1: status says invalid" false "$(jget "$out" consumer.valid)"
  assert_contains "$1: status has a consumer diagnostic" "$(jget "$out" diagnostics)" consumer_config_invalid
  assert_eq "$1: no deliveries were invented" "[]" "$(jget "$out" deliveries)"
  assert_eq "$1: the runner never started" '"stopped"' "$(jget "$out" runner.state)"
}
bad_config "not JSON" 'argv: [oops'
bad_config "wrong schema version" '{"schema_version":2,"consumer":{"argv":["/bin/sh"],"cwd":".."}}'
bad_config "relative argv[0] (no PATH search)" '{"schema_version":1,"consumer":{"argv":["sh"],"cwd":".."}}'
bad_config "missing executable" '{"schema_version":1,"consumer":{"argv":["/nonexistent/consumer"],"cwd":".."}}'
bad_config "argv[0] is a directory" '{"schema_version":1,"consumer":{"argv":["/tmp"],"cwd":".."}}'
bad_config "argv[0] is not executable" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$plain_file\"],\"cwd\":\"..\"}}"
bad_config "missing cwd" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"],\"cwd\":\"does-not-exist\"}}"
bad_config "no cwd at all" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"]}}"
bad_config "empty argv" '{"schema_version":1,"consumer":{"argv":[],"cwd":".."}}'
bad_config "non-string argv element" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\",3],\"cwd\":\"..\"}}"
bad_config "env name that is not an identifier" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"],\"cwd\":\"..\",\"env\":{\"A-B\":\"1\"}}}"
bad_config "non-string env value" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"],\"cwd\":\"..\",\"env\":{\"A\":1}}}"
for reserved in GROUNDHOG_INSTANCE GROUNDHOG_DELIVERY_ID GROUNDHOG_ATTEMPT_ID; do
  bad_config "reserved env name $reserved" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"],\"cwd\":\"..\",\"env\":{\"$reserved\":\"x\"}}}"
done

# A valid configuration reads as valid; a non-executable script with an
# explicit interpreter is fine; an absolute cwd works too.
new_instance; gh init >/dev/null
printf 'exit 0\n' > "$INST/script.sh"      # not executable
write_config /bin/sh "$INST/script.sh"
status_to "$out"
assert_eq "interpreter plus non-executable script: valid" true "$(jget "$out" consumer.valid)"
assert_eq "...configured" true "$(jget "$out" consumer.configured)"
assert_eq "...and the digest stays null until a runner freezes it" null "$(jget "$out" consumer.config_digest)"
assert_eq "...no diagnostics" "[]" "$(jget "$out" diagnostics)"
CFG_CWD="$INST" write_config /bin/sh "$INST/script.sh"
status_to "$out"
assert_eq "an absolute cwd is valid" true "$(jget "$out" consumer.valid)"
write_config /bin/sh "$INST/script.sh"

# --- no config: delivery only; a stray executable enables nothing --------------
new_instance; gh init >/dev/null; gh add daily nudge >/dev/null; enroll_ok
consumer_script consume.sh 'echo ran >> "$PWD/ran.txt"'      # never configured
cp "$CONS" "$GHD/consume.sh"; cp "$CONS" "$GHD/schedule/daily/nudge/consume.sh"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "no-consumer delivery registered" 80 state_is "nudge-$(today)" pending
sleep 2.5
assert_eq "no consumer: still pending after several cycles" '"pending"' "$(dstate "nudge-$(today)")"
assert_eq "...with reason no_consumer" '"no_consumer"' "$(dget path "out/nudge-$(today)" reason)"
assert_eq "...and no attempts" "[]" "$(dget path "out/nudge-$(today)" attempts)"
assert_eq "...nothing was invoked (no discovery of consume.sh)" 0 "$(lines "$INST/ran.txt")"
status_to "$out"
assert_eq "...consumer.configured is false" false "$(jget "$out" consumer.configured)"
assert_eq "...and valid" true "$(jget "$out" consumer.valid)"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# A standalone tick never invokes a configured consumer.
new_instance; gh init >/dev/null; gh add daily nudge >/dev/null
consumer_script consumer.sh 'echo ran >> "$PWD/ran.txt"'
write_config /bin/sh "$CONS"
gh tick >/dev/null 2>&1
assert_eq "a standalone tick fires the item" 1 "$(out_count)"
assert_eq "...and never invokes the configured consumer" 0 "$(lines "$INST/ran.txt")"

# --- success: the whole invocation contract, in one delivery -------------------
fresh_consumer '
{
  echo "argc=$#"
  echo "arg1=$1"
  echo "pwd=$(pwd -P)"
  echo "instance=$GROUNDHOG_INSTANCE"
  echo "delivery=$GROUNDHOG_DELIVERY_ID"
  echo "attempt=$GROUNDHOG_ATTEMPT_ID"
  echo "extra=$EXTRA_ONE"
  echo "override=$OVERRIDE_ME"
  echo "runneronly=$RUNNER_ONLY"
  echo "stdin=$(cat | wc -c | tr -d " ")"
  echo "fd8=$([ -e /dev/fd/8 ] && echo open || echo closed)"
  echo "fd9=$([ -e /dev/fd/9 ] && echo open || echo closed)"
  env
} > "$PWD/seen.txt"
cp "$1/note.txt" "$PWD/got-note.txt"
exit 0'
CFG_ENV_JSON='{"EXTRA_ONE":"one","OVERRIDE_ME":"from-config"}' write_config /bin/sh "$CONS"
secret="$(secret_of "$TOK")"
verifier="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["owner"]["token_verifier"])' "$GHD/runtime/state.json")"
before_tree="$(cd "$GHD/out/$NAME" 2>/dev/null && ls -R 2>/dev/null | cksum)"
OVERRIDE_ME=from-runner RUNNER_ONLY=r1 start_runner --token-file "$TOK" --interval-seconds 1
wait_for "plain script accepted" 100 state_is "$NAME" accepted
snap
seen="$(cat "$INST/seen.txt" 2>/dev/null)"
assert_contains "exactly one argument" "$seen" "argc=1"
assert_contains "the argument is the canonical absolute delivery path" "$seen" "arg1=$GHD/out/$NAME"
assert_contains "cwd is the configured one, relative to the instance" "$seen" "pwd=$INST"
assert_contains "GROUNDHOG_INSTANCE" "$seen" "instance=$GHD"
assert_contains "GROUNDHOG_DELIVERY_ID is the delivery's id" "$seen" "delivery=$(did "$NAME")"
assert_contains "GROUNDHOG_ATTEMPT_ID is the attempt's id" "$seen" "attempt=$(dget path "out/$NAME" attempts.0.id | tr -d '"')"
assert_contains "the configured env map applies" "$seen" "extra=one"
assert_contains "the configured env map overrides the runner's" "$seen" "override=from-config"
assert_contains "the runner's own env is inherited" "$seen" "runneronly=r1"
assert_contains "stdin is /dev/null" "$seen" "stdin=0"
assert_contains "no runner lock fd (8) leaks into the consumer" "$seen" "fd8=closed"
assert_contains "no mutation lock fd (9) leaks into the consumer" "$seen" "fd9=closed"
assert_not_contains "the owner secret never reaches the consumer" "$seen" "$secret"
assert_not_contains "the verifier never reaches the consumer" "$seen" "${verifier#sha256:}"
assert_not_contains "the token file path never reaches the consumer" "$seen" "$TOK"
assert_eq "the consumer saw the payload" "hello" "$(cat "$INST/got-note.txt")"
assert_eq "status: accepted" '"accepted"' "$(dstate "$NAME")"
assert_eq "...original out path kept" '"out/'"$NAME"'"' "$(dget path "out/$NAME" path)"
assert_true "...and still in out/" test -f "$GHD/out/$NAME/note.txt"
assert_eq "...payload untouched" "hello" "$(cat "$GHD/out/$NAME/note.txt")"
assert_eq "...one attempt" 1 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
assert_eq "...outcome accepted" '"accepted"' "$(dget path "out/$NAME" attempts.0.outcome)"
assert_eq "...exit_code 0" 0 "$(dget path "out/$NAME" attempts.0.exit_code)"
assert_eq "...finished_at set" 'str' "$(dget path "out/$NAME" attempts.0.finished_at | cut -c1 | sed 's/"/str/')"
assert_eq "...execution stays unknown" '"unknown"' "$(dget path "out/$NAME" execution)"
assert_eq "...origin runtime" '"runtime"' "$(dget path "out/$NAME" origin)"
assert_eq "...the schedule path is journaled" '"schedule/daily/nudge"' "$(dget path "out/$NAME" schedule_path)"
assert_eq "...and the occurrence date" "\"$(today)\"" "$(dget path "out/$NAME" occurrence.date)"
DG_CACHED=0
status_to "$out"
assert_eq "status reports the frozen config digest" 'str' "$(jget "$out" consumer.config_digest | cut -c1-2 | sed 's/"s/str/')"
assert_not_contains "status never exposes argv" "$(cat "$out")" "consumer.sh"
assert_not_contains "...env" "$(cat "$out")" "from-config"
# Accepted is terminal: more cycles do not hand it off again.
sleep 2.2
assert_eq "accepted is not handed off again by later cycles" 1 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
# a restarted runner does not replay it either
start_runner --token-file "$TOK" --interval-seconds 1
sleep 2.2
assert_eq "a restart does not replay an accepted delivery" 1 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# --- a nonzero exit is failed, never retried by later cycles --------------------
fresh_consumer 'echo x >> "$PWD/calls.txt"; exit 7'
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "nonzero exit recorded as failed" 100 state_is "$NAME" failed
sleep 3.2
assert_eq "failed is not retried by later cycles" 1 "$(lines "$INST/calls.txt")"
assert_eq "...exit_code recorded" 7 "$(dget path "out/$NAME" attempts.0.exit_code)"
assert_eq "...outcome failed" '"failed"' "$(dget path "out/$NAME" attempts.0.outcome)"
assert_eq "...structured error code" '"consumer_failed"' "$(dget path "out/$NAME" attempts.0.error.code)"
assert_true "...the payload stays in out/" test -d "$GHD/out/$NAME"
id1="$(did "$NAME")"

# retry needs a stopped runner and a valid token; it keeps the delivery id.
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>"$out.e" || rc=$?
assert_eq "retry with a live runner fails busy (4)" 4 "$rc"
assert_eq "...and changed nothing" '"failed"' "$(dstate "$NAME")"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
rc=0; gh retry --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "retry without --delivery exits 2" 2 "$rc"
rc=0; gh retry --token-file "$TOK" --delivery "../etc" >/dev/null 2>&1 || rc=$?
assert_eq "retry with a malformed id exits 2" 2 "$rc"
rc=0; gh retry --token-file "$TOK" --delivery d-nope >/dev/null 2>&1 || rc=$?
assert_eq "retry of an unknown delivery exits 5" 5 "$rc"
rc=0; gh retry --token-file "$TOK" --delivery "$id1" --bogus x >/dev/null 2>&1 || rc=$?
assert_eq "retry with an unknown option exits 2" 2 "$rc"
tok_real="$TOK"
new_token_path
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>&1 || rc=$?
assert_eq "retry with a missing token file exits 2" 2 "$rc"
TOK="$tok_real"
printf '#!/bin/sh\necho second >> "$PWD/calls.txt"\nexit 0\n' > "$INST/consumer.sh"
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>"$out.e" || rc=$?
assert_eq "retry of a failed delivery exits 0" 0 "$rc"
assert_eq "...it is pending again" '"pending"' "$(dstate "$NAME")"
assert_eq "...with the same delivery id" "$id1" "$(did "$NAME")"
assert_eq "...and its attempt history kept" 1 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>&1 || rc=$?
assert_eq "retrying a pending delivery is a no-op (0)" 0 "$rc"
assert_eq "...still pending" '"pending"' "$(dstate "$NAME")"
assert_eq "a retry alone invokes nothing" 1 "$(lines "$INST/calls.txt")"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "retried delivery is handed off in a new attempt" 100 state_is "$NAME" accepted
assert_eq "...same delivery id" "$id1" "$(did "$NAME")"
assert_eq "...two attempts" 2 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
assert_eq "...the first attempt keeps its failure" '"failed"' "$(dget path "out/$NAME" attempts.0.outcome)"
assert_eq "...the second is accepted" '"accepted"' "$(dget path "out/$NAME" attempts.1.outcome)"
a0="$(dget path "out/$NAME" attempts.0.id)"; a1="$(dget path "out/$NAME" attempts.1.id)"
assert_true "...with a different attempt id" test "$a0" != "$a1"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>"$out.e" || rc=$?
assert_eq "retry of an accepted delivery exits 5" 5 "$rc"

# A consumer killed by a signal is a failure with the signal recorded.
fresh_consumer 'kill -9 $$'
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "signal death recorded as failed" 100 state_is "$NAME" failed
assert_eq "...exit status 137" 137 "$(dget path "out/$NAME" attempts.0.exit_code)"
assert_eq "...signal named" '"SIGKILL"' "$(dget path "out/$NAME" attempts.0.signal)"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# A consumer whose executable vanishes after startup is a visible runner failure
# and nothing is handed off.
fresh_consumer 'exit 0'
cp "$CONS" "$INST/consumer-copy.sh"
write_config "$INST/consumer-copy.sh"
mkdir -p "$GHD/out/waiting-thing"          # a pending delivery to hand off (legacy, imported by run)
gh pause --token-file "$TOK" >/dev/null 2>&1
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "paused runner imports the delivery" 100 state_is "waiting-thing" pending
rm -f "$INST/consumer-copy.sh"
gh resume --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner ends when its consumer is gone" 60 "$RUNNER_PID"
assert_eq "...with exit 2" 2 "$WAIT_RC"
assert_eq "...the delivery stays pending" '"pending"' "$(dstate waiting-thing)"
assert_eq "...nothing was attempted" "[]" "$(dget path out/waiting-thing attempts)"
status_to "$out"
assert_eq "...runner failed" '"failed"' "$(jget "$out" runner.state)"
assert_eq "...with a structured error" '"consumer_unavailable"' "$(jget "$out" runner.last_error.code)"

t_finish
  exit $?
fi

out="$T_TMP/c.json"
secret_of() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$1"; }

# --- invalid configuration is a visible failure, never "no consumer" ----------
good_exe="$T_TMP/good.sh"; printf '#!/bin/sh\nexit 0\n' > "$good_exe"; chmod +x "$good_exe"
plain_file="$T_TMP/plain.txt"; printf 'x\n' > "$plain_file"
bad_config() { # DESC JSON
  new_instance; gh init >/dev/null; gh add daily nudge >/dev/null; enroll_ok
  mkdir -p "$GHD/runtime"; printf '%s\n' "$2" > "$GHD/runtime/config.json"
  local rc=0
  gh run --token-file "$TOK" --interval-seconds 1 >"$out.o" 2>"$out.e" || rc=$?
  assert_eq "$1: run exits 2" 2 "$rc"
  assert_contains "$1: stderr names the config" "$(cat "$out.e")" "config.json"
  assert_contains "$1: nothing was ticked" "$(cat "$out.e")" "nothing was ticked"
  assert_eq "$1: out/ stays empty" 0 "$(out_count)"
  assert_true "$1: no runner lock left" lock_is_free "$GHD/runtime/locks/runner.lock"
  status_to "$out"
  assert_eq "$1: status says configured" true "$(jget "$out" consumer.configured)"
  assert_eq "$1: status says invalid" false "$(jget "$out" consumer.valid)"
  assert_contains "$1: status has a consumer diagnostic" "$(jget "$out" diagnostics)" consumer_config_invalid
  assert_eq "$1: no deliveries were invented" "[]" "$(jget "$out" deliveries)"
  assert_eq "$1: the runner never started" '"stopped"' "$(jget "$out" runner.state)"
}
bad_config "not JSON" 'argv: [oops'
bad_config "wrong schema version" '{"schema_version":2,"consumer":{"argv":["/bin/sh"],"cwd":".."}}'
bad_config "relative argv[0] (no PATH search)" '{"schema_version":1,"consumer":{"argv":["sh"],"cwd":".."}}'
bad_config "missing executable" '{"schema_version":1,"consumer":{"argv":["/nonexistent/consumer"],"cwd":".."}}'
bad_config "argv[0] is a directory" '{"schema_version":1,"consumer":{"argv":["/tmp"],"cwd":".."}}'
bad_config "argv[0] is not executable" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$plain_file\"],\"cwd\":\"..\"}}"
bad_config "missing cwd" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"],\"cwd\":\"does-not-exist\"}}"
bad_config "no cwd at all" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"]}}"
bad_config "empty argv" '{"schema_version":1,"consumer":{"argv":[],"cwd":".."}}'
bad_config "non-string argv element" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\",3],\"cwd\":\"..\"}}"
bad_config "env name that is not an identifier" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"],\"cwd\":\"..\",\"env\":{\"A-B\":\"1\"}}}"
bad_config "non-string env value" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"],\"cwd\":\"..\",\"env\":{\"A\":1}}}"
for reserved in GROUNDHOG_INSTANCE GROUNDHOG_DELIVERY_ID GROUNDHOG_ATTEMPT_ID; do
  bad_config "reserved env name $reserved" "{\"schema_version\":1,\"consumer\":{\"argv\":[\"$good_exe\"],\"cwd\":\"..\",\"env\":{\"$reserved\":\"x\"}}}"
done

# A valid configuration reads as valid; a non-executable script with an
# explicit interpreter is fine; an absolute cwd works too.
new_instance; gh init >/dev/null
printf 'exit 0\n' > "$INST/script.sh"      # not executable
write_config /bin/sh "$INST/script.sh"
status_to "$out"
assert_eq "interpreter plus non-executable script: valid" true "$(jget "$out" consumer.valid)"
assert_eq "...configured" true "$(jget "$out" consumer.configured)"
assert_eq "...and the digest stays null until a runner freezes it" null "$(jget "$out" consumer.config_digest)"
assert_eq "...no diagnostics" "[]" "$(jget "$out" diagnostics)"
CFG_CWD="$INST" write_config /bin/sh "$INST/script.sh"
status_to "$out"
assert_eq "an absolute cwd is valid" true "$(jget "$out" consumer.valid)"
write_config /bin/sh "$INST/script.sh"

# --- no config: delivery only; a stray executable enables nothing --------------
new_instance; gh init >/dev/null; gh add daily nudge >/dev/null; enroll_ok
consumer_script consume.sh 'echo ran >> "$PWD/ran.txt"'      # never configured
cp "$CONS" "$GHD/consume.sh"; cp "$CONS" "$GHD/schedule/daily/nudge/consume.sh"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "no-consumer delivery registered" 80 state_is "nudge-$(today)" pending
sleep 2.5
assert_eq "no consumer: still pending after several cycles" '"pending"' "$(dstate "nudge-$(today)")"
assert_eq "...with reason no_consumer" '"no_consumer"' "$(dget path "out/nudge-$(today)" reason)"
assert_eq "...and no attempts" "[]" "$(dget path "out/nudge-$(today)" attempts)"
assert_eq "...nothing was invoked (no discovery of consume.sh)" 0 "$(lines "$INST/ran.txt")"
status_to "$out"
assert_eq "...consumer.configured is false" false "$(jget "$out" consumer.configured)"
assert_eq "...and valid" true "$(jget "$out" consumer.valid)"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# A standalone tick never invokes a configured consumer.
new_instance; gh init >/dev/null; gh add daily nudge >/dev/null
consumer_script consumer.sh 'echo ran >> "$PWD/ran.txt"'
write_config /bin/sh "$CONS"
gh tick >/dev/null 2>&1
assert_eq "a standalone tick fires the item" 1 "$(out_count)"
assert_eq "...and never invokes the configured consumer" 0 "$(lines "$INST/ran.txt")"

# --- success: the whole invocation contract, in one delivery -------------------
fresh_consumer '
{
  echo "argc=$#"
  echo "arg1=$1"
  echo "pwd=$(pwd -P)"
  echo "instance=$GROUNDHOG_INSTANCE"
  echo "delivery=$GROUNDHOG_DELIVERY_ID"
  echo "attempt=$GROUNDHOG_ATTEMPT_ID"
  echo "extra=$EXTRA_ONE"
  echo "override=$OVERRIDE_ME"
  echo "runneronly=$RUNNER_ONLY"
  echo "stdin=$(cat | wc -c | tr -d " ")"
  echo "fd8=$([ -e /dev/fd/8 ] && echo open || echo closed)"
  echo "fd9=$([ -e /dev/fd/9 ] && echo open || echo closed)"
  env
} > "$PWD/seen.txt"
cp "$1/note.txt" "$PWD/got-note.txt"
exit 0'
CFG_ENV_JSON='{"EXTRA_ONE":"one","OVERRIDE_ME":"from-config"}' write_config /bin/sh "$CONS"
secret="$(secret_of "$TOK")"
verifier="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["owner"]["token_verifier"])' "$GHD/runtime/state.json")"
before_tree="$(cd "$GHD/out/$NAME" 2>/dev/null && ls -R 2>/dev/null | cksum)"
OVERRIDE_ME=from-runner RUNNER_ONLY=r1 start_runner --token-file "$TOK" --interval-seconds 1
wait_for "plain script accepted" 100 state_is "$NAME" accepted
snap
seen="$(cat "$INST/seen.txt" 2>/dev/null)"
assert_contains "exactly one argument" "$seen" "argc=1"
assert_contains "the argument is the canonical absolute delivery path" "$seen" "arg1=$GHD/out/$NAME"
assert_contains "cwd is the configured one, relative to the instance" "$seen" "pwd=$INST"
assert_contains "GROUNDHOG_INSTANCE" "$seen" "instance=$GHD"
assert_contains "GROUNDHOG_DELIVERY_ID is the delivery's id" "$seen" "delivery=$(did "$NAME")"
assert_contains "GROUNDHOG_ATTEMPT_ID is the attempt's id" "$seen" "attempt=$(dget path "out/$NAME" attempts.0.id | tr -d '"')"
assert_contains "the configured env map applies" "$seen" "extra=one"
assert_contains "the configured env map overrides the runner's" "$seen" "override=from-config"
assert_contains "the runner's own env is inherited" "$seen" "runneronly=r1"
assert_contains "stdin is /dev/null" "$seen" "stdin=0"
assert_contains "no runner lock fd (8) leaks into the consumer" "$seen" "fd8=closed"
assert_contains "no mutation lock fd (9) leaks into the consumer" "$seen" "fd9=closed"
assert_not_contains "the owner secret never reaches the consumer" "$seen" "$secret"
assert_not_contains "the verifier never reaches the consumer" "$seen" "${verifier#sha256:}"
assert_not_contains "the token file path never reaches the consumer" "$seen" "$TOK"
assert_eq "the consumer saw the payload" "hello" "$(cat "$INST/got-note.txt")"
assert_eq "status: accepted" '"accepted"' "$(dstate "$NAME")"
assert_eq "...original out path kept" '"out/'"$NAME"'"' "$(dget path "out/$NAME" path)"
assert_true "...and still in out/" test -f "$GHD/out/$NAME/note.txt"
assert_eq "...payload untouched" "hello" "$(cat "$GHD/out/$NAME/note.txt")"
assert_eq "...one attempt" 1 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
assert_eq "...outcome accepted" '"accepted"' "$(dget path "out/$NAME" attempts.0.outcome)"
assert_eq "...exit_code 0" 0 "$(dget path "out/$NAME" attempts.0.exit_code)"
assert_eq "...finished_at set" 'str' "$(dget path "out/$NAME" attempts.0.finished_at | cut -c1 | sed 's/"/str/')"
assert_eq "...execution stays unknown" '"unknown"' "$(dget path "out/$NAME" execution)"
assert_eq "...origin runtime" '"runtime"' "$(dget path "out/$NAME" origin)"
assert_eq "...the schedule path is journaled" '"schedule/daily/nudge"' "$(dget path "out/$NAME" schedule_path)"
assert_eq "...and the occurrence date" "\"$(today)\"" "$(dget path "out/$NAME" occurrence.date)"
DG_CACHED=0
status_to "$out"
assert_eq "status reports the frozen config digest" 'str' "$(jget "$out" consumer.config_digest | cut -c1-2 | sed 's/"s/str/')"
assert_not_contains "status never exposes argv" "$(cat "$out")" "consumer.sh"
assert_not_contains "...env" "$(cat "$out")" "from-config"
# Accepted is terminal: more cycles do not hand it off again.
sleep 2.2
assert_eq "accepted is not handed off again by later cycles" 1 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
# a restarted runner does not replay it either
start_runner --token-file "$TOK" --interval-seconds 1
sleep 2.2
assert_eq "a restart does not replay an accepted delivery" 1 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# --- a nonzero exit is failed, never retried by later cycles --------------------
fresh_consumer 'echo x >> "$PWD/calls.txt"; exit 7'
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "nonzero exit recorded as failed" 100 state_is "$NAME" failed
sleep 3.2
assert_eq "failed is not retried by later cycles" 1 "$(lines "$INST/calls.txt")"
assert_eq "...exit_code recorded" 7 "$(dget path "out/$NAME" attempts.0.exit_code)"
assert_eq "...outcome failed" '"failed"' "$(dget path "out/$NAME" attempts.0.outcome)"
assert_eq "...structured error code" '"consumer_failed"' "$(dget path "out/$NAME" attempts.0.error.code)"
assert_true "...the payload stays in out/" test -d "$GHD/out/$NAME"
id1="$(did "$NAME")"

# retry needs a stopped runner and a valid token; it keeps the delivery id.
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>"$out.e" || rc=$?
assert_eq "retry with a live runner fails busy (4)" 4 "$rc"
assert_eq "...and changed nothing" '"failed"' "$(dstate "$NAME")"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
rc=0; gh retry --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "retry without --delivery exits 2" 2 "$rc"
rc=0; gh retry --token-file "$TOK" --delivery "../etc" >/dev/null 2>&1 || rc=$?
assert_eq "retry with a malformed id exits 2" 2 "$rc"
rc=0; gh retry --token-file "$TOK" --delivery d-nope >/dev/null 2>&1 || rc=$?
assert_eq "retry of an unknown delivery exits 5" 5 "$rc"
rc=0; gh retry --token-file "$TOK" --delivery "$id1" --bogus x >/dev/null 2>&1 || rc=$?
assert_eq "retry with an unknown option exits 2" 2 "$rc"
tok_real="$TOK"
new_token_path
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>&1 || rc=$?
assert_eq "retry with a missing token file exits 2" 2 "$rc"
TOK="$tok_real"
printf '#!/bin/sh\necho second >> "$PWD/calls.txt"\nexit 0\n' > "$INST/consumer.sh"
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>"$out.e" || rc=$?
assert_eq "retry of a failed delivery exits 0" 0 "$rc"
assert_eq "...it is pending again" '"pending"' "$(dstate "$NAME")"
assert_eq "...with the same delivery id" "$id1" "$(did "$NAME")"
assert_eq "...and its attempt history kept" 1 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>&1 || rc=$?
assert_eq "retrying a pending delivery is a no-op (0)" 0 "$rc"
assert_eq "...still pending" '"pending"' "$(dstate "$NAME")"
assert_eq "a retry alone invokes nothing" 1 "$(lines "$INST/calls.txt")"
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "retried delivery is handed off in a new attempt" 100 state_is "$NAME" accepted
assert_eq "...same delivery id" "$id1" "$(did "$NAME")"
assert_eq "...two attempts" 2 "$(dget path "out/$NAME" attempts | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))')"
assert_eq "...the first attempt keeps its failure" '"failed"' "$(dget path "out/$NAME" attempts.0.outcome)"
assert_eq "...the second is accepted" '"accepted"' "$(dget path "out/$NAME" attempts.1.outcome)"
a0="$(dget path "out/$NAME" attempts.0.id)"; a1="$(dget path "out/$NAME" attempts.1.id)"
assert_true "...with a different attempt id" test "$a0" != "$a1"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"
rc=0; gh retry --token-file "$TOK" --delivery "$id1" >/dev/null 2>"$out.e" || rc=$?
assert_eq "retry of an accepted delivery exits 5" 5 "$rc"

# A consumer killed by a signal is a failure with the signal recorded.
fresh_consumer 'kill -9 $$'
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "signal death recorded as failed" 100 state_is "$NAME" failed
assert_eq "...exit status 137" 137 "$(dget path "out/$NAME" attempts.0.exit_code)"
assert_eq "...signal named" '"SIGKILL"' "$(dget path "out/$NAME" attempts.0.signal)"
gh stop --token-file "$TOK" >/dev/null 2>&1
wait_exit "runner exited" 50 "$RUNNER_PID"

# A consumer whose executable vanishes after startup is a visible runner failure
# and nothing is handed off.
fresh_consumer 'exit 0'
cp "$CONS" "$INST/consumer-copy.sh"
write_config "$INST/consumer-copy.sh"
gh pause --token-file "$TOK" >/dev/null 2>&1
start_runner --token-file "$TOK" --interval-seconds 1
wait_for "paused runner registers the delivery" 100 state_is "$NAME" pending
rm -f "$INST/consumer-copy.sh"
gh resume --token-file "$TOK" >/dev/null 2>&1
wait_exit "the runner ends when its consumer is gone" 60 "$RUNNER_PID"
assert_eq "...with exit 2" 2 "$WAIT_RC"
assert_eq "...the delivery stays pending" '"pending"' "$(dstate "$NAME")"
status_to "$out"
assert_eq "...runner failed" '"failed"' "$(jget "$out" runner.state)"
assert_eq "...with a structured error" '"consumer_unavailable"' "$(jget "$out" runner.last_error.code)"

t_finish
