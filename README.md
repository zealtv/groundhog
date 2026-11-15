# 🦫 groundhog

A tiny, file-based protocol for recurring items.

The script remains passive: it materializes deliveries when explicitly ticked.
The [optional runtime contract](docs/runtime-contract.md) specifies supervision,
ownership, pause and consumer handoff. Bob accepted the design on 2026-11-15.
This version implements all of it on hosts with the lock and process tools it
needs: the read-only inspection commands (`capabilities --json` and
`status --json`, see [Inspection](#inspection)); ownership, the runner and the
persistent pause ([Runner, ownership and pause](#runner-ownership-and-pause));
and the optional consumer, the delivery journal, `retry` and `recover`
([Consumers and deliveries](#consumers-and-deliveries)).
Groundhog works with or without AI. A consumer is a plain executable run with
literal argv, a documented cwd, an absolute delivery path and ordinary exit
status. A script can finish its work synchronously and exit 0; no SDK, queue,
model or AI account is required. Without a configured consumer, it remains
delivery-only.

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

To replace a loop like this with the supervised `run`, see
[Migrating from a tick loop](#migrating-from-a-tick-loop).

This single loop is the heartbeat for any system built on these protocols. Anything else that wants to "come alive" — a tender, an agent, a watcher — can be triggered by a groundhog item firing into its inbox.

## Fired

`fired/<YYYY-MM-DD>/<schedule-relative-path>` is a file recording that the item fired on that date. It is empty, except that when a supervised runner fires a one-shot it writes the one-shot's source generation (inode and mtime of the directory it copied) into the marker, so a later tick removes that source and never a replacement put there the same day (see *The journal* under [Consumers and deliveries](#consumers-and-deliveries)). Only the marker's existence means "fired". The marker mirrors the schedule subtree, so `weekly/sat/foo` and `monthly/25/foo` get distinct markers and neither is silently swallowed. Groundhog writes it; nothing else should. Three useful things fall out:

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
each vendored copy is self-contained. `groundhog.sh` is the only file the
instance needs; `README.md` is documentation (its link to
`docs/runtime-contract.md` points into this repository and dangles in a
vendored copy). `./install.sh <host-dir>` does the same copy and runs `init`.
Neither starts a runner, enrolls an owner or writes a configuration: see
[Deployment and migration](#deployment-and-migration).

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
./groundhog.sh retry --token-file PATH --delivery ID                    # failed -> pending
./groundhog.sh recover --token-file PATH --delivery ID --decision retry|accept
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
  interval: reconcile the delivery journal, tick once (unless paused), then hand
  off pending deliveries to the consumer, if one is configured (see
  [Consumers and deliveries](#consumers-and-deliveries)). It never enrolls and
  never clears the pause. A second `run`,
  even with the same token, exits 4. SIGINT, SIGTERM, SIGHUP and `stop` close
  admission, interrupt the sleep and exit 0, keeping ownership and pause; a
  consumer call in progress is detached, not killed. A failing tick ends the
  runner with exit 6 and a `runner.last_error`.
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
the verifier) and `runner` state, and `revision` rises with every write to
`state.json` (see [Change tokens](#change-tokens-revision-and-journal_generation)
for what it does and does not cover).
A state file that still says `running` but whose recorded process is gone (a
crash) shows the runner as `unknown` with a `runner_not_observed` diagnostic;
status takes no locks and repairs nothing. The owner stays.

### The runner's output streams

`run` writes its log lines (`groundhog: …`) to stderr and a `fired …` line to
stdout, and a consumer inherits both streams. **A supervisor should give `run`
stdout and stderr that outlive it, such as a regular file, not a pipe it may
close.** A supervisor that reads the runner's output through a pipe and then
exits (quits, crashes or is killed) leaves the runner and its consumer writing
into a pipe with no reader. The consumer, which runs with the default SIGPIPE
disposition, is then killed by SIGPIPE at its next write to the closed stream
and the delivery is recorded `failed`. With a regular file, a consumer
survives its supervisor's exit and its output stays readable.

The runner survives a closed pipe on its own side. It ignores SIGPIPE, treats
every log line and `fired` line as best-effort, and on the first failed write
points its own stdout and stderr at `/dev/null` (consumers it starts afterwards
inherit that), keeps running, and records `runner.last_error` with code
`output_lost` once. `runner.state` stays `running`; a later `stop` still exits
0 with state `stopped`, and the `output_lost` error remains in the state file
until the next `run` clears it. Nothing else changes: ticks, handoffs and the
recording of each consumer's result go on, but the runner no longer logs
anything. A consumer that was already writing to the closed pipe still dies of
SIGPIPE; that is the reason to prefer a file.

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
between cycles, and every consumer) with `8>&- 9>&-`. Short-lived tools such as
`cp` hold the descriptors for milliseconds.

**Requirements.** The runner commands and the three capabilities
`ownership-v1`, `runner-v1` and `pause-v1` appear only when the host has: a lock
helper (util-linux `flock` or perl with `Fcntl`); a SHA-256 tool (`sha256sum`,
`shasum` or `openssl`); `perl` with `IO::Handle` or `sync(1)` for durable writes;
`od` and `/dev/urandom`. Without them `capabilities` lists `status-json-v1` only,
`enroll`, `run`, `pause`, `resume`, `stop`, `release`, `retry` and `recover` exit
5 with a message, and every legacy command works as before without taking any
lock. `consumer-v1` and `delivery-v1` additionally need a way to start a consumer
in a session of its own: perl with `POSIX` (it ships with macOS), else
`setsid(1)`. Without that, the host lists the first four capabilities and `run`
refuses a configured consumer with exit 5. Support is
single host, local filesystem; do not share an instance over a network
filesystem. On macOS `fsync` does not force the drive's write cache to the
platter.

Older copies of this script know nothing about the locks or the pause and can
bypass both. Stop other tick loops before enrolling an instance.

### State written under `runtime/`

`.groundhog/runtime/` holds machine-specific state (absolute paths, the owner
label and the token verifier, delivery records, lock files). It belongs in the
project's VCS ignore list (for git, a `.groundhog/runtime/` line in
`.gitignore`); `install.sh` writes no ignore file.

`state.json` is replaced atomically (temp file in the same directory, fsync,
rename, fsync of the directory) with `revision` + 1. Besides the fields
`status` reads (`schema_version`, `revision`, `paused`, `owner`, `runner`,
`config_digest`) it records `instance` (the canonical directory as the file
system spells it, found with the external `/bin/pwd -P`; see below),
`last_generation`, the owner's
`token_verifier` (SHA-256 of owner id and token), and runner diagnostics (`id`,
`pid`, `start_id`, `stop_requested_for`). Diagnostics grant no authority. Unusable
state makes every control command exit 5 and is never overwritten; `status`
shows it with `consistent: false`.

The `instance` binding exists to protect tokens, so it matters only while the
instance is owned. A released instance that has moved (or was reached by another
spelling of its path) simply ignores the stale binding, and the next state write
records the current directory. An owned instance whose state names another
directory fails closed: `tick`, `add`, `drop`, `sweep` and `enroll` exit 5, and `status --json` reports `consistent: false` with the
diagnostic `state_bound_elsewhere`. (A token file names the directory too, so a
command that reads the old token file stops at the foreign-token check, exit 3,
before it reads the state.) Offline repair, with no runner running: edit
`instance` in `runtime/state.json` and in the token file to the directory
`status` now reports. Moving the project back also works.

The runner's recorded `start_id` is a process start time in UTC with the C locale,
so `status` reads the same value from any `TZ`; a runner started by a copy of
this script from before that change shows `runner_not_observed` until it is
restarted.

### Change tokens: `revision` and `journal_generation`

`status --json` carries two numbers a client can compare between reads to learn
whether anything changed. They cover different files, and neither covers
everything. These readings describe this implementation, as of the change that
added `journal_generation`:

* **`revision`** is the `revision` in `runtime/state.json`. It rises by one with
  every write of that file: `enroll`, `run` (start and stop), `pause`, `resume`,
  `stop`, `release`, and the runner recording `last_error`. It covers ownership,
  pause, the runner's state and error, and the configuration digest. It does
  **not** move when a delivery record changes (admit, record, `retry`,
  `recover`, a firing, reconciliation, filing under `done/`, `sweep`), when
  `config.json` is edited, or when the schedule, `fired/` or `out/` change by
  hand or by a plain `tick`.
* **`journal_generation`** is the number in `runtime/journal.gen` (0 when the
  file is absent), an additive field on the status object. Every write to the
  delivery journal moves it, each write in two steps: odd while the write is in
  progress, even again once it is done. The writes it covers: delivery records
  (admission of an attempt, recording its result, marking a path missing,
  reconciliation fixes, imports of legacy `out/` entries, `retry`, `recover`, the
  runner's finalization of an in-flight attempt, and the `out_collision` the
  standalone tick attaches to a record); a firing (prepared record, `out/` entry,
  marker, delivery record, prepared record removed, as one bracket);
  completing, discarding or setting aside a prepared firing in reconciliation;
  the move of a settled record under `done/`; and the removal of records by
  `sweep`. It does **not** cover `done/index` (a cache of what the records say;
  rewriting it changes nothing `status` prints), `config.json`, `state.json`,
  the schedule, `fired/` or `out/` outside a firing, or the contents of any
  payload.
* A client that wants "anything protocol-visible changed" compares both numbers
  and the `consistent` flag; a number alone says nothing about the other file.
  Both are observations: equal numbers across two reads say no write went by
  between them (as far as these files go), not that a later write will not.
  After a power loss `journal.gen` can read as an older value; compare it for
  equality with what you last saw, never for order across a restart of the
  machine.

`status` takes no lock. It reads `journal.gen` before and after its pass and
reports `consistent: false` when:

* the number changed between the two reads (`journal_changed_during_read`);
* the number is odd, so a journal write is in progress or an earlier one did not
  finish (`journal_write_in_progress`). A crash can leave it odd; the next
  command that takes the mutation lock (any control command, `tick`, `sweep`, a
  runner start) settles it, because holding the lock means no writer is alive;
* the file is not a readable number (`journal_generation_unreadable`); the next
  journal write replaces it.

Each diagnostic names `runtime/journal.gen`, and a client refreshes before acting,
as for any `consistent: false`. The existing check on `state.json` stays.

A firing creates its `out/` entry before its delivery record. While it runs the
prepared record names that path, so `status` does not list the entry as an
unregistered `legacy_out` delivery (it lists no delivery for it yet, and the
generation is odd, so the read is `consistent: false` anyway). A prepared record
left by a crash keeps its entry out of the unregistered list until the next `run`
completes or discards it.

## Consumers and deliveries

A *delivery* is one directory in `out/`. A *consumer* is whatever you configure
to receive deliveries: any executable or script, with or without AI. Nothing is
discovered: a `consume.sh` lying around, in an instance or inside a payload,
enables nothing. Only an explicit `runtime/config.json` does.

```json
{
  "schema_version": 1,
  "consumer": {
    "argv": ["/bin/sh", "/example/project/copy-note.sh"],
    "cwd": "..",
    "env": {"EXAMPLE_QUEUE": "demo"}
  }
}
```

* `argv` is a nonempty array of literal strings. Element zero must be an
  absolute path to an existing executable file. A script that is not executable
  works with an explicit interpreter as above. There is no shell expansion and
  no PATH search.
* `cwd` is required, resolved relative to the canonical instance directory
  (`..` is the project containing `.groundhog/`), and must exist.
* `env` (optional) is a map of strings. Names must be plain identifiers, and the
  three reserved names below are refused.

`run` reads and validates the file before it ticks anything, and freezes it for
the runner's lifetime (a change needs `stop` and `run`). An invalid file,
a missing executable or cwd, or a reserved name makes `run` exit 2 with the
reason on stderr and ticks nothing; `status` shows `consumer.valid: false` and a
`consumer_config_invalid` diagnostic. That differs on purpose from having no
file: with no `config.json`, `run` still ticks and registers deliveries as
`pending` with reason `no_consumer`, and invokes nothing. An unowned standalone
`tick` never invokes a consumer even when a config exists.

**Invocation.** The runner executes `argv` plus one extra argument: the
canonical absolute delivery directory. The consumer starts in `cwd`, with stdin
from `/dev/null`, with the runner's environment, then the `env` map, then:

```
GROUNDHOG_INSTANCE=/absolute/project/.groundhog
GROUNDHOG_DELIVERY_ID=d-…
GROUNDHOG_ATTEMPT_ID=a-…
```

The owner token and the token file's path never reach it. It inherits no lock
descriptor, so a consumer that outlives a crashed runner cannot hold the runner's
locks. `argv`, `env` and the consumer's output never appear in `status`;
stdout and stderr go to the runner's own streams. The consumer runs with the
default SIGPIPE disposition, although the runner itself ignores SIGPIPE (see
[The runner's output streams](#the-runners-output-streams)).

**Its own session.** A consumer must survive Ctrl-C on the runner's terminal.
bash 3.2 on macOS has no `setsid(1)`, so the runner starts the consumer through
`perl -MPOSIX -e 'POSIX::setsid(); exec …'` when perl has `POSIX`, which is the
case wherever perl is already the lock helper. The consumer becomes leader of a
new session and process group (its pgid equals its pid) and replaces perl by
`exec`, so the pid the runner waits on is the consumer's. The same step restores
SIGINT and SIGQUIT, which a background job of a non-interactive shell inherits
as ignored. Where perl lacks `POSIX`, `setsid -w` is used if present (untested
here, since this was built on macOS); with neither, the host does not offer
`consumer-v1`. `tests/test_delivery.sh` checks the separate group and that a
SIGINT to the runner's group leaves the consumer running.

**Acknowledgement.** Exit status 0 is the whole acknowledgement. It means the
consumer accepted responsibility before returning: either it finished
synchronous work, or it durably accepted asynchronous work (starting a process is
not durable acceptance). The delivery becomes `accepted` and stays in `out/`
unchanged. Any other status, a signal or a failure to start becomes `failed` with
the exit code and a structured error. bash reports a signal death as 128 plus the
signal number, and a script can exit with such a number itself, so the record
carries the status as `exit_code` and, for 129 to 159, also the `signal` name with
a message that says both readings are possible. A consumer that cannot be started
exits 126 or 127, with its reason on stderr, likewise ambiguous with a script that
returns them. `execution` stays `unknown` in every case: Groundhog records the
handoff, not whether the work succeeded. Groundhog never retries by itself and
promises no exactly-once effects; consumers deduplicate on `GROUNDHOG_DELIVERY_ID`.

**The journal.** Delivery records live in `runtime/deliveries/<id>.json`, one
file per delivery, each replaced atomically. The runner's firings are journaled:
a prepared record (`runtime/prepared/<id>.json`) naming the schedule path,
fired marker, occurrence and the original source's identity (inode and mtime)
is written first; the item is copied into `runtime/staging/<id>/`, renamed
into `out/`, marked in `fired/`, recorded as a pending delivery, and only then
is the prepared record removed. Each step can be redone or finished by the next
`run`. The `.landing` names of the passive tick never appear for these.
Standalone `tick` keeps its legacy behavior.

A fired one-shot's marker records the source generation, and the journaled tick
removes a one-shot whose marker exists only if its directory still has that
generation. Say a crash left the marker without the removal and the operator then
put a new `schedule/once/<item>/` in place the same day: the recovery step and
every later tick leave the replacement alone (the runner logs it once). A marker
without a recorded generation (the standalone tick's, or one written before this
was recorded) keeps the legacy rule, so its one-shot is removed. The standalone
tick itself is unchanged.

**Terminal records and the lock (implementation reading).** Not part of the
accepted contract's interface; `status --json` shows the same deliveries as
before. A delivery that is `accepted` or `missing` never changes again, so the
runner files its record under `runtime/deliveries/done/<id>.json` on a later
cycle (a rename; `retry`, `recover`, `sweep` and `release` look in both
directories). Next to those files sits `done/index`, a cache the runner
writes: per filed record, the inode, size, mtime and mode the file had when the
runner last read it, and the JSON `status` prints for it. This keeps the cost of a
cycle, of `release` and of `status` from growing with every settled delivery:

* A cycle lists `done/` with one `find` and one `stat`. A record whose signature
  matches the index is trusted without being parsed; any other (new, edited,
  replaced, or with a changed mode) is parsed. An unchanged listing costs
  nothing more. Records that carry `out_collision` entries are never cached, so
  status always re-reads them.
* The barrier still fails closed. A file in `done/` that cannot be read, is not
  a terminal record (for example an `in_flight` one filed there by hand), or also
  exists in `deliveries/` blocks every consumer admission and shows in `status`
  as `delivery_record_unreadable` or `delivery_record_malformed`, like an
  unreadable record in `deliveries/`. The runner does not re-parse a filed record
  on every cycle, so an in-place edit that leaves the inode, size, mtime (to the
  second) and mode as they were goes unseen until `done/index` is removed or the
  record is replaced; any atomic rewrite changes the inode.
* The index is only a cache: delete it and the next `status` or `run` reads every
  record once and, for `run`, writes it again. Deleting records (retention) is
  not part of this layout; `sweep` still refuses while an owner exists.
* A runner is the only writer of delivery records while it lives, so it reads
  them without the mutation lock and takes the lock only to write: in slices of
  about a second, each followed by a short pause for `pause`, `stop`, `retry` or
  `recover` to take it, each record re-read before it is changed. The first
  cycle after an upgrade files the existing accepted and missing records the same
  way; a runner stopped during it finishes the job on the next run. Pending,
  failed, in-flight and uncertain records stay in `deliveries/` and are read every
  cycle, so a journal that accumulates those (for example `pending` with reason
  `no_consumer`) still costs time per cycle, though no longer lock time.
* The order of `deliveries` in `status --json` follows the files (live records,
  then filed ones); delivery ids are random, so the order carried no meaning
  before either.

A name in `out/` or `schedule/` that is not valid UTF-8 (possible on Linux; APFS
refuses it) cannot round-trip through a record, so it would have been imported
again every cycle. The runner now leaves such a schedule item unfired
and such an `out/` entry unimported (the standalone `tick` is unchanged); `status` does not list the entry as a
delivery and reports `out_entry_name_not_utf8` or `schedule_name_not_utf8` instead.

**Serial handoff.** One consumer call at a time per instance, across stop,
crash and restart:

1. under the mutation lock the runner checks the token, a stop request, the
   pause, and the barrier below, picks the oldest pending delivery, and writes an
   attempt as `in_flight` durably;
2. it releases the lock and starts the consumer (so `pause`, `stop` and the
   status commands never wait for a running consumer; `status` takes no locks);
3. it takes the lock again and records `accepted` or `failed`.

A slow consumer delays only its own instance's later cycles; cycles never
overlap, and missed slots are skipped, not queued. A paused instance admits no
new handoff (pending stays pending); a call admitted before the pause finishes
and records.

**The barrier.** While any attempt is `in_flight`, or any delivery is
`uncertain`, or any delivery record cannot be read, the runner admits no
consumer call at all: not for other deliveries, not under a new configuration.
Ticks still register new deliveries meanwhile (they wait as pending).

**Crash and shutdown.** If the runner dies between step 1 and step 3 (`kill -9`,
power loss), the record stays `in_flight` with an unknown outcome; `status` shows
it as such and repairs nothing. The next `run` reconciles it to `uncertain`
without replaying it. SIGINT, SIGTERM and `stop` do not kill the consumer: they
close admission, detach and leave the delivery `uncertain` with the error code
`consumer_detached`. Nothing reports `accepted` merely because a shutdown
succeeded. A consumer never gets killed by Groundhog.

**`retry` and `recover`** both need the token and a stopped runner (a live one
makes them exit 4), and both write the record durably before they return.

* `retry --delivery ID` turns a `failed` delivery `pending` (same delivery ID;
  history kept; the next admission makes a new attempt). Retrying a `pending`
  delivery changes nothing. Any other state exits 5. If the failed handoff might
  have had side effects, reconcile them first.
* `recover --delivery ID --decision accept|retry` settles an `uncertain` (or
  abandoned `in_flight`) delivery. First establish by your own means that the
  original consumer call has finished; a lock, a dead runner or a missing pid
  proves nothing. `accept` records the delivery as `accepted` on your say-so,
  `retry` makes it `pending`. The decision and its time go on the attempt, whose
  outcome stays `unknown`. Recovery invokes nothing. Another unresolved attempt
  keeps the barrier up.

`release` exits 5 while any attempt is unresolved or any record unreadable.

**Reconciliation on `run`**, under the mutation lock, at the start of each cycle
and whatever the pause says:

* an interrupted firing is completed, or discarded when nothing was exposed
  (and refired if still due); evidence that conflicts (a fired marker but no
  `out/` entry, or an unreadable prepared record) is set aside as
  `runtime/prepared/<id>.blocked`, reported by `status` as
  `firing_reconciliation_error`, and its occurrence is not fired again;
* abandoned `in_flight` attempts become `uncertain`;
* complete `out/` directories without a record become `pending` deliveries with
  `origin: legacy_out` and an unknown occurrence, ignoring `*.landing`; this
  imports metadata only and never implies a handoff;
* pending deliveries whose path vanished become `missing`, never recreated;
* an `out/` name that already exists when an occurrence fires follows the legacy
  no-overwrite rule (the firing is recorded, one-shots are still removed), no
  second delivery is invented, and the existing delivery's record carries an
  `out_collision` that `status` reports.

One compatibility note: a one-shot whose fired marker already exists is still
removed by the next tick, as in the legacy script; the source-identity check
only protects the runner's own recovery from deleting a replacement.

**`sweep` on a supervised instance** (one with delivery records or `state.json`)
keeps every out entry whose delivery is pending, failed, in flight or
uncertain, and every unregistered entry, plus the `fired/<date>/` directories
their markers live in, and reports each as `skipped`. Accepted entries leave
together with their record; a record whose path is already gone leaves once it is
old enough, as do terminal `missing` records. An unreadable record stops the
sweep before it removes anything. An instance with no runtime state sweeps
exactly as before.

## Deployment and migration

Written for operators on 2026-11-15, from the behavior this repository's tests
exercise (`tests/test_e2e.sh` walks the paths below on scratch instances). The
runtime is optional and opt-in per instance. Nothing in this script, in
`install.sh` or in an upgrade enables it for an instance that did not ask.

### Tick-only installations keep working

An instance that never runs `enroll` has no owner, no pause and no runner, and
behaves as before: `tick` copies what is due into `out/` and records it in
`fired/`, with the same names, markers and one-shot removal. The new script
differs for such an instance in a few small, visible ways:

* `tick`, `init`, `add`, `drop` and `sweep` take a short mutation lock, which
  creates `.groundhog/runtime/locks/` (two empty lock files) on first use. They
  create no other runtime file: no `state.json`, no `config.json`, no delivery
  records.
* `help` lists the new commands. `lint` and `add` print a `note:` on stderr when
  an item id exists at more than one schedule path (see
  [Output name collisions](#output-name-collisions)); their stdout and exit codes
  stay the same. `list` no longer fails under bash 3.2 when an item directory has
  no subdirectories.
* `capabilities --json` and `status --json` read the instance without writing
  anything and work before `init`.

No old consumer, tick loop or cron line needs a change. Nothing is discovered:
a `consume.sh` in an instance or a payload enables nothing, and `run` refuses
to start without a token from an explicit `enroll`.

### Opting one instance in

Do this per instance, deliberately; discovery or an upgrade never does it for
you.

1. **Check the host.** `./groundhog.sh capabilities --json` should list all six
   capabilities (`status-json-v1`, `ownership-v1`, `runner-v1`, `pause-v1`,
   `consumer-v1`, `delivery-v1`). Without the last two the instance can still be
   owned, paused and run delivery-only.
2. **Stop whatever else writes to the instance.** Other `tick` loops, cron lines,
   and any process that moves entries out of `out/` (see the next section). An
   older copy of the script, or a loop calling it, knows nothing about the lock,
   the owner or the pause and can bypass all three.
3. **Choose where the token lives.** A private directory outside the instance,
   for example `~/.config/<your-supervisor>/session/`. The token file is the
   whole credential: whoever can read it controls the instance.
4. **Enroll.** `./groundhog.sh enroll --owner-label my-service --token-file
   /private/dir/token`. This writes the token and the owner record and starts
   nothing. The pause stays off unless you set it.
5. **Optionally write `runtime/config.json`** (a consumer; see
   [Consumers and deliveries](#consumers-and-deliveries)). Without one the runner
   fires deliveries into `out/` and marks them `pending` with reason
   `no_consumer`. Any entries already in `out/` become pending deliveries on the
   first `run` and go to the consumer if one is configured, so move aside anything
   you do not want handed off.
6. **Run it under a supervisor of your choice.** `run` is a foreground process:
   a terminal multiplexer pane, a launchd or systemd unit, a `nohup` line, a
   process manager. Groundhog does not install or start one. Give the service the
   token file path (and nothing else secret): `./groundhog.sh run --token-file
   /private/dir/token --interval-seconds 60`.
7. **Operate it with the same token file**, from any process: `status --json`
   (no token needed), `pause`, `resume`, `stop`, `retry`, `recover`, `release`.

A service may keep the token across its own restarts and run again without
re-enrolling: `stop` ends the runner and keeps the owner. `release`, after a
safe stop and with no unresolved handoff, ends ownership; then delete the token
file. The runtime has one rule for every supervisor, human or service. A client
may choose a stricter policy for itself (for example never reusing a stored
token after a restart); that is its own choice and not a limit of this script.

### Migrating from a tick loop

A hand-rolled loop (`while sleep 60; do ./groundhog.sh tick; done`, a cron line,
a launchd job) and `run` must not tick at once. The script cannot see the
loop, so the order matters:

1. **Stop the loop** and confirm nothing else calls it
   (`pgrep -fl 'groundhog.sh'`; check cron and launchd). If the loop stays
   alive, a standalone `tick` meets the owner and fails with exit 3, but an older
   copy of the script will not notice and will fire alongside the runner.
2. **Decide who consumes `out/`.** If a script moves entries out of `out/`
   today, either keep the instance unenrolled (nothing changes), or turn that
   script's per-entry work into a configured consumer (it receives one absolute
   delivery path and exits 0 to accept) and stop its directory watcher. Do not
   run a watcher and a configured consumer together: both would take the same
   entry, and a pending delivery whose directory has been moved away is recorded
   `missing` and never handed off.
3. **Leave `fired/` and `schedule/` alone.** Markers carry over, so nothing fires
   twice. Entries still in `out/` are imported as `legacy_out` pending
   deliveries and go to the consumer one at a time; drain or move aside what
   should not.
4. **Enroll, configure, run** as above.

To go back: `stop`, `release`, delete the token, restart the old loop. Delivery
records and the pause stay in `runtime/` and are ignored by an older script.

### Upgrading the vendored script

Replacing `.groundhog/groundhog.sh` (and `README.md`), by hand or with
`./install.sh <host-dir>`:

* **Does:** swap the script and README; run `init`, which only creates missing
  trays.
* **Does not:** touch `schedule/`, `out/`, `fired/` or anything in `runtime/`;
  enroll, configure, start or stop anything; change an existing owner, pause or
  delivery record. An instance that was enrolled stays enrolled, and the
  installer leaves it alone (`init` on an owned instance exits 3, which
  `install.sh` reports as a note).
* **Replaces the script by rename.** `install.sh` copies the new script to a
  temporary file in `.groundhog/` and renames it over the old one, so a runner
  or consumer that is already running keeps reading the old file (bash reads a
  script lazily, which makes an in-place overwrite unsafe). Only a runner
  started afterwards runs the new version, so to be sure which version runs,
  `stop` the runner and start it again with the same token. A by-hand `cp` over
  the script does not have this property: stop the runner first.
* **Old copies elsewhere** (other projects, other worktrees) stay old: they ignore
  the lock, owner and pause.

## Output name collisions

A firing lands in `out/<item-id>-<date>` (`-<HH-MM>` for `every/`). The legacy
rule, kept by the runtime, never overwrites an existing entry: the occurrence is
marked fired and, for a one-shot, the source is still removed, but no second
delivery exists. Two firings can claim one name in these ways. What each leaves
behind, as of this version:

| Case | Result |
|---|---|
| The same item id at two schedule paths, due the same day (`daily/09/foo` and `daily/17/foo`; `daily/foo` and `weekly/sun/foo`) | The first firing (in `due` order) is the delivery. The later one is marked in `fired/` and gets an `out_collision` diagnostic on that delivery in `status`. `lint` and `add` print a `note:` when an id exists at more than one path. |
| A one-shot and a recurring item with one id | Same, and the one-shot's source is removed even though it was never delivered: only the diagnostic and its marker remain. Keep one-shot ids unique. |
| The same id in two `every/` buckets (`every/1h/foo`, `every/30m/foo`) at a shared slot | Same as the first row. |
| Standalone `tick` and `run` mixed on an instance once supervised (after `release`) | A hand-run `tick` that finds the name taken warns on stderr and also attaches the `out_collision` to the delivery's record. An instance that never had delivery records keeps the legacy stderr warning only. |
| The name exists from another source (a legacy entry, a hand-made directory) | The existing directory becomes the delivery (`legacy_out`); the firing is recorded and not delivered; `out_collision` as above. |
| A non-directory (file, dangling symlink) squats on the name | No delivery can stand for it. The firing is marked and not delivered; `status` lists the entry as `out_entry_not_directory` and the runner logs `out_collision`; there is no `out_collision` record for it. |
| The same name on different dates | No collision: the date is part of the name. |
| A path reused after the first delivery vanished | The old record turns `missing`; the new firing is a new delivery with its own id; a later collision attaches to the live delivery. |
| An occurrence re-armed by deleting its marker while the entry is still in `out/` | The refire finds the name taken: recorded, not delivered, `out_collision`. |

A collision costs the later occurrence (it is not delivered and not retried);
the earlier delivery is never overwritten. If two items must both deliver on one
day, give them different ids.

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
{"protocol":"groundhog-runtime","protocol_version":1,"implementation_version":"dev","capabilities":["status-json-v1","ownership-v1","runner-v1","pause-v1","consumer-v1","delivery-v1"]}
```

`capabilities` lists only what this script implements on this host: `status-json-v1`
always, `ownership-v1`, `runner-v1` and `pause-v1` where the locking tools
exist (see [Runner, ownership and pause](#runner-ownership-and-pause)), and
`consumer-v1` and `delivery-v1` where a consumer can also be started in a
session of its own. A client needs all six capabilities in the contract before
it may offer supervised control. An older
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
  reason `unregistered`, `id: null`. Status registers nothing. Reasons the
  runtime writes: `no_consumer` (pending, no config), `path_missing` (missing),
  `result_not_recorded` and `consumer_detached` (uncertain).
* `owner`, `paused`, `revision`, `runner` and `consumer` come from
  `runtime/state.json` and `runtime/config.json` when they exist, and default
  (`owner: null`, `paused: false`, `revision: 0`, runner `stopped`, consumer not
  configured) when they do not. `enroll`, `run`, `pause`, `resume`, `stop` and
  `release` write `state.json`; `run`, `retry` and `recover` write delivery
  records; nothing writes `config.json`. `consumer.valid` also reflects the
  executable, cwd and environment names (status stats them and runs nothing), and
  `consumer.config_digest` is the SHA-256 of the file the last `run` froze.
  Secrets (the owner token verifier, consumer argv and environment) are never
  printed.
* `journal_generation` is an additive field: the change token for the delivery
  journal (see [Change tokens](#change-tokens-revision-and-journal_generation)).
* `consistent` is `false`, with `diagnostics`, when `state.json` or a delivery
  record is unreadable, malformed or of an unsupported `schema_version`, when
  `state.json` changes while status reads it, or when the delivery journal
  changes, is mid-write or has an unreadable generation (`journal_changed_during_read`,
  `journal_write_in_progress`, `journal_generation_unreadable`). An unusable `state.json` also
  shows the runner as `unknown`, owner `null`, and adds `invalid_state` to every
  item's `blocked_by`. A bad `config.json` only sets `consumer.valid: false`.
  An `out_collision`, a `firing_reconciliation_error`, an
  `out_entry_name_not_utf8` or a `schedule_name_not_utf8` is a diagnostic, not an
  inconsistency.
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
runner tests. `test_e2e.sh` is one readable walk of the operator's path (tick-only use, the
upgrade, recurring and overdue delivery, ownership, pause, synchronous and
asynchronous consumers, shutdown, token reuse, release); `test_collisions.sh`
covers [Output name collisions](#output-name-collisions); `test_streams.sh` closes
the runner's output pipes while a consumer runs. The consumer tests
(`test_consumer.sh`, `test_delivery.sh`, `test_journal.sh`) use plain `/bin/sh` consumers that write marker files, kill
the runner with `kill -9` or signal its process group while a consumer sleeps,
hand-write delivery and prepared records for crashes that cannot be timed from
outside, and skip on hosts without the lock and process-isolation tools. Run them
from a foreground shell: a runner started from a background job of a
non-interactive shell inherits an ignored SIGINT and cannot catch it.
New tests: add `tests/test_<area>.sh`, source `tests/lib.sh`, and finish with
`t_finish`.
