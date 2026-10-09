#!/usr/bin/env bash
# Build rv and run TUI regression scripts.
#   mise run tui-regress           small only
#   mise run tui-regress -- large  generated large fixture
#   mise run tui-regress -- --all  small, then large
set -euo pipefail

usage() {
  echo "usage: mise run tui-regress -- [small|large|--all]" >&2
  exit 2
}

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)
cd "$root"

target=small
if [[ $# -gt 1 ]]; then
  usage
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    small | large | --all) target=$1 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
fi

zig build
rv=$root/zig-out/bin/rv
[[ -x $rv ]] || {
  echo "rv-tui: missing binary: $rv" >&2
  exit 1
}

run_small() {
  local name
  for name in boot hunk-nav approve-hunk approve-file unapprove comment layout statuses; do
    echo "rv-tui: $name"
    "$script_dir/drive.sh" --rv "$rv" --fixture small "$script_dir/tui/$name"
  done
  echo "rv-tui: layout-narrow"
  "$script_dir/drive.sh" --rv "$rv" --fixture small --cols 48 "$script_dir/tui/layout-narrow"
}

run_large() {
  local name
  for name in approve-one approve-all; do
    echo "rv-tui: $name"
    "$script_dir/drive.sh" --rv "$rv" --fixture large "$script_dir/tui/$name"
  done
}

case "$target" in
  small) run_small ;;
  large) run_large ;;
  --all) run_small; run_large ;;
esac
