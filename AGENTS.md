# AGENTS.md

Project rules for `rv`.

## Tooling

- Use **mise** as the tool and script manager for this project (tool versions, tasks, and project scripts). Prefer `mise run <task>` / tasks defined in `mise.toml` over ad-hoc scripts when a task exists or should exist.
- Use **goal** for task tracking. Create, start, update, and complete work with `goal` rather than informal TODO lists or untracked notes.
- After a change that touches load, paint, present, or approve, run `mise run bench -- --compare`. Spawn counts should match `bench/baseline.json`. If the new times are the intended baseline, `--write-baseline bench/baseline.json` and replace the table in `bench/RESULTS.md`. How timings are taken is in `bench/README.md`.

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
- **Never wrap just to add a parameter.** Do not invent a second function whose only job is to call the first with one more argument (for example `git` → `gitAllow(..., max_ok_exit)`). Extend the existing API: add a parameter, or an options struct field with a default (Zig has no default function parameters — see `goal`’s `proc.ExecOptions` style). Keep one implementation.
- **Allocator parameters and locals are named `alloc`.** Not `gpa`, `allocator`, or single-letter `a` for an `Allocator` value (struct fields that own a longer-lived pool may still use a descriptive name such as `arena` when that is clearer). Prefer `const alloc = …` at the use site.
- **Do not use `@as` unless Zig cannot type-check without it.** Applies to production code **and tests**. Default: no `@as`.
  - Prefer peer resolution and typed locals/constants: `try testing.expectEqual(2, d.files.len)`, not `expectEqual(@as(usize, 2), …)`.
  - For `?T` assertions: unwrap when non-null (`expectEqual(2, opt.?)`), or `expect(opt == null)`. Do **not** write `@as(?usize, 2)` (or any `@as(?T, …)`) just to feed `expectEqual`.
  - Prefer a typed local over a cast at the call: `const n: usize = 2;` then use `n`.
  - **Allowed only when** the compiler errors without a cast **and** no typed local / peer-type rewrite / different API is cleaner. If you reach for `@as`, stop and try those first. Needless `@as` is a rule violation. Fix it before asking for review.
- **Test utilities stay out of the production build.** Helpers, fixtures, and fake fds used only by tests must not live on production types (e.g. not nested in `Tty` / public app APIs) and must not ship real implementation into `zig build` artifacts. Prefer file-scope helpers gated with `if (builtin.is_test)` (or equivalent), or code that exists only inside `test` blocks. Production builds may expose an empty stub type at most — never pipe/PTY open helpers, injectable globals meant only for tests, or other harness code.
- **Self-check AGENTS.md before review.** Before asking the user to review, re-read the relevant rules in this file and scan your own diff for violations (needless `@as`, trivial wrappers, wrong allocator names, banned terms, and the rest). Fix those first. A change a person would see in the TUI is not ready for review until you have driven it (**Exercising the TUI**). Do not hand the user a change that still breaks project rules.

## Exercising the TUI

