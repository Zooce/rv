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

Store: `.rv/reviews/current.json` in the **repo root**. Run commands there.

## Commands

| Command | Purpose |
|---------|---------|
| `rv status` | Live comment count and store path |
| `rv list` | Comments on the board |
| `rv show <id>` | One comment: path, lines, side, body |
| `rv export` | Markdown (default) or `--format json`; `-o path` writes a file |
| `rv resolve <id> [id…]` | Delete comments after you fixed them |

Bare `rv` opens the TUI; agents should use the headless commands above.

## Workflow

1. `rv list` or `rv export --format md` — read comments and anchors.
2. Edit only the paths/lines given; do not invent anchors.
3. `rv resolve <id>` for each fully addressed comment (deletes the id).
4. `rv list` again until the board is empty (or only deferred items remain).

## Rules

1. **Do not invent paths or line numbers** — use ids/anchors from list/show/export.
2. Resolve only after the fix is in the tree.
3. Prefer CLI over hand-editing `.rv/reviews/*.json`.
