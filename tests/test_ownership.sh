#!/usr/bin/env bash
# Enrollment, tokens, persistent pause, release, and the passive callers
# (tick, init, add, drop, sweep) around an owned or paused instance. No runner
# is started here; test_runner.sh covers `run` and `stop`.
. "$(dirname "$0")/lib.sh"

if ! have_runtime_support; then
  t_skip "this host has no lock helper, hash tool or durable-write tool; the runner commands are not offered (see the no-helper case in test_runtime_gate.sh)"
  t_finish
  exit $?
fi

out="$T_TMP/o.json"
rc_of() { local rc=0; "$@" >"$T_TMP/rc.out" 2>"$T_TMP/rc.err" || rc=$?; echo "$rc"; }

# --- enroll ------------------------------------------------------------------
new_instance
gh init >/dev/null
gh add daily nudge >/dev/null
new_token_path
tok1="$TOK"
rc=0; gh enroll --owner-label "demo session" --token-file "$tok1" >"$out.o" 2>"$out.e" || rc=$?
assert_eq "enroll exits 0" 0 "$rc"
assert_true "the token file exists" test -f "$tok1"
mode="$(stat -f %Lp "$tok1" 2>/dev/null || stat -c %a "$tok1")"
assert_eq "the token file is mode 0600" 600 "$mode"
assert_json_valid_loose() { if python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));assert isinstance(d,dict)' "$1"; then t_ok; else t_fail "valid JSON object: $1"; fi; }
assert_json_valid_loose "$tok1"
tokj() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$tok1" "$1"; }
secret="$(tokj token)"
assert_eq "token file schema_version" 1 "$(tokj schema_version)"
assert_eq "token file names the canonical instance" "$GHD" "$(tokj instance)"
assert_eq "token file generation" 1 "$(tokj generation)"
assert_true "the secret is long and hex" test "${#secret}" -ge 32
status_to "$out"
assert_json_valid "$out"
assert_eq "status owner id matches the token metadata" "\"$(tokj owner_id)\"" "$(jget "$out" owner.id)"
assert_eq "status owner generation matches" 1 "$(jget "$out" owner.generation)"
assert_eq "status owner label" '"demo session"' "$(jget "$out" owner.label)"
assert_eq "status stays consistent with real state" true "$(jget "$out" consistent)"
assert_eq "the first protocol write is revision 1" 1 "$(jget "$out" revision)"
assert_eq "enroll leaves the runner stopped" '"stopped"' "$(jget "$out" runner.state)"
assert_eq "enroll does not pause" false "$(jget "$out" paused)"
for f in "$out" "$out.o" "$out.e" "$GHD/runtime/state.json"; do
  case "$(cat "$f")" in
    *"$secret"*) t_fail "the secret leaked into $(basename "$f")" ;;
    *) t_ok ;;
  esac
done
assert_not_contains "status never shows a verifier" "$(cat "$out")" verifier
assert_contains "the state holds a verifier, not the secret" "$(cat "$GHD/runtime/state.json")" token_verifier

# --- enroll refusals ---------------------------------------------------------
new_token_path
rc=0; gh enroll --owner-label other --token-file "$TOK" >/dev/null 2>"$out.e" || rc=$?
assert_eq "enroll on an owned instance fails 3" 3 "$rc"
assert_false "...and writes no token file" test -e "$TOK"
rc=0; gh run --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "a token file that does not exist is an argument error (2)" 2 "$rc"

