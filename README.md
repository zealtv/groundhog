# 🦫 groundhog

Some things should appear on a schedule.

An item is a directory. Its position under `schedule/` is when it returns. Each time it's due, a fresh copy lands in `out/`.

## Get started

Copy `.groundhog/` into your project:

```sh
git clone https://github.com/zealtv/groundhog
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

## The schedule

```text
.groundhog/
  schedule/   what should happen
  out/        the tray for whatever picks the work up
  fired/      what has happened
```

The path above an item is its schedule: `daily/`, `weekly/mon/`, `monthly/1/`, `yearly/03-15/`, `once/2026-05-01/`, `every/15m/`. Move an item to reschedule it. What an item is is up to you; groundhog does not care what's inside.

Groundhog is passive: `tick` only fires when invoked. To bring the schedule to life, run it on an interval: `while sleep 60; do ./.groundhog/groundhog.sh tick; done`.

## Notes

- To upgrade, run `groundhog/install.sh my-project`. It leaves `schedule/`, `out/` and `fired/` alone.
- The full protocol lives in [`.groundhog/README.md`](.groundhog/README.md).
- The file system is the protocol. No header fields, no metadata files, no state outside the file system.
