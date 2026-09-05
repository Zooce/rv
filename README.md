# rv

**Local terminal diff review for humans - precise comments for AI agents.**

`rv` (short for *review*) is a fast, keyboard-driven TUI for reviewing local git diffs and leaving comments that your AI coding agent can act on. Stay in the terminal. Point at the exact lines. Hand the feedback to Grok, Claude, or any other agent without retyping filenames and line numbers.

> Name is provisional. `rv` is fine for now.

---

## The problem

AI agents write a lot of code. Reviewing that code still feels stuck between two bad options:

1. **GUI review tools** (Sublime Merge, IDE review panes, browser UIs) - great for looking, terrible for *feeding structured feedback back into the agent session*. You end up describing changes by hand: paths, line numbers, intent.
2. **Agent-only review** - you ask the model to "look at the diff," but there is no durable, navigable comment surface on the actual hunks. Feedback is chat text that drifts from the code.

The loop people actually run today looks like:

```
agent makes changes
    -> open a GUI diff tool
    -> take notes mentally or in a scratch buffer
    -> switch back to the agent
    -> carefully restate every issue with path + line + intent
    -> hope nothing was mis-described
```

On small diffs this is annoying. On large diffs it is exhausting and error-prone.

`rv` collapses that into:

```
agent makes changes
    -> rv (terminal, vim keys, comments on real ranges)
    -> agent reads comments (export / CLI / later MCP)
    -> agent addresses them; `rv resolve` deletes those ids
```

---

## Why other tools didn't cut it

| Approach | What works | What doesn't |
|---|---|---|
| **GitHub / GitLab PR UI** | Mature review model | Requires push/PR for *local* work; remote-first; heavyweight |
| **IDE review / GitLens-style** | Inline in editor | Not terminal-native; awkward agent handoff |
| **Sublime Merge (and similar GUIs)** | Excellent diff reading | No path from a comment on a hunk -> structured agent task |
| **delta / tig / lazygit** | Fast local diff navigation | Viewing, not commenting + resolution loops |
| **Agent chat alone** | Flexible | No anchors on the real diff; you retype locations |
| **local-pr-reviewer** | Local PR-ish idea | Buggy in practice; comments didn't produce a useful handoff |
| **revdiff** | Closer - local review focus | Output path unreliable (stdout paste or broken file write); handoff format not agent-friendly |
| **Local web UIs** | Familiar PR-style layout | Forces a browser; leaves the terminal workflow |
| **hunk** (modem-dev) | Strong terminal review UI; live session CLI; human notes agents can read | Agent skill is **not auto-installed** — only `hunk skill path` + manual symlink/copy (or Nix home-manager). Session-bound notes, not a durable comment board; coarser anchors than file/hunk/line/char + overlaps. **`j`/`k` only scroll the viewport one line** — no moveable current-line cursor; leaving a note often requires the **mouse** |

Design reactions baked into `rv`:

- **Terminal only** - no local web server, no browser tab.
- **No file-tree panel** - long paths (Java packages, monorepos) waste space and aren't how you navigate a *diff*. Navigate the changed files and hunks themselves.
- **Keyboard-first cursor on the diff** - a highlighted **current line** (and column when needed) moves with vim keys; comments attach from that cursor. Mouse is optional, never required.
- **Handoff is a first-class feature** - not an afterthought dump to stdout.
- **Agent skill install is a product command** - not "print a path and hope the user symlinks it."
- **Enjoyable daily driver** - if the TUI isn't pleasant, the tool fails even if the data model is right.

---

## Who it's for

Terminal + AI-agent power users who already work in sessions with tools like **Grok** and **Claude** (and want the same flow with *any* agent).

Not a multi-user code-review platform. Not a GitHub replacement. A **personal review board** sitting between your agent and your tree.

---

## Core workflow

### Review surfaces (MVP -> later)

| Surface | Status |
|---|---|
| Working tree + staged (`git diff HEAD` + untracked) | MVP |
| Branch vs base (e.g. `rv main...HEAD`) | MVP |
| Arbitrary patches | Later |

