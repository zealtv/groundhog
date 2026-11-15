#!/usr/bin/env bash
# Runtime state: runtime/state.json, config.json and deliveries/ are parsed when
# present (these tests write synthetic files; nothing in this script writes
# them yet), defaulted when absent, and reported, never repaired, when broken.
. "$(dirname "$0")/lib.sh"
export TZ=UTC
set_clock "2026-11-15 12:00:00"
out="$T_TMP/state.json"

state() { printf '%s' "$1" > "$GHD/runtime/state.json"; }
codes() { jq_py col "$out" diagnostics code | tr '\n' ' '; }
fresh() { new_instance; mkdir -p "$GHD/runtime/deliveries" "$GHD/out"; }

# --- defaults when nothing exists ---------------------------------------------
new_instance
status_to "$out"
assert_eq "no state: revision 0" 0 "$(jget "$out" revision)"
assert_eq "no state: not paused" false "$(jget "$out" paused)"
assert_eq "no state: owner null" null "$(jget "$out" owner)"
assert_eq "no state: runner stopped" '{"state":"stopped","last_error":null}' "$(jget "$out" runner)"
assert_eq "no state: consumer not configured" '{"configured":false,"valid":true,"config_digest":null}' "$(jget "$out" consumer)"
assert_eq "no state: consistent" true "$(jget "$out" consistent)"
assert_eq "no state: instance is the canonical directory" "\"$GHD\"" "$(jget "$out" instance)"

# --- a stopped, owned, paused instance ----------------------------------------
fresh
state '{"schema_version":1,"revision":12,"paused":true,"owner":{"id":"o-demo","generation":1,"label":"demo-session","token_verifier":"SECRETVERIFIER"},"runner":{"state":"stopped","last_error":null},"config_digest":null,"pid":4242}'
status_to "$out"
assert_json_valid "$out"
assert_eq "revision" 12 "$(jget "$out" revision)"
assert_eq "paused" true "$(jget "$out" paused)"
assert_eq "owner shows only public metadata" '{"id":"o-demo","generation":1,"label":"demo-session"}' "$(jget "$out" owner)"
assert_not_contains "the verifier never reaches the output" "$(cat "$out")" SECRETVERIFIER
assert_eq "consistent" true "$(jget "$out" consistent)"
assert_eq "no diagnostics for a valid state" "[]" "$(jget "$out" diagnostics)"

# Pause and ownership feed firing_allowed / blocked_by; eligibility stays legacy.
# (`add` refuses an owned instance, so the item is made directly.)
mkdir -p "$GHD/schedule/daily/nudge"
status_to "$out"
assert_eq "paused+owned: item still eligible_now" true "$(jq_py find "$out" schedule path schedule/daily/nudge | python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["eligible_now"]))')"
rec="$(jq_py find "$out" schedule path schedule/daily/nudge)"
assert_contains "paused+owned: firing not allowed" "$rec" '"firing_allowed":false'
assert_contains "paused+owned: blocked_by lists both" "$rec" '"blocked_by":["instance_paused","owned"]'

# Unpaused, unowned: nothing blocks.
state '{"schema_version":1,"revision":3,"paused":false,"owner":null,"runner":{"state":"stopped","last_error":null},"config_digest":null}'
status_to "$out"
rec="$(jq_py find "$out" schedule path schedule/daily/nudge)"
assert_contains "free: firing allowed" "$rec" '"firing_allowed":true'
assert_contains "free: nothing blocks" "$rec" '"blocked_by":[]'

# Optional fields default; extra fields are ignored.
state '{"schema_version":1,"future_field":{"x":[1,2,3]}}'
status_to "$out"
assert_eq "minimal state: consistent" true "$(jget "$out" consistent)"
assert_eq "minimal state: revision defaults to 0" 0 "$(jget "$out" revision)"
assert_eq "minimal state: runner defaults to stopped" '"stopped"' "$(jget "$out" runner.state)"

