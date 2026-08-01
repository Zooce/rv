# Goal order

Recommended order for agents and humans. Prefer this over numeric id order.
Override only if the user says so.

Start a goal with: `goal start <id>`  
Full brief: `goal show <id>`  
See also: [`AGENTS.md`](AGENTS.md) (how to use `goal`).

---

## 1. Foundation bugs (done)

Completed before the MVP-0 split. Kept here for history only.

| Order | ID | Title |
|------:|----|-------|
| — | **6–9** | SIGWINCH wait, termios restore on open fail, EOF/HUP spin, `present` retry |

---

## 2. Optional TUI polish (nice anytime)

Not blockers. Do any subset before or after MVP-0 slices; cheap DX wins first if time is short.

| Order | ID | Title |
|------:|----|-------|
| — | **11** | [suggestion] Add `Screen.fillRow` / `fillRect` helpers |
| — | **10** | [suggestion] Document event key limits (ASCII `.char`) |
| — | **13** | [suggestion] Document exclusive `Tty` ownership |
| — | **12** | [suggestion] Document or reset signal handlers on `deinit` |
| — | **14** | [suggestion] Document `codepointWidth` as best-effort |
| — | **15** | [suggestion] Document `Screen.present` hot-path expectations |
| — | **16** | [nit] Fix present comment (front→back not a full copy) |
| — | **17** | [nit] Preserve `getSize` errors in `event.poll` |

---

## 3. MVP-0 slices (critical path)

Original epic **#2** is split. Implement in order; do not start a later slice until the previous is done (or the user skips).

| Order | ID | Title |
|------:|----|-------|
| 1 | **18** | MVP-0.1: Unified diff model + parser |
| 2 | **19** | MVP-0.2: Git load + smart default |
| 3 | **20** | MVP-0.3: Review TUI — render, cursor, viewport, quit |
| 4 | **21** | MVP-0.4: Hunk jump, status, empty/error UX |

**Why this sequence:** 0.1 is pure data + tests. 0.2 feeds the parser from `git`. 0.3 is the first interactive vertical (show + `j`/`k` + quit). 0.4 closes original MVP-0 acceptance (`[/]`, footer, empty/error).

Epic pointer (Later, do not implement as one goal): **#2**.

---

## 4. Later product slices

| Order | ID | Title |
|------:|----|-------|
| 5 | **3** | MVP-1: Line comments + `.rv/` store |
| 6 | **4** | MVP-2: Agent handoff CLI (export, list, resolve, install-skill) |
| 7 | **5** | MVP-3: Navigation depth (search, files, ranges) |

---

## Quick path

```text
18 → 19 → 20 → 21 → 3 → 4 → 5
```

Park suggestions/nits (#10–#17) in Later until after MVP-0.4 unless you want fill helpers (#11) first.
