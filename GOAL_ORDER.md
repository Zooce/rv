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
| **2** | MVP-0 epic pointer (closed after slices) |
| **3** | MVP-1: Line comments + `.rv/` store |
| **29** | Enrich display rows (path / line nos / anchors) — shipped with MVP-1 |

---

## 1. Critical product path (Next)

Comments exist on disk; agents still need a headless surface. Start here.

| Order | ID | Title |
|------:|----|-------|
| 1 | **4** | MVP-2: Agent handoff CLI (export, list, resolve, install-skill) |

**Why first:** closes the human → agent loop promised in the README. Unblocked by MVP-1.

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

## 3. Readability → navigation depth

| Order | ID | Title |
|------:|----|-------|
| 6 | **34** | Horizontal scroll / long-line visibility |
| 7 | **5** | MVP-3: Navigation depth (search, files, ranges) |

**Why:** #34 before #5 so column cursor / range selection can share horizontal viewport state. MVP-3 prefers MVP-2 so export grows range fields once.

---

## 4. Scale and performance (measurement-first)

| Order | ID | Title |
|------:|----|-------|
| 8 | **33** | [perf] Reproducible bench/profile harness |
| 9 | **32** | [perf] Event loop: no-op keys must not repaint |
| 10 | **31** | Performance program (umbrella) |
| 11 | **22** | Large diffs: stream / bound / abbreviate |

**Why:** harness (#33) before concrete wins (#32) and the program (#31). Large-diff strategy (#22) after profiles or real pain.

---

## 5. Next product era (design only until ready)

| Order | ID | Title |
|------:|----|-------|
| 12 | **26** | Design: changesets (comment-scoped reviews → one commit) |
| 13 | **25** | Design: stage / unstage / discard hunks and files |

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
#4 MVP-2
  → #28 (tiny error UX)
  → #35 → #37 → #36   (review readability pack)
  → #34 horizontal scroll
  → #5  MVP-3
  → #33 → #32 → #31 → #22
  → #26, #25 designs
  → #10–17, #11, #23, #24, #30   (filler)
```

Immediate Next queue (promoted): **#4**, **#28**, **#35**. Start with `goal start 4`.
