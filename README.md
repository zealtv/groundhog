# 🦫 groundhog

A tiny, file-based protocol for recurring items.

An *item* is a directory. Its position under `schedule/` is when it returns. Each time it's due, a fresh copy lands in `out/`.

When you open `.groundhog/schedule/`, you are looking at the things that come around again.

```
.groundhog/
  schedule/
  out/
```

## What groundhog is for

Some things should appear on a schedule. A weekly prompt. A monthly check. A daily nudge. The occasional one-shot reminder for a future date.

Groundhog holds the pattern. Each tick, anything due is copied into `out/`, ready to be picked up — by a hand, by an agent, by a script.

What an item *is* is up to you. A directory of files. A single prompt. A payload to run. An empty directory whose mere appearance is the signal. Groundhog does not care what's inside.

The schedule is a directory tree. There are no header fields, no metadata files, no state outside the file system.

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
```

The path *above* the item is its schedule. The path table:

| Path under `schedule/`              | Fires                              |
|-------------------------------------|------------------------------------|
| `daily/<item>/`                     | every day                          |
| `daily/<HH>/<item>/`                | every day at or after hour `HH`    |
| `weekly/<item>/`                    | every Monday (default)             |
| `weekly/<dow>/<item>/`              | weekly on `<dow>` (mon..sun)       |
| `weekly/<dow>/<HH>/<item>/`         | weekly at or after hour `HH`       |
| `monthly/<item>/`                   | the 1st of every month (default)   |
| `monthly/<dom>/<item>/`             | monthly on day-of-month `<dom>`    |
| `monthly/<dom>/<HH>/<item>/`        | monthly at or after hour `HH`      |
| `yearly/<item>/`                    | Jan 1 each year (default)          |
| `yearly/<MM-DD>/<item>/`            | yearly on that date                |
| `yearly/<MM-DD>/<HH>/<item>/`       | yearly at or after hour `HH`       |
| `once/<item>/`                      | next tick, then source removed     |
| `once/<YYYY-MM-DD>/<item>/`         | one-shot on that date; source removed after firing |

Hour is optional and always the innermost axis.

An item placed at the *root* of an axis fires on the first slot of the cycle: Mon for weekly, the 1st for monthly, Jan 1 for yearly. The exception is `once/<item>/`, which fires on the very next tick — a one-shot you don't have to date.

## Rules

1. The schedule is the path. Move an item under `schedule/` to reschedule it.
2. Materialize by copy: a due item is `cp -r`'d to `out/<item-name>-<YYYY-MM-DD>/`.
3. Idempotent by name: if `out/<item-name>-<YYYY-MM-DD>/` exists, the item has already fired today.
4. One-shots remove themselves from `schedule/once/<date>/` after firing.
5. Item contents are opaque. Groundhog only reads paths.

The file system is the protocol.

## Tick loop

1. Read every item directory at the expected depth under each schedule axis.
2. For each, decide whether today (and the current hour, if specified) matches its path.
3. If due and `out/<id>-<YYYY-MM-DD>/` does not exist, copy the item there.
4. For each one-shot under `once/<past-or-today-date>/`, remove the source after firing.

The loop has no memory. The path encodes the schedule; `out/` encodes what's already fired today. That's all the state groundhog needs.

## Catch-up

Missed days are missed. If a tick doesn't run on Monday, Monday's daily and weekly items are gone for that cycle — the next cycle brings fresh ones. Recurrence beats fidelity.

One-shots wait. A `once/2026-05-01/<item>/` whose date has passed fires on the next tick regardless. A scheduled date should not be missed just because the tick was late.

## Out

`out/` is a tray of fresh items. Groundhog does not know what consumes them. Pipe, move, watch, or ignore — the next reader is your concern.

* a hand: `mv .groundhog/out/* somewhere/`
* an agent: point its inbox at `out/` and let it tend
* a script: cron + tick + mv, in one line

If `out/` accumulates, that is a visible signal — items are being deposited but no one is collecting.

## Commands

```
./groundhog.sh init
./groundhog.sh add <when> <item-id>     # mkdir under schedule/<when>/<item-id>/; you fill the contents
./groundhog.sh tick                     # fire any due items into out/
./groundhog.sh due                      # what would fire now (read-only)
./groundhog.sh list                     # tree-like view of schedule/
./groundhog.sh drop <item-id>           # remove from schedule/
./groundhog.sh out                      # ls out/
./groundhog.sh sweep [days]             # remove out/ entries older than N days (default 14)
```

`<when>` is the schedule path: `daily`, `daily/09`, `weekly`, `weekly/mon`, `weekly/mon/09`, `monthly`, `monthly/1`, `monthly/15/09`, `yearly`, `yearly/03-15`, `once`, `once/2026-05-01`. A bare axis (`weekly`, `monthly`, `yearly`, `once`) takes the default slot.
