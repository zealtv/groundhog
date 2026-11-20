# 🦫 groundhog

A tiny, file-based protocol for recurring items.

An *item* is a directory. Its position under `schedule/` is when it returns. Each time it's due, a fresh copy lands in `out/`. If the item holds an executable `run`, the copy's `run` is then started, once, in a session of its own.

When you open `.groundhog/schedule/`, you are looking at the things that come around again.

```
.groundhog/
  groundhog.sh
  schedule/
  out/
  fired/
```

Groundhog is passive: nothing happens until something calls `tick` (or `run`, a plain loop of ticks). It works with or without AI: a `run` is any executable, with an absolute delivery path in `$1`, a documented cwd and environment, and an ordinary exit status. The machine-readable interface, protocol 2, is in [docs/runtime-contract.md](docs/runtime-contract.md).

## What groundhog is for

Some things should appear on a schedule. A weekly prompt. A monthly check. A daily nudge. The occasional one-shot reminder for a future date.

Groundhog holds the pattern. Each tick, anything due is copied into `out/`, ready to be picked up — by a hand, by an agent, by a script. A small note is left in `fired/` so groundhog remembers what it has already done.

What an item *is* is up to you. A directory of files. A single prompt. An empty directory whose mere appearance is the signal. Or a payload that says what to do with itself: an executable `run`, which Groundhog starts when the item fires (see [Runs](#runs)). Apart from `run` and the two files Groundhog writes into each delivery, it does not care what's inside.

Three folders, three roles: `schedule/` is what *should* happen, `fired/` is what *has* happened, `out/` is the tray for whatever picks the work up. All the state is in the file system: the paths, the markers in `fired/`, and one small record Groundhog writes into each delivery.

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
      .groundhog-record
    follow-up-2026-04-25/
      .groundhog-record
    heartbeat-2026-04-25-09-15/
      run
      .groundhog-record
      .groundhog-log
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
5. Item contents are the item's own, with three reserved names. An executable `run` is started for each delivery that holds one. `.groundhog-record` (the delivery's record) and `.groundhog-log` (its run's output) are Groundhog's: a firing replaces any copies the item brought. Nothing else inside an item is read.
6. A `.paused` suffix on any path component excludes that subtree. `due` and `tick` skip it; `list` shows it tagged `[paused]`; `lint` accepts it. Pausing cascades — `weekly/mon.paused/` pauses every item beneath. A paused `once/<date>/` does not auto-fire and is not removed when its date passes; it fires on the next tick after unpause.

The file system is the protocol.

## Tick loop

1. Read every item directory at the expected depth under each schedule axis.
2. For each, decide whether today (and the current time, if `<HH>` or `<HH-MM>` is specified) matches its path.
3. If due and its schedule-relative marker under `fired/<today>/` does not exist: copy to `out/<item-name>-<today>.landing/`, write the fresh record into the copy, rename it to `out/<item-name>-<today>/`, then touch that marker.
4. For each one-shot under `once/<past-or-today-date>/`, remove the source after firing.
5. Start every delivery in `out/` whose record says it has a `run` and never started (see [Runs](#runs)).

While the instance is paused, a tick does none of this. An item whose firing fails (a file the ticker cannot read, say) costs only itself: the tick warns on stderr, fires the rest, still starts the runs, and exits 1; `status` shows `firing_failed` for it until a tick fires it. A `run` that is present but not an executable file (no execute bit, a link that breaks once copied into `out/`) is warned about and the delivery is only delivered; `status` shows `run_not_executable`. `fired/` is what has fired; each delivery's record is what became of it.

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

`out/` is a tray of fresh items. An item with a `run` says itself what happens next; for the rest, Groundhog does not know what consumes them. Pipe, move, watch, or ignore — the next reader is your concern.

* the item: put an executable `run` in it
* a hand: `mv .groundhog/out/* somewhere/`
* an agent: point its inbox at `out/` and let it tend
* a script: cron + tick + mv, in one line

Anything can take items from `out/` immediately and the next tick will not re-deposit them — `fired/` remembers, not `out/`. If `out/` accumulates, that is a visible signal: items are being deposited but no one is collecting.

### Polling

Groundhog is passive — `tick` only fires when invoked. To bring the schedule to life, run `tick` on an interval. `./groundhog.sh run` is that loop, built in: it ticks every 60 seconds (`--interval-seconds N` to change it) until Ctrl-C, SIGTERM or SIGHUP, and exits 0. Ctrl-C, or a signal sent to the loop's pid alone, lets the tick in progress finish; SIGHUP or SIGTERM sent to the loop's whole process group (a closed terminal pane, a service manager stopping the group) cuts that tick short, which is as safe as a crash (see the crash table in the [runtime contract](docs/runtime-contract.md#crash-windows)). The simplest possible hand-made loop does the same:

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

`fired/<YYYY-MM-DD>/<schedule-relative-path>` is an empty file recording that the item fired on that date. Only the marker's existence means "fired". The marker mirrors the schedule subtree, so `weekly/sat/foo` and `monthly/25/foo` get distinct markers and neither is silently swallowed. Groundhog writes it; nothing else should. Three useful things fall out:

* **Idempotency**, even if something takes items out of `out/` immediately.
* **History**: `find fired/2026-04-25 -type f` answers "what fired that day?" forever, regardless of whether the items have been collected.
* **One-shot trace**: when a `once/<date>/<item>/` self-deletes, its `fired/` marker is the only durable record that it ever existed.

To **rearm an item that already fired today** — say you accidentally tended it and want a fresh copy — remove its marker:

```
rm .groundhog/fired/$(date +%Y-%m-%d)/weekly/sat/foo
```

The next tick will refire it, provided `out/` no longer holds that day's copy (otherwise the refire is a [collision](#output-name-collisions)). Groundhog has no other override; `fired/` is the truth.

Old `fired/<date>/` directories are pruned by `sweep` on the same retention as `out/`.


## Installing and upgrading

To install groundhog, copy the `.groundhog/` directory into the project. To
upgrade, run `./install.sh <host-dir>` from a groundhog checkout: it refreshes
`groundhog.sh`, `README.md` and `docs/`, runs `init` (which only creates
missing trays), and leaves `schedule/`, `out/`, `fired/` and `runtime/` alone.
The script is replaced by a rename, so a `run` loop or a run already going
keeps the old script until it is restarted.

`init` creates `schedule/`, `out/`, and `fired/` next to itself.
`groundhog.sh` operates on the `.groundhog/` directory it lives in, so each
copy is self-contained, and `groundhog.sh` is the only file the instance
needs; `README.md` and `docs/` are documentation.

`.groundhog/runtime/` holds machine-specific state: the lock files, the pause,
the last tick and any firing that failed. It belongs in the project's VCS
ignore list (for git, a `.groundhog/runtime/` line in `.gitignore`). So do the
contents of `out/` and `fired/`: a tracked `out/` carries each delivery's
record, and on another machine the next tick starts every pending `run` in it
(for git: `.groundhog/out/*` and `.groundhog/fired/*`, with `!.gitkeep` lines
to keep the trays). `install.sh` writes no ignore file.

Coming from protocol 1 (the owner, runner and consumer)? See
[Upgrading from protocol 1](#upgrading-from-protocol-1).

## Commands

```
./groundhog.sh init
./groundhog.sh add <when> <item-id> [--from DIR]  # mkdir under schedule/<when>/<item-id>/ (you fill it), or with --from copy a prepared DIR in with one rename
./groundhog.sh tick                     # fire any due items into out/, then start every run that is due to start
./groundhog.sh due                      # what would fire now (read-only)
./groundhog.sh list                     # tree-like view of schedule/
./groundhog.sh lint                     # report any orphaned paths walk_due will never see
./groundhog.sh drop <item-id>           # remove from schedule/
./groundhog.sh out                      # ls out/
./groundhog.sh sweep [days]             # remove out/ entries and fired/ dates older than N days (default 14), keeping runs that are pending or running
./groundhog.sh pause                    # stop firings and run starts for the whole instance
./groundhog.sh resume                   # undo pause
./groundhog.sh retry <delivery>         # start a delivery's run again, now
./groundhog.sh run [--interval-seconds N]  # tick every N seconds (default 60) until interrupted
./groundhog.sh capabilities --json      # which capabilities this script implements here (read-only)
./groundhog.sh status --json [--next-due]  # one JSON snapshot of schedule, pause and deliveries (read-only)
```

`<when>` is the schedule path: `daily`, `daily/09`, `daily/09-30`, `weekly`, `weekly/mon`, `weekly/mon/09`, `weekly/mon/09-30`, `monthly`, `monthly/1`, `monthly/15/09`, `monthly/15/09-30`, `yearly`, `yearly/03-15`, `yearly/03-15/09-30`, `once`, `once/2026-05-01`, `once/2026-05-01/09-30`, `every/15m`, `every/3h`. A bare axis (`weekly`, `monthly`, `yearly`, `once`) takes the default slot. `every/` has no default — the bucket is required.

Plain `add` makes an empty item directory that you fill afterwards, and a tick
between the two steps can fire the item half-made. **`add <when> <item-id>
--from DIR`** closes that race: it copies the prepared directory `DIR` (copied,
never moved) to `runtime/staging/` and renames it into the schedule under the
mutation lock, so a tick sees the item whole or not at all. Prepare the
payload, `run` included, before the call. It runs the checks plain `add` runs
(exit 1 for a bad `<when>` or `<item-id>` or an existing item), prints the new
path, and exits 2 for a malformed `--from` or extra arguments, 4 if the lock
stays busy.

`retry`, `pause`, `resume` and `run` exit 0 on success, 2 for invalid
arguments, 3 when refused by the pause (`retry` only), 4 when busy, 5 when
there is nothing to do or the host cannot do it, 6 on an I/O failure. The
schedule commands keep their old exit codes (1 for an error). Every writer
(`init`, `add`, `drop`, `sweep`, `tick`, `pause`, `resume`, `retry`) takes the
mutation lock and exits 4 if it stays busy for about three seconds.

## Runs

**An item that holds an executable `run` says what happens when it fires.**
Write the script, make it executable, and schedule the item:

```sh
./.groundhog/groundhog.sh add daily/09 report
cat > .groundhog/schedule/daily/09/report/run <<'SH'
#!/bin/sh
# $1 is this delivery, e.g. .../.groundhog/out/report-2026-05-01
./scripts/make-report.sh "$1" && mv "$1" archive/
SH
chmod +x .groundhog/schedule/daily/09/report/run
```

From 09:00, the first tick copies the item to `out/report-<date>/` and starts
that copy's `run`. Without an executable `run`, an item is only delivered, as
always.

**The record.** Every firing writes `.groundhog-record` into the `.landing`
copy before the rename into `out/`, so a delivery is never visible without it.
It is append-only, one line per event:

```
fired d-3f9c0a1b2c3d4e5f 2026-05-01T09:00:04Z run 2026-05-01 - schedule/daily/09/report
start a-77aa01b2c3d4e5f6 2026-05-01T09:00:04Z tick
exit a-77aa01b2c3d4e5f6 2026-05-01T09:00:31Z 0
```

The fired line comes first: a random delivery id, when, `run` or `none` (did
the item hold an executable `run`), the occurrence's date and slot (`-` outside
`every/`) and the schedule path. Each start has a fresh attempt id and says
who started it (`tick` or `retry`); each exit gives the status. A collision
adds a `collision` line (see [Output name collisions](#output-name-collisions)).
The exact format is in the [runtime contract](docs/runtime-contract.md#the-record).

**Any tick starts the runs that are due.** After its firings, every tick
looks at each delivery in `out/` and starts every one whose record says `run`
and has no start line. A tick that crashed after the rename, a Ctrl-C, a
laptop asleep at 09:00: the next tick, from any caller, starts it. A payload
put in `out/` by hand, or imported from elsewhere, has no record Groundhog
made, so it never runs.

**What `run` gets.** `$1` is the absolute path of its delivery; its cwd is the
project (the directory that holds `.groundhog/`); stdin is `/dev/null`;
stdout and stderr are appended to `.groundhog-log` in the delivery; and the
environment is the ticker's plus:

| Variable | Value |
|---|---|
| `GROUNDHOG_INSTANCE` | the instance's `.groundhog/` directory, canonical and absolute |
| `GROUNDHOG_DELIVERY_ID` | the delivery id from the fired line; the same for every attempt |
| `GROUNDHOG_ATTEMPT_ID` | this attempt's id from its start line |

**Exit 0 means "accepted", not "done".** Groundhog records the status and
nothing else. A `run` that hands its work to something else and exits 0 has
done its part; whether that work finished is for that something to say.

**The wrapper.** Each run starts through a small wrapper in a session of its
own (perl's `POSIX::setsid`, or `setsid(1)`), so Ctrl-C on a tick loop or a
closed terminal cannot reach it, and the tick moves on at once: a slow or hung
`run` stalls nothing. The wrapper holds the record's lock (`flock(2)` on
`.groundhog-record`) for as long as `run` lives, then appends the exit line.
`run` itself gets neither that lock nor the mutation lock. `$1` and the cwd
are spelled canonically, whatever path the ticker used to reach the
instance, so `$1` always lies under `$GROUNDHOG_INSTANCE`. A signal to the
wrapper alone waits for `run`; to stop a run, signal its process group, which
is the wrapper's pid (`kill -TERM -- -<pid>`): the exit line then records
`143`. A `run` killed by a signal records 128 plus its number; a `run` that is
gone records 127, one that is not executable 126. On the `setsid(1)` path
(a host without perl), a ticker that runs under bash 3.2, or was itself
started with SIGINT ignored, passes that ignored SIGINT on to `run`.

**States**, as `status --json` reports them from the record and its lock:

| State | Meaning |
|---|---|
| `delivered` | no `run`: delivered only |
| `pending` | a `run` that never started; the next unpaused tick starts it |
| `running` | the record's lock is held |
| `accepted` | the last attempt exited 0 |
| `failed` | the last attempt exited nonzero (`exit_status` says how) |
| `interrupted` | the last attempt has a start and no exit, and the lock is free |
| `unrecorded` | no record Groundhog made: put there by hand, imported, or a collision squatter |

**Interrupted is never re-run by itself.** A run whose wrapper died (a
`kill -9` of its session, a reboot) leaves a start with no exit and a free
lock. Groundhog cannot know how far it got, so it leaves it for you:
`retry` it, or delete it. `interrupted` means the wrapper is gone, not
necessarily `run`: after a `kill -9` of the wrapper's pid alone, `run` goes on
without the lock, and a `retry` would start a second copy beside it. Check
(`ps`, or the run's own traces) before retrying.

**`retry <delivery>`** starts the delivery's run again now, whatever its last
run did, as a new attempt under the same lock. `<delivery>` is the name in
`out/`, `out/<name>`, or the delivery's absolute path. It needs no token. It
exits 4 while the delivery is running (or another writer holds the mutation
lock; it tries the record's lock three times, 0.1 s apart, first), 3 while
the instance is paused, 5 when there is nothing to run (no
record Groundhog made, a `none` record, or the `run` is gone), 2 for anything
that is not a delivery of this instance. It returns once the run has started;
watch `status --json` for its end.

**For a `run`'s author.** A retry carries the same `GROUNDHOG_DELIVERY_ID` as
the first attempt: a `run` that skips a delivery id it has seen before skips
the retry too, and exits 0, which reads `accepted`. De-duplicate on the attempt
id, or only on success. And a host that ticks and then moves `out/*` away (a
hand-made loop feeding another tray) moves a delivery from under the run just
started for it: leave deliveries whose record says `run`, or let `run` do the
moving.

**Executing tracked files.** `schedule/` is usually under version control, so
a `git pull` or a clone can bring in a `run` that the next tick executes. Treat
a `run` like any other script in the repository. If an instance should not
execute anything new until someone has looked, `pause` it before pulling.

## Pause

`pause` stops the whole instance: while `runtime/paused` exists, a tick fires
nothing and starts nothing, and `retry` exits 3. Runs already going are left
alone and their exits are still recorded. `resume` removes the file. Both are
idempotent, need no token (anyone who can write the instance can pause it),
and take the mutation lock, so once `pause` returns no tick is half-way
through. A paused tick still counts for `last_tick`. Pause is separate from
the `.paused` suffix on schedule components, which takes a subtree off the
schedule.

## Sweep and dismissal

`sweep [days]` removes `out/` entries and `fired/` date directories whose
mtime is more than `days` (default 14) days old, and leftover `.landing`
copies. A delivery whose run is `pending` or `running` stays, whatever its
age, with a `skipped out <name> (<state>)` line. Failed and interrupted ones
age out like the rest.

To dismiss a delivery, delete it: `rm -rf .groundhog/out/<name>`. `fired/`
still remembers the occurrence, so it does not fire again.

## Locks and what the host needs

Exclusion uses `flock(2)` advisory locks, so the operating system releases them
when the holder dies and no PID is ever consulted. bash cannot call `flock(2)`
itself: the script opens the file on a numbered descriptor and a short-lived
helper takes the lock on it, util-linux `flock -n FD` when `flock --version`
says so, otherwise `perl -MFcntl=:flock` (perl ships with macOS). The lock
belongs to the open file description, so it stays with the shell, and with any
child that inherits the descriptor, until the last of them exits.

There are two kinds. `runtime/locks/mutation.lock` is held by every writer for
the length of its command, which serializes firings: on a host with a lock
helper, two tickers (cron and a loop, say) fire each occurrence exactly once.
Each delivery's `.groundhog-record` is the other: a tick or `retry` takes it to
write a start line and hands it to the wrapper, which holds it for the life of
`run`, so a delivery runs at most once at a time.

**Requirements.** Runs (capability `handlers-v1`) need a lock helper and a way
to start a session: perl with `POSIX`, else `setsid(1)`. On a host without
them, `capabilities` leaves out `handlers-v1`, a tick still fires and writes
records but starts nothing (it says so on stderr, and `status` shows
`handlers_unavailable`), and `retry` exits 5. Without a lock helper every
other command runs unlocked, as Groundhog always has, and `last_tick` is not
recorded. Support is single host, local filesystem; do not share an instance
over a network filesystem. Nothing is fsynced: a crash of a process is safe
at every step, but a power loss can lose a firing that had just happened.

## Upgrading from protocol 1

Protocol 1 ran deliveries through an owner, a runner and a consumer in
`runtime/config.json`. **Protocol 2 drops all of that, and the contract broke
on purpose.** A client tells them apart with `capabilities --json`:
`protocol_version` is `2`, and `handlers-v1` is the capability for runs. A
protocol 1 script answers `1` and lists `ownership-v1`; an older one still
answers `capabilities` with `unknown command` (exit 1).

Upgrade an instance in this order:

1. **Stop and release any protocol 1 runner** with the old script, while its
   commands still exist: `stop --token-file …`, then `release --token-file …`.
   A runner left going keeps the old script in memory and goes on handing
   `out/` to its consumer after the swap, while the new ticks start each item's
   `run`: the work would happen twice. Stop other tick loops and cron lines
   too.
2. **Carry a pause over by hand.** If the instance is paused (its
   `runtime/state.json` says `"paused":true`), create the file
   `.groundhog/runtime/paused` before installing. Protocol 1 ignores it and
   protocol 2 honours it from its first tick; otherwise the first tick from any
   caller fires what is due.
3. **Install with `install.sh`**, which replaces the script by a rename, not
   with a `cp` over the old file.
4. **Check `status --json`**, then resume ticking.

* **Gone:** `enroll`, token files, generations, `release`, `stop`,
  `sweep --token-file`, the consumer config, the delivery journal under
  `runtime/deliveries/` (and its `prepared/`, `done/` and `journal.gen`), the
  handoff barrier, `recover`, `discard` and `status --active`. Each of them now
  exits 1 (`unknown command`) or 2 (an unknown option).
* **Changed:** `pause` and `resume` take no token; `retry` takes a delivery,
  not `--token-file` and `--delivery`; `run` is a plain tick loop with no
  token; plain `tick`, `init`, `drop` and `sweep` work on every instance;
  `status --json` has no `owner`, `runner`, `consumer`, `revision`,
  `journal_generation` or `consistent`, and reports deliveries from their
  records.
* **Reversed:** "item contents are opaque" and "metadata beside, never
  inside". `run`, `.groundhog-record` and `.groundhog-log` are reserved names
  inside an item and a delivery. Check before upgrading that no item already
  holds an executable `run` that was not meant to be started.
* **Left alone:** `runtime/config.json`, `runtime/state.json` and
  `runtime/deliveries/` stay on disk, ignored. `status` flags the first two
  (`config_ignored`, `state_ignored`). A pause recorded in `state.json` no
  longer applies (step 2 above carries it over). Deliveries already in `out/`
  have no record and never run.
* **To move a consumer over:** put its per-delivery work in the item as `run`
  (it gets the same `$1` and the same three `GROUNDHOG_*` variables), delete
  `runtime/config.json`, and tick plainly from cron, a loop or `run`.

## Output name collisions

A firing lands in `out/<item-id>-<date>` (`-<HH-MM>` for `every/`). Groundhog
never overwrites an existing entry: the occurrence is marked fired and, for a
one-shot, the source is still removed, but no second delivery exists, so **the
later occurrence's `run` never runs**. Two firings can claim one name in these
ways:

| Case | Result |
|---|---|
| The same item id at two schedule paths, due the same day (`daily/09/foo` and `daily/17/foo`; `daily/foo` and `weekly/sun/foo`) | The first firing (in `due` order) is the delivery. The later one is marked in `fired/`, warned about on stderr, and appended as a `collision` line to the delivery's record, which `status` shows as an `out_collision` diagnostic. `lint` and `add` print a `note:` when an id exists at more than one path. |
| A one-shot and a recurring item with one id | Same, and the one-shot's source is removed even though it was never delivered: only the diagnostic and its marker remain. Keep one-shot ids unique. |
| The same id in two `every/` buckets (`every/1h/foo`, `every/30m/foo`) at a shared slot | Same as the first row. |
| An occurrence re-armed by deleting its marker while its entry is still in `out/` | Same: recorded, not delivered, `out_collision`; the delivery's run is not started again. |
| A tick that crashed between the rename and the marker | The next tick finds the occurrence's own delivery and records it as a collision with itself. Harmless: the delivery and its run are untouched. |
| A directory made by hand (no record) holds the name | The firing is marked and not delivered, with the stderr warning only: there is no record to carry the collision, and `status` lists the entry as `unrecorded`. |
| A non-directory (file, dangling symlink) holds the name | The same, and `status` lists the entry as `out_entry_not_directory`. |
| The same name on different dates | No collision: the date is part of the name. |

If two items must both deliver on one day, give them different ids.

## Inspection

`capabilities --json` and `status --json` are the machine-readable view of an
instance. Each prints one JSON object and a newline on stdout; diagnostics go to
stderr. They take exactly `--json` (`status` also takes `--next-due`); anything
else exits 2, and `status` needs the script to sit in a `.groundhog/` directory
(otherwise exit 2). Output is UTF-8; human output from the other commands is
not an API. The full projection is in the
[runtime contract](docs/runtime-contract.md#read-only-json-projection).

They are **strictly read-only**, even on an uninitialized instance: no
directories, lock files or markers are created, nothing is ticked, started or
repaired. Of a payload, only directory names and the delivery's own record are
read. To tell `running` from `interrupted`, `status` tests the record's lock,
taking a shared lock for an instant and letting it go, so readers never get in
each other's way; a tick that tries to start that delivery in that instant
finds it busy and leaves it to the next tick, and `retry` tries again.

```
$ ./groundhog.sh capabilities --json
{"protocol":"groundhog-runtime","protocol_version":2,"implementation_version":"dev","capabilities":["status-json-v2","next-due-v1","add-from-v1","pause-v2","handlers-v1"]}
```

`status --json` has `paused`, `last_tick` (`{"at", "source"}`, source
`standalone` for `tick` and `runner` for the `run` loop, or `null`), `schedule`
(one record per item, with `cadence`, `eligible_now`, `fired_marker`, `fired`,
`firing_allowed` and `blocked_by`, and `next_due` under `--next-due`),
`deliveries` (one per directory in `out/`, with its `state` and attempts) and
`diagnostics`. `next_due` is the UTC time at which the item's next unfired
occurrence begins, computed by asking the same `walk_due` that `tick` uses; the
item fires on the first tick at or after it.

Item names containing a tab or newline break `walk_due`'s own row format (as they
do for `tick`); status skips the fragments rather than inventing items.

## Tests

```
tests/run.sh                    # every test, under each bash found
tests/run.sh test_handlers.sh   # one test file
TEST_BASHES=/bin/bash tests/run.sh
```

`tests/run.sh` runs each `tests/test_*.sh` under macOS's stock `/bin/bash` 3.2
and under any newer bash installed (`/opt/homebrew/bin/bash`,
`/usr/local/bin/bash`, or `bash` on `PATH`). It needs `python3` to parse the
JSON output (the script itself uses no python) and optionally `jq`, which then
parses every document as a second opinion. Tests copy the script into
temporary directories under `$TMPDIR` and never touch a real schedule. To test
a chosen moment they put a `date` shim first on `PATH`, so the script needs no
test hook. `test_handlers.sh` covers the record, the wrapper and what `run`
gets, crashes and interrupts, and racing ticks; `test_retry.sh` covers
`retry`; `test_pause_sweep.sh` the pause, `sweep` and the `run` loop;
`test_scale.sh` a tick over 3,000 finished deliveries, which must stay quick
enough for other writers to get the lock;
`test_runtime_gate.sh` a host with no lock helper and, on Linux, the
`setsid(1)` path. Every run a test starts is a `/bin/sh` script that ends by
itself or is killed by its process group, and a test fails if it leaves a run
or a loop behind. Run them from a foreground shell: a loop started from a
background job of a non-interactive shell inherits an ignored SIGINT.
New tests: add `tests/test_<area>.sh`, source `tests/lib.sh`, and finish with
`t_finish`.