# Runner states and a structured error; configuration digest.
state '{"schema_version":1,"revision":5,"runner":{"state":"failed","last_error":{"code":"consumer_config_invalid","message":"line one\nline \"two\"","path":"runtime/config.json"}},"config_digest":"sha256:abc"}'
status_to "$out"
assert_eq "failed runner state" '"failed"' "$(jget "$out" runner.state)"
assert_eq "structured runner error" '{"code":"consumer_config_invalid","message":"line one\nline \"two\"","path":"runtime/config.json"}' "$(jget "$out" runner.last_error)"
assert_eq "config_digest comes from state" '"sha256:abc"' "$(jget "$out" consumer.config_digest)"
for st in running stopping unknown stopped; do
  state "{\"schema_version\":1,\"runner\":{\"state\":\"$st\",\"last_error\":null}}"
  status_to "$out"
  assert_eq "runner state $st passes through" "\"$st\"" "$(jget "$out" runner.state)"
done

# --- malformed or unsupported state: reported, consistent:false, untouched -----
check_bad() { # DESC CONTENT EXPECTED-CODE
  fresh
  gh add daily nudge >/dev/null
  state "$2"
  local before; before="$(cat "$GHD/runtime/state.json")"
  status_to "$out"
  assert_json_valid "$out"
  assert_eq "$1: consistent false" false "$(jget "$out" consistent)"
  assert_contains "$1: diagnosed as $3" "$(codes)" "\"$3\""
  assert_eq "$1: runner unknown" '"unknown"' "$(jget "$out" runner.state)"
  assert_eq "$1: owner not guessed" null "$(jget "$out" owner)"
  assert_contains "$1: firing blocked as invalid_state" "$(jq_py find "$out" schedule path schedule/daily/nudge)" '"invalid_state"'
  assert_eq "$1: file untouched" "$before" "$(cat "$GHD/runtime/state.json")"
  assert_eq "$1: stderr quiet" "" "$(cat "$out.err")"
}
check_bad "not json"            'this is not json'                                         state_malformed
check_bad "empty file"          ''                                                         state_malformed
check_bad "truncated"           '{"schema_version":1,"revision":'                           state_malformed
check_bad "trailing data"       '{"schema_version":1} x'                                   state_malformed
check_bad "array at top"        '[1]'                                                      state_malformed
check_bad "bad escape"          '{"schema_version":1,"x":"\q"}'                            state_malformed
check_bad "raw control char"    "$(printf '{"schema_version":1,"x":"a\tb"}')"              state_malformed
check_bad "leading zero number" '{"schema_version":1,"revision":01}'                       state_malformed
check_bad "negative revision"   '{"schema_version":1,"revision":-1}'                       state_malformed
check_bad "fractional revision" '{"schema_version":1,"revision":1.5}'                      state_malformed
check_bad "string paused"       '{"schema_version":1,"paused":"yes"}'                      state_malformed
check_bad "owner without id"    '{"schema_version":1,"owner":{"generation":1}}'            state_malformed
check_bad "owner bad generation" '{"schema_version":1,"owner":{"id":"o","generation":"1"}}' state_malformed
check_bad "owner as string"     '{"schema_version":1,"owner":"me"}'                        state_malformed
check_bad "unknown runner state" '{"schema_version":1,"runner":{"state":"sleeping"}}'      state_malformed
check_bad "missing version"     '{"revision":1}'                                           state_unsupported
check_bad "future version"      '{"schema_version":2,"revision":1}'                        state_unsupported
deep='{"schema_version":1,"x":'; i=0
while [ "$i" -lt 40 ]; do deep="$deep["; i=$((i + 1)); done
i=0; while [ "$i" -lt 40 ]; do deep="$deep]"; i=$((i + 1)); done
check_bad "deep nesting"        "$deep}" state_malformed

# A directory where the file should be.
fresh
mkdir "$GHD/runtime/state.json"
status_to "$out"
assert_eq "directory as state: consistent false" false "$(jget "$out" consistent)"
assert_contains "directory as state: diagnosed" "$(codes)" '"state_unreadable"'

# Diagnostics never echo values from the file.
fresh
state '{"schema_version":1,"owner":{"id":"o-secret-id","generation":"oops","token_verifier":"TOPSECRET"}}'
status_to "$out"
assert_not_contains "malformed state does not leak the verifier" "$(cat "$out")" TOPSECRET

