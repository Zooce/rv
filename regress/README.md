# TUI regression fixtures

Checked-in git worktrees for driving `rv`. Materialize into `/tmp`; do not copy a machine-local scratch repo.

```
mise run fixture
mise run fixture -- small
mise run fixture -- small /tmp/rv-regress
```

Default name is `small`, default dest is `/tmp/rv-regress`. Dest is replaced if it already exists. Dest must be under `/tmp` and outside this work tree.

## Layout

```
regress/fixtures/<name>/
  series                 # apply order
  *.patch
  untracked/             # copied into the worktree root
  rv/                    # copied to dest/.rv/
  expected.status        # git status --porcelain=v1 after materialize
```

`series` is `mode path` lines. `#` starts a comment line. Blank lines are ignored. Path is relative to the fixture directory.

| mode | action |
|---|---|
| `commit` | `git apply --index`, then `git commit` (message = patch basename) |
| `cached` | `git apply --index` (index and worktree; a later `worktree` line is the unstaged remainder) |
| `worktree` | `git apply` (worktree only) |
| `untracked` | copy directory tree into the worktree root |
| `rv` | copy directory tree to `.rv/` |

`cached` uses `--index` rather than `--cached` so a staged-only path matches the index in the worktree until a `worktree` patch diverges (needed for `MM` files).

Git identity in the materialized repo is `rv regress` / `rv@regress`. Author and committer dates are pinned. User and system gitconfig are ignored while materializing.

`small` also commits a `.gitignore` with `.rv/` so the review store is not untracked, independent of a user’s global ignore.

## small

Export of the mixed local statuses used to drive the TUI: unstaged modify/delete, staged rename, staged+unstaged (`MM`) `fav.txt`, untracked `new.txt`/`tabs.txt`, seeded `.rv/approved.json` on `fav.txt`.