**Default invocation:** bare `rv` reviews local changes only (staged, unstaged, and untracked). The TUI groups those under labeled **Unstaged**, **Untracked**, and **Staged** sections (empty groups omitted). A clean worktree opens an empty review. Approved local hunks are omitted from the walk; when every remaining change is approved the footer is `HEAD · N approved`, not `HEAD · empty`. Branch and other diffs are opt-in: `rv <range>` (for example `rv main...HEAD`) and have no section headers. The TUI footer shows the git range (`HEAD` for local, `HEAD · empty` when the worktree is clean, `HEAD · N approved` when the tree is dirty but nothing unapproved remains, or the range you passed).

### Navigation and selection (keyboard-first)

`rv` is built around a **cursor on the diff**, not viewport-only scrolling.

`rv` leans into a **vim / Helix-like** modal, keyboard-first review — navigate with a real cursor, search with `/`, comment without leaving the keys. No floating pickers or IDE-style popovers when a buffer-style prompt will do.

| Keys | Behavior |
|---|---|
| `j` / `k` | Move the **current line** down / up (highlighted). Viewport follows so the cursor stays visible. |
| `h` / `l` | Move **left / right** on the current line (column cursor for char-range comments). |
| `[` / `]` | Jump to the **previous / next hunk**. |
| `za` | **Toggle fold** at the cursor. Hunk header or line: hide/show that hunk’s body (`@@` stays). File header: hide/show its hunks (per-hunk folds kept). No-op on a section, binary / hunk-less file, or empty list. Far-right `Fold (za)` / `Unfold (za)` on headers that can fold. |
| `zM` | **Collapse all files** (headers only). |
| `zR` | **Expand everything**. |
| `(` / `)` | Jump to the **previous / next live comment**. Cursor goes to that comment’s side (old line or new line). Wraps; no comments stays put with a footer note. Landing expands folds so the row is visible. |
| `/` | **Search the diff text** — body lines in the loaded changeset, including folded hunks (like vim `/`). Enter jumps to the first match and expands folds so the row is visible. `n` / `N` next / previous match. |
| `Space` `f` | **List files** — floating overlay on the still-painted diff. One row per changed file (flatten order). `j`/`k` move; Enter jumps to that **file header** and closes. Esc closes without moving the cursor. `q` still quits. Empty diff: empty overlay. Opens on the file under the cursor when there is one. |
| `Space` `l` | **List comments** — floating overlay on the still-painted diff (same live board as `rv list`). `j`/`k` move; Enter jumps to that comment’s side (same landing as `(`/`)`) and closes the overlay. Esc closes without moving the cursor. `q` still quits. Empty board: empty overlay. A row whose path/line is gone from the flatten: footer note, stay in the list. Read-only: edit or dismiss after jumping. |
| `Space` `A` | **List approved hunks** — floating overlay on the still-painted diff (local only). One row per live approved identity (flatten order): path, git group, short hunk preview (or binary / hunk-less placeholder). `j`/`k` move; Enter unapproves that identity, rebuilds the main list, jumps to the restored row, and closes. Esc closes without changing approval. `q` still quits. Empty set: empty overlay. Opens on an approved identity in the file under the cursor when there is one. Range loads ignore this chord. |
| `Space` `Space` | **Stage or unstage** the current file (on a file header) or hunk (in a hunk), or **the whole group** on an Unstaged / Untracked / Staged section header. Group action always confirms (`No` selected first; `yes` proceeds). Local review only. Far-right hints on the current section, file, and hunk rows name the action and chord. Range loads (`rv main...HEAD`) ignore this chord and show no hints. Git failure: centered overlay; Enter or Esc dismisses. If some files in a group already mutated, the list reloads to match git, then the overlay opens. |
| `Space` `S` | **Stage or unstage the containing file** while the cursor is in a hunk. Local only. Temporary stand-in until Ctrl bindings exist. |
| `Space` `d` | **Discard** the current file (on a file header) or hunk (in a hunk). Local unstaged/untracked only. Always confirms (`No` selected first; `yes` proceeds). If the target has live comments, a second overlay asks to delete them (`Yes` selected; `no` keeps them). Git discard runs first; comments are deleted only on success. Staged rows are no-ops (unstage first). Range loads ignore this chord. Far-right hints name the chord on unstaged/untracked rows. Git failure: same overlay as stage/unstage. |
| `Space` `x` | **Discard the containing file** while the cursor is in a hunk. Local only. Temporary stand-in until Ctrl bindings exist. |
| `Space` `a` | **Approve** the current hunk (hunk header or line), remaining hunks of the file in this group (file header), or the whole group (section header). No confirm. Local only. Hides those rows from the walk. Far-right hints name the chord on the current section, file, and hunk rows. Range loads ignore this chord and show no hints. |
| `?` | **Help** — centered overlay with the grouped key catalog (motion, search, comments, session, prompts). The title bar is a short hint; this is the full list. `j`/`k` (and arrows) scroll when it does not fit. `?` or Esc closes. `q` still quits. From a file, comment, or approved list, `?` replaces the list with help. While commenting or searching, `?` inserts a question mark. |
| `i` / `c` / `a` / `Enter` | Create or edit the comment on **new** (right pane in side-by-side, or the current `+` / context line in unified). Open a box **below the cursor**. Same action; pick the muscle memory you prefer. |
| `I` / `C` / `A` | Create or edit the comment on **old** (left pane in side-by-side, or the current `-` / context line in unified). Missing side does nothing. |
| `d` | Dismiss the comment on **new** (right) at the cursor. Gone from the board; no confirm. |
| `D` | Dismiss the comment on **old** (left). Missing side or no comment there: footer note; does not take the other pane. |
| `r` | **Reload** the loaded diff from the same source (re-runs the startup git load). Comments in `.rv` stay. Failed reload keeps the previous view and shows a footer error. Not bound while typing a comment (or in search / a list overlay). |
| (later) | Page/half-page scroll, more `Space` leader maps — same vocabulary |