# --- a writer racing the read -------------------------------------------------
fresh
state '{"schema_version":1,"revision":7,"paused":false}'
gh add daily nudge >/dev/null
printf 'printf %s > "%s"\n' "'{\"schema_version\":1,\"revision\":8,\"paused\":true}'" "$GHD/runtime/state.json" > "$T_SHIM/hook"
status_to "$out"
assert_eq "state changed mid-read: consistent false" false "$(jget "$out" consistent)"
assert_contains "state changed mid-read: diagnosed" "$(codes)" '"state_changed_during_read"'
status_to "$out"
assert_eq "a quiet re-read is consistent again" true "$(jget "$out" consistent)"
assert_eq "...and sees the new revision" 8 "$(jget "$out" revision)"

# --- consumer configuration ---------------------------------------------------
fresh
printf '%s' '{"schema_version":1,"consumer":{"argv":["/bin/sh","/example/consume.sh"],"cwd":"..","env":{"EXAMPLE":"1"}}}' > "$GHD/runtime/config.json"
status_to "$out"
assert_eq "valid config: configured, valid" '{"configured":true,"valid":true,"config_digest":null}' "$(jget "$out" consumer)"
assert_eq "valid config: no diagnostics" "[]" "$(jget "$out" diagnostics)"
assert_not_contains "config contents never appear" "$(cat "$out")" consume.sh
for bad in '[1]' '{"schema_version":1}' '{"schema_version":1,"consumer":{"argv":[],"cwd":".."}}' \
           '{"schema_version":1,"consumer":{"argv":["relative"],"cwd":".."}}' \
           '{"schema_version":1,"consumer":{"argv":["/bin/sh",1],"cwd":".."}}' \
           '{"schema_version":1,"consumer":{"argv":["/bin/sh"]}}' \
           '{"schema_version":1,"consumer":{"argv":["/bin/sh"],"cwd":"..","env":{"K":1}}}' \
           '{"schema_version":2,"consumer":{"argv":["/bin/sh"],"cwd":".."}}' '{oops'; do
  printf '%s' "$bad" > "$GHD/runtime/config.json"
  status_to "$out"
  assert_eq "bad config $bad: configured but invalid" '{"configured":true,"valid":false,"config_digest":null}' "$(jget "$out" consumer)"
  assert_contains "bad config $bad: diagnosed" "$(codes)" '"consumer_config_invalid"'
  assert_eq "bad config $bad: snapshot stays consistent" true "$(jget "$out" consistent)"
done

# --- deliveries ---------------------------------------------------------------
fresh
mkdir -p "$GHD/out/nudge-2026-11-15" "$GHD/out/old-legacy" "$GHD/out/work-2026-11-15" "$GHD/out/x.landing"
printf x > "$GHD/out/a-file"
cat > "$GHD/runtime/deliveries/d-demo-1.json" <<'JSON'
{"schema_version":1,"id":"d-demo-1","path":"out/nudge-2026-11-15","origin":"runtime",
 "schedule_path":"schedule/daily/nudge","occurrence":{"date":"2026-11-15","slot":null},
 "state":"pending","reason":"no_consumer","attempts":[]}
JSON
cat > "$GHD/runtime/deliveries/d-demo-2.json" <<'JSON'
{"schema_version":1,"id":"d-demo-2","path":"out/work-2026-11-15","origin":"runtime",
 "schedule_path":"schedule/daily/work","occurrence":{"date":"2026-11-15","slot":"09-15"},
 "state":"failed","reason":null,
 "attempts":[{"id":"a-1","started_at":"2026-11-15T01:00:00Z","finished_at":"2026-11-15T01:00:02Z",
              "outcome":"failed","exit_code":7,"signal":null,
              "error":{"code":"consumer_exit","message":"exited 7","path":null}}]}
JSON
state '{"schema_version":1,"revision":2,"runner":{"state":"stopped","last_error":null}}'
status_to "$out"
assert_json_valid "$out"
assert_eq "records plus unregistered entries" '["out/nudge-2026-11-15","out/work-2026-11-15","out/old-legacy"]' \
  "$(python3 -I -c 'import json,sys;print(json.dumps([d["path"] for d in json.load(open(sys.argv[1]))["deliveries"]],separators=(",",":")))' "$out")"
