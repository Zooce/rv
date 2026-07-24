# AGENTS.md

Project rules for `rv`.

## Tooling

- Use **mise** as the tool and script manager for this project (tool versions, tasks, and project scripts). Prefer `mise run <task>` / tasks defined in `mise.toml` over ad-hoc scripts when a task exists or should exist.
- Use **goal** for task tracking. Create, start, update, and complete work with `goal` rather than informal TODO lists or untracked notes.

## Session start

At the start of a new session in this project, run `goal status --full` for current work context (after `goal` is initialized here).
