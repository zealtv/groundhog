# Runtime contract — protocol 2

**Accepted on 2026-11-19; implemented in this script.** An item that holds an
executable `run` says itself what happens when it fires: any tick starts the
delivery's `run`, once, in a session of its own, and a record inside the
delivery says what became of it. Protocol 2 replaces protocol 1's owner,
runner, consumer configuration and delivery journal; nothing of those
remains. [README.md](../README.md) is the user's guide; this document is the
interface a client builds on.

## Boundaries and vocabulary

- **Instance**: the canonical absolute `.groundhog/` directory holding
  `groundhog.sh`, `schedule/`, `out/` and `fired/`. Select the script by
  absolute path; the caller's cwd never selects an instance.
- **Item**: a directory under `schedule/`. Its path is its schedule.
- **Firing**: copying a due item into `out/` and marking the occurrence in
  `fired/`. Firing executes nothing.
- **Delivery**: one directory in `out/`. Groundhog made it if and only if it
  holds a record whose first line is a fired line.
- **Run**: the delivery's executable `run`, started by the wrapper.
- **Attempt**: one start of a run, with its own id; a retry adds an attempt.
- **Execution**: what a run does. Groundhog records that a run started and
  how it exited, never whether its work succeeded. Exit 0 means "accepted".

Inspection never ticks, starts, creates directories or repairs state. Runtime
behavior never branches on the identity of a caller, project or host. A run is
any executable: no SDK, queue, model, AI account or prompt schema is involved.

## Reserved names

Inside an item, and so inside each delivery, three names are Groundhog's:

| Name | Who writes it | Meaning |
|---|---|---|
| `run` | the item's author | an executable regular file; starts for each delivery that holds one |
| `.groundhog-record` | Groundhog | the delivery's append-only record |
| `.groundhog-log` | the wrapper (run's output) | run's stdout and stderr, every attempt appended |

A firing deletes any `.groundhog-record` and `.groundhog-log` the copy
brought from the item before it writes the fresh record. Everything else in
an item is the author's and is never read by Groundhog.

## Commands and negotiation

```text
groundhog.sh capabilities --json
groundhog.sh status --json [--next-due]
groundhog.sh tick
groundhog.sh pause
groundhog.sh resume
groundhog.sh retry <delivery>
groundhog.sh run [--interval-seconds N]
groundhog.sh sweep [days]
groundhog.sh add <when> <item-id> [--from DIR]
```

plus the schedule commands (`init`, `due`, `list`, `lint`, `drop`, `out`),
whose interface is unchanged. JSON commands print one UTF-8 JSON object and a
newline on stdout; diagnostics go to stderr; human output is not an API.

Exit codes of `retry`, `pause`, `resume` and `run`: 0 success, 2 invalid
arguments (or, for `retry`, not a delivery of this instance), 3 refused by
the instance pause, 4 busy, 5 nothing to do or not possible on this host,
6 I/O failure. `tick`, `init`, `add`, `drop` and `sweep` keep exit 1 for
errors (for `tick`: an item that could not be fired, after the rest of the
tick has run; `sweep` exits 2 for more than one argument) and also exit 4
when the mutation lock stays busy (about three seconds) and 6 when it cannot
be taken. `capabilities` and `status` exit 2 on
invalid arguments, and `status` also when the script is not inside a
`.groundhog/` directory.

```json
{"protocol":"groundhog-runtime","protocol_version":2,"implementation_version":"dev","capabilities":["status-json-v2","next-due-v1","add-from-v1","pause-v2","handlers-v1"]}
```

| Capability | Offered | Means |
|---|---|---|
| `status-json-v2` | always | `status --json` as projected below |
| `next-due-v1` | always | `status --json --next-due` adds `next_due` to schedule records |
| `add-from-v1` | always | `add <when> <item-id> --from DIR`, atomic under the lock |
| `pause-v2` | always | `pause` and `resume` with no token |
| `handlers-v1` | with a lock helper and a session helper | runs, the record, `retry` |

`protocol_version` is an integer that changes only for incompatible changes;
`implementation_version` is informational. Clients ignore unknown fields,
unknown record lines and unknown diagnostics, and decline unknown states and
capabilities for control. **To tell the protocols apart:** protocol 2 answers
`protocol_version: 2` and lists `handlers-v1` where runs work; protocol 1
answered `1` and listed `ownership-v1`; an older script answers `capabilities`
with its `unknown command` error (exit 1). Do not probe by running `tick`,
`run` or `init`.

## The record

`.groundhog-record` is text, one event per line, fields separated by single
spaces, each line ending in a newline. The schedule path, which may contain
spaces, is always the last field.

```text
fired <delivery-id> <utc> <handler> <date> <slot> <schedule-path>
start <attempt-id> <utc> <by>
exit <attempt-id> <utc> <status>
collision <utc> <date> <slot> <schedule-path>
```

| Field | Form |
|---|---|
| `delivery-id` | `d-` and letters or digits (16 hex digits from `/dev/urandom` where it exists) |
| `attempt-id` | `a-` and letters or digits |
| `utc` | `YYYY-MM-DDTHH:MM:SSZ` |
| `handler` | `run` (the item held an executable `run` when it fired) or `none` |
| `date`, `slot` | the occurrence: `YYYY-MM-DD`, and `HH-MM` for `every/` or `-` |
| `by` | `tick` or `retry` |
| `status` | the run's exit status, 0..255 (128 + N for signal N; 127 gone; 126 not executable) |
| `schedule-path` | relative to the instance, e.g. `schedule/daily/09/report` |

**Invariants.**

1. The fired line is the first line and is written once, into the `.landing`
   copy, before the rename into `out/`. A delivery is never visible without it.
2. A start line is written only by a holder of the record's lock, after
   reading the record again under that lock.
3. That holder hands the lock to the wrapper, which holds it until `run`
   exits and then appends the exit line for the same attempt. Nothing else
   takes the lock for longer than an instant.
4. Each append is one short write in append mode, so lines never interleave.
   `collision` lines are appended without the lock.
5. Attempts are sequential: an exit always belongs to the latest start.

Readers take the first line as the fired line (a record that does not start
with a valid one is malformed: the delivery is `unrecorded` and never runs),
pair each exit with its start by attempt id, and ignore lines they do not
know or cannot parse.

## Runs

**When a run starts.** Every tick that is not paused, after its firings,
looks at every directory in `out/` (not `.landing` copies, not symlinks) whose
record says `run` and has no start line. For each, it opens the record and
tries its lock without waiting. If the lock is held, another process is
starting or running it, and the tick moves on. Otherwise the tick reads the
record again, and if it still has no start it writes the start line (`by
tick`), opens `.groundhog-log` for appending, and starts the wrapper with the
locked descriptor. The tick does not wait for the run.

**The wrapper** runs in a new session (perl's `POSIX::setsid`, else
`setsid(1)`), stdout and stderr on `.groundhog-log`, stdin `/dev/null`, and
without the mutation lock. On the perl path, SIGINT, SIGQUIT and SIGPIPE are
at their defaults. On the `setsid(1)` path they are reset by the shell, which
works under bash 5 when the ticker had them at their defaults; under bash 3.2,
or from a ticker started with SIGINT ignored, `run` inherits SIGINT ignored.
It starts `run` with:

- `$1`: the delivery's absolute path, spelled from the canonical instance
  (so it lies under `GROUNDHOG_INSTANCE` however the ticker reached the
  instance), and no other argument;
- cwd: the project, the canonical parent of `.groundhog/`;
- stdin: `/dev/null`; stdout and stderr: the log;
- environment: the ticker's, plus `GROUNDHOG_INSTANCE` (the canonical
  instance directory), `GROUNDHOG_DELIVERY_ID` (from the fired line) and
  `GROUNDHOG_ATTEMPT_ID` (from this start line), each overriding any value
  the ticker had;
- neither the record's lock nor the mutation lock.