new_instance
fresh_args() {
  local desc="$1"; shift
  local rc=0; gh "$@" >/dev/null 2>"$out.e" || rc=$?
  assert_eq "$desc exits 2" 2 "$rc"
  assert_contains "$desc explains itself" "$(cat "$out.e")" "error:"
}
new_token_path
fresh_args "enroll without a label" enroll --token-file "$TOK"
fresh_args "enroll without a token file" enroll --owner-label x
fresh_args "enroll with a relative token path" enroll --owner-label x --token-file relative-token
fresh_args "enroll with an unknown option" enroll --owner-label x --token-file "$TOK" --force
fresh_args "enroll with a repeated option" enroll --owner-label x --owner-label y --token-file "$TOK"
fresh_args "enroll with an option missing its value" enroll --owner-label
fresh_args "enroll with a parent directory that does not exist" enroll --owner-label x --token-file "$T_TMP/nodir/token"
fresh_args "enroll with a token file inside the instance" enroll --owner-label x --token-file "$GHD/token"
printf 'x' > "$T_TOKDIR/present"
fresh_args "enroll over an existing token file" enroll --owner-label x --token-file "$T_TOKDIR/present"
assert_eq "enroll over an existing file leaves it alone" x "$(cat "$T_TOKDIR/present")"
fresh_args "run without a token file" run
fresh_args "run with a bad interval" run --token-file "$T_TOKDIR/present" --interval-seconds 0
fresh_args "run with a non-numeric interval" run --token-file "$T_TOKDIR/present" --interval-seconds 5s
fresh_args "pause with an unknown option" pause --token-file "$T_TOKDIR/present" --now
fresh_args "pause given --interval-seconds" pause --token-file "$T_TOKDIR/present" --interval-seconds 5
fresh_args "stop with a stray argument" stop extra
assert_false "none of that created runtime state" test -e "$GHD/runtime/state.json"

# --- tokens: stale, foreign, malformed ---------------------------------------
new_instance
gh init >/dev/null
gh add daily nudge >/dev/null
enroll_ok; good="$TOK"
status_to "$out"; rev0="$(jget "$out" revision)"

python3 -I - "$good" "$T_TOKDIR" <<'PY'
import json, sys
src, d = sys.argv[1], sys.argv[2]
t = json.load(open(src))
w = lambda name, o: open(d + "/" + name, "w").write(json.dumps(o) + "\n")
b = dict(t); b["token"] = "0" * len(t["token"]);        w("badsecret", b)
g = dict(t); g["generation"] = t["generation"] + 1;     w("badgen", g)
o = dict(t); o["owner_id"] = "o-someone-else";          w("badowner", o)
i = dict(t); i["instance"] = "/not/this/instance";      w("badinstance", i)
open(d + "/garbage", "w").write("not json\n")
w("notoken", {"schema_version": 1, "instance": t["instance"], "owner_id": t["owner_id"], "generation": 1})
PY
for cmd in pause resume stop release run; do
  for f in badsecret badgen badowner; do
    rc=0; gh $cmd --token-file "$T_TOKDIR/$f" >/dev/null 2>"$out.e" || rc=$?
    assert_eq "$cmd with a stale token ($f) fails 3" 3 "$rc"
  done
  rc=0; gh $cmd --token-file "$T_TOKDIR/badinstance" >/dev/null 2>"$out.e" || rc=$?
  assert_eq "$cmd with another instance's token fails 3" 3 "$rc"
  rc=0; gh $cmd --token-file "$T_TOKDIR/garbage" >/dev/null 2>"$out.e" || rc=$?
  assert_eq "$cmd with a malformed token file fails 2" 2 "$rc"
  rc=0; gh $cmd --token-file "$T_TOKDIR/notoken" >/dev/null 2>"$out.e" || rc=$?
  assert_eq "$cmd with a token file lacking the token fails 2" 2 "$rc"
  rc=0; gh $cmd --token-file "$T_TOKDIR/does-not-exist" >/dev/null 2>"$out.e" || rc=$?
  assert_eq "$cmd with a missing token file fails 2" 2 "$rc"
done
status_to "$out"
assert_eq "refused commands changed nothing: revision" "$rev0" "$(jget "$out" revision)"
assert_eq "refused commands changed nothing: still owned" true "$(jget "$out" owner | python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin) is not None))')"

