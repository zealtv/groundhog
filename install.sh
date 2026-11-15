#!/usr/bin/env bash
# usage: ./install.sh <host-dir>
# Lays down a .groundhog/ at the host directory — a sanctioned standalone
# install for scopes not delivered by any bundle. Idempotent: re-running
# repairs groundhog.sh and README.md and re-seeds missing trays (via
# groundhog.sh init); it never touches schedule/out/fired contents.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:?usage: install.sh <host-dir>}"
[ -d "$target" ] || { echo "no such host dir: $target" >&2; exit 1; }

dest="$target/.groundhog"
mkdir -p "$dest"
cp -f "$REPO_DIR/.groundhog/groundhog.sh" "$dest/groundhog.sh"
chmod +x "$dest/groundhog.sh"
cp -f "$REPO_DIR/README.md" "$dest/README.md"
"$dest/groundhog.sh" init

echo "installed $dest"
