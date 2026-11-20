#!/usr/bin/env bash
# The atomic `add <when> <item-id> --from DIR` (capability add-from-v1): what it
# writes, every malformed call, a held lock, and a tick racing a stream of
# `--from` adds, standalone and from the `run` loop, which must never fire a
# partial item.
# test_runtime_gate.sh covers `add` on a host with no lock helper.
. "$(dirname "$0")/lib.sh"

if ! have_lock_helper; then
  t_skip "this host has no lock helper; see the no-helper case in test_runtime_gate.sh"
  t_finish
  exit $?
fi

out="$T_TMP/a.json"
rc_of() { local rc=0; "$@" >"$T_TMP/rc.out" 2>"$T_TMP/rc.err" || rc=$?; echo "$rc"; }
staged() { # how many entries sit under runtime/staging (0 when the directory is absent)
  find "$GHD/runtime/staging" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}
same_tree() { diff -r -x .groundhog-record "$1" "$2" >/dev/null 2>&1; }   # a delivery also holds its record

# A prepared payload: a nested directory, a dotfile, a few files and prompt.md.
PAYLOAD="$T_TMP/payload"
mkdir -p "$PAYLOAD/notes/deeper"
printf 'wake up\n' > "$PAYLOAD/prompt.md"
printf 'hidden\n' > "$PAYLOAD/.hidden"
printf 'one\n' > "$PAYLOAD/notes/one.txt"
printf 'two\n' > "$PAYLOAD/notes/deeper/two.txt"
PAYLOAD_SUM="$(tree_hash "$PAYLOAD")"

# --- the capability ---------------------------------------------------------------------
new_instance
gh capabilities --json > "$out"
assert_contains "capabilities lists add-from-v1" "$(jget "$out" capabilities)" '"add-from-v1"'

# --- plain add is as it was ------------------------------------------------------
gh init >/dev/null
p="$(gh add daily plain 2>"$T_TMP/e")"; rc=$?
assert_eq "plain add exits 0" 0 "$rc"
assert_eq "...prints the new path alone" "$GHD/schedule/daily/plain" "$p"
assert_true "...and makes an empty directory" test -d "$GHD/schedule/daily/plain" -a -z "$(ls -A "$GHD/schedule/daily/plain")"
assert_eq "...staging nothing" 0 "$(staged)"
assert_eq "plain add of an existing item exits 1" 1 "$(rc_of gh add daily plain)"
assert_eq "plain add with a bad <when> exits 1" 1 "$(rc_of gh add fortnightly x)"
assert_eq "plain add with a bad id exits 1" 1 "$(rc_of gh add daily 'bad id')"

# --- --from ---------------------------------------------------------------------
p="$(gh add daily/09 wake --from "$PAYLOAD" 2>"$T_TMP/e")"; rc=$?
assert_eq "add --from exits 0" 0 "$rc"
assert_eq "...prints the new path alone" "$GHD/schedule/daily/09/wake" "$p"
assert_true "...the item is the whole payload" same_tree "$PAYLOAD" "$GHD/schedule/daily/09/wake"
assert_true "...the dotfile came too" test -f "$GHD/schedule/daily/09/wake/.hidden"
assert_eq "...DIR is copied, not moved: it is intact" "$PAYLOAD_SUM" "$(tree_hash "$PAYLOAD")"
assert_eq "...nothing is left in staging" 0 "$(staged)"
assert_false "...and no state file was written" test -e "$GHD/runtime/state.json"
gh add once/2030-01-01/07-30 later --from "$PAYLOAD" >/dev/null
assert_true "a deeper <when> gets its parents made" same_tree "$PAYLOAD" "$GHD/schedule/once/2030-01-01/07-30/later"
gh add daily/ trailing --from "$PAYLOAD" >/dev/null
assert_true "a trailing slash on <when> is dropped, as plain add does" test -d "$GHD/schedule/daily/trailing"
assert_eq "the note about a shared id goes to stderr, the path alone to stdout" \
  "$GHD/schedule/daily/10/wake" "$(gh add daily/10 wake --from "$PAYLOAD" 2>"$T_TMP/e")"