assert_eq "runtime delivery as recorded" '{"id":"d-demo-1","path":"out/nudge-2026-11-15","origin":"runtime","schedule_path":"schedule/daily/nudge","occurrence":{"date":"2026-11-15","slot":null},"state":"pending","reason":"no_consumer","attempts":[],"execution":"unknown"}' \
  "$(jq_py find "$out" deliveries id d-demo-1)"
assert_eq "failed delivery keeps its attempt" '{"id":"a-1","started_at":"2026-11-15T01:00:00Z","finished_at":"2026-11-15T01:00:02Z","outcome":"failed","exit_code":7,"signal":null,"error":{"code":"consumer_exit","message":"exited 7","path":null}}' \
  "$(jget "$out" deliveries.1.attempts.0)"
assert_eq "unregistered out entry is read-only legacy" '{"id":null,"path":"out/old-legacy","origin":"legacy_out","schedule_path":null,"occurrence":null,"state":"pending","reason":"unregistered","attempts":[],"execution":"unknown"}' \
  "$(jget "$out" deliveries.2)"
assert_eq "exactly three deliveries (.landing ignored)" 3 "$(jq_py col "$out" deliveries path | wc -l | tr -d ' ')"
assert_contains "a plain file in out/ is mentioned, not listed" "$(codes)" '"out_entry_not_directory"'
assert_eq "status registered nothing" 2 "$(ls "$GHD/runtime/deliveries" | wc -l | tr -d ' ')"

# In-flight records: with no live runner the outcome reads unknown; delivery state is kept.
cat > "$GHD/runtime/deliveries/d-demo-3.json" <<'JSON'
{"schema_version":1,"id":"d-demo-3","path":"out/old-legacy","state":"in_flight",
 "attempts":[{"id":"a-1","started_at":"2026-11-15T01:00:00Z","finished_at":null,"outcome":"in_flight"}]}
JSON
for st in stopped unknown failed; do
  state "{\"schema_version\":1,\"runner\":{\"state\":\"$st\"}}"
  status_to "$out"
  assert_eq "runner $st: abandoned in-flight attempt reads unknown" '"unknown"' "$(jget "$out" deliveries.2.attempts.0.outcome)"
  assert_eq "runner $st: delivery stays in_flight" '"in_flight"' "$(jget "$out" deliveries.2.state)"
done
for st in running stopping; do
  state "{\"schema_version\":1,\"runner\":{\"state\":\"$st\"}}"
  status_to "$out"
  assert_eq "runner $st: live in-flight attempt reads in_flight" '"in_flight"' "$(jget "$out" deliveries.2.attempts.0.outcome)"
done
# A registered record claims its out entry, so it is not also listed as legacy.
assert_eq "no duplicate for the claimed entry" 3 "$(jq_py col "$out" deliveries path | wc -l | tr -d ' ')"

# Recovery decisions are shown once recorded.
cat > "$GHD/runtime/deliveries/d-demo-3.json" <<'JSON'
{"schema_version":1,"id":"d-demo-3","path":"out/old-legacy","state":"accepted",
 "attempts":[{"id":"a-1","started_at":"2026-11-15T01:00:00Z","finished_at":null,"outcome":"unknown",
              "decision":"accept","decided_at":"2026-11-15T02:00:00Z"}]}
JSON
status_to "$out"
assert_eq "decision and decided_at" '"accept"' "$(jget "$out" deliveries.2.attempts.0.decision)"
assert_eq "decided_at" '"2026-11-15T02:00:00Z"' "$(jget "$out" deliveries.2.attempts.0.decided_at)"

# A record whose directory is gone is flagged, not rewritten.
rm -rf "$GHD/out/work-2026-11-15"
status_to "$out"
assert_contains "missing path flagged" "$(codes)" '"delivery_path_missing"'
assert_eq "its recorded state is kept" '"failed"' "$(jget "$out" deliveries.1.state)"
assert_eq "still consistent" true "$(jget "$out" consistent)"