# --- pause and resume --------------------------------------------------------
rc=0; gh pause --token-file "$good" >/dev/null 2>&1 || rc=$?
assert_eq "pause exits 0" 0 "$rc"
status_to "$out"
assert_eq "pause is persisted" true "$(jget "$out" paused)"
rev1="$(jget "$out" revision)"
assert_eq "pause advances the revision" "$((rev0 + 1))" "$rev1"
rc=0; gh pause --token-file "$good" >/dev/null 2>&1 || rc=$?
assert_eq "pausing twice exits 0" 0 "$rc"
status_to "$out"
assert_eq "a repeated pause changes nothing" "$rev1" "$(jget "$out" revision)"
assert_eq "still paused" true "$(jget "$out" paused)"
gh resume --token-file "$good" >/dev/null 2>&1
status_to "$out"
assert_eq "resume clears the pause" false "$(jget "$out" paused)"
rev2="$(jget "$out" revision)"
assert_eq "resume advances the revision" "$((rev1 + 1))" "$rev2"
gh resume --token-file "$good" >/dev/null 2>&1
status_to "$out"
assert_eq "a repeated resume changes nothing" "$rev2" "$(jget "$out" revision)"
assert_eq "pause does not touch schedule .paused components" "" "$(find "$GHD/schedule" -name '*.paused')"

# --- the passive callers refuse while owned ----------------------------------
gh add daily other >/dev/null 2>&1 && t_fail "add should have refused" || true
gh init >/dev/null 2>&1 || true
before="$(tree_hash "$GHD/schedule")$(tree_hash "$GHD/out")$(tree_hash "$GHD/fired")"
for c in "tick" "init" "add daily blocked" "drop nudge" "sweep 0"; do
  rc=0; gh $c >/dev/null 2>"$out.e" || rc=$?
  assert_eq "'$c' on an owned instance fails 3" 3 "$rc"
  assert_contains "'$c' says why" "$(cat "$out.e")" "owned"
done
after="$(tree_hash "$GHD/schedule")$(tree_hash "$GHD/out")$(tree_hash "$GHD/fired")"
assert_eq "...and changed no schedule, out or fired entry" "$before" "$after"
assert_true "the item is still there" test -d "$GHD/schedule/daily/nudge"

# Ownership wins over pause for a standalone tick.
gh pause --token-file "$good" >/dev/null 2>&1
rc=0; gh tick >/dev/null 2>"$out.e" || rc=$?
assert_eq "paused and owned: tick fails 3 (ownership over pause)" 3 "$rc"
assert_eq "...and fires nothing" 0 "$(out_count)"

# The read-only commands keep working on an owned instance.
for c in due list lint out; do
  rc=0; gh $c >/dev/null 2>&1 || rc=$?
  assert_eq "'$c' still works while owned" 0 "$rc"
done

# --- release keeps the pause, advances the generation ------------------------
rc=0; gh release --token-file "$good" >/dev/null 2>&1 || rc=$?
assert_eq "release exits 0 with the runner stopped" 0 "$rc"
status_to "$out"
assert_eq "release removes the owner" null "$(jget "$out" owner)"
assert_eq "release leaves the pause" true "$(jget "$out" paused)"
assert_eq "release leaves the runner stopped" '"stopped"' "$(jget "$out" runner.state)"
for cmd in pause resume stop release run; do
  rc=0; gh $cmd --token-file "$good" >/dev/null 2>&1 || rc=$?
  assert_eq "the released token no longer authorizes $cmd (3)" 3 "$rc"
done

# Unowned but paused: standalone tick succeeds without firing.
rc=0; gh tick >"$out.o" 2>"$out.e" || rc=$?
assert_eq "unowned, paused: tick exits 0" 0 "$rc"
assert_eq "...fires nothing" 0 "$(out_count)"
assert_contains "...and says so on stderr" "$(cat "$out.e")" "paused"
assert_eq "...with nothing on stdout" "" "$(cat "$out.o")"
# init/add/drop/sweep are not pause-gated: they only refuse an owner.
rc=0; gh add daily later >/dev/null 2>&1 || rc=$?
assert_eq "unowned, paused: add still works" 0 "$rc"

new_token_path; second="$TOK"
rc=0; gh enroll --owner-label again --token-file "$second" >/dev/null 2>&1 || rc=$?
assert_eq "an unowned instance can be enrolled again" 0 "$rc"
status_to "$out"
assert_eq "the generation advances after release" 2 "$(jget "$out" owner.generation)"
assert_eq "the pause survives re-enrollment" true "$(jget "$out" paused)"
rc=0; gh pause --token-file "$good" >/dev/null 2>&1 || rc=$?
assert_eq "the first generation's token stays stale" 3 "$rc"
gh resume --token-file "$second" >/dev/null 2>&1
status_to "$out"
assert_eq "the new token controls the instance" false "$(jget "$out" paused)"

