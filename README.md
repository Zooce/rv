# rv

**Local terminal diff review for humans - precise comments for AI agents.**

`rv` (short for *review*) is a fast, keyboard-driven TUI for reviewing local git diffs and leaving comments that your AI coding agent can act on. Stay in the terminal. Point at the exact lines. Hand the feedback to Grok, Claude, or any other agent without retyping filenames and line numbers.

---

## Install

Linux and macOS. No Windows builds yet.

Prebuilt binaries are on [GitHub Releases](https://github.com/Zooce/rv/releases):

| OS | Arch | Asset |
|---|---|---|
| Linux | x86_64 | `rv-linux-x86_64.tar.gz` |
| Linux | aarch64 | `rv-linux-aarch64.tar.gz` |
| macOS | x86_64 | `rv-macos-x86_64.tar.gz` |
| macOS | aarch64 | `rv-macos-aarch64.tar.gz` |

Each tarball contains `bin/rv` and `share/rv/skills/rv`. Extract into `~/.local` so `rv install-skill` can find the bundled skill:

```sh
mkdir -p ~/.local
tar -C ~/.local -xzf rv-linux-x86_64.tar.gz
```

`SHA256SUMS` is on the same release; verify the tarball before extracting.

If `~/.local/bin` is not on `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Then:

```sh
rv install-skill
```

### From source

Zig 0.16.0.

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

`mise run build` (or `zig build`) produces a Debug build in `zig-out/`.

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
    -> rv (terminal, vim keys, comments on files, hunks, and lines)
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
| **hunk** (modem-dev) | Strong terminal review UI; live session CLI; human notes agents can read | Agent skill is **not auto-installed** — only `hunk skill path` + manual symlink/copy (or Nix home-manager). Session-bound notes, not a durable comment board; coarser anchors than file/hunk/line. **`j`/`k` only scroll the viewport one line** — no moveable current-line cursor; leaving a note often requires the **mouse** |

Design reactions baked into `rv`:

- **Terminal only** - no local web server, no browser tab.
- **No file-tree panel** - long paths (Java packages, monorepos) waste space and aren't how you navigate a *diff*. Navigate the changed files and hunks themselves.
- **Keyboard-first cursor on the diff** - a highlighted **current line** moves with vim keys; comments attach from that cursor. Keyboard is enough; mouse is never required.
- **Handoff is a first-class feature** - not an afterthought dump to stdout.
- **Agent skill install is a product command** - not "print a path and hope the user symlinks it."
- **Enjoyable daily driver** - if the TUI isn't pleasant, the tool fails even if the data model is right.

---

## Who it's for

Terminal + AI-agent power users who already work in sessions with tools like **Grok** and **Claude** (and want the same flow with *any* agent).

Not a multi-user code-review platform. Not a GitHub replacement. A **personal review board** sitting between your agent and your tree.

---

## Core workflow

### Review surfaces

| Surface | Status |
|---|---|
| Working tree + staged (`git diff HEAD` + untracked) | v1 |
| One commit (`rv HEAD`, `rv <hash>`) | v1 |
| Branch vs base (e.g. `rv main...HEAD`) | v1 |
| Arbitrary patches | Later |

**Default invocation:** bare `rv` reviews local changes only (staged, unstaged, and untracked). The TUI groups those under labeled **Unstaged**, **Untracked**, and **Staged** sections (empty groups omitted). A clean worktree opens an empty review. Approved local hunks are omitted from the walk; when every remaining change is approved the footer is `HEAD · N approved`, not `HEAD · empty`. A commit-ish (`rv HEAD`, a hash, a branch name) opens the patch that commit introduced, not worktree vs that rev. A range that contains `..` or `...` (`rv main...HEAD`) is `git diff <range>` as written. Commit and range reviews have no section headers and are read-only for stage / unstage / discard / approve. The footer shows the load source (`HEAD` for local, `HEAD · empty` when the worktree is clean, `HEAD · N approved` when the tree is dirty but nothing unapproved remains, or the commit-ish / range you passed).

### Navigation and selection (keyboard-first)

`rv` is built around a **cursor on the diff**, not viewport-only scrolling.

`rv` leans into a **vim / Helix-like** modal, keyboard-first review — navigate with a real cursor, search with `/`, comment without leaving the keys. No floating pickers or IDE-style popovers when a buffer-style prompt will do.

| Keys | Behavior |
|---|---|
| `j` / `k` | Move the **current line** down / up (highlighted). Viewport follows so the cursor stays visible. |
| `h` / `l` | Pan the current hunk left / right. |
| `0` / `$` | Pan the current hunk to the start / end of the line. |
| `J` / `K` | Jump to the **next / previous changed line**. |
| `[` / `]` | Jump to the **previous / next hunk**. |
| `{` / `}` | Jump to the **previous / next file header**. |
| `(` / `)` | Jump to the **previous / next live comment**. Cursor goes to that comment’s side (old line or new line). Wraps; no comments stays put with a footer note. A comment on an approved hunk unapproves that hunk first (same for `Space` `c` Enter). Unapprove does not unstage. |
| `/` | **Search the diff text** — body lines in the loaded changeset (like vim `/`). Enter jumps to the first match. `n` / `N` next / previous match. |
| `Space` `f` | **List files** — floating overlay on the still-painted diff. One row per changed file (flatten order). `j`/`k` move; Enter jumps to that **file header** and closes. `a`/`A` approve remaining hunks of that file (same as `A` on the header; local only). Esc closes without moving the cursor. `q` still quits. Empty diff: empty overlay. Opens on the file under the cursor when there is one. |
| `Space` `c` | **List comments** — floating overlay on the still-painted diff (same live board as `rv list`). `j`/`k` move; Enter jumps to that comment’s side (same landing as `(`/`)`) and closes the overlay. Esc closes without moving the cursor. `q` still quits. Empty board: empty overlay. A row whose path/line is gone from the live diff: footer note, stay in the list. Read-only: edit or dismiss after jumping. |
| `Space` `a` | **List approved hunks** — floating overlay on the still-painted diff (local only). One row per live approved identity (flatten order): path, git group, short hunk preview (or binary / hunk-less placeholder). `j`/`k` move; Enter unapproves that identity, rebuilds the main list, jumps to the restored row, and closes. Unapprove does not unstage (`gu` / `gU` still unstage). Esc closes without changing approval. `q` still quits. Empty set: empty overlay. Opens on an approved identity in the file under the cursor when there is one. Range and commit reviews ignore this chord. |
| `g` `s` / `g` `u` / `g` `d` | **Stage / unstage / discard** the current hunk (header or inside the hunk). Local only. Hunk chords are no-ops on a file header or section. Stage and unstage are separate keys (already-staged `gs` and not-staged `gu` are no-ops). Discard is unstaged/untracked only and always confirms (`No` selected first; `yes` proceeds). If the target has live comments, a second overlay asks to delete them (`Yes` selected; `no` keeps them). Git discard runs first; comments are deleted only on success. Staged `gd` is a no-op (unstage first). Range and commit reviews ignore git keys. Far-right hints on the hunk header name these chords (discard only when unstaged/untracked). Git failure: centered overlay; Enter or Esc dismisses. |
| `g` `S` / `g` `U` / `g` `D` | **Stage / unstage / discard** the containing file (file header or inside that file). Local only. No-op on a section. Same stage/unstage and discard rules as the hunk chords. Far-right hints on the file header (including sticky) name these chords. |
| `a` | **Approve** the current hunk (header or inside the hunk). Local only. Stages the hunk first (same as `gs`; already staged: skip), then hides it from the walk. Live comments open a confirm (No selected; `yes` proceeds). No-op on a file header or section. Far-right hints stay `Approve Hunk (a)`. Range and commit reviews ignore this key. |
| `A` | **Approve** the remaining hunks of that file in this group (from a hunk or the file header). Local only. Stages those hunks first (same as `gS`; already staged: skip), then hides them. Live comments on the file open a confirm (No selected; `yes` proceeds). No-op on a section. Far-right hints stay `Approve File (A)`. Range and commit reviews ignore this key. |
| `?` | **Help** — centered overlay with the grouped key catalog (motion, search, comments, session, prompts). The title bar is a short hint; this is the full list. `j`/`k` (and arrows) scroll when it does not fit. `?` or Esc closes. `q` still quits. From a file, comment, or approved list, `?` replaces the list with help. While commenting or searching, `?` inserts a question mark. |
| `i` / `c` / `Enter` | Create or edit a comment: **file** on a file header, **hunk** on a hunk header, otherwise **new** (right pane in side-by-side, or the current `+` / context line in unified). Open a box **below the cursor**. Same action; pick the muscle memory you prefer. |
| `I` / `C` | Create or edit the comment on **old** (left pane in side-by-side, or the current `-` / context line in unified). Missing side does nothing. |
| `d` | Dismiss the comment on **new** (right) at the cursor. Gone from the board; no confirm. |
| `D` | Dismiss the comment on **old** (left). Missing side or no comment there: footer note; does not take the other pane. |
| `t` | Toggle layout preference (side-by-side vs unified). Wide terminals default to side-by-side; an explicit unified choice stays unified even when wide. |
| `#` | Toggle line numbers (on by default). |
| `w` | Toggle wrap of diff body lines (off by default). Wrap on: long lines fill the pane; `h`/`l` / `0`/`$` do nothing. Wrap off: truncate and pan as usual. File and hunk headers stay one row. |
| `e` | **Expand** the current hunk by 8 lines of context above and below (repeatable, clamped to the file). Neighbor hunks in the same file and git group merge when they meet. Far-right hint `Expand (e)` on a hunk that can still grow. No-op on a file header, section, binary / hunk-less file, empty list, or when both edges already sit at the file. Not bound while commenting, searching, or in a list/help overlay. Reload (`r`) restores git’s default context. |
| `r` | **Reload** the loaded diff from the same source (re-runs the startup git load). Comments in `.rv` stay. Failed reload keeps the previous view and shows a footer error. Not bound while typing a comment (or in search / a list overlay). |

Contrast with tools where `j`/`k` only pan the view and comment placement needs a mouse: in `rv`, **where the cursor is is where the comment goes.**

#### Search

`/` is a **prompt on the status/command line** (vim-style). Query against **diff content** (added/removed/context lines as shown). Enter jumps to the first match; `n` / `N` walk matches. Prefer this over a separate search UI.

#### File list

`Space` `f` is a list overlay, not a search prompt — same pattern as `Space` `c`. It opens a centered overlay so the diff stays visible in the margins. Rows are flatten order: one display path per file header. Opening inside a file selects that file.

#### Comment list

`Space` `c` is the in-session board, not a search prompt. It opens a centered overlay so the diff stays visible in the margins. Rows are store order: id, source (`local` / the range string / the commit-ish, or `-` if missing), path, side (`old` / `new` / `ctx`), line (`-N` / `+N`), body preview. Creating or dismissing a comment shows up the next time you open the list. Source is what was under review when the comment was left; it is not a request to rewrite that commit.

#### Approved list

`Space` `a` is a list overlay, not a search prompt — same pattern as `Space` `f` and `Space` `c`. Local review only; range and commit reviews ignore it. Rows are flatten order: one live approved identity per row (path, current git group, short hunk preview). Enter unapproves that identity and jumps to the restored row; it does not unstage. There is no peek without unapproving.

#### Comment mode

Entering comment mode inserts an inline **comment box under the current cursor position** (below the highlighted line). Focus moves into the box so you type immediately — no separate dialog floating away from the code.

```text
j/k           # land the current-line highlight on the code you care about
h/l 0/$       # pan the current hunk
/ query       # find text in the diff; n/N walk matches
Space f       # list changed files; j/k; Enter jump; Esc close
Space c       # list comments; j/k; Enter jump; Esc close
Space a       # list approved hunks; j/k; Enter unapprove and jump; Esc close
?             # help overlay; ? or Esc close
i | c | Enter       # create or edit (file / hunk / new)
I | C               # create or edit old (left / -)
              # type the note; Enter save; Esc cancel
```

- Anchor is the **current row**: file header → file comment, hunk header → hunk comment, otherwise the current line (and side).
- `i` / `c` / `Enter` create or edit on new (or file/hunk); `I` / `C` on old. Same box. Pick the muscle memory you prefer.
- **Current line** is always visible as a clear highlight (not just a scroll offset).
- Hunk jumps (`[`/`]`) move both focus and cursor to a sensible line in the target hunk (e.g. first changed line).

### Commenting model

Comments are the product. v1 supports:

- **File** comments (cursor on a file header)
- **Hunk** comments (cursor on a hunk header)
- **Line** comments (cursor on a diff line; old or new side)

Anchors are path + optional old/new line + side. No character ranges.

Lifecycle (v1): **present | gone**. Humans dismiss in the TUI (`d` / `D`); agents call `rv resolve`, which deletes the same ids. No reopen and no resolved list.

### Agent handoff (hybrid)

Built for any agent (Grok, Claude, Codex, Cursor, ...):

1. **Export** - `rv export` (and friends) emit a stable, agent-readable document of comments (ids, source, paths, loc, bodies). Source is `local`, a range string, or a commit-ish: what was under review, not a request to amend that commit. Paste, pipe, or `@`-include into a session. `list` / `export` stay comments.
2. **CLI** - `rv status` reports comment count and live approved count. Approved hunks are staged and hidden from the TUI walk; agents use `rv approved` / `rv unapprove` to see or restore them in the walk (unapprove does not unstage; do not edit `.rv/approved.json`). `list` / `show` / `resolve` stay comments.
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

Behavior:

- Canonical link: `~/.agents/skills/rv` → the bundled skill next to the binary (`share/rv/skills/rv`).
- Agent roots (`~/.grok/skills`, `~/.claude/skills`, `~/.codex/skills`, `~/.cursor/skills`) get `rv` → that canonical path when the agent root exists (created on install).
- Idempotent: safe to re-run after upgrading `rv`.

The contract is: **one command makes the agent able to read and act on `rv` comments.**

### Sketch of a session

```text
$ rv install-skill             # once per machine (or after upgrade)

$ grok   # or claude - agent implements a feature

$ rv     # local changes only (empty when the worktree is clean)
         # j/k line; h/l pan; [/] hunks; (/) comments; / text; Space f files
         # Space c comments; Space a approved (local, Enter unapproves, still staged)
         # gs/gu/gd hunk git; gS/gU/gD file git (local); a/A stage then hide hunk/file (local)
         # i/c/Enter -> create or edit file / hunk / new
         # I/C -> old; d dismiss new; D dismiss old; r reload; ? help

$ rv status                    # comments + approved counts and store paths
                               # approved hunks are hidden from the TUI walk
$ rv approved                  # if approved > 0
$ rv unapprove <n>             # restore that hunk in the walk; does not unstage
                               # do not hand-edit .rv/approved.json

$ rv export -o .rv/review.md   # or stdout / JSON; comments only
# agent already knows the skill: address rv comments

$ rv list                      # comments
$ rv resolve <id>              # deletes the id
$ rv                         # confirm, leave more, continue
```

---

## UX principles (non-negotiable)

1. **Clean and simple** - enjoyable to use every day; no cluttered "IDE in the terminal."
2. **Performance** - no slop. Instant open on large diffs is a requirement, not a nice-to-have.
3. **Vim / Helix-like keybindings** - `j`/`k` move a **highlighted current line** (not merely scroll); `h`/`l` pan the hunk; `[`/`]` jump hunks; `{`/`}` jump files; `(`/`)` jump comments; `/` search diff text; `Space` `f` list changed files (overlay); `Space` `c` list comments (overlay); `Space` `a` list approved hunks (overlay, local; Enter unapproves and jumps, does not unstage); `?` help (overlay); `i`/`c`/`Enter` create or edit (file / hunk / new), `I`/`C` on old (box below the cursor); `d`/`D` dismiss new/old; `gs`/`gu`/`gd` stage/unstage/discard hunk and `gS`/`gU`/`gD` the file (local); `a`/`A` approve hunk/file (local; stages, then hides).
4. **Diff-first layout** - files and hunks from the *change set*, not a full project tree.
5. **Precise selection** - comments attach to a file, hunk, or line.
6. **Keyboard is enough** - placing a comment does not need a mouse.
7. **Prompts over popovers** - search and similar actions use an inline command-line style interaction; avoid floating pickers unless they clearly beat that model.

---

## Non-goals (v1)

- No remotes, no GitHub/GitLab API, no "open a PR from rv"
- No multi-user collaboration or review assignment
- No auto-fix / apply-patch engine inside `rv` (agents do that)
- No browser or embedded web UI
- No mandatory file-tree sidebar

---

## Implementation

| Decision | Choice | Notes |
|---|---|---|
| Language | **Zig** | Single fast binary; fits the performance bar |
| License | **MIT** | |
| Git data | Prefer **shelling out to `git`** for diffs/status | Correctness and zero vendored git complexity; revisit libgit2 only if needed |
| TUI | Custom Zig TUI (`tui/`) | Pure Zig, no C deps, no terminfo |
| Comment store | **Repo-local `.rv/`** (gitignored) | Agents already work in the project root; discoverable default. Optional XDG later for global prefs |
| Export formats | Markdown (human/agent paste) + JSON (tooling) | Stable schema with comment ids and anchors |
| Agent integration | CLI first -> `install-skill` -> export ergonomics -> MCP | Works with Grok, Claude, and anything that can read a file or run a command; skill discovery is installed, not documented-only |

### On-disk layout

```text
.rv/
  approved.json        # local approved hunks/files (not comments)
  reviews/
    current.json       # comments + anchors for the live board
```

Exact schema is implementation detail; the README-level contract is: **stable ids, precise anchors, exportable.**

### CLI

```text
rv                  # TUI, local changes
rv <commit>         # TUI on that commit's patch (e.g. HEAD, a hash)
rv <range>          # TUI on `git diff <range>` (e.g. main...HEAD)
rv status           # live comment count, approved count, and store paths
rv approved         # list approved hunks and files
rv unapprove <n>    # drop the nth row from that list (does not unstage)
rv list             # list comments
rv show <id>
rv resolve <id> ... # delete comments
rv export [--format md|json] [-o path]
rv install-skill [--agent <name>] [--list] [--uninstall]
                    # install/update the bundled agent skill into
                    # known discovery paths (symlink preferred)
rv version, -v, --version
                    # print version and exit
```

---

## Success criteria

`rv` is succeeding when:

- Reviewing agent output no longer requires a GUI *and* a prose re-description of every issue
- Leaving a comment on a file, hunk, or line is faster than typing the location into chat — and possible without taking hands off the keyboard
- `j`/`k` feel like moving a cursor through the change, not nudging a scrollbar
- Export/CLI handoff is reliable enough that "address `rv` comments" is a normal agent instruction
- `rv install-skill` is enough to make that instruction work in Grok/Claude (and peers) without manual path plumbing
- The TUI is something you *want* to open mid-session, not a chore

---

## License

MIT. See [LICENSE](LICENSE).
