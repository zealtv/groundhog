#!/usr/bin/env bash
# Scale: a tick holds the mutation lock while it looks for runs to start, so
# with many finished deliveries in out/ it must stay quick enough that other
# writers (pause, retry, add, a second ticker), which wait about three seconds
# for that lock, still get in. The records are written as fixtures.
. "$(dirname "$0")/lib.sh"

if ! have_handlers; then
  t_skip "this host cannot start runs"
  t_finish
  exit $?
fi

N=3000
new_instance; gh init >/dev/null
i=0
while [ "$i" -lt "$N" ]; do
  d="$GHD/out/done-$i"
  mkdir "$d"
  printf 'fired d-%04d 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/x\nstart a-%04d 2026-11-15T10:00:01Z tick\nexit a-%04d 2026-11-15T10:00:02Z 0\n' "$i" "$i" "$i" > "$d/.groundhog-record"
  i=$((i + 1))
done
mkdir "$GHD/out/zz-pending"
printf '#!/bin/sh\necho ran >> "$1/count"\n' > "$GHD/out/zz-pending/run"; chmod +x "$GHD/out/zz-pending/run"
printf 'fired d-9999 2026-11-15T10:00:00Z run 2026-11-15 - schedule/daily/zz\n' > "$(rec zz-pending)"

t0="$(python3 -I -c 'import time; print(time.time())')"
gh tick >/dev/null 2>&1
t1="$(python3 -I -c 'import time; print(time.time())')"
secs="$(python3 -I -c 'import sys; print("%.2f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$t0" "$t1")"
printf 'tick over %d finished deliveries: %ss\n' "$N" "$secs" >&2
if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.5 else 1)' "$secs"; then t_ok
else t_fail "a tick over $N finished deliveries takes under 1.5s" "took ${secs}s"; fi
wait_for "...and it started the one pending run among them" 50 exited zz-pending 1

# Writers that meet such a tick get the lock in time.
( gh tick >/dev/null 2>&1 ) &
tp=$!
assert_eq "pause during a tick over $N deliveries succeeds" 0 "$(rc_of gh pause)"
assert_eq "...as does resume" 0 "$(rc_of gh resume)"
wait "$tp" 2>/dev/null
assert_eq "no finished delivery was started again" 1 "$(rec_count zz-pending start)"
assert_eq "...nor any of the others" "$N" "$(find "$GHD/out" -name .groundhog-record -path '*/done-*' -exec cat {} + | grep -c '^start ')"

t_finish
