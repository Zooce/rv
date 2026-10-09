#!/usr/bin/env bash
# Build a git worktree from regress/fixtures/<name>/ into dest (default /tmp/rv-regress).
set -euo pipefail

usage() {
  echo "usage: mise run fixture -- [name] [dest]" >&2
  echo "  name  fixture under regress/fixtures/ (default small)" >&2
  echo "  dest  directory under /tmp (default /tmp/rv-regress)" >&2
  exit 2
}

die() {
  echo "rv-fixture: $*" >&2
  exit 1
}

name=small
dest=/tmp/rv-regress
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  usage
fi
if [[ -n ${1:-} ]]; then
  name=$1
fi
if [[ -n ${2:-} ]]; then
  dest=$2
fi
if [[ -n ${3:-} ]]; then
  usage
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)
fixture=$root/regress/fixtures/$name
series=$fixture/series

[[ $name == */* || $name == .* || $name == *..* ]] && die "invalid fixture name: $name"
[[ -d $fixture ]] || die "no fixture directory: $fixture"
[[ -f $series ]] || die "missing series file: $series"

# Isolate from user/system gitconfig (identity, excludes, aliases).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="rv regress"
export GIT_AUTHOR_EMAIL="rv@regress"
export GIT_COMMITTER_NAME="rv regress"
export GIT_COMMITTER_EMAIL="rv@regress"
export GIT_AUTHOR_DATE="2000-01-01T00:00:00Z"
export GIT_COMMITTER_DATE="2000-01-01T00:00:00Z"

if [[ $dest != /* ]]; then
  die "dest must be an absolute path under /tmp"
fi
dest=$(realpath -m -- "$dest")
if [[ $dest != /tmp/* || $dest == /tmp ]]; then
  die "dest must be a directory under /tmp (got $dest)"
fi
case "$dest" in
  "$root" | "$root"/*) die "dest must not be inside the rv work tree: $dest" ;;
esac
case "$dest" in
  *..*) die "dest must not contain ..: $dest" ;;
esac

rm -rf -- "$dest"
mkdir -p -- "$dest"

git_ok() {
  git -C "$dest" "$@"
}

git_ok init -b main
git_ok config user.email rv@regress
git_ok config user.name "rv regress"

apply_patch() {
  local mode=$1 patch=$2
  local extra=()
  case "$mode" in
    commit | cached)
      # Index + worktree so a later worktree patch is the unstaged remainder.
      extra=(--index)
      ;;
    worktree) extra=() ;;
    *) die "internal: apply_patch mode $mode" ;;
  esac
  git_ok apply --whitespace=nowarn "${extra[@]}" -- "$patch" || die "git apply failed ($mode): $patch"
}

copy_tree() {
  local src=$1 target=$2
  mkdir -p -- "$target"
  cp -a -- "$src"/. "$target"/
}

while IFS= read -r line || [[ -n $line ]]; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  read -r mode rel <<<"$line"
  [[ -n ${rel:-} ]] || die "series line missing path: $line"
  case "$rel" in
    /* | *..*) die "series path must be relative with no ..: $rel" ;;
  esac
  src=$fixture/$rel
  case "$mode" in
    commit)
      [[ -f $src ]] || die "missing patch: $src"
      apply_patch commit "$src"
      msg=$(basename -- "$rel" .patch)
      git_ok commit -m "$msg"
      ;;
    cached)
      [[ -f $src ]] || die "missing patch: $src"
      apply_patch cached "$src"
      ;;
    worktree)
      [[ -f $src ]] || die "missing patch: $src"
      apply_patch worktree "$src"
      ;;
    untracked)
      [[ -d $src ]] || die "missing untracked dir: $src"
      copy_tree "$src" "$dest"
      ;;
    rv)
      [[ -d $src ]] || die "missing rv dir: $src"
      copy_tree "$src" "$dest/.rv"
      ;;
    *) die "unknown series mode '$mode' in: $line" ;;
  esac
done <"$series"

if [[ -f $fixture/expected.status ]]; then
  got=$(git_ok status --porcelain=v1)
  want=$(cat "$fixture/expected.status")
  if [[ $got != "$want" ]]; then
    echo "rv-fixture: git status --porcelain=v1 does not match expected.status" >&2
    echo "--- expected ---" >&2
    printf '%s\n' "$want" >&2
    echo "--- got ---" >&2
    printf '%s\n' "$got" >&2
    exit 1
  fi
fi

printf 'rv-fixture: %s -> %s\n' "$name" "$dest"