Contrast with tools where `j`/`k` only pan the view and comment placement needs a mouse: in `rv`, **where the cursor is is where the comment goes.**

#### Search

`/` is a **prompt on the status/command line** (vim-style). Query against **diff content** (added/removed/context lines as shown). Enter jumps to the first match; `n` / `N` walk matches. Prefer this over a separate search UI.

#### File list

`Space` `f` is a list overlay, not a search prompt — same pattern as `Space` `l`. It opens a centered overlay so the diff stays visible in the margins. Rows are flatten order: one display path per file header. Opening inside a file selects that file.

#### Comment list

`Space` `l` is the in-session board, not a search prompt. It opens a centered overlay so the diff stays visible in the margins. Rows are store order: id, path, side (`old` / `new` / `ctx`), line (`-N` / `+N`), body preview. Creating or dismissing a comment shows up the next time you open the list.

#### Approved list

`Space` `A` is a list overlay, not a search prompt — same pattern as `Space` `f` and `Space` `l`. Local review only; range loads ignore it. Rows are flatten order: one live approved identity per row (path, current git group, short hunk preview). Enter unapproves that identity and jumps to the restored row. There is no peek without unapproving.

#### Comment mode

Entering comment mode inserts an inline **comment box under the current cursor position** (below the highlighted line / selection). Focus moves into the box so you type immediately — no mouse, no separate dialog floating away from the code.

```text
j/k           # land the current-line highlight on the code you care about
h/l           # optional: set start column
/ query       # find text in the diff; n/N walk matches
Space f       # list changed files; j/k; Enter jump; Esc close
Space l       # list comments; j/k; Enter jump; Esc close
Space A       # list approved hunks; j/k; Enter unapprove and jump; Esc close
?             # help overlay; ? or Esc close
v or V        # optional: start character- or line-wise range (vim-flavored)
j/k h/l       # extend the selection (overlapping ranges allowed later)
i | c | a | Enter   # create or edit new (right / +)
I | C | A           # create or edit old (left / -)
              # type the note; Esc cancel; Ctrl-S or equivalent save
```