Before you call a change done, exercise the behavior that change affects, and check it against the fixture in **Repository**. When it changes what the screen shows or what a key does, drive `rv` in tmux and check that behavior before you ask for review and before you say the work is verified. `mise run test` does not replace that session. `mise run tui-regress` is the automated suite for the keys and screens it already covers, and it stays separate from `mise run test`. A visible change still needs a tmux drive of the behavior that changed. When that path should stay covered, add a script under `regress/tui/`. When the change has no screen or key effect, run the checks that do apply (`mise run test`, `mise run build`, the goal's verify steps) and say that there was nothing on screen to drive.

`rv` reads keys and paints on `/dev/tty` (`tui/tty.zig`), in raw mode, on the alternate screen. A pipe on stdin does not deliver keys. The process needs a controlling terminal. tmux supplies one. `tmux capture-pane -p` prints the visible text, including the alternate screen. Do not depend on `pyte`, `expect`, or another terminal emulator.

### Session

1. Build with `mise run build`. Run that binary by its absolute path (`zig-out/bin/rv` in this repo), not a copy installed elsewhere.
2. Materialize the fixture into `/tmp` (**Repository**). Leave global git config alone. Do not launch `rv` in this repo. Approve and stage write to the copy you start in.
3. Start a detached session and leave a shell in it. Pass `rv` through `send-keys`, not as the session command, so `q` returns to the shell and you can start `rv` again:

```
tmux new-session -d -s rv-drive -x 100 -y 32 -c /tmp/rv-regress
tmux send-keys -t rv-drive /absolute/path/to/zig-out/bin/rv Enter
```

`-x 100 -y 32` is wide enough for side-by-side. Below `min_side_by_side_cols` (49, `src/view/layout.zig`) the screen is unified, and the footer shows `uni~` when the preference is still side-by-side. Use a narrow session only when the change is that fallback.

4. When the check ends, including on failure, run `tmux kill-session -t rv-drive`. If no tmux server is running yet, that prints `error connecting to /tmp/tmux-…/default (No such file or directory)`. Ignore that line. Do not leave the session up.

### What to send and what to read

- Send one key at a time: `tmux send-keys -t rv-drive ]`. tmux key names are `Enter`, `Space`, and `Escape`. A word with no spaces (`noteone`) is typed as letters. A leader and its letter are two sends: `Space`, then `a`.
- After each send, poll `tmux capture-pane -p -t rv-drive` about every 0.1s until the text matches, and give up after a few seconds. Wait until the screen shows the state you set up before the first key. A fixed sleep is not a check. Staging and a reload need a longer wait than a cursor move. Wait until the pane shows the result before you send the next key. Queuing `Space`, `a`, and `Enter` in one burst can press `Enter` before the list is open.
- Check the text and files that this change is supposed to affect. A token that appears only in the fixture is easier to see than a word that also appears in a title or the footer. When the key writes the approved store, the comment store, or the index, also read `.rv/approved.json` (`entries[].path`), `.rv/reviews/current.json`, or `git diff --cached`. `capture-pane -p` has no color and no reverse video, so it does not mark the selected row. Judge the cursor by which text is on screen and by what the next key does.
- While diff rows are still on screen, the word `approved` means the approved list is open (its title bar contains it). The footer prints `HEAD · N approved` only when the row list is empty and the approved count is greater than zero.
- On a timeout, keep the pane text and say which step failed. Put a one-off driver script in `/tmp` and delete it when the check is done. A path that should stay covered is a script under `regress/tui/`.

### Repository

Materialize the checked-in fixture and drive that copy. `mise run fixture` builds `small` at `/tmp/rv-regress` and replaces that directory when it already exists:

```
mise run fixture
```

`mise run fixture -- large` builds the generated large tree. The fixture sets the copy's git identity. Approve, stage, and comments belong on the copy under `/tmp`.

Fixture format is in `regress/README.md`.

The copy includes `.rv`, so a local load already omits whatever the approved store claims, and existing comments are already there. Read `.rv/approved.json` and `.rv/reviews/` on the copy before you treat a missing row as a failure. Clear those files on the copy only when the check needs an empty store.

Read `git status` on the copy. `small` includes an unstaged edit, an unstaged deletion, a staged rename, a staged deletion, a staged new file, two hunks in one file, a nested path, a file that is both staged and unstaged, and untracked files. A row or key that used to work on one of those and no longer does is a regression.

When the change needs a status the fixture does not have, add a patch or file under `regress/fixtures/small/` and update `expected.status`. When a check had to invent a status that is not worth keeping, say so and leave it off the fixture. When you add two hunks in one file, keep them apart: git's default context is 3 lines, so a 12-line file edited on line 1 and line 10 stays two hunks. Pick tokens that do not appear in titles, the footer, or help.

### Keys that are easy to mis-drive

Drive the keys the change uses. These notes are for keys that are easy to get wrong. On a local load the cursor starts on the section header (`Unstaged`), not on a hunk.

| Key | Effect |
|-----|--------|
| `]` | Next hunk header. The first `]` from the section header is the first hunk. |
| `}` | Next file header. |
| `a` | Approve the hunk under the cursor: stage it, then hide it. No effect on a section header. No effect on a file header when that file has hunks. |
| `A` | Approve the whole file, including from that file's header. |
| Space, then `a` | Open the approved list. It opens on an approved identity in the file under the cursor, otherwise on the first row. From a section header the list cursor stays on the first row. |
| Enter | On that list: drop one matching store entry, rebuild, move to that row, and close the list. The change stays staged. |
| `i`, text, Enter | On a hunk header, open a hunk comment. The title contains `create/edit hunk`. Enter saves. |
| `a` or `A` when that hunk has a live comment | Confirm dialog, No selected. `y` approves. |
| `)` | Next comment, wrapping. A comment on a hidden hunk unapproves that hunk and lands on it. |
| `q` | Quit to the shell. |

After `a` hides the hunk under the cursor, the cursor rests on the next header. After Enter unapproves, the cursor rests on the restored hunk header, so the next `i` comments that hunk.

Report what you drove and what the pane and the files showed.

## Language (project)

- Do **not** call goals “epics,” “stories,” or other agile jargon. A larger goal that is split for implementation is a **parent** goal; the pieces are **slices** (or just goals / sub-goals). Say “MVP-2 parent #4” or “slices #38–#42,” not “the MVP-2 epic.”

## Session start (project)

Always-on rules above apply first. Project extras:

1. After `goal status --full`, if the user wants work and there is no active goal, pick from **`goal list` Next order** (top first). Start with `goal start <id>` only when they ask to start work (or name a goal).
2. Read the full brief with `goal show <id>` (or rely on `status --full` once active) before coding.

## Using `goal`

`goal` tracks one active goal at a time. Lists: **Active** (in progress), **Next** (upcoming), **Later** (backlog).

### Everyday commands

| Command | When to use |
|---------|-------------|
| `goal status --full` | Session start; see active goal + body |
| `goal list` / `goal list --all` | See Next / Later / everything (see **List order** below) |
| `goal show <id>` | Full text of a goal (brief for implementers) |
| `goal start <id>` | Begin a session on that goal (makes it active) |
| `goal note "…"` | Append progress, decisions, or blockers to the **active** goal |
| `goal stop` | Pause active work (returns it to Next) |
| `goal stop --later` | Pause and demote active work to Later |
| `goal complete` | Finish the active goal |
| `goal new --file path.md` | Create a goal from a markdown file (first line = title) |
| `goal new "title"` | Create a goal with only a title |
| `goal next <id>` | Promote Later → Next, **or** move an already-Next goal to the **top** of Next |
| `goal later <id>` | Demote Next → Later |
| `goal edit <id>` | Edit goal body in `$EDITOR` |

Use `goal help <command>` for full flags (`-q` / `--quiet` prints only an id, useful in scripts).

### List order (live queue)

`goal list` is the only work queue — do not invent a second ranking doc.

| List | Sort key | Meaning |
|------|----------|---------|
| **Next** | Most recently `goal next`’d first | Top of Next = do next. Calling `goal next <id>` on an already-Next goal re-pins it to the top. |
| **Later** | Most recently **created** first | Creation-time backlog order only; not a priority queue. Demote with `goal later`; do not expect `next`/`later` to re-rank Later. |

**Shaping Next:**

1. Put the ordered critical path in **Next**; leave park / anytime hygiene in **Later**.
2. To set Next order, call `goal next <id>` from **last → first** (bottom of desired order first, then work up). The last `next` becomes the top of the list.
3. To bump one goal without reshuffling the rest, `goal next <id>` that id alone (it jumps to top).
4. When adding a goal into the middle of the plan: `goal new` (Later) → `goal next` it, then re-`next` everything that should stay above it (or re-run last→first for the whole Next stack).

### Workflow for agents

1. **One goal per session** when possible. Start with `goal start <id>` before substantial work.
2. **Read the goal body** (`goal show` / `status --full`). It is the source of truth for scope, acceptance criteria, and verify steps.
3. **Stay in scope.** Do not implement a different goal “while you are here” unless the user asks. Out-of-scope discoveries → `goal note` or a new goal via `goal new`.
4. **Record decisions** with `goal note` (API choices, deferred follow-ups, test harness notes).
5. **Finish cleanly:** leave the tree buildable; run the goal's verify steps; exercise a visible TUI change in tmux (**Exercising the TUI**); use `goal note` for leftover work. Run `goal complete` / `goal stop` only when the user asks.
6. **Order of work:** follow **`goal list` Next** (top first). Prefer re-ordering with `goal next` over inventing a side plan.

### Placement defaults

- `goal new` adds goals to **Later** by default (newest Later first in `goal list`).
- Promote with `goal next <id>` when something should enter (or jump to the top of) the upcoming queue.
- Demote with `goal later <id>` when it should not compete with current Next work (park / filler).

### Bug goals (test-first)

When a goal is marked **`[bug]`** and requires tests:

1. Write a failing test first (**RED**) — `zig build test` must fail on current code.
2. Implement the fix (**GREEN**) until that test passes.
3. Do not “fix first, test later” unless the goal explicitly allows it.

### What not to do

- Do not replace `goal` with ad-hoc TODO files, scratch notes as the only plan, or a second ranking/checklist doc.
- Do not complete a goal that still fails its stated acceptance criteria or verify commands.
- Do not start multiple goals at once; stop or complete the active one first.
