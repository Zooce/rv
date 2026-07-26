//! `rv` entry point (stub).
//!
//! Product work lives in the README. The TUI foundation is under `tui/` and
//! can be exercised with `zig build run-demo` / `mise run demo`.

const std = @import("std");

pub fn main() !void {
    std.debug.print(
        \\rv — local terminal diff review (not implemented yet)
        \\
        \\The TUI foundation is ready:
        \\  zig build run-demo
        \\  mise run demo
        \\
        \\See tui/README.md and the project README for direction.
        \\
    , .{});
}