- Anchor for a plain open is the **current line** (and column if set). With an active visual selection, the box attaches to that **range**.
- `i` / `c` / `a` / `Enter` create or edit on new; `I` / `C` / `A` on old. Same box; no `e`. Pick the muscle memory you prefer.
- **Current line** is always visible as a clear highlight (not just a scroll offset).
- **Mouse** may still scroll or click to move the cursor for people who want it; it must never be the only way to place a note.
- Hunk jumps (`[`/`]`) move both focus and cursor to a sensible line in the target hunk (e.g. first changed line).

### Commenting model

Comments are the product. v1 supports:

- **File-level** comments
- **Hunk-level** comments
- **Line** comments (default: the current line under the keyboard cursor)
- **Ranges** - line ranges and character ranges within lines, built from the cursor / visual selection
- **Overlapping ranges** - e.g. comment A on `file:3:6-3:12` and comment B on `file:3:5-4:16` are both valid and independent

Anchoring:

- **Display anchors:** path + line/column (and optional old/new side) for human readability
- **Stability anchors:** hunk/context identity so comments survive small surrounding edits better than bare line numbers alone

Lifecycle (v1): **present | gone**. Humans dismiss in the TUI (`d` / `D`); agents call `rv resolve`, which deletes the same ids. No reopen and no resolved list.

### Agent handoff (hybrid)

Built for any agent (Grok, Claude, Codex, Cursor, ...):

1. **Export** - `rv export` (and friends) emit a stable, agent-readable document of comments (paths, ranges, bodies, ids). Paste, pipe, or `@`-include into a session.
2. **CLI** - list / show / resolve (delete) comments programmatically so an agent in the repo can close the loop without GUI.
3. **Skill install** - `rv install-skill` wires a bundled agent skill into the agent's discovery paths so "address `rv` comments" works without re-pasting docs or hand-symlinking after every upgrade.
4. **MCP (later)** - same operations as tools the agent can call directly.

`rv` does **not** apply fixes itself. It is the comment board; the agent does the work.

#### Why skill install is in scope

Nearby tools (notably **hunk**) ship a good review skill but stop at **printing a path**. The user must manually symlink or copy into `~/.claude/skills`, `~/.grok/skills`, etc.; upgrades can leave stale copies; there is no one-shot install for multi-agent setups. That is a real handoff gap: the comment board only works if the agent knows how to use it.

`rv` treats install as part of the product:

```text
rv install-skill              # detect known agents; install or update the rv skill
rv install-skill --agent claude
rv install-skill --agent grok
rv install-skill --list       # where it would install / what is already linked
rv install-skill --uninstall
```

Indicative behavior:

- Install into standard skill roots (e.g. `~/.claude/skills/rv/`, `~/.grok/skills/rv/`) via **symlink to the installed binary's bundled skill** so upgrades stay current (prefer link over copy).
- Support multi-agent machines without requiring separate manual steps per tool.
- Idempotent: safe to re-run after upgrading `rv`.
- Optional project-local install (e.g. `.claude/skills/` / `.grok/skills/` in the repo) for teams that want the skill committed or shared.

Exact agent detection and paths are implementation detail; the contract is: **one command makes the agent able to read and act on `rv` comments.**

### Sketch of a session

```text
$ rv install-skill             # once per machine (or after upgrade)

$ grok   # or claude - agent implements a feature

$ rv     # local changes only (empty when the worktree is clean)
         # j/k line; h/l col; [/] hunks; za/zM/zR folds; (/) comments; / text; Space f files
         # Space l comments; Space A approved (local, Enter unapproves); Space Space stage/unstage
         # Space a approve hunk, file, or group (local); Space S file from hunk (until Ctrl)
         # Space d discard file or hunk; Space x discard file from hunk (until Ctrl)
         # i/c/a/Enter -> create or edit new
         # I/C/A -> old; d dismiss new; D dismiss old; r reload; ? help

$ rv export -o .rv/review.md   # or stdout / JSON
# agent already knows the skill: address rv comments

$ rv list
$ rv resolve <id>              # deletes the id
$ rv                         # confirm, leave more, continue
```