assert_contains "...the shared-id note" "$(cat "$T_TMP/e")" "note:"
ln -s "$PAYLOAD" "$T_TMP/payload-link"
gh add daily viasym --from "$T_TMP/payload-link" >/dev/null
assert_true "a symlink to a directory works as DIR, and the item is a real copy" test ! -L "$GHD/schedule/daily/viasym" -a -f "$GHD/schedule/daily/viasym/prompt.md"
assert_true "...with the symlink's contents" same_tree "$PAYLOAD" "$GHD/schedule/daily/viasym"

# --- refusals change nothing ------------------------------------------------------
before="$(tree_hash "$GHD/schedule")"
assert_eq "--from an existing item exits 1" 1 "$(rc_of gh add daily/09 wake --from "$PAYLOAD")"
assert_eq "--from with a bad <when> exits 1" 1 "$(rc_of gh add fortnightly x --from "$PAYLOAD")"
assert_eq "--from with a bad id exits 1" 1 "$(rc_of gh add daily 'bad id' --from "$PAYLOAD")"
assert_eq "--from a directory that does not exist exits 2" 2 "$(rc_of gh add daily n1 --from "$T_TMP/nope")"
printf 'x' > "$T_TMP/afile"
assert_eq "--from a file exits 2" 2 "$(rc_of gh add daily n1 --from "$T_TMP/afile")"
assert_eq "--from an empty string exits 2" 2 "$(rc_of gh add daily n1 --from "")"
assert_eq "--from with no argument exits 2" 2 "$(rc_of gh add daily n1 --from)"
assert_eq "--from given twice exits 2" 2 "$(rc_of gh add daily n1 --from "$PAYLOAD" --from "$PAYLOAD")"
assert_eq "--from with an argument trailing exits 2" 2 "$(rc_of gh add daily n1 --from "$PAYLOAD" extra)"
assert_eq "--from= (not a form this script knows) exits 2" 2 "$(rc_of gh add daily n1 --from="$PAYLOAD")"
assert_eq "a stray third argument exits 2 rather than making an empty item" 2 "$(rc_of gh add daily n1 surprise)"
assert_eq "a stray third argument to plain add, with a trailing slash on <when>, exits 2" 2 "$(rc_of gh add daily/ n1 extra)"
assert_eq "plain add with two stray arguments exits 2" 2 "$(rc_of gh add daily n1 extra more)"
assert_eq "plain add with an empty third argument exits 2" 2 "$(rc_of gh add daily n1 "")"
assert_contains "a malformed call explains itself" "$(cat "$T_TMP/rc.err")" "error:"
assert_eq "none of those changed the schedule" "$before" "$(tree_hash "$GHD/schedule")"
assert_eq "...or left anything in staging" 0 "$(staged)"
assert_eq "...and DIR is intact" "$PAYLOAD_SUM" "$(tree_hash "$PAYLOAD")"

# --- a held mutation lock: exit 4, nothing lands, nothing stays staged ---------------------------
new_instance
gh init >/dev/null
mkdir -p "$GHD/runtime/locks"
hold_lock "$GHD/runtime/locks/mutation.lock" 120
( rc=0; gh add daily/09 busy --from "$PAYLOAD" >/dev/null 2>"$out.e1" || rc=$?; echo "$rc" > "$out.r1" ) &
( rc=0; gh add daily busyplain >/dev/null 2>"$out.e2" || rc=$?; echo "$rc" > "$out.r2" ) &
wait_for "both blocked adds gave up" 900 test -s "$out.r1" -a -s "$out.r2"
assert_eq "add --from against a held mutation lock exits 4" 4 "$(cat "$out.r1")"
assert_eq "plain add against a held mutation lock exits 4" 4 "$(cat "$out.r2")"
kill "$HOLD_PID" 2>/dev/null || true
wait "$HOLD_PID" 2>/dev/null || true
assert_false "the busy --from put nothing in the schedule" test -e "$GHD/schedule/daily/09/busy"
assert_false "the busy plain add made no directory" test -e "$GHD/schedule/daily/busyplain"
assert_eq "...and staged nothing, a failed add cleaning up after itself" 0 "$(staged)"
assert_eq "...and DIR is intact" "$PAYLOAD_SUM" "$(tree_hash "$PAYLOAD")"
assert_eq "once the lock is free the same add works" 0 "$(rc_of gh add daily/09 busy --from "$PAYLOAD")"

