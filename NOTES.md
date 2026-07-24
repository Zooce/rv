# Notes

## hunk discovery (2026-07-21)

`hunk` (mise, v0.17.3 seen) is a strong existing alternative to building `rv` for local terminal review + agent notes.

- Agent does **not** auto-receive notes; it must run session CLI (or skill/MCP).
- User notes: `hunk session comment list --repo . --type user` (or `--type all`).
- Also: `hunk session review --repo . --include-notes [--json]`.
- Bundled skill: `hunk skill path` -> hunk-review SKILL.md.
- Notes are live-session / daemon bound, not a durable repo export by default.

Next: learn hunk more deeply before deciding whether `rv` is still needed.

Global memory also has this summary: `~/.grok/memory/MEMORY.md`.
