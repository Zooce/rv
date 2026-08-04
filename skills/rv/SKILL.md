---
name: rv
description: >
  Address open rv code-review comments. Use when the user asks to fix rv
  comments, address review feedback from rv, or work through open items from
  `rv list` / `rv export` / `.rv/reviews/`.
---

# rv review comments

`rv` is a terminal code-review **comment board**. Humans leave comments on a
diff; agents fix the code and mark comments resolved. `rv` does **not** apply
patches.

Store: `.rv/reviews/current.json` in the **repo root**. Run commands there.

## Commands

| Command | Purpose |
|---------|---------|
| `rv status` | Open / resolved / total counts |
| `rv list` | Open comments (default); `--all` / `--resolved` / `--open` |
| `rv show <id>` | One comment: path, lines, side, body |
| `rv export` | Markdown (default) or `--format json`; `-o path` writes a file |
| `rv resolve <id> [id…]` | Mark resolved after you fixed them |
| `rv reopen <id> [id…]` | Mark open again |

Bare `rv` opens the TUI; agents should use the headless commands above.

## Workflow

1. `rv list` or `rv export --format md` — read open comments and anchors.
2. Edit only the paths/lines given; do not invent anchors.
3. `rv resolve <id>` for each fully addressed comment.
4. `rv list` again until open is empty (or only deferred items remain).

## Rules

1. **Do not invent paths or line numbers** — use ids/anchors from list/show/export.
2. Resolve only after the fix is in the tree.
3. Prefer CLI over hand-editing `.rv/reviews/*.json`.
