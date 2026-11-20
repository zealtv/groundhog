# Shared helpers for the Groundhog tests. Source it; do not run it.
#
# Needs: bash (3.2 or newer), python3 (parses the JSON the script prints; the
# script itself never uses it), and the usual POSIX tools. jq is optional: when
# present it re-validates every JSON document as a second, independent parser.
#
# Environment:
#   TEST_BASH   bash that runs the script under test (default: bash on PATH)
#   GH_SCRIPT   script under test (default: ../.groundhog/groundhog.sh)
#   TMPDIR      where scratch instances are built

T_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T_REPO_DIR="$(dirname "$T_LIB_DIR")"
GH_SCRIPT="${GH_SCRIPT:-$T_REPO_DIR/.groundhog/groundhog.sh}"
TEST_BASH="${TEST_BASH:-bash}"
T_PASS=0
T_FAIL=0
T_SKIP=0

# Canonical (no "//", no symlinks) so path comparisons against script output hold.
T_TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/groundhog-tests.XXXXXX")" && pwd -P)"
T_REAL_DATE="$(command -v date)"
T_HAVE_JQ=0
command -v jq >/dev/null 2>&1 && T_HAVE_JQ=1

# Loops and lock holders the test started; t_finish and t_cleanup make sure none outlives it.
T_PIDS=""

# wrappers_left — pids of handler wrappers still running for this test's
# instances (each is its own session and process-group leader).
wrappers_left() { pgrep -f "_handle $T_TMP/" 2>/dev/null || true; }

t_cleanup() {
  local p
  for p in $T_PIDS; do kill -9 "$p" 2>/dev/null || true; done
  for p in $(wrappers_left); do kill -9 -- "-$p" 2>/dev/null || true; done
  chmod -R u+rwx "$T_TMP" 2>/dev/null || true
  rm -rf "$T_TMP"
}
trap t_cleanup EXIT

# --- assertions --------------------------------------------------------------
t_ok()   { T_PASS=$((T_PASS + 1)); }
t_fail() {
  T_FAIL=$((T_FAIL + 1))
  printf 'FAIL [%s]: %s\n' "$(basename "$0")" "$1" >&2
  if [ -n "${2:-}" ]; then printf '        %s\n' "$2" >&2; fi
}
t_skip() { T_SKIP=$((T_SKIP + 1)); printf 'skip: %s\n' "$1" >&2; }

assert_eq() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then t_ok; else t_fail "$1" "expected: $2 | actual: $3"; fi
}
assert_true() { # DESC COMMAND…
  local desc="$1"; shift
  if "$@"; then t_ok; else t_fail "$desc" "command failed: $*"; fi
}
assert_false() { # DESC COMMAND…
  local desc="$1"; shift
  if "$@"; then t_fail "$desc" "command unexpectedly succeeded: $*"; else t_ok; fi
}
assert_contains() { # DESC HAYSTACK NEEDLE
  case "$2" in *"$3"*) t_ok ;; *) t_fail "$1" "missing: $3 | in: $2" ;; esac
}
assert_not_contains() { # DESC HAYSTACK NEEDLE
  case "$2" in *"$3"*) t_fail "$1" "unexpected: $3" ;; *) t_ok ;; esac
}

t_finish() {
  local p
  for p in $T_PIDS; do
    if kill -0 "$p" 2>/dev/null; then t_fail "the test left a process behind (pid $p)"; kill -9 "$p" 2>/dev/null || true; fi
  done
  for p in $(wrappers_left); do
    t_fail "the test left a run behind (wrapper pid $p)"; kill -9 -- "-$p" 2>/dev/null || true
  done
  printf '%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$T_PASS" "$T_FAIL" "$T_SKIP"
  [ "$T_FAIL" -eq 0 ]
}

# --- instances ---------------------------------------------------------------
INST=""
GHD=""
T_COUNTER=0

# new_instance — a fresh scratch directory holding only a copy of the script.
# Sets INST (the project dir) and GHD (its .groundhog dir). Not initialized.
new_instance() {
  T_COUNTER=$((T_COUNTER + 1))
  INST="$T_TMP/inst$T_COUNTER"
  GHD="$INST/.groundhog"
  mkdir -p "$GHD"
  cp "$GH_SCRIPT" "$GHD/groundhog.sh"
  chmod +x "$GHD/groundhog.sh"
}

# gh ARGS… — run the script in the current instance with TEST_BASH.
gh() { "$TEST_BASH" "$GHD/groundhog.sh" "$@"; }

# status_to FILE — run `status --json`, stdout to FILE, stderr to FILE.err.
# Returns the exit status.
status_to() {
  local rc=0
  gh status --json > "$1" 2> "$1.err" || rc=$?
  return "$rc"
}

# --- JSON --------------------------------------------------------------------
jq_py() { python3 -I "$T_LIB_DIR/jsonq.py" "$@"; }