---

## UX principles (non-negotiable)

1. **Clean and simple** - enjoyable to use every day; no cluttered "IDE in the terminal."
2. **Performance** - no slop. Instant open on large diffs is a requirement, not a nice-to-have.
3. **Vim / Helix-like keybindings** - `j`/`k` move a **highlighted current line** (not merely scroll); `h`/`l` move by column; `[`/`]` jump hunks; `(`/`)` jump comments; `/` search diff text; `Space` `f` list changed files (overlay); `Space` `l` list comments (overlay); `Space` `A` list approved hunks (overlay, local; Enter unapproves and jumps); `?` help (overlay); `i`/`c`/`a`/`Enter` create or edit on new, `I`/`C`/`A` on old (box below the cursor); `d`/`D` dismiss new/old; `Space` `Space` stage/unstage file, hunk, or group (local); `Space` `a` approve hunk, file, or group (local); `Space` `d` / `Space` `x` discard (local, confirm).
4. **Diff-first layout** - files and hunks from the *change set*, not a full project tree.
5. **Precise selection** - comments must attach to the exact span you care about, including overlapping ranges.
6. **Mouse optional** - never required to place or target a comment.
7. **Prompts over popovers** - search and similar actions use an inline command-line style interaction; avoid floating pickers unless they clearly beat that model.

---

## Non-goals (v1)

- No remotes, no GitHub/GitLab API, no "open a PR from rv"
- No multi-user collaboration or review assignment
- No auto-fix / apply-patch engine inside `rv` (agents do that)
- No browser or embedded web UI
- No mandatory file-tree sidebar

---

## Technical direction

| Decision | Choice | Notes |
|---|---|---|
| Language | **Zig** | Single fast binary; fits the performance bar |
| License | **MIT** | |
| Git data | Prefer **shelling out to `git`** for diffs/status | Correctness and zero vendored git complexity; revisit libgit2 only if needed |
| TUI | Lean Zig TUI stack (evaluate **ZigZag**, **libvaxis**-style, or minimal custom) | Prefer small deps; measure latency on big diffs early |
| Comment store | **Repo-local `.rv/`** (gitignored) | Agents already work in the project root; discoverable default. Optional XDG later for global prefs |
| Export formats | Markdown (human/agent paste) + JSON (tooling) | Stable schema with comment ids and anchors |
| Agent integration | CLI first -> `install-skill` -> export ergonomics -> MCP | Works with Grok, Claude, and anything that can read a file or run a command; skill discovery is installed, not documented-only |

### Suggested on-disk layout

```text
.rv/
  config.toml          # optional local overrides
  reviews/
    <review-id>.json   # comments + anchors for a review session
  export/
    latest.md          # optional last export convenience path
```

Exact schema is implementation detail; the README-level contract is: **stable ids, precise anchors, exportable.**

### CLI surface (indicative)

```text
rv                  # TUI, local changes
rv <range>          # TUI on `git diff <range>` (e.g. main...HEAD)
rv list             # list comments
rv show <id>
rv resolve <id> ... # delete comments
rv export [--format md|json] [-o path]
rv status           # live count and store path
rv install-skill [--agent <name>] [--list] [--uninstall]
                    # install/update the bundled agent skill into
                    # known discovery paths (symlink preferred)
```

---

## Success criteria

`rv` is succeeding when:

- Reviewing agent output no longer requires a GUI *and* a prose re-description of every issue
- Leaving a comment on a multi-line, even overlapping, span is faster than typing the location into chat — and possible without taking hands off the keyboard
- `j`/`k` feel like moving a cursor through the change, not nudging a scrollbar
- Export/CLI handoff is reliable enough that "address `rv` comments" is a normal agent instruction
- `rv install-skill` is enough to make that instruction work in Grok/Claude (and peers) without manual path plumbing
- The TUI is something you *want* to open mid-session, not a chore

---

## Status

**Design phase.** This README defines the product. Implementation comes next.

---

## License

MIT. See [LICENSE](LICENSE).
