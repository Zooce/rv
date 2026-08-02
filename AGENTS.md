# AGENTS.md

Project rules for `rv`.

## Tooling

- Use **mise** as the tool and script manager for this project (tool versions, tasks, and project scripts). Prefer `mise run <task>` / tasks defined in `mise.toml` over ad-hoc scripts when a task exists or should exist.
- Use **goal** for task tracking. Create, start, update, and complete work with `goal` rather than informal TODO lists or untracked notes.

<!-- goal-agent-rules:start -->
## Goal (agent rules)

When the `goal` CLI is installed and this project is initialized for goal:

1. **Session start:** run `goal status --full` and treat it as work context.
2. **Track work in goal:** prefer existing goals (`goal list`, `goal start <id>`)
   over inventing a parallel todo list or second task system.
3. **Progress:** capture decisions and progress with `goal note` (text or
   `--file`). Prefer notes over editing the goal body mid-work.
4. **Non-interactive only:** pass explicit goal IDs; use title args, `--file`,
   `-q`/`--quiet`, and `--yes` as needed. Never rely on TTY pickers or editors.
5. **Do not complete, stop, delete, or switch goals** unless the user asks.
   Finishing the code is not the same as completing the goal.
6. **Do not run git commands that change the repo** unless the user asks
   (commit, push, reset, etc.). Goal may still record its own state commits.

For command details, load the `goal` skill / playbook when available.
<!-- goal-agent-rules:end -->

## Code style

- **Least execution necessary.** Prefer the shortest correct path: one atomic take over peek-then-take, no redundant checks, no extra branches that only restate the same work. Do more only when the extra work is required for correctness (for example peek in a wait loop so a later `poll` can still take).
- **Local symmetry.** When nearby code handles parallel cases (e.g. winch vs quit flags), keep the same structure and the same API pattern unless a real difference forces divergence. Asymmetry should signal intent, not habit.
- **No trivial wrappers.** Do not add a function that only forwards to a one-liner (for example `return a.dupe(u8, path)` or `return std.mem.eql(u8, path, "/dev/null")`). Call the underlying API at the use site. Extract a helper only when it encodes real shared logic or a non-obvious invariant.
- **Allocator parameters and locals are named `alloc`.** Not `gpa`, `allocator`, or single-letter `a` for an `Allocator` value (struct fields that own a longer-lived pool may still use a descriptive name such as `arena` when that is clearer). Prefer `const alloc = …` at the use site.
- **Avoid `@as` when a typed value or peer resolution is enough.** Prefer `try testing.expectEqual(2, d.files.len)` over `try testing.expectEqual(@as(usize, 2), …)`, and typed locals/constants over casting at the call. Use `@as` only when Zig cannot infer the type and the cast is the clearest fix.
- **Test utilities stay out of the production build.** Helpers, fixtures, and fake fds used only by tests must not live on production types (e.g. not nested in `Tty` / public app APIs) and must not ship real implementation into `zig build` artifacts. Prefer file-scope helpers gated with `if (builtin.is_test)` (or equivalent), or code that exists only inside `test` blocks. Production builds may expose an empty stub type at most — never pipe/PTY open helpers, injectable globals meant only for tests, or other harness code.

## Change size (review batches)

- **Never make more than about 250 lines of change at a time** (insertions + deletions across the batch). That is roughly the most that can be reviewed in one pass.
- **Even if the task needs more work, stop at ~250 lines.** Do not continue implementing the next slice until the user has reviewed and approved the current batch.
- **Ask for review before continuing.** When you hit the limit (or would exceed it with the next edit), stop, summarize what changed, and wait for explicit approval. Only then proceed with the next part of the change.
- Count net diff size for the unapproved batch (not the whole goal). Prefer smaller, coherent batches over packing to the limit.
- **Each batch must be a complete, buildable change.** Stopping mid-edit is not allowed if it leaves the tree broken. The task must be broken into slices that each leave the project building and tests runnable (for example: introduce types/stubs/boilerplate first, wire call sites, then fill in behavior in later approved batches).
- **Exceptions** (these may exceed ~250 lines in one go when splitting would be worse or impossible):
  - Deleting a whole file (or a few whole files) as one intentional removal
  - Mechanical mass renames / bulk renames that are the same edit repeated
  - Generated or vendored content the agent did not hand-author (still prefer not dumping huge generated blobs without need)
  When an exception applies, still stop for review after that batch before unrelated follow-up work.

## Language (project)

- Do **not** call goals “epics,” “stories,” or other agile jargon. A larger goal that is split for implementation is a **parent** goal; the pieces are **slices** (or just goals / sub-goals). Say “MVP-2 parent #4” or “slices #38–#42,” not “the MVP-2 epic.”

## Session start (project)

Always-on rules above apply first. Project extras:

1. After `goal status --full`, if the user wants work and there is no active goal, pick from the recommended order in [`GOAL_ORDER.md`](GOAL_ORDER.md) (or `goal list`) and `goal start <id>` only when they ask to start work (or name a goal).
2. Read the full brief with `goal show <id>` (or rely on `status --full` once active) before coding.

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
5. **Finish cleanly:** leave the tree buildable; run the goal's verify steps; use `goal note` for leftover work. Run `goal complete` / `goal stop` only when the user asks.
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
