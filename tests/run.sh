#!/usr/bin/env bash
# Run the Groundhog tests under every bash found (macOS's stock /bin/bash 3.2
# and, if installed, a newer one).
#
#   tests/run.sh                    all tests, all bashes found
#   tests/run.sh test_state.sh ...  only the named tests
#   TEST_BASHES="/bin/bash /opt/homebrew/bin/bash" tests/run.sh
#
# Needs: python3 (parses the script's JSON output), standard POSIX tools.
# Optional: jq (a second, independent JSON parser for every document).
# Scratch instances are built under $TMPDIR (default /tmp) and removed after.
# Tests only ever run copies of the script in temporary directories; they never
# tick a real schedule.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

if ! python3 -I -c 'import json' >/dev/null 2>&1; then
  echo "tests/run.sh: python3 is required to parse JSON output" >&2
  exit 2
fi

bashes="${TEST_BASHES:-}"
if [ -z "$bashes" ]; then
  for b in /bin/bash /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)"; do
    [ -x "$b" ] || continue
    case " $bashes " in *" $b "*) continue ;; esac
    # Skip a second path to the same bash binary.
    dup=0
    for seen in $bashes; do [ "$seen" -ef "$b" ] && dup=1; done
    [ "$dup" -eq 1 ] || bashes="$bashes $b"
  done
fi

if [ "$#" -gt 0 ]; then tests="$*"; else
  tests=""
  for f in "$here"/test_*.sh; do tests="$tests $(basename "$f")"; done
fi

failed=0
for b in $bashes; do
  printf '=== %s (%s)\n' "$b" "$("$b" -c 'echo $BASH_VERSION')"
  for t in $tests; do
    if ! TEST_BASH="$b" "$b" "$here/$t"; then failed=$((failed + 1)); fi
  done
done

if [ "$failed" -eq 0 ]; then
  echo "all tests passed"
else
  echo "$failed test file run(s) failed" >&2
  exit 1
fi
