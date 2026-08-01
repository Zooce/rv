# AGENTS.md

Project rules for `rv`.

## Tooling

- Use **mise** as the tool and script manager for this project (tool versions, tasks, and project scripts). Prefer `mise run <task>` / tasks defined in `mise.toml` over ad-hoc scripts when a task exists or should exist.
- Use **goal** for task tracking. Create, start, update, and complete work with `goal` rather than informal TODO lists or untracked notes.

## Code style

- **Least execution necessary.** Prefer the shortest correct path: one atomic take over peek-then-take, no redundant checks, no extra branches that only restate the same work. Do more only when the extra work is required for correctness (for example peek in a wait loop so a later `poll` can still take).
- **Local symmetry.** When nearby code handles parallel cases (e.g. winch vs quit flags), keep the same structure and the same API pattern unless a real difference forces divergence. Asymmetry should signal intent, not habit.
- **Test utilities stay out of the production build.** Helpers, fixtures, and fake fds used only by tests must not live on production types (e.g. not nested in `Tty` / public app APIs) and must not ship real implementation into `zig build` artifacts. Prefer file-scope helpers gated with `if (builtin.is_test)` (or equivalent), or code that exists only inside `test` blocks. Production builds may expose an empty stub type at most — never pipe/PTY open helpers, injectable globals meant only for tests, or other harness code.

## Session start

At the start of a new session in this project:

1. Run `goal status --full` for current work context (after `goal` is initialized here).
2. If there is no active goal, pick the next item from the recommended order in [`GOAL_ORDER.md`](GOAL_ORDER.md) (or from `goal list --next`), then `goal start <id>`.
3. Read the full brief with `goal show <id>` (or rely on `status --full` once active) before coding.

## Using `goal`

`goal` tracks one active goal at a time. Lists: **Active** (in progress), **Next** (upcoming), **Later** (backlog).

### Everyday commands

| Command | When to use |
|---------|-------------|
| `goal status --full` | Session start; see active goal + body |
| `goal list` / `goal list --all` | See Next / Later / everything |
| `goal show <id>` | Full text of a goal (brief for implementers) |
| `goal start <id>` | Begin a session on that goal (makes it active) |
| `goal note "…"` | Append progress, decisions, or blockers to the **active** goal |
| `goal stop` | Pause active work (returns it to Next) |
| `goal stop --later` | Pause and demote active work to Later |
| `goal complete` | Finish the active goal |
| `goal new --file path.md` | Create a goal from a markdown file (first line = title) |
| `goal new "title"` | Create a goal with only a title |
| `goal next <id>` | Promote Later → Next |
| `goal later <id>` | Demote Next → Later |
| `goal edit <id>` | Edit goal body in `$EDITOR` |

Use `goal help <command>` for full flags (`-q` / `--quiet` prints only an id, useful in scripts).

### Workflow for agents

1. **One goal per session** when possible. Start with `goal start <id>` before substantial work.
2. **Read the goal body** (`goal show` / `status --full`). It is the source of truth for scope, acceptance criteria, and verify steps.
3. **Stay in scope.** Do not implement a different goal “while you are here” unless the user asks. Out-of-scope discoveries → `goal note` or a new goal via `goal new`.
4. **Record decisions** with `goal note` (API choices, deferred follow-ups, test harness notes).
5. **Finish cleanly:** leave the tree buildable; run the goal’s verify steps; then `goal complete` (or `goal stop` / `goal note` if incomplete).
6. **Order of work:** follow [`GOAL_ORDER.md`](GOAL_ORDER.md) unless the user overrides. Foundation bugs before product MVP slices that depend on them.

### Placement defaults

- `goal new` adds goals to **Later** by default.
- Promote with `goal next <id>` when something should enter the upcoming queue.
- Demote with `goal later <id>` when it should not compete with current Next work.

### Bug goals (test-first)

When a goal is marked **`[bug]`** and requires tests:

1. Write a failing test first (**RED**) — `zig build test` must fail on current code.
2. Implement the fix (**GREEN**) until that test passes.
3. Do not “fix first, test later” unless the goal explicitly allows it.

### What not to do

- Do not replace `goal` with ad-hoc TODO files, scratch notes as the only plan, or untracked checklist markdown (except project docs like `GOAL_ORDER.md` / design notes).
- Do not complete a goal that still fails its stated acceptance criteria or verify commands.
- Do not start multiple goals at once; stop or complete the active one first.
