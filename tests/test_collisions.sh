#!/usr/bin/env bash
# Output collisions: every way two firings can claim one out/ name, and what the
# status and the lint/add notes say about each. The contract accepts the legacy
# no-overwrite rule (the later firing is recorded but not delivered); these tests
# pin that it is never silent.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support; then
  t_skip "this host lacks the runner's tools"
  t_finish
  exit $?
fi

out="$T_TMP/c.json"
run_once() { # run for a moment, then stop (the first cycle runs immediately)
  start_runner --token-file "$TOK" --interval-seconds 1
  wait_for "the runner is up" 80 runner_is running
  sleep "${1:-1.5}"
  gh stop --token-file "$TOK" >/dev/null 2>&1
  wait_exit "the runner exited" 50 "$RUNNER_PID"
}
dow="$(date +%a | tr '[:upper:]' '[:lower:]')"
td="$(today)"
diag_has() { jget "$out" diagnostics | grep -q "$1"; }

# --- 1. a standalone tick on a previously supervised instance -------------------
# (released, then ticked by hand: the collision used to reach stderr only)
new_instance; gh init >/dev/null
gh add daily foo >/dev/null; echo d > "$GHD/schedule/daily/foo/n.txt"
enroll_ok; gh resume --token-file "$TOK" >/dev/null
run_once
gh release --token-file "$TOK" >/dev/null 2>&1
gh add "weekly/$dow" foo >/dev/null; echo w > "$GHD/schedule/weekly/$dow/foo/n.txt"
err="$(gh tick 2>&1 >/dev/null)"
assert_contains "the standalone tick still warns on stderr" "$err" "already exists in out/"
assert_eq "...and did not overwrite the delivery" d "$(cat "$GHD/out/foo-$td/n.txt")"
status_to "$out"
assert_true "status now carries the out_collision for it" diag_has out_collision
assert_contains "...naming the schedule item that lost" "$(jget "$out" diagnostics)" "schedule/weekly/$dow/foo"
assert_eq "...against the one delivery that owns the name" 1 "$(jq_py where "$out" deliveries path "\"out/foo-$td\"" id | wc -l | tr -d ' ')"

t_finish
