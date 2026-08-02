# Goal order

Recommended order for agents and humans. Prefer this over numeric id order.
Override only if the user says so.

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

---

## 1. Critical product path (Next)

Comments exist on disk; agents still need a headless surface. Start here.

### #4 MVP-2 — Agent handoff CLI

Parent goal for export, list, resolve, install-skill. Work the **slices in order**; complete #4 when 2.1–2.5 land and acceptance holds.

| Order | ID | Title |
|------:|----|-------|
| 1a | **38** | MVP-2.1: Store resolve/reopen API |
| 1b | **39** | MVP-2.2: CLI dispatch + read-only commands (`status`, `list`, `show`, help) |
| 1c | **40** | MVP-2.3: CLI resolve and reopen |
| 1d | **41** | MVP-2.4: Export markdown and JSON |
| 1e | **42** | MVP-2.5: Bundled skill + `install-skill` |

**Why first:** closes the human → agent loop promised in the README. Unblocked by MVP-1.

**Design locks (session on #4):**

| Topic | Decision |
|-------|----------|
| `list` default | open-only (`--all` / `--resolved` for others) |
| `reopen` | included in 2.3 |
| export auto-write | no (stdout or explicit `-o` only) |
| JSON | export envelope (`version`, `review_id`, `filter`, `comments[]`) |
| skill root | canonical `~/.agents/skills/rv`; auto-detect other agent skill dirs and symlink them to canonical |
| project-local skill | not in MVP-2 |
| agent set | auto-detect only (optional `--agent` for one target) |

---

## 2. Small polish (interleave with or right after MVP-2)

Cheap, independent, high clarity for daily use.

| Order | ID | Title |
|------:|----|-------|
| 2 | **28** | TUI setup failures: clear message when Tty/Screen open fails after load |
| 3 | **35** | Diff line styling: light/dark green-red backgrounds, drop +/- markers |
| 4 | **37** | Stronger file and hunk header styling |
| 5 | **36** | Sticky file and hunk headers in the review viewport |

**Why this sequence:** #28 is a tiny post-load error path. #35 then #37 share the paint style table; #36 pins headers using those styles.

---

## 3. Input flexibility

| Order | ID | Title |
|------:|----|-------|
| 6 | **43** | Non-git diff input (file / stdin / patch path) |

**Why here:** after handoff CLI so agents can review a saved patch and still `list` / `export` / `resolve`. Same TUI + `.rv/` board; git smart-default remains bare `rv`. Can pull earlier if offline patch review is blocking.

---

## 4. Readability → navigation depth

| Order | ID | Title |
|------:|----|-------|
| 7 | **34** | Horizontal scroll / long-line visibility |
| 8 | **5** | MVP-3: Navigation depth (search, files, ranges) |

**Why:** #34 before #5 so column cursor / range selection can share horizontal viewport state. MVP-3 prefers MVP-2 so export grows range fields once.

---

## 5. Scale and performance (measurement-first)

| Order | ID | Title |
|------:|----|-------|
| 9 | **33** | [perf] Reproducible bench/profile harness |
| 10 | **32** | [perf] Event loop: no-op keys must not repaint |
| 11 | **31** | Performance program (parent) |
| 12 | **22** | Large diffs: stream / bound / abbreviate |

**Why:** harness (#33) before concrete wins (#32) and the program (#31). Large-diff strategy (#22) after profiles or real pain.

---

## 6. Next product era (design only until ready)

| Order | ID | Title |
|------:|----|-------|
| 13 | **26** | Design: changesets (comment-scoped reviews → one commit) |
| 14 | **25** | Design: stage / unstage / discard hunks and files |

Design after MVP-2 is real. #26 is the multi-round agent loop; #25 is useful but secondary to comment → resolve.

---

## 7. Park / anytime hygiene (Later)

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
#4 MVP-2 via slices:
  #38 store resolve/reopen
  → #39 CLI dispatch + status/list/show
  → #40 resolve/reopen CLI
  → #41 export md/json
  → #42 install-skill (~/.agents/skills + detect/symlink)
  → close #4 when acceptance holds

  → #28 (tiny error UX)
  → #35 → #37 → #36   (review readability pack)
  → #43 non-git diff input
  → #34 horizontal scroll
  → #5  MVP-3
  → #33 → #32 → #31 → #22
  → #26, #25 designs
  → #10–17, #11, #23, #24, #30   (filler)
```

Immediate Next queue: **#38** (first MVP-2 slice) while **#4** is the active parent; polish **#28**, **#35** remain promoted. Start coding with `goal start 38` (or keep #4 active and work the slice — prefer starting the slice id when implementing).
