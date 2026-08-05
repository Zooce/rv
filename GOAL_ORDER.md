# Goal order

Recommended order for agents and humans. Prefer this over numeric id order.
Override only if the user says so.

**Live queue:** `goal list` **Next** order is the operational ranking (most recently `goal next`’d first). Keep it aligned with the tables below via `goal next` (last→first when reshaping the whole stack). See [`AGENTS.md`](AGENTS.md) § List order.

Start a goal with: `goal start <id>`  
Full brief: `goal show <id>`  
See also: [`AGENTS.md`](AGENTS.md) (how to use `goal`).

---

## Done (history)

| IDs | Title |
|-----|-------|
| **1** | Minimal pure-Zig TUI foundation |
| **6–9** | Foundation bugs (SIGWINCH, termios, EOF/HUP, `present` retry) |
| **18–21** | MVP-0.1–0.4 (parser, git load, review TUI, hunk jump / empty UX) |
| **2** | MVP-0 parent (closed after slices) |
| **3** | MVP-1: Line comments + `.rv/` store |
| **29** | Enrich display rows (path / line nos / anchors) — shipped with MVP-1 |
| **38–42** | MVP-2.1–2.5 (store resolve, CLI, export, install-skill) |
| **4** | MVP-2 parent (agent handoff CLI) — verified closed |
| **28** | TUI setup failures: clear message when Tty/Screen open fails after load |
| **35** | Diff line styling: light/dark green-red backgrounds, drop +/- markers |
| **37** | Stronger file and hunk header styling |
| **36** | Sticky file headers in the review viewport (file-only pin; hunks scroll) |

MVP-2 design locks (history): `list` open-only by default; `reopen` in CLI; export stdout/`-o` only (no auto-write); JSON export envelope; skill canonical `~/.agents/skills/rv` + agent symlinks; no project-local skill in MVP-2.

---

## 1. Header navigation (Next)

Land the cursor on hunk/file **header rows** (for later stage/unstage/discard). After sticky file pin (#36).

| Order | ID | Title |
|------:|----|-------|
| 1 | **48** | Jump cursor to next/previous hunk header row |
| 2 | **49** | Jump cursor to next/previous file header row |

**Why this sequence:** Hunk jump first (denser, replaces/adjusts `[`/`]` feel); then file jump. Both keep headers cursor-reachable.

---

## 2. Input flexibility

| Order | ID | Title |
|------:|----|-------|
| 3 | **46** | Include untracked files in the smart-default diff |
| 4 | **43** | Non-git diff input (file / stdin / patch path) |

**Why here:** #46 completes live worktree review (new files without a forced `git add`); #43 is offline/saved patches. Same TUI + `.rv/` board; bare `rv` stays git smart-default. Pull either earlier if blocked on new-file or patch review.

---

## 3. Readability → navigation depth

| Order | ID | Title |
|------:|----|-------|
| 5 | **34** | Horizontal scroll / long-line visibility |
| 6 | **5** | MVP-3: Navigation depth (search, files, ranges) |

**Why:** #34 before #5 so column cursor / range selection can share horizontal viewport state. MVP-3 prefers MVP-2 so export grows range fields once.

---

## 4. Scale and performance (measurement-first)

| Order | ID | Title |
|------:|----|-------|
| 7 | **33** | [perf] Reproducible bench/profile harness |
| 8 | **32** | [perf] Event loop: no-op keys must not repaint |
| 9 | **31** | Performance program (parent) |
| 10 | **22** | Large diffs: stream / bound / abbreviate |

**Why:** harness (#33) before concrete wins (#32) and the program (#31). Large-diff strategy (#22) after profiles or real pain.

---

## 5. Next product era (design only until ready)

| Order | ID | Title |
|------:|----|-------|
| 11 | **26** | Design: changesets (comment-scoped reviews → one commit) |
| 12 | **25** | Design: stage / unstage / discard hunks and files |

Design after MVP-2 is real. #26 is the multi-round agent loop; #25 is useful but secondary to comment → resolve.

---

## 6. Park / anytime hygiene (Later)

Not on the critical path. Do when touching related files or as filler.

| Cluster | IDs | Notes |
|---------|-----|--------|
| Docs / nits | **10–17** | Prefer docs when editing those modules |
| Fill helpers | **11** | `main` already has local `fillRow`; promote to `Screen` only if shared |
| Viewport policy | **30** | After sticky headers / scroll feel settle |
| Test helper | **24** | Extract IsolatedTmp when a second module needs it |
| Style hygiene | **23** | Rename Allocator locals/params to `alloc` (mechanical) |

---

## Quick path

```text
#4 MVP-2 (done): #38–#42 slices + parent closed
#28 TUI setup failures (done)
#35 → #37 → #36   (review readability pack; sticky = file-only)

  → #48 hunk-header jump → #49 file-header jump
  → #46 untracked in smart-default
  → #43 non-git diff input
  → #34 horizontal scroll
  → #5  MVP-3
  → #33 → #32 → #31 → #22
  → #26, #25 designs
  → #10–17, #11, #23, #24, #30   (filler)
```

Immediate Next (top of `goal list`): **#48** → **#49** → **#46** → … Start with `goal start 48`.
