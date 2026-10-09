#!/usr/bin/env bash
# Run one TUI script against a materialized fixture in a detached tmux session.
set -euo pipefail

usage() {
  echo "usage: regress/drive.sh --rv PATH [--fixture NAME] [--dest DIR] [--timeout SEC] [--cols N] [--rows N] SCRIPT" >&2
  exit 2
}

die() {
  echo "rv-tui: $*" >&2
  exit 1
}

rv=""
fixture=small
dest=""
timeout=10
cols=100
rows=32
script=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rv)
      [[ $# -ge 2 ]] || usage
      rv=$2
      shift 2
      ;;
    --fixture)
      [[ $# -ge 2 ]] || usage
      fixture=$2
      shift 2
      ;;
    --dest)
      [[ $# -ge 2 ]] || usage
      dest=$2
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || usage
      timeout=$2
      shift 2
      ;;
    --cols)
      [[ $# -ge 2 ]] || usage
      cols=$2
      shift 2
      ;;
    --rows)
      [[ $# -ge 2 ]] || usage
      rows=$2
      shift 2
      ;;
    -h | --help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z $script ]] || usage
      script=$1
      shift
      ;;
  esac
done
if [[ $# -gt 0 ]]; then
  [[ -z $script ]] || usage
  script=$1
  shift
fi
[[ $# -eq 0 ]] || usage
[[ -n $rv ]] || die "missing --rv"
[[ -n $script ]] || usage
[[ -f $script ]] || die "no script: $script"
[[ -x $rv ]] || die "rv is not executable: $rv"
[[ $cols =~ ^[1-9][0-9]*$ ]] || die "cols must be a positive number"
[[ $rows =~ ^[1-9][0-9]*$ ]] || die "rows must be a positive number"
command -v tmux >/dev/null || die "tmux not found"

script_dir=$(cd "$(dirname "$0")" && pwd)
rv=$(realpath -- "$rv")
script=$(realpath -- "$script")

if [[ -z $dest ]]; then
  dest=/tmp/rv-regress-$$
fi

session=rv-tui-$$
started=0

cleanup() {
  local ec=$?
  if [[ $started -eq 1 ]]; then
    tmux kill-session -t "$session" 2>/dev/null || true
  fi
  if [[ $ec -eq 0 ]]; then
    rm -rf -- "$dest"
  else
    echo "rv-tui: dest kept: $dest" >&2
  fi
}
trap cleanup EXIT

"$script_dir/materialize.sh" "$fixture" "$dest" >/dev/null

tmux new-session -d -s "$session" -x "$cols" -y "$rows" -c "$dest"
started=1
tmux send-keys -t "$session" -l "$rv"
tmux send-keys -t "$session" Enter

dump_pane() {
  echo "--- pane ---" >&2
  tmux capture-pane -p -t "$session" >&2 || true
  echo "--- end pane ---" >&2
}

wait_token() {
  local token=$1
  local start=$SECONDS
  local pane=""
  while ((SECONDS - start < timeout)); do
    pane=$(tmux capture-pane -p -t "$session")
    if [[ $pane == *"$token"* ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "rv-tui: timeout waiting for $(printf %q "$token")" >&2
  dump_pane
  return 1
}

wait_gone() {
  local token=$1
  local start=$SECONDS
  local pane=""
  while ((SECONDS - start < timeout)); do
    pane=$(tmux capture-pane -p -t "$session")
    if [[ $pane != *"$token"* ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "rv-tui: timeout waiting for gone $(printf %q "$token")" >&2
  dump_pane
  return 1
}

wait_until() {
  local token=$1 key=$2
  local start=$SECONDS
  local pane=""
  while ((SECONDS - start < timeout)); do
    pane=$(tmux capture-pane -p -t "$session")
    if [[ $pane == *"$token"* ]]; then
      return 0
    fi
    tmux send-keys -t "$session" -- "$key"
    sleep 0.1
  done
  echo "rv-tui: timeout seeking $(printf %q "$token") with $(printf %q "$key")" >&2
  dump_pane
  return 1
}

wait_approved() {
  local path=$1
  local f=$dest/.rv/approved.json
  local start=$SECONDS
  while ((SECONDS - start < timeout)); do
    if [[ -f $f ]] && grep -qF "\"path\": \"$path\"" "$f"; then
      return 0
    fi
    sleep 0.1
  done
  echo "rv-tui: timeout waiting for approved path $path" >&2
  echo "--- approved.json ---" >&2
  if [[ -f $f ]]; then
    cat "$f" >&2
  else
    echo "(missing)" >&2
  fi
  dump_pane
  return 1
}

wait_review() {
  local text=$1
  local f=$dest/.rv/reviews/current.json
  local start=$SECONDS
  while ((SECONDS - start < timeout)); do
    if [[ -f $f ]] && grep -qF -- "$text" "$f"; then
      return 0
    fi
    sleep 0.1
  done
  echo "rv-tui: timeout waiting for review text $(printf %q "$text")" >&2
  echo "--- reviews/current.json ---" >&2
  if [[ -f $f ]]; then
    cat "$f" >&2
  else
    echo "(missing)" >&2
  fi
  dump_pane
  return 1
}

wait_staged() {
  local path=$1
  local start=$SECONDS
  local names=""
  while ((SECONDS - start < timeout)); do
    names=$(git -C "$dest" --no-pager diff --cached --name-only -- "$path" || true)
    if [[ $names == "$path" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "rv-tui: timeout waiting for staged path $path" >&2
  echo "--- git diff --cached --name-only ---" >&2
  git -C "$dest" --no-pager diff --cached --name-only >&2 || true
  dump_pane
  return 1
}

while IFS= read -r line || [[ -n $line ]]; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  cmd=${line%% *}
  rest=${line#* }
  if [[ $cmd == "$line" ]]; then
    rest=""
  fi
  case "$cmd" in
    wait)
      [[ -n $rest ]] || die "wait needs a token: $line"
      wait_token "$rest"
      ;;
    gone)
      [[ -n $rest ]] || die "gone needs a token: $line"
      wait_gone "$rest"
      ;;
    send)
      [[ -n $rest ]] || die "send needs a key: $line"
      tmux send-keys -t "$session" -- "$rest"
      ;;
    until)
      [[ -n $rest ]] || die "until needs TOKEN KEY: $line"
      key=${rest##* }
      token=${rest% *}
      [[ -n $token && $token != "$rest" ]] || die "until needs TOKEN KEY: $line"
      wait_until "$token" "$key"
      ;;
    approved)
      [[ -n $rest ]] || die "approved needs a path: $line"
      wait_approved "$rest"
      ;;
    review)
      [[ -n $rest ]] || die "review needs text: $line"
      wait_review "$rest"
      ;;
    staged)
      [[ -n $rest ]] || die "staged needs a path: $line"
      wait_staged "$rest"
      ;;
    *)
      die "unknown command '$cmd' in $script"
      ;;
  esac
done <"$script"
