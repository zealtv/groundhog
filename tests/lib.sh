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

t_cleanup() {
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

# --- runtime support ---------------------------------------------------------
# have_runtime_support — does this host have what the script needs for the
# runner (a lock helper, a hash tool, durable writes)? Mirrors rt_detect.
have_runtime_support() {
  local lock=0 hash=0 sync=0 v
  if command -v flock >/dev/null 2>&1; then
    v="$(flock --version 2>&1 || true)"; case "$v" in *util-linux*) lock=1 ;; esac
  fi
  if [ "$lock" -eq 0 ] && command -v perl >/dev/null 2>&1 && perl -MFcntl=:flock -e 'exit 0' >/dev/null 2>&1; then lock=1; fi
  for v in sha256sum shasum openssl; do command -v "$v" >/dev/null 2>&1 && hash=1; done
  if command -v perl >/dev/null 2>&1 && perl -MIO::Handle -e 'exit 0' >/dev/null 2>&1; then sync=1
  elif command -v sync >/dev/null 2>&1; then sync=1; fi
  [ "$lock" -eq 1 ] && [ "$hash" -eq 1 ] && [ "$sync" -eq 1 ] && [ -r /dev/urandom ]
}
