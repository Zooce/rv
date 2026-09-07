---
name: rv
description: >
  Address rv code-review comments. Use when the user asks to fix rv
  comments, address review feedback from rv, or work through items from
  `rv list` / `rv export` / `.rv/reviews/`.
---

# rv review comments

`rv` is a terminal code-review **comment board**. Humans leave comments on a
diff; agents fix the code and `rv resolve` deletes those ids. `rv` does **not**
apply patches. There is no reopen and no resolved list.

Comments: `.rv/reviews/current.json` in the **repo root**. Approvals:
`.rv/approved.json` in the repo root, separate from the comment store. Run
commands there.

## Commands

| Command | Purpose |
|---------|---------|
| `rv status` | Live comment count, approved count, and store paths |
| `rv approved` | List approved hunks and files (hidden from the TUI walk) |
| `rv unapprove <n>` | Drop the nth row from that list |
| `rv list` | Comments on the board (`id  source  anchor  body`) |
| `rv show <id>` | One comment: source, path, lines, side, body |
| `rv export` | Markdown (default) or `--format json`; `-o path` writes a file |
| `rv resolve <id> [id…]` | Delete comments after you fixed them |

`list` / `show` / `resolve` / `export` stay comments. Bare `rv` opens the TUI;
agents should use the headless commands above.

## Workflow

1. `rv status` — if `approved` is greater than 0, run `rv approved` so a hidden
   local walk is not mistaken for a clean tree.
2. `rv list` or `rv export --format md` — read comments and anchors. Source is
   `local`, a range string, or a commit-ish (or `-` if missing).
3. Edit only the paths/lines given; do not invent anchors. A commit or range
   source is what was under review, not a request to amend or rebase that
   commit. Fix the current tree.
4. `rv resolve <id>` for each fully addressed comment (deletes the id).
5. `rv unapprove <n>` only when you must see or comment on that hunk again.
6. `rv list` again until the board is empty (or only deferred items remain).

## Rules

1. **Do not invent paths or line numbers** — use ids/anchors from list/show/export.
2. Resolve only after the fix is in the tree.
3. Prefer CLI over hand-editing `.rv/reviews/*.json` or `.rv/approved.json`.
4. Do not rewrite git history because a comment was left on a commit or range.
