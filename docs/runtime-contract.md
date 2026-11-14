# Optional runtime contract — proposed v1

**Unimplemented design for review, 2026-11-15.** None of the commands or
runtime files specified here exists in the current script. This document
settles a proposed interface for later implementation; it does not enable a
runner. The existing commands in [README.md](../README.md) remain the current
passive interface. Basis: the source `groundhog.sh` and Easyhog's `docs/design.md`
and ownership finding, read on 2026-11-15. Bob's design acceptance is pending.

## Boundaries and vocabulary

An instance is the canonical absolute directory containing `groundhog.sh`,
`schedule/`, `out/` and `fired/`. Resolve the selected script by absolute path;
caller cwd never selects an instance. Identity is the canonical directory, not
a repository name, PID, hostname or supervising application.

- **Firing** copies an opaque scheduled directory into `out/` and records a
  schedule occurrence in `fired/`. It does not execute anything.
- **Delivery** is a particular materialized directory. A durable, opaque delivery
  ID distinguishes generations even when an out path is reused.
- **Handoff** invokes the configured consumer for that delivery. Acceptance
  records the consumer's acknowledgement; it does not prove work completed.
- **Execution** belongs to the consumer or the agent it launches. v1 reports
  execution as `unknown`; it never infers success from a firing or handoff.
- **Enrollment** assigns persistent control ownership to a supervisor session.
  A runner's activity and ownership are separate facts.

Inspection never enrolls, ticks, dispatches, creates directories, repairs state,
loads a consumer, or evaluates payload contents. Discovery grants inspection
only. No application names, hostnames or live-PID heuristics grant control.

## Commands and negotiation

All commands below are proposed additions to `groundhog.sh`. Options have no
implicit environment equivalents. Unknown options fail. JSON commands emit one
UTF-8 JSON object and a newline on stdout, with diagnostics only on stderr.
Human output is not an API. Exit codes for new commands: 0 success, 2 invalid
arguments/configuration, 3 ownership conflict, 4 busy/lock conflict, 5 invalid or
unsupported state, 6 I/O failure, 7 enrollment outcome uncertain. For `enroll`,
6 guarantees failure before owner commit; 7 covers uncertain or postcommit
failure. Legacy command exit codes remain unchanged.

```text
groundhog.sh capabilities --json
groundhog.sh status --json
groundhog.sh enroll --owner-label LABEL --token-file ABSENT_ABSOLUTE_PATH
groundhog.sh run --token-file PATH [--interval-seconds N]
groundhog.sh pause --token-file PATH
groundhog.sh resume --token-file PATH
groundhog.sh stop --token-file PATH
groundhog.sh release --token-file PATH
groundhog.sh retry --token-file PATH --delivery ID
groundhog.sh recover --token-file PATH --delivery ID --decision retry|accept
```

`capabilities` and `status` are strictly read-only even before `init` or
enrollment. Missing optional state means defaults; malformed state is reported,
not overwritten. A status read that races a writer returns a coherent revision
or `consistent:false` plus diagnostics; callers must refresh before control.
A busy read may fail with 4 without taking a write lock or creating lock files.

