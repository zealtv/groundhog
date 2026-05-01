# 🦫 groundhog

A tiny, file-based protocol for recurring items.

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
      2026-05-01/
        follow-up/
  out/
    morning-nudge-2026-04-25/
      note.md
    follow-up-2026-04-25/
  fired/
    2026-04-25/
      morning-nudge
      follow-up
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

Time is optional and always the innermost axis: bare `<HH>` (00..23) or `<HH-MM>` (e.g. `09-30`). They coexist — pick whichever reads better. `HH-MM` is forbidden directly under `yearly/` because it would collide with the `MM-DD` shape; if you want a yearly time, write the date out (`yearly/01-01/09-30/<item>/`).

A past-dated one-shot with an inner `<HH-MM>` fires on the next tick regardless — the day is already gone, so the time is moot.

An item placed at the *root* of an axis fires on the first slot of the cycle: Mon for weekly, the 1st for monthly, Jan 1 for yearly. The exception is `once/<item>/`, which fires on the very next tick — a one-shot you don't have to date.

## Rules

1. The schedule is the path. Move an item under `schedule/` to reschedule it.
2. Materialize by copy: a due item is `cp -r`'d to `out/<item-name>-<YYYY-MM-DD>/`.
3. Each firing is recorded by `touch fired/<YYYY-MM-DD>/<item-name>`. An item with a marker for today will not fire again that day.
4. One-shots remove themselves from `schedule/once/<date>/` after firing.
5. Item contents are opaque. Groundhog only reads paths.

The file system is the protocol.

## Tick loop

1. Read every item directory at the expected depth under each schedule axis.
2. For each, decide whether today (and the current time, if `<HH>` or `<HH-MM>` is specified) matches its path.
3. If due and `fired/<today>/<item-name>` does not exist: copy to `out/<item-name>-<today>/`, then `touch fired/<today>/<item-name>`.
4. For each one-shot under `once/<past-or-today-date>/`, remove the source after firing.

`fired/` is groundhog's only memory. The path encodes the schedule; the journal encodes what's done. That's all the state groundhog needs.

## Catch-up

Missed days are missed. If a tick doesn't run on Monday, Monday's daily and weekly items are gone for that cycle — the next cycle brings fresh ones. Recurrence beats fidelity.

One-shots wait. A `once/2026-05-01/<item>/` whose date has passed fires on the next tick regardless. A scheduled date should not be missed just because the tick was late.

### Short-month days

`monthly/29/`, `monthly/30/`, and `monthly/31/` only fire when that day-of-month actually exists. February has no 29..31 in non-leap years; April, June, September, and November have no 31. **There is no end-of-month fallback.** If you want "always the last day of the month," use `monthly/28/` (which exists every month) and accept the early trigger, or schedule the item explicitly with `once/<YYYY-MM-DD>/` entries generated for each month you care about. Keep the protocol simple; let the schedule express the truth.

### Daylight saving time

Groundhog reads local time. On the spring-forward day, an item at `daily/02/<item>/` may never fire — the local clock skips from 01:59 directly to 03:00. On the autumn-back day, the same item may fire twice if you tick during the doubled hour. **The tick is "the agent ran groundhog at this wall-clock moment," not "groundhog scheduled an event."** If precision-at-an-hour matters more than precision-at-a-day, prefer hour buckets that don't sit on the DST boundary.

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
```

`<when>` is the schedule path: `daily`, `daily/09`, `daily/09-30`, `weekly`, `weekly/mon`, `weekly/mon/09`, `weekly/mon/09-30`, `monthly`, `monthly/1`, `monthly/15/09`, `monthly/15/09-30`, `yearly`, `yearly/03-15`, `yearly/03-15/09-30`, `once`, `once/2026-05-01`, `once/2026-05-01/09-30`. A bare axis (`weekly`, `monthly`, `yearly`, `once`) takes the default slot.