# assert_status_valid FILE — one line, one object, parses with python (and jq).
assert_json_valid() {
  if jq_py valid "$1" 2>/dev/null; then t_ok; else t_fail "valid JSON document: $1" "$(head -c 300 "$1")"; fi
  if [ "$T_HAVE_JQ" -eq 1 ]; then
    if jq -e 'type == "object"' "$1" >/dev/null 2>&1; then t_ok; else t_fail "jq also parses: $1"; fi
  fi
}

# jget FILE PATH — compact JSON at the dotted PATH.
jget() { jq_py get "$1" "$2"; }

# --- clock -------------------------------------------------------------------
# The script reads time only through `date`. To test arbitrary moments without
# a test hook in the script, set_clock puts a `date` shim first on PATH that
# replays the real date at a fixed instant. TZ stays whatever the caller set.
T_SHIM="$T_TMP/shim"

epoch_for() { # "YYYY-MM-DD HH:MM:SS" in $TZ
  if "$T_REAL_DATE" -d "1970-01-01 00:00:00" >/dev/null 2>&1; then
    "$T_REAL_DATE" -d "$1" +%s
  else
    "$T_REAL_DATE" -j -f "%Y-%m-%d %H:%M:%S" "$1" +%s
  fi
}

set_clock() { # "YYYY-MM-DD HH:MM:SS"
  local epoch flag
  mkdir -p "$T_SHIM"
  epoch="$(epoch_for "$1")"
  if "$T_REAL_DATE" -d @0 >/dev/null 2>&1; then flag="-d @"; else flag="-r "; fi
  cat > "$T_SHIM/date" <<SHIM
#!/bin/sh
# Test shim: replays the real date at a fixed instant. A one-shot hook file
# runs on the first call that is not the UTC "observed_at" call (the script
# makes that one before it reads any state), so a test can change files while
# status is part-way through reading.
case " \$* " in
  *" -u "*) ;;
  *)
    if [ -f "$T_SHIM/hook" ]; then
      hook="$T_SHIM/hook.run"
      mv "$T_SHIM/hook" "\$hook"
      sh "\$hook"
      rm -f "\$hook"
    fi
    ;;
esac
if [ "$flag" = "-d @" ]; then
  exec "$T_REAL_DATE" -d "@$epoch" "\$@"
else
  exec "$T_REAL_DATE" -r "$epoch" "\$@"
fi
SHIM
  chmod +x "$T_SHIM/date"
  case ":$PATH:" in *":$T_SHIM:"*) ;; *) PATH="$T_SHIM:$PATH"; export PATH ;; esac
}

clear_clock() {
  rm -rf "$T_SHIM"
}

# --- trees -------------------------------------------------------------------
# tree_hash DIR — checksum of every path, mode, inode, mtime, size and file
# content below DIR. Any create, delete, rewrite, rename or touch changes it.
tree_hash() {
  (
    cd "$1" || exit 1
    if stat -f %m . >/dev/null 2>&1; then
      find . -exec stat -f '%N %Sp %i %m %z' {} +
    else
      find . -exec stat -c '%n %A %i %Y %s' {} +
    fi 2>/dev/null | LC_ALL=C sort
    # Files a test made unreadable on purpose are covered by the stat line only.
    find . -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort
  ) | cksum
}

# age_tree DIR — push every mtime into the past, so a later touch or rewrite
# (even of identical content) shows up in tree_hash.
age_tree() {
  find "$1" -exec touch -h -t 202001010000 {} + 2>/dev/null || find "$1" -exec touch -t 202001010000 {} + 2>/dev/null
}

# --- host support ------------------------------------------------------------
# have_lock_helper — util-linux flock(1), or perl with Fcntl (mirrors rt_detect).
have_lock_helper() {
  local v
  if command -v flock >/dev/null 2>&1; then
    v="$(flock --version 2>&1 || true)"; case "$v" in *util-linux*) return 0 ;; esac
  fi
  command -v perl >/dev/null 2>&1 && perl -MFcntl=:flock -e 'exit 0' >/dev/null 2>&1
}
# have_isolation — can this host start a run in a session of its own?
have_isolation() {
  if command -v perl >/dev/null 2>&1 && perl -MPOSIX -e 'exit 0' >/dev/null 2>&1; then return 0; fi
  command -v setsid >/dev/null 2>&1
}
# have_handlers — capability handlers-v1 on this host.
have_handlers() { have_lock_helper && have_isolation; }

# --- waiting -------------------------------------------------------------------
# wait_for DESC TRIES COMMAND… — poll every 0.1s, up to TRIES times.
wait_for() {
  local desc="$1" tries="$2" i=0
  shift 2
  while [ "$i" -lt "$tries" ]; do
    if "$@" 2>/dev/null; then t_ok; return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  t_fail "timed out waiting for: $desc"
  return 1
}

