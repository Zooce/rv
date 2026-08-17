//! Minimal pure-Zig TUI for `rv`. Read files in this order:
//!
//! 1. `tty.zig`    — own the terminal (termios, raw mode, alt screen, restore)
//! 2. `event.zig`  — bytes → keys; SIGWINCH → resize
//! 3. `screen.zig` — cell grid + diff render (CUP / SGR escapes);
//!    overlay helpers (`Rect`, `fillRect`, `drawBox`; `putStr` takes an optional clip).
//!    Still not a widget library.
//!
//! App loop pattern (see `examples/tui_demo.zig`):
//!   open tty → draw into Screen → present → wait event → repeat → deinit
//!
//! ## Acronym cheat sheet (full names used again at first use in each file)
//!
//! | Short | Full name | One-line meaning |
//! |-------|-----------|------------------|
//! | TTY | teletypewriter | "the terminal device" (historical name; still used in APIs) |
//! | fd | file descriptor | integer handle for an open file/device (`/dev/tty`) |
//! | termios | terminal I/O settings | kernel struct: echo, line mode, ctrl keys, VMIN/VTIME, … |
//! | CSI | Control Sequence Introducer | escape prefix `ESC [` used by most modern sequences |
//! | ESC | escape character | byte `0x1b` (`\x1b`); starts almost every terminal control sequence |
//! | SGR | Select Graphic Rendition | style/color: `\x1b[...m` (bold, colors, reset) |
//! | CUP | Cursor Position | move cursor: `\x1b[row;colH` (1-based) |
//! | DEC | Digital Equipment Corporation | family of private modes (`?1049`, `?25`, …) from old DEC terminals / xterm |
//! | SIG | signal | async kernel notification (SIGINT, SIGTERM, SIGWINCH, …) |
//! | SIGWINCH | signal: window change | "terminal was resized"; re-query size with ioctl |
//! | SIGINT / SIGTERM | interrupt / terminate | usual "please quit" signals (kill -2 / kill default) |
//! | ioctl | I/O control | device-specific call; we use `TIOCGWINSZ` for rows/cols |
//! | VMIN / VTIME | min bytes / timeout | non-canonical `read()` rules in termios `cc[]` |
//! | ISIG / ICANON / ECHO | termios local flags | signals-from-keys / line-editing / echo typed chars |
//! | SGR params 38/48 | fg/bg extended color | `38;5;n` 256-color fg, `38;2;r;g;b` truecolor fg (48 = bg) |

// Submodules — each is a tutorial file; start with tty, then event, then screen.
pub const tty = @import("tty.zig");
pub const event = @import("event.zig");
pub const screen = @import("screen.zig");

// Convenience re-exports so apps can write `tui.Tty` instead of `tui.tty.Tty`.
pub const Tty = tty.Tty;
pub const Size = tty.Size;

pub const Event = event.Event;
pub const Key = event.Key;

pub const Screen = screen.Screen;
pub const Cell = screen.Cell;
pub const Style = screen.Style;
pub const Color = screen.Color;
pub const Rect = screen.Rect;

// Pull submodule tests into `zig build test` via this root.
test {
    _ = tty;
    _ = event;
    _ = screen;
}
