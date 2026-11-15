#!/usr/bin/env bash
# Compatibility: every legacy command keeps its output and exit status. The
# expected text below was recorded from the script as it stood before
# `capabilities` and `status` were added (Groundhog main at 252b705).
. "$(dirname "$0")/lib.sh"
export TZ=UTC
set_clock "2026-11-15 12:00:00"

new_instance
mkdir -p "$GHD/out"
for w in daily/nudge weekly/sun/09/standup monthly/15/rent every/15m/beat once/2026-11-14/past yearly/11-15/anniv; do
  gh add "${w%/*}" "${w##*/}" >/dev/null
done
mkdir -p "$GHD/schedule/daily/held.paused" "$GHD/schedule/bogus/x" "$GHD/schedule/weekly.paused/mon/deep"

run() { echo "== $*"; gh "$@" 2>&1; echo "rc=$?"; }
actual="$(
  { run lint; run list; run due; run tick; run due; run out; run sweep 0; run out
    run drop nudge; run lint; run bogus; run add daily/99 q; run add weekly dup; } 2>&1 \
  | sed "s#$INST#ROOT#g"
)"

expected="$(cat <<'GOLDEN'
== lint
orphan: ROOT/.groundhog/schedule/bogus
1 orphan(s) found — these paths will not fire
rc=1
== list
├── bogus
│   └── x
├── daily
│   ├── held [paused]
│   └── nudge
├── every
│   └── 15m
│       └── beat
├── monthly
│   └── 15
│       └── rent
├── once
│   └── 2026-11-14
│       └── past
├── weekly
│   └── sun
│       └── 09
│           └── standup
├── weekly [paused]
│   └── mon
│       └── deep
└── yearly
    └── 11-15
        └── anniv
rc=0
== due
ROOT/.groundhog/schedule/daily/nudge
ROOT/.groundhog/schedule/weekly/sun/09/standup
ROOT/.groundhog/schedule/monthly/15/rent
ROOT/.groundhog/schedule/yearly/11-15/anniv
ROOT/.groundhog/schedule/once/2026-11-14/past
ROOT/.groundhog/schedule/every/15m/beat
rc=0
== tick
fired nudge -> ROOT/.groundhog/out/nudge-2026-11-15
fired standup -> ROOT/.groundhog/out/standup-2026-11-15
fired rent -> ROOT/.groundhog/out/rent-2026-11-15
fired anniv -> ROOT/.groundhog/out/anniv-2026-11-15
fired past -> ROOT/.groundhog/out/past-2026-11-15
fired beat -> ROOT/.groundhog/out/beat-2026-11-15-12-00
rc=0
== due
rc=0
== out
anniv-2026-11-15
beat-2026-11-15-12-00
nudge-2026-11-15
past-2026-11-15
rent-2026-11-15
standup-2026-11-15
rc=0
== sweep 0
rc=0
== out
anniv-2026-11-15
beat-2026-11-15-12-00
nudge-2026-11-15
past-2026-11-15
rent-2026-11-15
standup-2026-11-15
rc=0
== drop nudge
dropped nudge
rc=0
== lint
orphan: ROOT/.groundhog/schedule/bogus
1 orphan(s) found — these paths will not fire
rc=1
== bogus
error: unknown command 'bogus'
rc=1
== add daily/99 q
error: expected HH or HH-MM in 'daily/99'
rc=1
== add weekly dup
ROOT/.groundhog/schedule/weekly/dup
rc=0
GOLDEN
)"
assert_eq "lint, list, due, tick, out, sweep, drop, add: output and exit codes" "$expected" "$actual"

# The legacy read commands still create the instance directories (the new
# JSON commands must not; see test_readonly.sh).
new_instance
for cmd in due list out lint; do
  rm -rf "$GHD/schedule" "$GHD/out" "$GHD/fired"
  gh "$cmd" >/dev/null 2>&1 || true
  case "$cmd" in
    lint) assert_false "lint still creates nothing" test -e "$GHD/schedule" ;;
    *)    assert_true "$cmd still creates the trays" test -d "$GHD/schedule" -a -d "$GHD/out" -a -d "$GHD/fired" ;;
  esac
done

# Help lists the new commands alongside the old ones; exit status unchanged.
help="$(gh help)"
for c in init add tick due list lint drop out sweep "capabilities --json" "status --json"; do
  assert_contains "help mentions $c" "$help" "groundhog.sh $c"
done
rc=0; gh >/dev/null 2>&1 || rc=$?
assert_eq "no arguments still prints usage and exits 0" 0 "$rc"
rc=0; gh nonsense >/dev/null 2>&1 || rc=$?
assert_eq "unknown command still exits 1" 1 "$rc"

clear_clock
t_finish