# wait_exit DESC TRIES PID — wait for a process to end; sets WAIT_RC.
WAIT_RC=""
wait_exit() {
  local desc="$1" tries="$2" pid="$3" i=0
  while [ "$i" -lt "$tries" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      WAIT_RC=0; wait "$pid" 2>/dev/null || WAIT_RC=$?
      t_ok; return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  t_fail "timed out waiting for exit: $desc"
  kill -9 "$pid" 2>/dev/null || true
  WAIT_RC=""
  return 1
}

# --- locks -----------------------------------------------------------------------
# lock_is_free FILE — can another process take the lock right now? (flock(2),
# the same family the script uses.)
lock_is_free() {
  python3 -I -c 'import fcntl,sys
f=open(sys.argv[1],"a")
try:
    fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)
except OSError:
    sys.exit(1)' "$1"
}
lock_is_held() { ! lock_is_free "$1"; }

# hold_lock FILE SECONDS — hold the lock from a background process. Sets
# HOLD_PID after the lock is taken.
HOLD_PID=""
hold_lock() {
  local ready="$T_TMP/hold.ready"
  rm -f "$ready"
  python3 -I -c 'import fcntl,sys,time
f=open(sys.argv[1],"a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[3],"w").write("x")
time.sleep(float(sys.argv[2]))' "$1" "$2" "$ready" &
  HOLD_PID=$!
  T_PIDS="$T_PIDS $HOLD_PID"
  wait_for "lock holder ready" 50 test -e "$ready"
}

# --- out/, records and runs ---------------------------------------------------------
# out_count — number of entries in the instance's out/.
out_count() { find "$GHD/out" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }
out_is() { [ "$(out_count)" = "$1" ]; }
today() { date +%Y-%m-%d; }

# with_run WHEN ID BODY — add an item whose executable `run` is a /bin/sh
# script with BODY. Every test run writes its pid to $1/pid first, so a test
# can find it (its process group is the wrapper's).
with_run() {
  gh add "$1" "$2" >/dev/null 2>&1 || { t_fail "add $1 $2"; return 1; }
  printf '#!/bin/sh\necho $$ > "$1/pid"\n%s\n' "$3" > "$GHD/schedule/$1/$2/run"
  chmod +x "$GHD/schedule/$1/$2/run"
}

# rec NAME — path of out/NAME's record; log NAME — its run's log.
rec() { printf '%s' "$GHD/out/$1/.groundhog-record"; }
log() { printf '%s' "$GHD/out/$1/.groundhog-log"; }
# rec_has NAME REGEX — does a line of out/NAME's record match?
rec_has() { grep -Eq "$2" "$(rec "$1")" 2>/dev/null; }
# rec_count NAME KIND — lines of KIND (fired, start, exit, collision).
rec_count() { grep -c "^$2 " "$(rec "$1")" 2>/dev/null || true; }
# exited NAME N — the record holds N exit lines (for wait_for).
exited() { [ "$(rec_count "$1" exit)" -ge "$2" ]; }
# wrapper_of NAME — pid of the wrapper running out/NAME's run, if any.
wrapper_of() { pgrep -f "_handle $GHD/out/$1 " 2>/dev/null | head -1; }
running() { [ -n "$(wrapper_of "$1")" ]; }
# kill_run NAME [SIGNAL] — signal the run's whole session (wrapper and run).
kill_run() { local w; w="$(wrapper_of "$1")"; [ -n "$w" ] && kill "-${2:-TERM}" -- "-$w" 2>/dev/null; return 0; }

# dget BY VALUE PATH — a field of the delivery whose BY (path or id) equals
# VALUE, from a fresh status. While DG_CACHED is 1, dget reads the last
# snapshot instead (assertion-heavy blocks take one with snap).
DG_CACHED=0
snap() { status_to "$T_TMP/dg.json" || true; DG_CACHED=1; }
dget() {
  if [ "$DG_CACHED" != 1 ]; then status_to "$T_TMP/dg.json" || true; fi
  jq_py dget "$T_TMP/dg.json" "$1" "$2" "$3"
}
# dstate NAME — state of the delivery at out/NAME; state_is NAME STATE.
dstate() { dget path "out/$1" state; }
state_is() { [ "$(dstate "$1")" = "\"$2\"" ]; }

# start_loop ARGS… — `run` (the plain loop) in the background. Job control
# gives it its own process group and default signal handling, so INT reaches
# it as it would from a terminal. Sets LOOP_PID, LOOP_OUT, LOOP_ERR.
T_LOOPS=0
LOOP_PID=""; LOOP_OUT=""; LOOP_ERR=""
start_loop() {
  T_LOOPS=$((T_LOOPS + 1))
  LOOP_OUT="$T_TMP/loop$T_LOOPS.out"
  LOOP_ERR="$T_TMP/loop$T_LOOPS.err"
  set -m
  "$TEST_BASH" "$GHD/groundhog.sh" run "$@" > "$LOOP_OUT" 2> "$LOOP_ERR" &
  LOOP_PID=$!
  set +m
  T_PIDS="$T_PIDS $LOOP_PID"
}

# rc_of COMMAND… — the exit status, output discarded.
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
# lines FILE — number of lines (0 if absent).
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
