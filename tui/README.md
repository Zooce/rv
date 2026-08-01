# tui — minimal pure-Zig TUI foundation for `rv`

Small, opinionated terminal UI core. Not a widget library.

## Goals

- Pure Zig, no C dependencies, no terminfo
- Correct terminal ownership and restore (including on signal)
- No-flicker diff rendering
- Tiny public API used by `rv` itself

## Layout

| File | Role |
|------|------|
| `root.zig` | Module re-exports + **acronym cheat sheet** |
| `tty.zig` | Open `/dev/tty`, raw mode, alt screen, buffered write, signal restore |
| `event.zig` | Key + resize events (basic parsing) |
| `screen.zig` | Cell grid, double buffer, SGR + CUP diff renderer |

## Acronyms (quick)

See the table at the top of `tui/root.zig`. Short list:

- **CUP** — Cursor Position (`\x1b[row;colH`)
- **SGR** — Select Graphic Rendition (styles/colors, `\x1b[…m`)
- **CSI** — Control Sequence Introducer (`ESC [`)
- **termios** — terminal I/O settings (kernel)
- **SIGWINCH** — signal: window change (resize)

Demo: `examples/tui_demo.zig` → binary `tui_demo`.

## Build / run

```text
zig build              # build rv stub + tui_demo
zig build run-demo     # interactive demo
mise run demo          # same via mise
```

Requires Zig **0.16+** (0.14/0.15 APIs may need small adjustments).

## What works now

1. **Terminal ownership** — opens `/dev/tty` (works with redirected stdio), saves termios, raw mode (`ECHO`/`ICANON`/`ISIG`/`IXON`/`IEXTEN`/`ICRNL` cleared, `VMIN=1`/`VTIME=0`), alt screen + hidden cursor. Restore on normal exit, `SIGINT`/`SIGTERM` (immediate exit after restore), and `SIGHUP`/`SIGQUIT`/`SIGABRT` (restore + re-raise). `SIGWINCH` sets a flag for the event loop.
2. **Events** — printable ASCII, Enter, Esc, Tab, Backspace, arrows; resize events from `SIGWINCH`. Hangup/EOF on the input fd (`poll`-ready + `read` 0, e.g. PTY torn down without a delivered SIGHUP) is `error.EndOfStream` from `Tty.readTimeout` and surfaces as `.quit` from `event.poll` / `event.next` so wait loops exit instead of busy-spinning.
3. **Screen** — 2D cells (`codepoint` + style + width), front/back buffers, diff present (only changed cells emit CUP + SGR + glyph). No full clear each frame.
4. **Demo** — counter / status line, resize-safe, quit on `q`.

## Known limitations (intentional for v1)

- Unicode width / grapheme clusters are simplified (ASCII + rough wide ranges). Real East Asian Width + combining marks come later.
- No Kitty keyboard protocol, mouse, focus, or bracketed paste.
- No widgets, layout, or focus management.
- Fatal SEGV/ILL/BUS still use Zig’s debug handler (tty may not restore on those).

## Next steps

1. UTF-8 multi-byte input in the key decoder
2. Better Unicode width (table or small dependency-free subset)
3. Optional non-blocking / frame-rate-driven loop for animations
4. Mouse and richer key modifiers when `rv` needs them
5. Build the actual review TUI on this foundation

## Design notes

- Immediate-mode is fine: app state → clear/draw → `present` each event.
- Prefer explicit code over clever abstractions until real use demands more.
- Prefer `std.posix` and hard-coded modern terminal sequences over terminfo.
