#!/usr/bin/env bash
# usage: ./install.sh <host-dir>
# Upgrades the .groundhog/ at the host directory (it also makes one if absent).
# To install, copy the .groundhog/ directory; this script is the upgrade path.
# It refreshes what groundhog ships (groundhog.sh, README.md,
# docs/runtime-contract.md), seeds what is absent (the trays, via
# groundhog.sh init), and never touches schedule/, out/ or fired/ contents or
# runtime/. Re-running changes nothing. The script is replaced by a temp file
# plus rename, so a process already running keeps the old file (bash reads its
# script lazily); only a runner started afterwards uses the new one. Stopping
# a runner first remains the way to be sure which version runs.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:?usage: install.sh <host-dir>}"
[ -d "$target" ] || { echo "no such host dir: $target" >&2; exit 1; }

dest="$target/.groundhog"
mkdir -p "$dest"
# Source and destination can be the same file (./install.sh .): skip the copy.
if [ ! "$REPO_DIR/.groundhog/groundhog.sh" -ef "$dest/groundhog.sh" ]; then
  tmp="$(mktemp "$dest/.groundhog.sh.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  cp -f "$REPO_DIR/.groundhog/groundhog.sh" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest/groundhog.sh"
fi
[ "$REPO_DIR/.groundhog/README.md" -ef "$dest/README.md" ] ||
  cp -f "$REPO_DIR/.groundhog/README.md" "$dest/README.md"
mkdir -p "$dest/docs"
[ "$REPO_DIR/.groundhog/docs/runtime-contract.md" -ef "$dest/docs/runtime-contract.md" ] ||
  cp -f "$REPO_DIR/.groundhog/docs/runtime-contract.md" "$dest/docs/runtime-contract.md"
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
