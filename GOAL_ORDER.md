# Goal order

Recommended order for agents and humans. Prefer this over numeric id order.
Override only if the user says so.

Start a goal with: `goal start <id>`  
Full brief: `goal show <id>`  
See also: [`AGENTS.md`](AGENTS.md) (how to use `goal`).

---

## 1. Foundation bugs (before MVP-0)

Fix these first. They affect terminal restore, resize, and event-loop safety.

| Order | ID | Title |
|------:|----|-------|
| 1 | **6** | [bug] Fix SIGWINCH drop in event wait helper |
| 2 | **7** | [bug] Restore termios if `Tty.open` fails after raw mode |
| 3 | **8** | [bug] Stop event loop busy-spin on tty EOF/HUP |
| 4 | **9** | [bug] Make `Screen.present` safe to retry after write failure |

**Why this sequence:** #6 unblocks reliable resize for the review TUI. #7/#8 are setup and hangup safety. #9 is present retry integrity. Each bug goal is **test-first** (RED then GREEN).

---

## 2. Optional TUI polish (nice before MVP-0)

Not blockers. Do any subset before or after MVP-0; cheap DX wins first if time is short.

| Order | ID | Title |
|------:|----|-------|
| 5 | **11** | [suggestion] Add `Screen.fillRow` / `fillRect` helpers |
| 6 | **10** | [suggestion] Document event key limits (ASCII `.char`) |
| 7 | **13** | [suggestion] Document exclusive `Tty` ownership |
| 8 | **12** | [suggestion] Document or reset signal handlers on `deinit` |
| 9 | **14** | [suggestion] Document `codepointWidth` as best-effort |
| 10 | **15** | [suggestion] Document `Screen.present` hot-path expectations |
| 11 | **16** | [nit] Fix present comment (front→back not a full copy) |
| 12 | **17** | [nit] Preserve `getSize` errors in `event.poll` |

---

## 3. Product slices

| Order | ID | Title |
|------:|----|-------|
| 13 | **2** | MVP-0: Read-only diff review TUI (cursor on diff) |
| 14 | **3** | MVP-1: Line comments + `.rv/` store |
| 15 | **4** | MVP-2: Agent handoff CLI (export, list, resolve, install-skill) |
| 16 | **5** | MVP-3: Navigation depth (search, files, ranges) |

Do **not** start MVP-0 until foundation bugs **#6–#9** are complete (or the user explicitly skips them).

---

## Quick path

If the next session should only advance the critical path:

```text
6 → 7 → 8 → 9 → 2 → 3 → 4 → 5
```

Park suggestions/nits (#10–#17) in Later until after MVP-0 unless you want fill helpers (#11) first.
