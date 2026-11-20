# 🦫 groundhog

Some things should appear on a schedule.

An item is a directory. Its position under `schedule/` is when it returns. Each time it's due, a fresh copy lands in `out/`. If the item holds an executable `run`, that copy's `run` is started.

## Get started

Copy `.groundhog/` into your project:

```sh
git clone https://github.com/zealtv/groundhog
mkdir -p my-project
cp -R groundhog/.groundhog my-project/
```

Schedule an item:

```sh
cd my-project
./.groundhog/groundhog.sh add daily morning-nudge
echo "Stretch." > .groundhog/schedule/daily/morning-nudge/note.md
```

Tick. Anything due is copied into `.groundhog/out/`:

```sh
./.groundhog/groundhog.sh tick
```

Give an item something to do. An executable `run` in it is started each time it fires, with the delivered copy as `$1`:

```sh
./.groundhog/groundhog.sh add daily/09 report
printf '#!/bin/sh
echo "report for $1"
' > .groundhog/schedule/daily/09/report/run
chmod +x .groundhog/schedule/daily/09/report/run
```

## The schedule

```text
.groundhog/
  schedule/   what should happen
  out/        the tray for whatever picks the work up
  fired/      what has happened
```

The path above an item is its schedule: `daily/`, `weekly/mon/`, `monthly/1/`, `yearly/03-15/`, `once/2026-05-01/`, `every/15m/`. Move an item to reschedule it. What an item is is up to you; groundhog does not care what's inside.

Groundhog is passive: `tick` only fires when invoked. To bring the schedule to life, run it on an interval: `./.groundhog/groundhog.sh run` ticks every 60 seconds until Ctrl-C, or use cron, or `while sleep 60; do ./.groundhog/groundhog.sh tick; done`.

## Notes

- To upgrade, run `groundhog/install.sh my-project`. It leaves `schedule/`, `out/` and `fired/` alone.
- The full protocol lives in [`.groundhog/README.md`](.groundhog/README.md).
- The file system is the protocol. No header fields and no state outside the file system: each delivery carries one small record of what became of it, `.groundhog-record`.
- `pause` holds a whole instance back (nothing fires, nothing starts) until `resume`; `retry <delivery>` starts a delivery's `run` again.