# A staging directory a crash left behind is inert, and later adds do not trip on it.
mkdir -p "$GHD/runtime/staging/add-1-1"; echo partial > "$GHD/runtime/staging/add-1-1/prompt.md"
assert_eq "an add beside a crashed one's leftover exits 0" 0 "$(rc_of gh add daily/12 after --from "$PAYLOAD")"
assert_true "...the leftover was not adopted: the item is the payload" same_tree "$PAYLOAD" "$GHD/schedule/daily/12/after"
rm -rf "$GHD/runtime/staging/add-1-1"

# --- a tick racing a stream of adds never fires a partial item ------------------------------------
# A big payload makes a copy slow enough for a tick to land in the middle of an
# unatomic add; prompt.md is written last, so a half-copied item lacks it. Each
# item is a `once` item, which fires on the next tick; a partial item would fire
# into out/ as a partial copy, which the comparison below catches.
BIG="$T_TMP/big"
mkdir -p "$BIG/files"
mkbig() { # FILES — (re)build BIG with that many files, prompt.md last
  rm -rf "$BIG"; mkdir -p "$BIG/files"
  local i=0; while [ "$i" -lt "$1" ]; do printf 'line %s\n' "$i" > "$BIG/files/f$i.txt"; i=$((i + 1)); done
  printf 'complete\n' > "$BIG/prompt.md"
}
mkbig 200
check_out_whole() { # N — out/ holds exactly N entries, each a whole copy of BIG
  local n="$1" d bad=0 count=0
  for d in "$GHD"/out/*; do
    [ -e "$d" ] || continue
    count=$((count + 1))
    same_tree "$BIG" "$d" || { bad=$((bad + 1)); printf 'partial or wrong item: %s\n' "$d" >&2; }
  done
  assert_eq "every fired item is the whole payload (none partial)" 0 "$bad"
  assert_eq "...and all $n items fired exactly once" "$n" "$count"
}
adder() { # N — add N items from BIG; writes the number of failed adds to $T_TMP/adder.fail
  # An add that finds the lock busy (exit 4, a tick copying a big payload) is retried,
  # as the contract tells a client; any other failure counts.
  local n="$1" i=1 fails=0 rc tries
  while [ "$i" -le "$n" ]; do
    tries=0
    while :; do
      rc=0; gh add once "item$i" --from "$BIG" >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 4 ] && [ "$tries" -lt 10 ] || break
      tries=$((tries + 1))
    done
    [ "$rc" -eq 0 ] || fails=$((fails + 1))
    i=$((i + 1))
  done
  echo "$fails" > "$T_TMP/adder.fail"
}

# standalone ticks
new_instance
gh init >/dev/null
N=20
rm -f "$T_TMP/adder.fail" "$T_TMP/ticked"
adder "$N" &
ADDER=$!
T_PIDS="$T_PIDS $ADDER"
ticks_fired_during=0
while kill -0 "$ADDER" 2>/dev/null; do
  if gh tick 2>/dev/null | grep -q '^fired '; then ticks_fired_during=$((ticks_fired_during + 1)); fi
done
wait "$ADDER" 2>/dev/null || true
gh tick >/dev/null 2>&1
assert_eq "no add of the stream failed" 0 "$(cat "$T_TMP/adder.fail")"
assert_true "ticks fired items while the adds were still streaming (the race was real)" test "$ticks_fired_during" -ge 1
check_out_whole "$N"
assert_eq "...and nothing is left in the schedule" 0 "$(find "$GHD/schedule/once" -mindepth 1 | wc -l | tr -d ' ')"
assert_eq "...or in staging" 0 "$(staged)"

# the run loop's ticks
new_instance
gh init >/dev/null
# The loop ticks once a second at best, so the copy must take a good part of a second to be caught.
mkbig 5000
N=12
rm -f "$T_TMP/adder.fail"
start_loop --interval-seconds 1
wait_for "the loop has ticked" 80 test -s "$GHD/runtime/last_tick"
adder "$N"
assert_eq "no add of the stream failed while the loop ticked" 0 "$(cat "$T_TMP/adder.fail")"
wait_for "all $N items fired" 400 out_is "$N"
kill -TERM "$LOOP_PID" 2>/dev/null
wait_exit "the loop exits on SIGTERM" 80 "$LOOP_PID"
check_out_whole "$N"
assert_eq "...and nothing is left in the schedule" 0 "$(find "$GHD/schedule/once" -mindepth 1 | wc -l | tr -d ' ')"
assert_eq "...or in staging" 0 "$(staged)"

t_finish