Synthetic capability response (not output from today's script):

```json
{
  "protocol": "groundhog-runtime",
  "protocol_version": 1,
  "implementation_version": "example-build",
  "capabilities": ["status-json-v1", "ownership-v1", "runner-v1", "pause-v1", "consumer-v1", "delivery-v1"]
}
```

Protocol version is an integer for incompatible changes; implementation version
is informational. Additive fields may appear. Clients ignore unknown fields
and decline unknown enum values for control. All six capabilities and version
1 are required for Easyhog Play/Pause. An old script returns its existing
unknown-command error: inspect its files as legacy, mark control unsupported,
and do not probe by running `run`, `tick` or `init`. Capability discovery invokes
only the deliberately selected instance's script; it is not a payload sandbox.

`enroll` is explicit and succeeds only if ownership is absent. It creates a
fresh unguessable token in the requested, previously absent file (mode 0600).
The private token file is a versioned JSON object containing `schema_version:1`,
`token` (the secret), and nonsecret metadata: canonical `instance`, fresh opaque
`owner_id` and proposed `generation`. Persist this
complete usable file durably before atomically replacing the owner record with
that ID, generation and secret verifier. Success (0) requires the owner commit's
durability operations to complete. There is no atomic rollback across the two
files; a committed owner always has its token durably written first.

A known precommit failure grants no ownership (including I/O exit 6). It may
leave an unused token file. Once owner replacement may have occurred, an error
returns 7 (`enrollment_uncertain`), even if replacement succeeded but a later
sync failed. Process death or a lost command result is also uncertain to the
caller. Retain any usable token on an uncertain outcome; never automatically
resume, run, re-enroll or discard it. Status never imports a token file.

After the enroll process has ended and storage errors have been resolved, use
`status --json` to reconcile against the private token's nonsecret metadata.
Require a coherent (`consistent:true`), valid state observation for the same
canonical instance. Matching `owner.id` and `owner.generation` identifies this
attempt's enrollment; the caller retains the token and may explicitly choose
control next. Owner null establishes that the attempt did not retain ownership;
a different ID/generation means this token does not control the current owner.
Only after establishing that the token is unused/stale may the caller explicitly
remove it and, if unowned, enroll with a new absent path. Busy, inconsistent,
malformed or unreadable status leaves the outcome unresolved: keep the token
and start no work. A snapshot is not an authorization or a durability repair;
all control commands still validate the secret and generation under lock.

The token file belongs outside the instance, under the supervisor's private
session directory. Labels and PIDs are display/diagnostic text, not enrollment
identifiers or authority. Do not print or put secrets, verifiers or the private
file contents in argv or status; status exposes only the public owner metadata.
All later control commands read the token file, verify the current generation,
and check the instance identity before mutating. Stale tokens fail with 3.
Tokens authorize cooperating processes; this is not a security boundary against
someone who can edit the instance's files.

`run` remains in the foreground and performs an immediate enabled cycle, then
one cycle per interval (default 60 seconds, positive integer). Cycles never
overlap; a slow consumer delays subsequent cycles and missed cycles are skipped. It does not
enroll or clear pause. Each cycle reconciles deliveries, ticks once if enabled,
then hands off eligible pending deliveries, serially. An unresolved
in-flight/uncertain attempt blocks every consumer admission across cycles and
runner lifetimes, including admissions under changed configuration. Reconciliation
may mark abandoned in-flight attempts uncertain; acquiring runner exclusion
never proves their consumers finished. Ticking may still materialize deliveries
while this handoff barrier holds; pending deliveries wait for explicit recovery.
Scheduling uses local time and the existing path/slot rules; missed slots are
not backfilled.
Changing interval does not change schedule interpretation. A second `run`,
even with the same token, fails busy. Runner startup validates configuration
before its first tick. Invalid configuration fails visibly without ticking.

`pause` persists the instance-wide pause and acts as an admission barrier.
`resume` clears that bit but does not start a runner, enroll or immediately
execute work itself. `stop` requests shutdown and waits until this runner can
admit no further work; it neither clears ownership nor changes pause. `release`
requires a stopped runner and no unresolved in-flight or uncertain attempt; it
removes ownership, invalidates the token and leaves pause and delivery records
intact. Absent a live runner, pause/resume/stop still work with the current token;
stop is idempotent. Repeated pause/resume set the requested value idempotently.
Retry and recover require a stopped runner, making operator decisions explicit
before the next run. Retry of another failed delivery does not lift an unresolved
invocation barrier. Before either recovery decision, the operator must establish
that the original consumer invocation has finished; runner exclusion or a PID
observation alone cannot establish this. None of these commands imports old
external consumers.

## Ownership, locks and enrollment lifecycle

Optional state lives only under `.groundhog/runtime/`:

```text
runtime/
  state.json                  # version, revision, pause, owner, runner, config digest
  config.json                 # optional explicit consumer configuration
  deliveries/<id>.json        # path, occurrence, attempts, handoff result
  staging/<id>/               # internal incomplete firing, never dispatchable
  locks/                      # instance mutation and runner exclusion locks
```

A synthetic stopped-owner `state.json` fragment illustrates persistence (the
verifier is a placeholder, never a usable token):

```json
{
  "schema_version": 1,
  "revision": 12,
  "paused": true,
  "owner": {
    "id": "o-demo",
    "generation": 1,
    "label": "demo-session",
    "token_verifier": "example-nonsecret-verifier"
  },
  "runner": {"state": "stopped", "last_error": null},
  "config_digest": null
}
```

Generation remains persisted after release even though owner becomes null;
next enrollment advances it. State records also bind tokens to the canonical
instance. This fragment omits that binding and optional liveness diagnostics;
it is not a complete file to install manually.

The installer must not replace runtime state. The authoritative owner record
contains an opaque owner ID, generation, label and token verifier. It survives
normal stop, crashes and reboot. No expiry, heartbeat age, PID death, hostname
change, process-name match or stopped external supervisor transfers ownership.
An unenrolled instance has no owner and cannot run. Enrollment does not remove
pause or adopt pending out entries as accepted.

Easyhog creates a new session token only on explicit Play of an unowned,
compatible selected instance. It can then resume and run under that token.
For its own paused instance, explicit Play resumes it. Reopening Easyhog starts
with no enrollments and must not silently use persisted tokens. An external
owner remains external even when stopped. Do not offer Play/Pause/release for
an owner whose token this supervisor session does not hold.

On clean Easyhog Quit: stop each owned runner, wait for the stop barrier, then
release ownership and delete its session token. Do not clear persistent pause.
If stop/release fails, report the retained owner and keep its token instead of
claiming cleanup. An uncertain enrollment likewise retains its token until the
read-only reconciliation above establishes its disposition.
A crash leaves ownership retained and must be shown as owned with liveness
unknown or stopped. A supervisor that still holds the matching token may stop,
recover outstanding attempts and release. Lost-token ownership requires a
separate, explicit offline operator repair: stop all writers, preserve a backup,
resolve ambiguous attempts, invalidate the old owner and advance generation.
There is deliberately no automatic takeover command in v1 and no Easyhog MVP
repair action. Never delete a lock file merely because a PID looks absent.

Use OS-released advisory exclusion, with one runner lock held for the runner's
lifetime and a separate short-lived mutation lock serializing all upgraded
writers (`tick`, firing commit, pause, dispatch admission, ownership, retry,
recovery and sweep). Lock ordering is runner then mutation; commands needing
both acquire runner exclusion nonblocking before taking mutation. Stop writes
its request under mutation without acquiring runner exclusion, then waits
without holding mutation for the runner to release exclusion. Locks must
not be inherited by consumer children. Releasing/acquiring runner exclusion
does not release the durable unresolved-invocation barrier or prove a detached
consumer ended. Files record diagnostic IDs, never
prove lock ownership. Persist state by atomic replacement with monotonic
revision, and order durable writes so interrupted updates remain recoverable.
Do not advertise these capabilities on a filesystem lacking the required lock,
rename and durability semantics; shared/network-filesystem coordination is
outside v1. Cooperative single-host use is the supported runtime scope.

Mutations revalidate token/generation under lock. Stop prevents new admissions
before releasing runner exclusion; pause commits under the same mutation lock
used to admit firings and handoffs. Work admitted before the pause barrier may
finish. A parent exiting does not send termination signals to accepted agents.
Runner PID/start ID and heartbeat are diagnostics only. A read reports
`unknown` if it cannot establish local activity; it never repairs stale state.

## Persistent pause and passive callers

The new global pause bit defaults to false and survives stop, release and
re-enrollment. It is independent of schedule component `.paused` suffixes.
Resume clears only the global bit; it never renames a schedule component.
While globally paused, no new firing or handoff may be admitted, including
pending deliveries that predate pause. Already admitted consumer calls may
finish and record their result. Already accepted independent work continues.

An upgraded standalone `tick` checks the same pause and locking rules. Paused
tick succeeds without firing and prints a human diagnostic to stderr. With an
owner present it fails ownership conflict: the runner calls the tick operation
internally under its token. If both paused and owned, ownership conflict takes
precedence for standalone tick. Upgraded `init`, `add`, `drop` and `sweep` also
serialize mutations and refuse while owned; v1 provides no supervised schedule-edit command. They do not clear
pause or runtime state. No-owner, unpaused tick continues to materialize
only, without enrollment or consumer invocation. No runtime directory is
required for ordinary legacy-style use; lock coordination may create optional
lock state, but never ownership or configuration. `due` continues to describe
schedule eligibility irrespective of global pause; status reports eligibility
and firing permission separately. `.paused` subtrees remain ineligible.

Older deployed scripts know nothing about the bit or locks and can bypass
both. Never claim global pause across mixed versions or an independent legacy
poller. Before opting an instance into supervision, its operator must stop
other tick loops and out consumers or explicitly keep the instance externally
managed. Discovery never stops them. Direct filesystem consumers are outside
the barrier; pause cannot withdraw work they already took.

## Consumer configuration and invocation

No conventional `consume.sh` is auto-discovered. An executable file appearing
in a schedule or instance cannot enable execution. Only an explicitly written
`runtime/config.json` opts into handoff; discovery never creates it. Example:

```json
{
  "schema_version": 1,
  "consumer": {
    "argv": ["/opt/example/bin/delivery-adapter", "--mode", "enqueue"],
    "cwd": "..",
    "env": {"EXAMPLE_QUEUE": "demo"}
  }
}
```

`argv` is a nonempty array of literal strings, never shell text. Element zero
must be an absolute executable path. `cwd` is required, resolved relative to
the canonical instance (here its parent), canonicalized and required to exist.
All relative consumer resources resolve there. Append exactly one argument,
the canonical absolute delivery directory, after the configured argv.
No shell expansion, PATH search, payload sourcing or implicit stdin input;
stdin is `/dev/null`. Consumer processes must be isolated from the runner
terminal's signal group so Ctrl-C cannot kill them as a side effect of stopping
the runner. Environment inherits the foreground runner's environment,
then applies the explicit string map, then these reserved values:

```text
GROUNDHOG_INSTANCE=/absolute/project/.groundhog
GROUNDHOG_DELIVERY_ID=d-demo-1
GROUNDHOG_ATTEMPT_ID=a-demo-1
```

Reserved names cannot be configured; owner token and token-file location must
not enter the consumer environment. Environment/configuration may hold secrets:
status exposes only consumer presence, validity and configuration digest,
never argv, env or logs. Consumers must supply their own required environment;
v1 does not promise identical environments across supervisors. No shell
profile is loaded by Groundhog. Freeze validated config for a runner lifetime;
changes require stop/start. A new configuration never resets delivery results
or bypasses an unresolved invocation from the previous configuration.
Stdout/stderr go to the runner's output streams, not the JSON protocol; status
records bounded structured errors, not unredacted consumer output.

Without configuration, cycles still fire deliveries into `out/`, mark them
`pending` with reason `no_consumer`, and never invoke anything. A later explicit
configuration plus run makes those pending deliveries eligible. An invalid or
missing executable/cwd is a visible configuration failure, not no-consumer.

## Delivery journal, acknowledgement and retry

Legacy names and payloads stay intact. Runtime records live outside the payload.
New supervised firings journal the exact schedule-relative path, fired marker,
local occurrence date and optional interval slot before exposing the delivery.
The full marker path identifies an occurrence; basename alone cannot identify
it. A delivery ID and attempt IDs are opaque and never derived from a PID.
Do not infer an old delivery's source by splitting its name: existing out names
can collide for equal item names on different schedule paths.

On explicit run, complete preexisting out directories without a record become
`pending` with `origin:legacy_out` and unknown occurrence. Ignore `.landing`
and internal staging. This imports delivery metadata only; it never implies a
successful handoff. Missing pending paths become `missing`, never recreated by
retrying handoff. Colliding existing destinations follow the legacy no-overwrite
rule for firing, but the runtime records an `out_collision` diagnostic and does
not invent a second delivery from the same directory or claim source identity.
One-shots retain legacy removal after firing, so inspect collision errors.

Immediately before invocation, persist an attempt as `in_flight`. Run only one
consumer call at a time per instance, including across stop/crash/restart.
While a call is in flight, no other consumer may be admitted. If its result is
lost, the persisted unresolved in-flight/uncertain attempt blocks all subsequent
consumer admissions until recovery, even for other deliveries. Accepted agents
may keep executing independently after their consumer handoff invocation has returned;
that execution is outside consumer-call serialization. Exit 0 is the complete
v1 acknowledgement: `accepted` means the consumer durably accepted responsibility before returning.
No stdout acknowledgement JSON is parsed. Nonzero exit, signal or exec failure
records `failed` with exit/signal/error information. A consumer that launches
an agent must return only after durable acceptance and preserve a usable prompt
path; queueing an agent does not report its final execution outcome. Consumers
must not move, delete or mutate the original delivery directory. They may copy
it into a durable queue, keyed by delivery ID for deduplication.

Accepted and failed deliveries remain in `out/` for inspection. Accepted is
terminal for automatic handoff even if the runner restarts. Failed does not
retry on each tick: `retry --delivery ID` changes only failed to pending, keeping
the same delivery ID and creating a new attempt on next admission. Repeating
retry on pending is a no-op. No implicit backoff, maximum-attempt loop, or
automatic replay of accepted deliveries exists. A new firing is a new delivery,
not a retry. If a failed handoff might already have side effects, the operator
must reconcile those before retrying; consumer deduplication remains necessary.

A crash after admission and before recording the exit result leaves an
`in_flight` attempt with outcome `unknown`. The next explicit run reconciles
that to `uncertain` and does not replay it. All subsequent consumer admissions
remain blocked, including other pending deliveries. After stopping the runner,
the operator must establish that the original consumer handoff invocation has
finished before recording either recovery decision. This does not require an
accepted agent's independent execution to finish. If the operator cannot
establish invocation completion, the barrier and ownership stay retained; a
runner lock, runner death or apparent PID absence is insufficient evidence.

The token holder then uses `recover --decision accept` only after confirming
durable acceptance, or `recover --decision retry` after reconciling side effects
to make the delivery pending. Recovery records the operator's decision with the
attempt; it does not automatically detect or terminate a detached consumer.
An abandoned `in_flight` attempt may be reconciled to `uncertain` by recover
under the same stopped-runner rules. If any other attempt remains unresolved,
the instance-wide handoff barrier stays. No exactly-once external effects are
promised, even for a reported failure.

Upgraded sweep must protect all pending, failed, uncertain and in-flight paths
and their referenced fired markers, reporting skipped entries. Accepted entries
and their records may be removed together under explicit sweep retention;
externally missing paths remain visible in records until explicitly swept as
terminal missing records. Sweep never turns an accepted item into pending.
An old sweep or manual deletion can lose evidence; compatibility cannot prevent
that. Keep unaccepted payloads until their disposition has been reconciled.

## Crash and shutdown observations

| Interruption | Durable observation and next enabled action |
|---|---|
| During staging copy | Incomplete staging, no dispatch. Next run resumes/reconciles firing; read-only status only diagnoses. |
| Out rename before fired marker | Prepared firing record binds the path to the occurrence. Reconcile marker before any new tick; never dispatch staging or duplicate a complete delivery. |
| Marker before one-shot removal | Reconcile that occurrence and remove only its original one-shot source; do not remove a newly replaced source. |
| Consumer started, no recorded result | Abandoned `in_flight` becomes `uncertain` on run/recover; all consumer admissions blocked until invocation completion is established and explicit recovery recorded; ownership retained. |
| Accepted recorded, runner dies | Accepted remains accepted; no replay; execution remains unknown. |
| Pause persisted, runner dies | Global pause remains true; token ownership remains; run cannot clear it. |
| Runner stopped, owner external | Stopped external owner still blocks enrollment. |

Prepared firing records must identify the original source generation so recovery
does not delete a replacement one-shot. Conflicting or corrupt evidence yields
a visible reconciliation error and blocks that occurrence rather than guessing.
Runtime journals do not retroactively make legacy tick copy/marker operations
transactional. Ambiguous unjournaled legacy evidence remains diagnostic.

SIGINT/SIGTERM and `stop` close admission, interrupt sleep, and detach from an
already admitted consumer call without killing it or its launched agents. If its
result cannot be collected before runner exit, record/retain `uncertain` and
require recovery; never report accepted merely because shutdown succeeded.
Runner exit and stop success do not establish that this invocation finished.
On restart the durable barrier blocks all new consumer invocations until the
operator establishes completion and records recovery. Release fails while an
unresolved attempt remains. A hanging consumer therefore cannot silently lose
its delivery, and Quit can leave retained ownership with an actionable error. Stop returns once runner exclusion is released; it does
not prove a detached handoff invocation ended or wait for independent agent
execution. A runner failure sets a structured runner error and exits nonzero,
retaining ownership and pause. Unsupported or malformed state fails closed for execution; read-only inspection remains available with
diagnostics where possible.

## Read-only JSON projection

`status --json` is the single schedule, ownership and delivery projection; no
separate JSON `list` or `due` variant is proposed. Required fields follow this
synthetic snapshot. Paths in arrays are relative to the instance; `instance`
is canonical absolute. Times are UTC RFC 3339; occurrence dates/slots use the
instance's local scheduling time. IDs and ordering carry no time semantics.

```json
{
  "protocol": "groundhog-runtime",
  "protocol_version": 1,
  "instance": "/example/project/.groundhog",
  "observed_at": "2026-11-15T00:01:00Z",
  "revision": 12,
  "consistent": true,
  "paused": true,
  "owner": {"id": "o-demo", "generation": 1, "label": "demo-session"},
  "runner": {"state": "stopped", "last_error": null},
  "consumer": {"configured": false, "valid": true, "config_digest": null},
  "schedule": [
    {
      "path": "schedule/daily/nudge",
      "item_id": "nudge",
      "paused_by": [],
      "eligible_now": false,
      "fired_marker": "fired/2026-11-15/daily/nudge",
      "fired": true,
      "firing_allowed": false,
      "blocked_by": ["already_fired", "instance_paused", "owned"]
    }
  ],
  "deliveries": [
    {
      "id": "d-demo-1",
      "path": "out/nudge-2026-11-15",
      "origin": "runtime",
      "schedule_path": "schedule/daily/nudge",
      "occurrence": {"date": "2026-11-15", "slot": null},
      "state": "pending",
      "reason": "no_consumer",
      "attempts": [],
      "execution": "unknown"
    }
  ],
  "diagnostics": []
}
```

Owner is null when unowned; it never exposes the verifier/token secret. Its
`id` and `generation` match the nonsecret metadata in the private token file for
enrollment reconciliation; matching them alone grants no authority. Runner
states: `stopped`, `running`, `stopping`, `unknown`, `failed`. Liveness evidence may
include a diagnostic PID/start ID/heartbeat, but grants no control. Delivery
states: `pending`, `in_flight`, `accepted`, `failed`, `uncertain`, `missing`.
Each attempt has `id`, `started_at`, nullable `finished_at`, `outcome` (in_flight,
accepted, failed, unknown), nullable `exit_code`, `signal` and structured `error`.
Recovery adds `decision` and `decided_at`. Any unresolved `in_flight` or
`uncertain` delivery blocks every consumer admission even when runner state is
`stopped` or `running`. Status displays these records without deciding whether
the original invocation finished; runner liveness cannot clear the barrier.
Error/diagnostic objects contain a stable `code`, a human `message` and nullable
instance-relative `path`.

`eligible_now` means the legacy due calculation including fired-marker
suppression and subtree pause, independent of global pause and ownership.
`firing_allowed` describes a standalone tick now: false when ineligible or
blocked by pause, an owner,
invalid state or lock conflict; the enrolled runner instead uses its token.
`blocked_by` uses `not_due`, `subtree_paused`, `already_fired`,
`instance_paused`, `owned`, `invalid_state` and `busy` as applicable.
`paused_by` lists schedule components ending in `.paused`. `fired_marker` is
the current candidate marker, or null if no applicable occurrence exists.
Schedule records include recognized items even when not due; unrecognized
paths appear in diagnostics, with no payload execution or recursive payload
interpretation. Empty optional directories yield empty arrays and defaults.
`revision` is 0 without state; it tracks protocol writes, not arbitrary manual
filesystem edits. Even `consistent:true` is an observation, never authorization
for a subsequent mutation. Control always rechecks under lock.

An unrecorded out entry appears read-only with null ID, `origin:legacy_out`,
null schedule/occurrence, state pending and reason `unregistered`; status does
not register it. A read observing an abandoned in-flight record keeps that
record visible and reports unknown outcome; only a later explicit run/recovery
may change it to uncertain. Missing or malformed runtime files appear in
diagnostics. Do not synthesize execution success from absence in out.

## Synthetic command and transition walkthrough

These commands illustrate the future contract only. All paths and IDs are
synthetic; do not run them against operational schedules with today's script.
The token parent directory must already exist and be private.

```sh
GH=/example/project/.groundhog/groundhog.sh
"$GH" capabilities --json
"$GH" status --json                          # leaves disk unchanged
"$GH" enroll --owner-label demo-session --token-file /example/session/owner-token
# Continue only after enroll returned 0, or explicit reconciliation confirmed ownership.
"$GH" resume --token-file /example/session/owner-token
"$GH" run --token-file /example/session/owner-token --interval-seconds 60
# From a second terminal holding the same session token:
"$GH" pause --token-file /example/session/owner-token
"$GH" stop --token-file /example/session/owner-token
"$GH" release --token-file /example/session/owner-token
# Ownership is absent again; global pause remains true.
```

| Synthetic sequence | Observable result |
|---|---|
| Scan unowned instance | owner null, runner stopped; no disk writes or firings. |
| Enroll, resume, run without consumer | owner retained, enabled tick deposits d-demo-1; pending/no_consumer. |
| Pause with d-demo-1 pending | Global pause true; no handoff; out and fired unchanged. |
| Stop, configure consumer, run while paused | Runner running but idle; pending remains pending. |
| Resume, consumer exits 0 | pending → in_flight → accepted; original out path retained; execution unknown. |
| Consumer exits 7 for d-demo-2 | in_flight → failed; later cycles do not retry. |
| Stop, retry d-demo-2, run | failed → pending → new in_flight attempt; delivery ID unchanged. |
| Stop detaches d-demo-3 consumer A, explicit restart while A may still act | in_flight → uncertain; consumer B and all other consumer admissions blocked, including with new config; enabled ticks may add pending deliveries. |
| Crash during d-demo-3 invocation, explicit restart | Same barrier; runner exclusion does not establish that A ended. |
| Stop, cannot establish A finished | No accept/retry recovery decision; barrier and ownership retained; release fails. |
| Stop, establish A finished and durable acceptance, recover d-demo-3 with decision accept | uncertain → accepted with decision, no consumer invocation; independent accepted agent may continue; next explicit run can admit B if no other unresolved attempt. |
| Stop, establish A finished and reconcile side effects, recover d-demo-3 with decision retry | uncertain → pending; next explicit run may create a new attempt if no other unresolved invocation. |
| External supervisor stops without release | owner retained, runner stopped; other supervisor enroll fails 3. |
| Quit cleanly, reopen viewer | No owner, runner stopped, pause retained; no auto-enrollment or start. |

Enrollment failure examples (no new command is needed):

| Synthetic sequence | Observable result and caller action |
|---|---|
| Token write fails before owner replacement | enroll exits 6; no ownership granted; explicitly remove any unused partial file before a new attempt. |
| Token durable, crash before owner replacement | Command result lost; retain usable token; after process exit and healthy storage, coherent status has owner null; explicitly discard unused token before re-enrollment. |
| Owner replaced, subsequent directory sync fails | enroll exits 7; retain usable token, start nothing; healthy coherent status matching token metadata (`instance`, owner ID o-demo, generation 1) identifies the enrollment; explicit control still validates the secret. |
| Enrollment succeeds but caller loses result | Treat as uncertain; same read-only reconciliation, no automatic start. |
| Reconciliation sees another owner ID/generation with the same label | Token is stale/unused for current ownership; label grants no control or takeover. |
| Reconciliation read is inconsistent or reports storage/state errors | Outcome unresolved; retain token, no work or automatic enrollment. |

## Compatibility and acceptance points

No payload fields, schedule grammar or consumer migration is required for
passive users. Existing out paths and fired-marker paths retain their meaning.
Upgraded tick gains pause/ownership exclusion only for opted-in state; ordinary
unowned, unpaused ticking remains delivery-only. Runtime-owned deliveries add
metadata beside, never inside, opaque payloads. Existing direct consumers may
continue unchanged when the instance remains externally managed.

The source script currently has no locking, ownership, consumer, pause bit or
runtime journal. Its `due`/`list`/`out` call `ensure_dirs`, so they are not strictly
write-free on an uninitialized instance. Its out-name collision warning records
a firing without overwrite, and one-shot cleanup still follows. Neither its
fired marker nor a missing out entry demonstrates execution. Proposed status
must not reuse those directory-creating code paths for inspection.

Decisions for Bob before implementation: persistent ownership with manual
lost-token repair; explicit configured argv rather than an automatic hook;
exit-zero durable acceptance rather than stdout JSON; retained payloads and
manual retries/recovery; cooperative local locking and no mixed-version pause
guarantee; upgraded standalone tick refusal while owned; and clean supervisor
release only after unresolved handoffs have been reconciled. No dependent
runtime implementation is authorized by this document.
