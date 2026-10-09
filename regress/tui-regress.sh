#!/usr/bin/env bash
# Build rv and run the small TUI regression scripts.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)
cd "$root"

zig build
rv=$root/zig-out/bin/rv
[[ -x $rv ]] || {
  echo "rv-tui: missing binary: $rv" >&2
  exit 1
}

for name in boot hunk-nav approve-hunk; do
  echo "rv-tui: $name"
  "$script_dir/drive.sh" --rv "$rv" --fixture small "$script_dir/tui/$name"
done
