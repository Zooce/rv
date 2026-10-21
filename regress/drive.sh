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
# Sibling repos for the projects script. Empty unless the script says `twin`.
other=""
norepo=""
# Directory tree for Tab completion. Empty unless the script says `tabdir`.
tabdir=""
# Extra arguments on the next rv launch (`args` in the script).
launch_args=""
# Private config dir so a developer file does not change the suite.
xdg=$(mktemp -d /tmp/rv-xdg-XXXXXX)

cleanup() {
  local ec=$?
  if [[ $started -eq 1 ]]; then
    tmux kill-session -t "$session" 2>/dev/null || true
  fi
  rm -rf -- "$xdg"
  if [[ $ec -eq 0 ]]; then
    rm -rf -- "$dest"
    if [[ -n $other ]]; then
      rm -rf -- "$other" "$norepo"
    fi
    if [[ -n $tabdir ]]; then
      rm -rf -- "$tabdir"
    fi
  else
    echo "rv-tui: dest kept: $dest" >&2
    if [[ -n $other ]]; then
      echo "rv-tui: other kept: $other" >&2
    fi
    if [[ -n $tabdir ]]; then
      echo "rv-tui: tabdir kept: $tabdir" >&2
    fi
  fi
}
trap cleanup EXIT

"$script_dir/materialize.sh" "$fixture" "$dest" >/dev/null
mkdir -p -- "$xdg/rv" "$dest/.rv"