# --- release refuses an unresolved attempt -----------------------------------
mkdir -p "$GHD/runtime/deliveries" "$GHD/out/pending-d"
cat > "$GHD/runtime/deliveries/d-1.json" <<'JSON'
{"schema_version":1,"id":"d-1","path":"out/pending-d","origin":"runtime","state":"uncertain","attempts":[{"id":"a-1","started_at":"2026-11-15T00:00:00Z","finished_at":null,"outcome":"unknown"}]}
JSON
rc=0; gh release --token-file "$second" >/dev/null 2>"$out.e" || rc=$?
assert_eq "release with an uncertain attempt fails 5" 5 "$rc"
assert_contains "...and says ownership is retained" "$(cat "$out.e")" "retained"
status_to "$out"
assert_eq "...the owner is still there" 2 "$(jget "$out" owner.generation)"
rm "$GHD/runtime/deliveries/d-1.json"
cat > "$GHD/runtime/deliveries/d-1.json" <<'JSON'
{"schema_version":1,"id":"d-1","path":"out/pending-d","origin":"runtime","state":"accepted","attempts":[]}
JSON
rc=0; gh release --token-file "$second" >/dev/null 2>&1 || rc=$?
assert_eq "release succeeds once nothing is unresolved" 0 "$rc"

# --- unusable state fails closed ---------------------------------------------
new_instance
gh init >/dev/null
enroll_ok
cp "$GHD/runtime/state.json" "$T_TMP/state.good"
for bad in 'not json' '{"schema_version":2}' '{"schema_version":1,"paused":"yes"}' ''; do
  printf '%s' "$bad" > "$GHD/runtime/state.json"
  for c in "pause --token-file $TOK" "stop --token-file $TOK" "release --token-file $TOK" "tick" "add daily x" "sweep 0"; do
    rc=0; gh $c >/dev/null 2>&1 || rc=$?
    assert_eq "'${c%% *}' with state '$bad' fails 5" 5 "$rc"
  done
  assert_eq "...and the file was left as it was" "$bad" "$(cat "$GHD/runtime/state.json")"
  status_to "$out"
  assert_eq "status still reports it (consistent false)" false "$(jget "$out" consistent)"
done
new_token_path
rc=0; gh enroll --owner-label x --token-file "$TOK" >/dev/null 2>&1 || rc=$?
assert_eq "enroll over an unusable state fails 5" 5 "$rc"
assert_false "...and writes no token" test -e "$TOK"
cp "$T_TMP/state.good" "$GHD/runtime/state.json"
# A state bound to another instance directory is refused too.
sed 's#"instance":"[^"]*"#"instance":"/elsewhere/.groundhog"#' "$T_TMP/state.good" > "$GHD/runtime/state.json"
rc=0; gh tick >/dev/null 2>&1 || rc=$?
assert_eq "state bound to another instance: tick fails 5" 5 "$rc"
cp "$T_TMP/state.good" "$GHD/runtime/state.json"

# --- enroll failure codes ----------------------------------------------------
# 6: the token cannot be written, so no ownership.
new_instance
gh init >/dev/null
mkdir -p "$T_TMP/ro-tokens"
chmod 500 "$T_TMP/ro-tokens"
if [ -w "$T_TMP/ro-tokens" ]; then
  t_skip "directory permissions do not bind this user; skipping the unwritable-token case"
else
  rc=0; gh enroll --owner-label x --token-file "$T_TMP/ro-tokens/t" >/dev/null 2>"$out.e" || rc=$?
  assert_eq "token write failure: enroll exits 6" 6 "$rc"
  status_to "$out"
  assert_eq "...and grants no ownership" null "$(jget "$out" owner)"
fi
chmod 700 "$T_TMP/ro-tokens"

# 7: the owner record may have been replaced but a later sync failed.
if command -v perl >/dev/null 2>&1; then
  new_instance
  gh init >/dev/null
  mkdir -p "$T_TMP/failsync"
  cat > "$T_TMP/failsync/perl" <<SHIM
