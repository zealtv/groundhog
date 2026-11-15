# 🦫 groundhog

A tiny, file-based protocol for recurring items.

The script remains passive: it materializes deliveries when explicitly ticked.
The [optional runtime contract](docs/runtime-contract.md) specifies supervision,
ownership, pause and consumer handoff. Bob accepted the design on 2026-11-15.
Of it, only the read-only inspection commands (`capabilities --json` and
`status --json`, see [Inspection](#inspection)) exist in this version; the
ownership, runner, pause and consumer commands remain **unimplemented**.
Groundhog works with or without AI. The accepted
design supports ordinary scripts through literal
argv, a documented cwd, an absolute delivery path and ordinary exit status. A
script can finish its work synchronously and exit 0; no SDK, queue, model or AI
account is required. Without a configured consumer, it remains delivery-only.

An *item* is a directory. Its position under `schedule/` is when it returns. Each time it's due, a fresh copy lands in `out/`.

When you open `.groundhog/schedule/`, you are looking at the things that come around again.

```
.groundhog/
  groundhog.sh
  schedule/
  out/
  fired/
```

## What groundhog is for

Some things should appear on a schedule. A weekly prompt. A monthly check. A daily nudge. The occasional one-shot reminder for a future date.

Groundhog holds the pattern. Each tick, anything due is copied into `out/`, ready to be picked up — by a hand, by an agent, by a script. A small note is left in `fired/` so groundhog remembers what it has already done.

What an item *is* is up to you. A directory of files. A single prompt. A payload to run. An empty directory whose mere appearance is the signal. Groundhog does not care what's inside.

Three folders, three roles: `schedule/` is what *should* happen, `fired/` is what *has* happened, `out/` is the tray for whatever picks the work up. There are no header fields, no metadata files, no state outside the file system.

## Structure

An item is a directory under a known schedule path.

```
.groundhog/
  schedule/
    daily/
      morning-nudge/
        note.md
    weekly/
      mon/
        09/
          standup-prompt/
            prompt.md
    monthly/
      1/
        rent-check/
          # contents are up to you
    yearly/
      03-15/
        anniversary/
    once/
      2026-04-25/
        follow-up/
    every/
      15m/
        heartbeat/
  out/
    morning-nudge-2026-04-25/
      note.md
    follow-up-2026-04-25/
    heartbeat-2026-04-25-09-15/
  fired/
    2026-04-25/
      daily/morning-nudge
      once/2026-04-25/follow-up
      every/15m/heartbeat/09-15
```

The path *above* the item is its schedule. The path table:

| Path under `schedule/`                  | Fires                                  |
|-----------------------------------------|----------------------------------------|
| `daily/<item>/`                         | every day                              |
| `daily/<HH>/<item>/`                    | every day at or after hour `HH`        |
| `daily/<HH-MM>/<item>/`                 | every day at or after `HH:MM`          |
| `weekly/<item>/`                        | every Monday (default)                 |
| `weekly/<dow>/<item>/`                  | weekly on `<dow>` (mon..sun)           |
| `weekly/<dow>/<HH>/<item>/`             | weekly at or after hour `HH`           |
| `weekly/<dow>/<HH-MM>/<item>/`          | weekly at or after `HH:MM`             |
| `monthly/<item>/`                       | the 1st of every month (default)       |
| `monthly/<dom>/<item>/`                 | monthly on day-of-month `<dom>`        |
| `monthly/<dom>/<HH>/<item>/`            | monthly at or after hour `HH`          |
| `monthly/<dom>/<HH-MM>/<item>/`         | monthly at or after `HH:MM`            |
| `yearly/<item>/`                        | Jan 1 each year (default)              |
| `yearly/<MM-DD>/<item>/`                | yearly on that date                    |
| `yearly/<MM-DD>/<HH>/<item>/`           | yearly at or after hour `HH`           |
| `yearly/<MM-DD>/<HH-MM>/<item>/`        | yearly at or after `HH:MM`             |
| `once/<item>/`                          | next tick, then source removed         |
| `once/<YYYY-MM-DD>/<item>/`             | one-shot on that date; source removed after firing |
| `once/<YYYY-MM-DD>/<HH-MM>/<item>/`     | one-shot at or after `HH:MM` on that date |
| `every/<N>m/<item>/`                    | every `N` minutes, anchored to 00:00   |
| `every/<N>h/<item>/`                    | every `N` hours, anchored to 00:00     |

Time is optional and always the innermost axis: bare `<HH>` (00..23) or `<HH-MM>` (e.g. `09-30`). They coexist — pick whichever reads better. `HH-MM` is forbidden directly under `yearly/` because it would collide with the `MM-DD` shape; if you want a yearly time, write the date out (`yearly/01-01/09-30/<item>/`).

Any path component may carry a `.paused` suffix to take that subtree off the schedule (`daily/foo.paused/`, `weekly/mon.paused/`, `once/2026-05-01.paused/`, even `weekly.paused/`). Toggle by rename: `mv schedule/daily/foo schedule/daily/foo.paused` and back. See Rule 6 below.

A past-dated one-shot with an inner `<HH-MM>` fires on the next tick regardless — the day is already gone, so the time is moot.

An item placed at the *root* of an axis fires on the first slot of the cycle: Mon for weekly, the 1st for monthly, Jan 1 for yearly. The exception is `once/<item>/`, which fires on the very next tick — a one-shot you don't have to date.

`every/` is the other exception. It has no canonical interval, so a bucket like `15m` or `3h` is required — `every/<item>/` on its own is rejected by `add` and flagged by `lint`.

## Rules

1. The schedule is the path. Move an item under `schedule/` to reschedule it.
2. Materialize by copy: a due item is `cp -r`'d to `out/<item-name>-<YYYY-MM-DD>/`. Sub-day items under `every/` extend the name with their slot: `out/<item-name>-<YYYY-MM-DD>-<HH-MM>/`, so multiple firings in a day don't collide.
3. Each firing is recorded by `touch fired/<YYYY-MM-DD>/<schedule-relative-path>` (with a slot suffix for `every/`). An occurrence with a marker will not fire again for that date and slot.
4. One-shots remove themselves from `schedule/once/<date>/` after firing.
5. Item contents are opaque. Groundhog only reads paths.
6. A `.paused` suffix on any path component excludes that subtree. `due` and `tick` skip it; `list` shows it tagged `[paused]`; `lint` accepts it. Pausing cascades — `weekly/mon.paused/` pauses every item beneath. A paused `once/<date>/` does not auto-fire and is not removed when its date passes; it fires on the next tick after unpause.

The file system is the protocol.

## Tick loop

1. Read every item directory at the expected depth under each schedule axis.
2. For each, decide whether today (and the current time, if `<HH>` or `<HH-MM>` is specified) matches its path.
3. If due and its schedule-relative marker under `fired/<today>/` does not exist: copy to `out/<item-name>-<today>/`, then touch that marker.
4. For each one-shot under `once/<past-or-today-date>/`, remove the source after firing.

`fired/` is groundhog's only memory. The path encodes the schedule; the journal encodes what's done. That's all the state groundhog needs.

## Catch-up

Missed days are missed. If a tick doesn't run on Monday, Monday's daily and weekly items are gone for that cycle — the next cycle brings fresh ones. Recurrence beats fidelity.

The same rule governs `every/`: missed sub-day slots are gone. A tick running mid-slot fires only that current slot, never backfilling earlier ones — the next slot is what matters.

One-shots wait. A `once/2026-05-01/<item>/` whose date has passed fires on the next tick regardless. A scheduled date should not be missed just because the tick was late.

### Short-month days

`monthly/29/`, `monthly/30/`, and `monthly/31/` only fire when that day-of-month actually exists. February has no 29..31 in non-leap years; April, June, September, and November have no 31. **There is no end-of-month fallback.** If you want "always the last day of the month," use `monthly/28/` (which exists every month) and accept the early trigger, or schedule the item explicitly with `once/<YYYY-MM-DD>/` entries generated for each month you care about. Keep the protocol simple; let the schedule express the truth.

### Intervals

`every/<N>m/` and `every/<N>h/` are calendar-orthogonal: they walk forward by `N` from 00:00 local each day. `every/15m/` fires at 00:00, 00:15, 00:30, …, 23:45. `every/3h/` fires at 00, 03, 06, 09, 12, 15, 18, 21.

When `N` doesn't divide evenly into the day, the last slot is short and the leftover is dropped — `every/7m/` walks 00:00, 00:07, …, 23:55 and the next slot (24:01) is past midnight, so it doesn't fire. Same spirit as the short-month rule: keep the protocol simple and let the schedule express the truth.

Each slot is journaled separately: `fired/<YYYY-MM-DD>/every/<bucket>/<item>/<HH-MM>`. To rearm a slot you accidentally tended, remove its marker (e.g. `rm .groundhog/fired/$(date +%Y-%m-%d)/every/15m/foo/14-30`).

### Daylight saving time

Groundhog reads local time and treats explicit times as "at or after" thresholds. On the spring-forward day, `daily/02/<item>/` can fire at a tick after the clock jumps to 03:00, provided a tick runs later that same day. On the autumn-back day, a marker already written for that date prevents a second firing during the repeated hour. Missed days still are not backfilled.

For `every/`, spring-forward skips slots that no tick observes. During fall-back, an already journaled date/slot does not fire again; the slot key does not distinguish the two occurrences of a repeated wall-clock time. Groundhog does not promise elapsed-time intervals across clock changes.

## Out

`out/` is a tray of fresh items. Groundhog does not know what consumes them. Pipe, move, watch, or ignore — the next reader is your concern.

* a hand: `mv .groundhog/out/* somewhere/`
* an agent: point its inbox at `out/` and let it tend
* a script: cron + tick + mv, in one line

A consumer can yoink items from `out/` immediately and the next tick will not re-deposit them — `fired/` remembers, not `out/`. If `out/` accumulates, that is a visible signal: items are being deposited but no one is collecting.

### Polling

Groundhog is passive — `tick` only fires when invoked. To bring the schedule to life, run `tick` on an interval. The simplest possible loop:

```
while sleep 60; do ./groundhog.sh tick; done
```

If you use minute-grained schedules (`<HH-MM>`), align the heartbeat to the wall-clock minute so items fire near `:00` of their target minute:

```
while :; do
  sleep $(( 60 - $(date +%s) % 60 ))
  ./groundhog.sh tick
done
```

Run it in a tmux pane, background it, or wrap it in launchd / systemd / cron — groundhog itself doesn't care. `sleep` is interruptible by Ctrl-C. `tick` already prints a line per firing, so piping the loop to a log gives you a free audit trail.

This single loop is the heartbeat for any system built on these protocols. Anything else that wants to "come alive" — a tender, an agent, a watcher — can be triggered by a groundhog item firing into its inbox.

## Fired

`fired/<YYYY-MM-DD>/<schedule-relative-path>` is an empty file recording that the item fired on that date. The marker mirrors the schedule subtree, so `weekly/sat/foo` and `monthly/25/foo` get distinct markers and neither is silently swallowed. Groundhog writes it; nothing else should. Three useful things fall out:

* **Idempotency**, even if the consumer takes items immediately.
* **History**: `find fired/2026-04-25 -type f` answers "what fired that day?" forever, regardless of whether the items have been collected.
* **One-shot trace**: when a `once/<date>/<item>/` self-deletes, its `fired/` marker is the only durable record that it ever existed.

To **rearm an item that already fired today** — say you accidentally tended it and want a fresh copy — remove its marker:

```
rm .groundhog/fired/$(date +%Y-%m-%d)/weekly/sat/foo
```

The next tick will refire it. Groundhog has no other override; the journal is the truth.

Old `fired/<date>/` directories are pruned by `sweep` on the same retention as `out/`.

## Vendoring

To add groundhog to another project, copy `groundhog.sh` and `README.md`
into the project's `.groundhog/` directory, then run
`./.groundhog/groundhog.sh init` to seed the trays:

```sh
mkdir -p <project>/.groundhog
cp groundhog.sh README.md <project>/.groundhog/
<project>/.groundhog/groundhog.sh init
```

`init` creates `schedule/`, `out/`, and `fired/` next to itself.
`groundhog.sh` operates on the `.groundhog/` directory it lives in, so
each vendored copy is self-contained.

## Commands

```
./groundhog.sh init
./groundhog.sh add <when> <item-id>     # mkdir under schedule/<when>/<item-id>/; you fill the contents
./groundhog.sh tick                     # fire any due items into out/
./groundhog.sh due                      # what would fire now (read-only)
./groundhog.sh list                     # tree-like view of schedule/
./groundhog.sh lint                     # report any orphaned paths walk_due will never see
./groundhog.sh drop <item-id>           # remove from schedule/
./groundhog.sh out                      # ls out/
./groundhog.sh sweep [days]             # remove out/ entries older than N days (default 14)
./groundhog.sh capabilities --json      # which runtime capabilities this script implements (read-only)
./groundhog.sh status --json            # one JSON snapshot of schedule, state and deliveries (read-only)
./groundhog.sh enroll --owner-label LABEL --token-file ABSENT_ABSOLUTE_PATH
./groundhog.sh run --token-file PATH [--interval-seconds N]   # foreground heartbeat (default 60)
./groundhog.sh pause|resume|stop|release --token-file PATH
```

`<when>` is the schedule path: `daily`, `daily/09`, `daily/09-30`, `weekly`, `weekly/mon`, `weekly/mon/09`, `weekly/mon/09-30`, `monthly`, `monthly/1`, `monthly/15/09`, `monthly/15/09-30`, `yearly`, `yearly/03-15`, `yearly/03-15/09-30`, `once`, `once/2026-05-01`, `once/2026-05-01/09-30`, `every/15m`, `every/3h`. A bare axis (`weekly`, `monthly`, `yearly`, `once`) takes the default slot. `every/` has no default — the bucket is required.

## Runner, ownership and pause

An instance can opt in to a supervised, foreground heartbeat. This is optional:
an instance that never runs `enroll` ticks exactly as before. The design is in
[docs/runtime-contract.md](docs/runtime-contract.md); this section records what
the script does and what it needs.

```
$ ./groundhog.sh enroll --owner-label my-session --token-file /private/dir/token
$ ./groundhog.sh resume --token-file /private/dir/token     # only if paused
$ ./groundhog.sh run --token-file /private/dir/token --interval-seconds 60
# from another terminal:
$ ./groundhog.sh pause --token-file /private/dir/token
$ ./groundhog.sh stop --token-file /private/dir/token
$ ./groundhog.sh release --token-file /private/dir/token    # then delete the token file
```

* **`enroll`** needs an unowned instance and an absent absolute `--token-file`
  outside the instance, in an existing private directory. It writes a fresh
  random token there (mode 0600, flushed to disk), then atomically replaces the
  owner record with the token's verifier. Exit 6 means failure before any owner
  was committed; exit 7 means the owner record may have been written, so keep the
  token and reconcile with `status --json`. The secret never goes into argv,
  `status` or any child's environment.
* **`run`** takes the runner lock for its lifetime, then repeats a cycle every
  interval: tick once (unless paused) and, in a later release, reconcile and hand
  off deliveries. It never enrolls and never clears the pause. A second `run`,
  even with the same token, exits 4. SIGINT, SIGTERM, SIGHUP and `stop` close
  admission, interrupt the sleep and exit 0, keeping ownership and pause. A
  failing tick ends the runner with exit 6 and a `runner.last_error`.
* **`pause`/`resume`** set the instance-wide pause (idempotently) under the
  mutation lock. Pause survives stop, restart, release and re-enrollment, and is
  independent of the `.paused` suffix on schedule components.
* **`stop`** records a request under the mutation lock, then waits, holding
  nothing, until the runner has released its lock. With no live runner it returns
  at once. **`release`** needs a stopped runner and no unresolved delivery
  attempt; it removes the owner and leaves the pause. The generation counter
  persists, so the next `enroll` issues generation + 1.
* **Standalone `tick`** fails 3 while the instance is owned (ownership wins over
  pause), succeeds without firing while paused, and otherwise ticks as always.
  `init`, `add`, `drop` and `sweep` also fail 3 while owned. All of them take the
  mutation lock and fail 4 if it stays busy for about three seconds.
* Exit codes of the new commands: 0 success, 2 invalid arguments or
  configuration, 3 ownership conflict or stale token, 4 busy, 5 unsupported or
  unusable state, 6 I/O failure, 7 enrollment outcome uncertain.

`status --json` reports the real `paused`, `owner` (id, generation, label; never
the verifier) and `runner` state, and `revision` rises with every protocol write.
A state file that still says `running` but whose recorded process is gone (a
crash) shows the runner as `unknown` with a `runner_not_observed` diagnostic;
status takes no locks and repairs nothing. The owner stays.

### Locks

Exclusion uses `flock(2)` advisory locks, so the operating system releases them
when the holder dies and no PID is ever consulted. Two lock files live in
`runtime/locks/` (created on first use, never deleted): `runner.lock`, held for a
runner's lifetime, and `mutation.lock`, held briefly by every writer. Order is
runner, then mutation.

bash cannot call `flock(2)` itself. The script opens the lock file on a numbered
descriptor in the shell (`exec 8>>runner.lock`, `exec 9>>mutation.lock`) and a
short-lived helper takes the lock on that inherited descriptor: `flock -n FD`
from util-linux when `flock --version` says so, otherwise
`perl -MFcntl=:flock` (perl ships with macOS). The lock belongs to the open file
description, so it stays held by the shell after the helper exits and goes away
when the shell exits, however it exits (checked with `kill -9`).

The catch: a child that inherits the descriptor keeps the lock alive after its
parent dies. The runner therefore starts its long-lived children (`sleep`
between cycles; later, consumers) with `8>&- 9>&-`. Short-lived tools such as
`cp` hold the descriptors for milliseconds.

**Requirements.** The runner commands and the three capabilities
`ownership-v1`, `runner-v1` and `pause-v1` appear only when the host has: a lock
helper (util-linux `flock` or perl with `Fcntl`); a SHA-256 tool (`sha256sum`,
`shasum` or `openssl`); `perl` with `IO::Handle` or `sync(1)` for durable writes;
`od` and `/dev/urandom`. Without them `capabilities` lists `status-json-v1` only,
`enroll`, `run`, `pause`, `resume`, `stop` and `release` exit 5 with a message,
and every legacy command works as before without taking any lock. Support is
single host, local filesystem; do not share an instance over a network
filesystem. On macOS `fsync` does not force the drive's write cache to the
platter.

Older copies of this script know nothing about the locks or the pause and can
bypass both. Stop other tick loops before enrolling an instance.

### State written under `runtime/`

`state.json` is replaced atomically (temp file in the same directory, fsync,
rename, fsync of the directory) with `revision` + 1. Besides the fields
`status` reads (`schema_version`, `revision`, `paused`, `owner`, `runner`,
`config_digest`) it records `instance` (the canonical directory; control refuses
a state bound to another directory), `last_generation`, the owner's
`token_verifier` (SHA-256 of owner id and token), and runner diagnostics (`id`,
`pid`, `start_id`, `stop_requested_for`). Diagnostics grant no authority. Unusable
state makes every control command exit 5 and is never overwritten; `status`
shows it with `consistent: false`.

## Inspection

`capabilities --json` and `status --json` are the machine-readable view of an
instance. Each prints one JSON object and a newline on stdout; diagnostics go to
stderr. They take exactly `--json` (anything else exits 2), and `status` needs the
script to sit in a `.groundhog/` directory (otherwise exit 2). Output is UTF-8;
human output from the other commands is not an API.

They are **strictly read-only**, even on an uninitialized instance: no
directories, lock files or markers are created, nothing is ticked, repaired or
overwritten, and payload contents are never read or evaluated (only directory
names are looked at). The `due`, `list`, `out` and other legacy commands keep
their behavior, including creating the trays.

```
$ ./groundhog.sh capabilities --json
{"protocol":"groundhog-runtime","protocol_version":1,"implementation_version":"dev","capabilities":["status-json-v1","ownership-v1","runner-v1","pause-v1"]}
```

`capabilities` lists only what this script implements on this host: `status-json-v1`
always, and `ownership-v1`, `runner-v1` and `pause-v1` where the locking tools
exist (see [Runner, ownership and pause](#runner-ownership-and-pause)). A client
needs all six capabilities in the contract before it may offer supervised
control, and `consumer-v1` and `delivery-v1` are not implemented yet. An older
script answers `capabilities` with its ordinary `unknown command` error (exit 1).

`status --json` follows the projection in the
[runtime contract](docs/runtime-contract.md#read-only-json-projection):

* `schedule` has one record per recognized item: its `path` (the identity,
  relative to the instance, so same-named items at different paths stay
  distinct), `item_id` (the last path component, verbatim), `paused_by` (the
  `.paused` components above or at the item), `eligible_now`, `fired_marker`,
  `fired`, `firing_allowed`, `blocked_by` and `cadence`. `eligible_now` and `fired_marker`
  come from the same `walk_due` and `fired_marker_for` that `tick` and `due` use,
  so they agree with `due` at any moment. `fired_marker` names the marker for
  the occurrence due right now and is `null` when none is. Paths the schedule
  grammar rejects are listed in `diagnostics` (the ones `lint` reports); an item
  that `tick` would nonetheless fire is also listed, because status says what
  `tick` would do.
* `cadence` is an additive, structured description of when the item recurs,
  taken from the components the schedule grammar matched (a client never parses
  `path`): `{"axis","day","date","time","interval","defaulted"}`, every key
  always present. `axis` is `daily`, `weekly`, `monthly`, `yearly`, `once` or
  `every`. `day` is `mon`..`sun` (weekly) or the day of month as a string such as
  `"15"` (monthly). `date` is `"MM-DD"` (yearly) or `"YYYY-MM-DD"` (once).
  `time` is local `"HH:MM"` (`09` reads `"09:00"`) or `null`. `interval` is
  `"15m"`/`"3h"` (every). Unused fields are `null`. `defaulted` is `true` when
  the axis root supplied the default: weekly `mon`, monthly `"1"`, yearly
  `"01-01"`, and once with `date: null` meaning the next tick. The whole object
  is `null` for an item that `tick` would fire but the grammar does not
  recognize. Paused items keep their cadence.
* `deliveries` lists the records under `runtime/deliveries/` plus, read-only,
  every other directory in `out/` as `origin: "legacy_out"`, state `pending`,
  reason `unregistered`, `id: null`. Status registers nothing.
* `owner`, `paused`, `revision`, `runner` and `consumer` come from
  `runtime/state.json` and `runtime/config.json` when they exist, and default
  (`owner: null`, `paused: false`, `revision: 0`, runner `stopped`, consumer not
  configured) when they do not. `enroll`, `run`, `pause`, `resume`, `stop` and
  `release` write `state.json`; nothing writes `config.json` or delivery records
  yet. Secrets (the owner token verifier, consumer argv and environment) are never
  printed.
* `consistent` is `false`, with `diagnostics`, when `state.json` or a delivery
  record is unreadable, malformed or of an unsupported `schema_version`, or when
  `state.json` changes while status reads it. An unusable `state.json` also
  shows the runner as `unknown`, owner `null`, and adds `invalid_state` to every
  item's `blocked_by`. A bad `config.json` only sets `consumer.valid: false`.
  Clients must refresh before acting. `observed_at` is UTC; schedule times use
  the local clock, as `tick` does.

Item names containing a tab or newline break `walk_due`'s own row format (as they
do for `tick`); status skips the fragments rather than inventing items.

## Tests

```
tests/run.sh                  # every test, under each bash found
tests/run.sh test_state.sh    # one test file
TEST_BASHES=/bin/bash tests/run.sh
```

`tests/run.sh` runs each `tests/test_*.sh` under macOS's stock `/bin/bash` 3.2
and under any newer bash installed (`/opt/homebrew/bin/bash`,
`/usr/local/bin/bash`, or `bash` on `PATH`). It needs `python3` to parse the JSON
output (the script itself uses no python) and optionally `jq`, which then parses
every document as a second opinion. Tests copy the script into temporary
directories under `$TMPDIR` and never touch a real schedule. To test a chosen
moment they put a `date` shim first on `PATH`, so the script needs no test hook.
The runner tests start real `run` processes in the background (own process group,
short `--interval-seconds`, bounded waits), prove the lock with Python's
`fcntl.flock`, and fail if a test leaves a runner behind. `test_runtime_gate.sh`
simulates a host with no lock helper. Hosts that lack the runner's tools skip the
runner tests.
New tests: add `tests/test_<area>.sh`, source `tests/lib.sh`, and finish with
`t_finish`.