# `seed` lines run before rv, in file order, wherever they sit in the script.
while IFS= read -r line || [[ -n $line ]]; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  cmd=${line%% *}
  [[ $cmd == seed ]] || continue
  rest=${line#* }
  kind=${rest%% *}
  text=${rest#* }
  [[ $kind == user || $kind == repo ]] || die "seed needs user or repo: $line"
  [[ $text != "$rest" ]] || die "seed needs a line of config: $line"
  if [[ $kind == user ]]; then
    printf '%s\n' "$text" >> "$xdg/rv/config"
  else
    printf '%s\n' "$text" >> "$dest/.rv/config"
  fi
done <"$script"

launch_rv() {
  # The tmux server does not take the client environment, so the assignment
  # is part of the shell command.
  local cmd="XDG_CONFIG_HOME=$(printf %q "$xdg") $(printf %q "$rv")"
  if [[ -n $launch_args ]]; then
    cmd+=" $(printf %q "$launch_args")"
  fi
  tmux send-keys -t "$session" -l -- "$cmd"
  tmux send-keys -t "$session" Enter
}

# `twin` is applied before rv starts. The command itself is a no-op later.
wants_twin=0
while IFS= read -r line || [[ -n $line ]]; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  cmd=${line%% *}
  [[ $cmd == twin ]] && wants_twin=1
done <"$script"
if [[ $wants_twin -eq 1 ]]; then
  other=$dest-other
  norepo=$dest-norepo
  rm -rf -- "$other" "$norepo"
  cp -a -- "$dest" "$other"
  printf 'othertoken\n' >"$other/a.txt"
  mkdir -p -- "$other/.rv/reviews"
  printf '%s\n' '{"version":1,"id":"current","comments":[{"id":"1","path":"a.txt","body":"othercomment","state":"open"}]}' >"$other/.rv/reviews/current.json"
  mkdir -p -- "$norepo"
fi

tmux new-session -d -s "$session" -x "$cols" -y "$rows" -c "$dest"
started=1
launch_rv

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

expand_at() {
  local s=$1
  s=${s//@dest/$dest}
  s=${s//@other/$other}
  printf '%s' "$s"
}

# `@base` / `@otherbase` are directory names. `@otherbase` is replaced first.
expand_token() {
  local s=$1
  local base=${dest##*/}
  local otherbase=""
  if [[ -n $other ]]; then
    otherbase=${other##*/}
  fi
  s=${s//@otherbase/$otherbase}
  s=${s//@base/$base}
  printf '%s' "$s"
}

project_paths() {
  local f=$xdg/rv/projects
  [[ -f $f ]] || return 0
  local line body
  while IFS= read -r line || [[ -n $line ]]; do
    body=${line%%#*}
    # Trim surrounding whitespace.
    body=${body#"${body%%[![:space:]]*}"}
    body=${body%"${body##*[![:space:]]}"}
    [[ -z $body ]] && continue
    [[ $body == current[[:space:]]* ]] && continue
    printf '%s\n' "$body"
  done <"$f"
}

project_has() {
  local want=$1 line
  while IFS= read -r line; do
    [[ $line == "$want" ]] && return 0
  done < <(project_paths)
  return 1
}

project_order_is() {
  # Keep the trailing newline. Command substitution would strip it.
  local got="" line expect="" p
  while IFS= read -r line; do
    got+="$line"$'\n'
  done < <(project_paths)
  for p in "$@"; do
    expect+="$p"$'\n'
  done
  [[ $got == "$expect" ]]
}

wait_project_has() {
  local token=$1
  local start=$SECONDS
  while ((SECONDS - start < timeout)); do
    if project_has "$token"; then
      return 0
    fi
    sleep 0.1
  done
  echo "rv-tui: timeout waiting for project path $token" >&2
  echo "--- projects ---" >&2
  project_paths >&2 || true
  dump_pane
  return 1
}

wait_project_gone() {
  local token=$1
  local start=$SECONDS
  while ((SECONDS - start < timeout)); do
    if ! project_has "$token"; then
      return 0
    fi
    sleep 0.1
  done
  echo "rv-tui: timeout waiting for project path to leave: $token" >&2
  echo "--- projects ---" >&2
  project_paths >&2 || true
  dump_pane
  return 1
}

wait_project_order() {
  local start=$SECONDS
  while ((SECONDS - start < timeout)); do
    if project_order_is "$@"; then
      return 0
    fi
    sleep 0.1
  done
  echo "rv-tui: timeout waiting for project order: $*" >&2
  echo "--- projects ---" >&2
  project_paths >&2 || true
  dump_pane
  return 1
}

steady_token() {
  local token=$1
  local i pane
  for ((i = 0; i < 8; i++)); do
    pane=$(tmux capture-pane -p -t "$session")
    if [[ $pane != *"$token"* ]]; then
      echo "rv-tui: $(printf %q "$token") left the pane" >&2
      dump_pane
      return 1
    fi
    sleep 0.1
  done
}

steady_gone() {
  local token=$1
  local i pane
  for ((i = 0; i < 8; i++)); do
    pane=$(tmux capture-pane -p -t "$session")
    if [[ $pane == *"$token"* ]]; then
      echo "rv-tui: $(printf %q "$token") appeared" >&2
      dump_pane
      return 1
    fi
    sleep 0.1
  done
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
      wait_token "$(expand_token "$rest")"
      ;;
    gone)
      [[ -n $rest ]] || die "gone needs a token: $line"
      wait_gone "$(expand_token "$rest")"
      ;;
    send)
      [[ -n $rest ]] || die "send needs a key: $line"
      tmux send-keys -t "$session" -- "$rest"
      ;;
    click)
      [[ -n $rest ]] || die "click needs COL ROW: $line"
      col=${rest%% *}
      row=${rest#* }
      [[ $col != "$rest" && $col =~ ^[1-9][0-9]*$ && $row =~ ^[1-9][0-9]*$ ]] || die "click needs COL ROW: $line"
      # SGR left press. Coordinates are 1-based cells, same as the terminal.
      tmux send-keys -t "$session" -l "$(printf '\033[<0;%s;%sM' "$col" "$row")"
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
    seed | twin)
      ;;
    restart)
      case $rest in
        "") ;;
        dest | norepo)
          dir=$dest
          if [[ $rest == norepo ]]; then
            [[ -n $norepo ]] || die "restart norepo needs twin: $line"
            dir=$norepo
          fi
          tmux send-keys -t "$session" -l -- "cd $(printf %q "$dir")"
          tmux send-keys -t "$session" Enter
          ;;
        *) die "restart takes dest or norepo: $line" ;;
      esac
      launch_rv
      ;;
    send-path)
      case $rest in
        dest) tmux send-keys -t "$session" -l -- "$dest" ;;
        other)
          [[ -n $other ]] || die "send-path other needs twin: $line"
          tmux send-keys -t "$session" -l -- "$other"
          ;;
        tab)
          [[ -n $tabdir ]] || die "send-path tab needs tabdir: $line"
          tmux send-keys -t "$session" -l -- "$tabdir/aaat"
          ;;
        *) die "send-path needs dest, other, or tab: $line" ;;
      esac
      ;;
    tabdir)
      tabdir=$dest-tab
      rm -rf -- "$tabdir"
      mkdir -p -- "$tabdir/aaatabother" "$tabdir/aaatabtarget"
      printf 'nope\n' >"$tabdir/aaatabfile"
      ;;
    projects)
      [[ -n $rest ]] || die "projects needs a path: $line"
      read -r -a parts <<< "$rest"
      for p in "${parts[@]}"; do
        wait_project_has "$(expand_at "$p")"
      done
      ;;
    projects-gone)
      [[ -n $rest ]] || die "projects-gone needs a path: $line"
      wait_project_gone "$(expand_at "$rest")"
      ;;
    projects-order)
      [[ -n $rest ]] || die "projects-order needs paths: $line"
      read -r -a parts <<< "$rest"
      expanded=()
      for p in "${parts[@]}"; do
        expanded+=("$(expand_at "$p")")
      done
      wait_project_order "${expanded[@]}"
      ;;
    args)
      launch_args=$(expand_at "$rest")
      ;;
    steady)
      [[ -n $rest ]] || die "steady needs a token: $line"
      steady_token "$(expand_token "$rest")"
      ;;
    steady-gone)
      [[ -n $rest ]] || die "steady-gone needs a token: $line"
      steady_gone "$(expand_token "$rest")"
      ;;
    *)
      die "unknown command '$cmd' in $script"
      ;;
  esac
done <"$script"
