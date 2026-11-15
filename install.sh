#!/usr/bin/env bash
# usage: ./install.sh <host-dir>
# Lays down a .groundhog/ at the host directory — a sanctioned standalone
# install for scopes not delivered by any bundle. Idempotent: re-running
# repairs groundhog.sh and README.md and re-seeds missing trays (via
# groundhog.sh init); it never touches schedule/out/fired contents or
# runtime/. The script is replaced by a temp file plus rename, so a process
# already running keeps the old file (bash reads its script lazily); only a
# runner started afterwards uses the new one. Stopping a runner first remains
# the way to be sure which version runs.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:?usage: install.sh <host-dir>}"
[ -d "$target" ] || { echo "no such host dir: $target" >&2; exit 1; }

dest="$target/.groundhog"
mkdir -p "$dest"
tmp="$(mktemp "$dest/.groundhog.sh.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp -f "$REPO_DIR/.groundhog/groundhog.sh" "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$dest/groundhog.sh"
cp -f "$REPO_DIR/README.md" "$dest/README.md"
# An owned instance refuses `init` (exit 3): its trays already exist and its
# owner's runner is the only writer. Leave them alone; any other failure stops us.
rc=0
"$dest/groundhog.sh" init || rc=$?
if [ "$rc" -eq 3 ]; then
  echo "note: $dest is owned by a runtime owner; trays and runtime state left untouched" >&2
elif [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

echo "installed $dest"