When `run` exits, the wrapper appends `exit <attempt-id> <utc> <status>` and
exits. SIGINT, SIGTERM and SIGHUP sent to the wrapper alone wait for `run`.
The wrapper's pid is the session's process group: signalling that group stops
the run and the exit line records it. A start without an exit is left by a
`kill -9` of the wrapper, a tick killed between the start line and the
wrapper, or the machine stopping (see [Crash windows](#crash-windows)).
`interrupted` means the wrapper is gone, not necessarily `run`: after a
`kill -9` of the wrapper's pid alone, `run` goes on without the lock, and a
`retry` would start a second copy beside it. Check before retrying.

**States.** A client derives them from the record and the lock; `status`
reports them as `state`:

| State | Record | Lock |
|---|---|---|
| `delivered` | fired `none` | — |
| `pending` | fired `run`, no start | — |
| `running` | latest start has no exit | held |
| `interrupted` | latest start has no exit | free |
| `accepted` | latest start's exit is 0 | — |
| `failed` | latest start's exit is not 0 | — |
| `unrecorded` | no record, or one that does not start with a fired line | — |

A `pending` delivery whose lock is held for an instant (a tick or `retry` in
the middle of starting it) still reads `pending` until its start line lands.
Every line that begins `start ` counts as a start, even one whose fields do
not parse (its attempt then shows `id` and `started_at` as `null`), so a torn
start fails closed, as `running` or `interrupted`, never `pending`.

**Never re-run automatically.** Groundhog starts a run by itself only from
`pending`. An `interrupted` run may have done part of its work; only an
explicit `retry` starts it again. There is no barrier: one delivery's state
never holds back another's. A run that needs exclusion from other runs takes
its own lock.

**Exactly once.** On a host with a lock helper, firings are serialized by the
mutation lock, so two tickers (cron and a loop, say) fire each occurrence once,
and the record's lock keeps each delivery's wrapper to one at a time. Without a lock
helper Groundhog fires unlocked, as it always has, and starts no run.

## Retry

`retry <delivery>` starts the delivery's run again now, from any state, as a
new attempt (`by retry`). `<delivery>` is the directory's name in `out/`,
`out/<name>`, or its absolute path; anything that does not name a directory
directly under this instance's `out/` exits 2. It takes the mutation lock,
then the record's lock (three tries, 0.1 s apart, so a reader's instant on it
does not count as busy), and returns once the wrapper has started. It exits 4
if the record's lock stays held (the delivery is running or being started) or
the mutation lock stays busy, 3 while the instance is paused, and 5 when the
delivery has no record Groundhog made, a `none` record, no executable `run`, or
the host offers no `handlers-v1`. No token is involved.

## Pause

The instance pause is the file `runtime/paused`. While it exists, `tick` fires
nothing and starts nothing (and says so on stderr, exit 0), and `retry` exits 3.
Runs already going are not touched, and their exits are recorded. `pause`
creates the file and `resume` removes it, idempotently, under the mutation
lock, so when `pause` returns no tick is in progress. Neither takes a token or
an argument. The pause is independent of `.paused` suffixes in `schedule/`.

## Sweep and dismissal

`sweep [days]` removes, by directory mtime, `out/` entries and `fired/` date
directories more than `days` (default 14) old, including leftover `.landing`
copies, except deliveries that are `pending` or `running`, which it reports
as skipped. Deleting a delivery from `out/` is the way to dismiss it: its
marker in `fired/` remains, so the occurrence does not fire again.

## The run loop

`run [--interval-seconds N]` ticks, then waits until N seconds (default 60)
after that tick began, and repeats, until SIGINT, SIGTERM or SIGHUP, and
exits 0. Ctrl-C (the tick's subshell ignores SIGINT), or SIGTERM or SIGHUP to
the loop's pid alone, lets the tick in progress finish. SIGTERM or SIGHUP to
the loop's whole process group (a closed terminal pane, a service manager
stopping the group) kills that tick too, which is one of the crash windows
below. Each tick runs in a
subshell, so a failing tick is logged and the loop goes on. The loop holds no
lock of its own and owns nothing: two loops, or a loop and cron, both tick.
Runs it started live on in their own sessions after it ends. `last_tick`
records its ticks with source `runner`.

## Crash windows

| A crash … | leaves | the next tick |
|---|---|---|
| while copying into `out/<name>.landing` | a `.landing` copy, no marker | fires again, replacing the copy; the copy never runs; `sweep` removes it if left |
| after the rename, before the marker | a delivery (pending, if it has a run), no marker | starts its run, and records the occurrence as a collision with its own delivery, which `status` reports as harmless |
| after the marker, before the scan | a pending delivery | starts its run |
| after a start line, before the wrapper | a start, no exit, free lock: `interrupted` | leaves it; `retry` restarts |
| of the wrapper (`kill -9`) | the same, while `run` may still be going | the same |
| of `run` | an exit line with 128 + N | nothing: `failed` |

## Read-only JSON projection

`status --json` (capability `status-json-v2`) prints:

```json
{"protocol":"groundhog-runtime","protocol_version":2,"instance":"/abs/.groundhog","observed_at":"2026-05-01T09:01:00Z","paused":false,"last_tick":{"at":"2026-05-01T09:00:04Z","source":"runner"},"schedule":[…],"deliveries":[…],"diagnostics":[…]}
```

- `instance`: the canonical instance directory. `observed_at`: UTC.
- `paused`: whether `runtime/paused` exists.
- `last_tick`: `{"at", "source"}` for the newest completed tick, paused or
  not (`source` is `standalone` for `tick`, `runner` for the `run` loop), or
  `null`. It is liveness only and grants nothing. Hosts without a lock helper
  record none.
- `schedule`: one record per item, as before: `path` (the identity, relative
  to the instance), `item_id`, `cadence` (`{"axis","day","date","time",
  "interval","defaulted"}`), `paused_by`, `eligible_now`, `fired_marker`,
  `fired`, `firing_allowed`, `blocked_by` (`subtree_paused`, `not_due`,
  `already_fired`, `instance_paused`) and, under `--next-due`, `next_due` (the
  UTC time the next unfired occurrence begins, or `null`). `eligible_now` and
  `fired_marker` come from the same walk `tick` uses.
- `deliveries`: one record per directory in `out/` (`.landing` copies left out):

```json
{"path":"out/report-2026-05-01","id":"d-3f9c0a1b2c3d4e5f","state":"accepted","fired_at":"2026-05-01T09:00:04Z","schedule_path":"schedule/daily/09/report","occurrence":{"date":"2026-05-01","slot":null},"run":true,"exit_status":0,"attempts":[{"id":"a-77aa01b2c3d4e5f6","started_at":"2026-05-01T09:00:04Z","by":"tick","finished_at":"2026-05-01T09:00:31Z","exit_status":0}],"log":"out/report-2026-05-01/.groundhog-log"}
```

  `state` is one of the seven above; `exit_status` is the latest attempt's
  (`null` while none finished); `run` is the fired line's handler; `log` is
  `null` until a run has written one. An `unrecorded` delivery has `id`,
  `fired_at`, `schedule_path`, `occurrence`, `exit_status` and `log` `null`,
  `run: false` and no attempts.
- `diagnostics`: `{"code","message","path"}` objects, none of them an error of
  `status` itself:

| Code | When |
|---|---|
| `schedule_unrecognized_path` | a path the schedule grammar rejects (what `lint` lists) |
| `out_collision` | one per `collision` line: a later occurrence lost its name, so its run never ran; or, when the line names the delivery's own occurrence (a re-arm, or a tick that ended before its marker), harmless |
| `out_entry_not_directory` | a file or dangling symlink in `out/` |
| `run_not_executable` | a `none` delivery holds an entry named `run` (no execute bit, or a link that broke in `out/`); it never ran |
| `firing_failed` | the last tick could not fire this schedule item (`path` is its schedule path); every tick tries again |
| `record_malformed` | a `.groundhog-record` that does not start with a fired line |
| `handlers_unavailable` | pending deliveries on a host without `handlers-v1` |
| `config_ignored` | a protocol 1 `runtime/config.json` is present and ignored |
| `state_ignored` | a protocol 1 `runtime/state.json` is present; its owner and pause no longer apply |
| `path_not_utf8` | a name is not valid UTF-8; invalid bytes are shown as U+FFFD |

`status` and `capabilities` are strictly read-only, even before `init`: they
create, lock-hold, tick, start and repair nothing. `status` reads directory
names, the files under `runtime/` and each delivery's record, and nothing else
in a payload. To tell `running` from `interrupted` it takes a shared lock on
the record for an instant and releases it; readers never collide with each
other, and a starter that meets one finds the delivery busy for that instant.

## What clients build on

Protocol 2 is shaped for three kinds of client, none of which ships with
Groundhog:

- **A supervising application** ticks each instance it runs with plain `tick`
  (every 60 seconds, say), reads `status --json` for each delivery's `state`
  and attempts, offers `retry` for `failed` and `interrupted` ones and `pause`
  for an instance, and reads `last_tick` for liveness. It owns nothing: when it
  quits it simply stops ticking, and runs go on in their own sessions.
- **A tool that schedules work** writes the item, `run` included, into a
  prepared directory and lands it with `add --from`, with `run` already
  executable. Its `run` uses `$1`, `GROUNDHOG_INSTANCE`,
  `GROUNDHOG_DELIVERY_ID` and `GROUNDHOG_ATTEMPT_ID`. A retry keeps the
  delivery id: a `run` that de-duplicates on the delivery id skips every retry
  and exits 0, which reads `accepted`. De-duplicate on the attempt id, or only
  on success.
- **A long-lived loop** in a terminal pane or a service calls `groundhog.sh
  run`, or its own `while sleep 60; do groundhog.sh tick; done`. A loop that
  ticks and then moves `out/*` away moves a delivery from under the run just
  started for it: it leaves deliveries whose record says `run`, or lets `run`
  do the moving.

A tick can exit 1 (a firing failed; the rest of the tick still happened) or
4 (the mutation lock stayed busy); `pause`, `resume` and `retry` can exit 4
too. Clients try again later rather than read 4 as a refusal.

A client finds `handlers-v1` before it relies on runs, `pause-v2` before it
calls `pause` without a token, `add-from-v1` before it passes `--from`, and
`next-due-v1` before it passes `--next-due`.

## Compatibility and accepted design choices

- **The contract broke.** Protocol 1's `enroll`, token files, generations,
  `release`, `stop`, `sweep --token-file`, `runtime/config.json`, the delivery
  journal (`runtime/deliveries/`, `prepared/`, `done/`, `journal.gen`), the
  handoff barrier, `recover`, `discard` and `status --active` are gone, as are
  the status fields `owner`, `runner`, `consumer`, `revision`,
  `journal_generation`, `consistent` and `settled`. Protocol 1 files left in
  `runtime/` are ignored and flagged.
- **Reserved names reverse two old rules.** "Item contents are opaque" and
  "metadata beside, never inside" no longer hold: `run`, `.groundhog-record`
  and `.groundhog-log` are reserved inside every item and delivery.
- **Groundhog executes tracked files.** A `git pull` or clone can bring in a
  `run` that the next tick starts. The pause is the hook for holding an
  instance back; an opt-in may follow if a need appears.
- **No automatic re-run.** Only `pending` starts by itself; `interrupted` waits
  for `retry`.
- **Known gap: collisions.** A later occurrence that finds its `out/` name
  taken is marked fired and not delivered, so its run never runs. It is shown
  (`out_collision`, where the name's holder has a record), not fixed.
- **No fsync.** Every step is safe against a process crash; a power loss can
  lose a firing that had just happened.
- **Single host, local filesystem.** Locks are `flock(2)`; do not share an
  instance over a network filesystem.