#!/bin/sh
# Test shim: fail the directory sync of runtime/ (the one after the owner
# replacement); pass everything else to the real perl.
for a in "\$@"; do last=\$a; done
case "\$last" in */runtime) echo "shim: injected sync failure" >&2; exit 1 ;; esac
exec "$(command -v perl)" "\$@"
SHIM
  chmod +x "$T_TMP/failsync/perl"
  new_token_path
  rc=0; PATH="$T_TMP/failsync:$PATH" gh enroll --owner-label x --token-file "$TOK" >"$out.o" 2>"$out.e" || rc=$?
  assert_eq "post-replacement sync failure: enroll exits 7" 7 "$rc"
  assert_true "...and the token file is retained" test -f "$TOK"
  assert_contains "...with advice to reconcile" "$(cat "$out.e")" "status"
  status_to "$out"
  tokj() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$TOK" "$1"; }
  assert_eq "reconciling: owner id matches the token metadata" "\"$(tokj owner_id)\"" "$(jget "$out" owner.id)"
  assert_eq "reconciling: generation matches" "$(tokj generation)" "$(jget "$out" owner.generation)"
  rc=0; gh pause --token-file "$TOK" >/dev/null 2>&1 || rc=$?
  assert_eq "the retained token works" 0 "$rc"
fi

# --- a busy mutation lock: exit 4 ---------------------------------------------
new_instance
gh init >/dev/null
enroll_ok
hold_lock "$GHD/runtime/locks/mutation.lock" 6
( rc=0; gh pause --token-file "$TOK" >/dev/null 2>"$out.e1" || rc=$?; echo "$rc" > "$out.r1" ) &
( rc=0; gh tick >/dev/null 2>"$out.e2" || rc=$?; echo "$rc" > "$out.r2" ) &
wait_for "both blocked commands gave up" 80 test -s "$out.r1" -a -s "$out.r2"
assert_eq "pause against a held mutation lock fails 4" 4 "$(cat "$out.r1")"
assert_eq "tick against a held mutation lock fails 4" 4 "$(cat "$out.r2")"
kill "$HOLD_PID" 2>/dev/null || true
wait "$HOLD_PID" 2>/dev/null || true
status_to "$out"
assert_eq "the busy commands changed nothing" false "$(jget "$out" paused)"

# --- the installer leaves an owned instance alone ----------------------------
mkdir -p "$T_TMP/host"
"$TEST_BASH" "$T_REPO_DIR/install.sh" "$T_TMP/host" >/dev/null 2>&1
new_token_path
"$TEST_BASH" "$T_TMP/host/.groundhog/groundhog.sh" enroll --owner-label inst --token-file "$TOK" >/dev/null 2>&1
before="$(cat "$T_TMP/host/.groundhog/runtime/state.json")"
rc=0; "$TEST_BASH" "$T_REPO_DIR/install.sh" "$T_TMP/host" >"$out.o" 2>"$out.e" || rc=$?
assert_eq "re-running the installer on an owned instance exits 0" 0 "$rc"
assert_contains "...and says it left it alone" "$(cat "$out.e")" "left untouched"
assert_eq "...and did not touch the runtime state" "$before" "$(cat "$T_TMP/host/.groundhog/runtime/state.json")"

# --- legacy behavior stays ---------------------------------------------------
new_instance
gh init >/dev/null
gh add daily nudge >/dev/null
rc=0; gh tick >"$out.o" 2>"$out.e" || rc=$?
assert_eq "legacy unowned tick exits 0" 0 "$rc"
assert_contains "...prints the firing line" "$(cat "$out.o")" "fired nudge ->"
assert_eq "...fires into out/" 1 "$(out_count)"
assert_eq "...says nothing on stderr" "" "$(cat "$out.e")"
assert_eq "...and leaves only lock state and the last-tick record under runtime/" "last_tick locks" "$(ls -A "$GHD/runtime" | tr '\n' ' ' | sed 's/ $//')"
assert_false "...no state file was created" test -e "$GHD/runtime/state.json"
rc=0; gh tick >"$out.o" 2>&1 || rc=$?
assert_eq "...a second tick the same day fires nothing" "" "$(cat "$out.o")"

t_finish