# Malformed records: diagnosed, snapshot inconsistent, files untouched.
bad_record() { # DESC CONTENT
  fresh
  mkdir -p "$GHD/out/e"
  printf '%s' "$2" > "$GHD/runtime/deliveries/d-bad.json"
  status_to "$out"
  assert_json_valid "$out"
  assert_eq "$1: consistent false" false "$(jget "$out" consistent)"
  assert_contains "$1: diagnosed" "$(codes)" '"delivery_record_malformed"'
  assert_eq "$1: file untouched" "$2" "$(cat "$GHD/runtime/deliveries/d-bad.json")"
}
bad_record "garbage" 'nope'
bad_record "id mismatch" '{"schema_version":1,"id":"d-other","path":"out/e","state":"pending"}'
bad_record "unknown state" '{"schema_version":1,"id":"d-bad","path":"out/e","state":"done"}'
bad_record "path escapes out/" '{"schema_version":1,"id":"d-bad","path":"out/../../x","state":"pending"}'
bad_record "path outside out/" '{"schema_version":1,"id":"d-bad","path":"schedule/daily","state":"pending"}'
bad_record "nested path" '{"schema_version":1,"id":"d-bad","path":"out/a/b","state":"pending"}'
bad_record "unknown origin" '{"schema_version":1,"id":"d-bad","path":"out/e","state":"pending","origin":"magic"}'
bad_record "attempts not array" '{"schema_version":1,"id":"d-bad","path":"out/e","state":"pending","attempts":{}}'
bad_record "attempt outcome unknown value" '{"schema_version":1,"id":"d-bad","path":"out/e","state":"failed","attempts":[{"id":"a","started_at":"t","outcome":"maybe"}]}'
bad_record "attempt without id" '{"schema_version":1,"id":"d-bad","path":"out/e","state":"failed","attempts":[{"started_at":"t","outcome":"failed"}]}'
bad_record "bad decision" '{"schema_version":1,"id":"d-bad","path":"out/e","state":"failed","attempts":[{"id":"a","started_at":"t","outcome":"failed","decision":"shrug"}]}'
# The entry a malformed record points at is still shown, as unregistered.
assert_contains "malformed record leaves its entry visible" "$(jq_py col "$out" deliveries path)" '"out/e"'

# --- strings survive parse and re-encode --------------------------------------
fresh
# é, a surrogate pair (U+1F600), \n, \t, \\ and a quote in the label.
state '{"schema_version":1,"revision":1,"owner":{"id":"o-1","generation":2,"label":"café 😀 line1\nline2\ttab \\ \"q\""}}'
status_to "$out"
assert_json_valid "$out"
assert_eq "label round-trips through parse and re-encode" \
  '"café 😀 line1\nline2\ttab \\ \"q\""' "$(jget "$out" owner.label)"
# Raw UTF-8 in the file, and a lone surrogate escape (becomes U+FFFD).
state "$(printf '{"schema_version":1,"owner":{"id":"o-1","generation":1,"label":"na\xc3\xafve \\ud800 x"}}')"
status_to "$out"
assert_json_valid "$out"
label_escaped() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["owner"]["label"].encode("unicode_escape").decode())' "$1"; }
assert_eq "raw UTF-8 kept, lone surrogate replaced" 'na\xefve \ufffd x' "$(label_escaped "$out")"
# Bytes that are not UTF-8 cannot be represented: replaced, and said so.
state "$(printf '{"schema_version":1,"owner":{"id":"o-1","generation":1,"label":"bad\xff\xfe!"}}')"
status_to "$out"
assert_json_valid "$out"
assert_eq "invalid bytes become U+FFFD" 'bad\ufffd\ufffd!' "$(label_escaped "$out")"
assert_contains "and the loss is diagnosed" "$(codes)" '"path_not_utf8"'
# Overlong and surrogate encodings are invalid UTF-8 too.
state "$(printf '{"schema_version":1,"owner":{"id":"o-1","generation":1,"label":"a\xc0\x80b\xed\xa0\x80c"}}')"
status_to "$out"
assert_json_valid "$out"
assert_contains "overlong and surrogate bytes are rejected" "$(codes)" '"path_not_utf8"'

clear_clock
t_finish
