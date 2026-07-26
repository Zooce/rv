//! Demo of the TUI loop (immediate-mode):
//!
//!   open → draw front buffer → present (diff to terminal)
//!        → wait for event → update state → redraw → ...
//!        → deinit restores the shell
//!
//!   zig build run-demo
//!
//! This file is the "app". The library does not own your state — you do.
//! Each frame you rebuild the screen from state, then present the diff.

const std = @import("std");
const tui = @import("tui"); // our module (see tui/root.zig)

pub fn main() !void {
    // DebugAllocator tracks leaks in Debug builds (Zig 0.16 name for the old GPA).
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit(); // returns .leak if something was not freed
    const gpa = gpa_state.allocator(); // the Allocator interface we pass to Screen

    // open(): /dev/tty + raw termios + alt screen + signal handlers.
    // defer deinit(): always restore the shell, even if we return via error.
    var term = try tui.Tty.open();
    defer term.deinit();

    // Ask the kernel how big the window is right now.
    var size = try term.getSize();
    // Allocate front/back cell grids matching that size.
    var scr = try tui.Screen.init(gpa, size);
    defer scr.deinit();

    // --- app state (immediate-mode: screen is rebuilt from this each time) ---
    var counter: u64 = 0; // how many keys we've seen
    var last_key: []const u8 = "(none)"; // label shown in the UI
    var last_key_buf: [64]u8 = undefined; // storage for formatted "char 'x'" labels
    var running = true; // main loop flag

    // First paint: dirty_all is true, so present writes every cell once.
    try draw(&scr, size, counter, last_key); // fill front buffer from state
    try scr.present(&term); // diff front→terminal (full first frame)

    while (running) {
        // Block until a key or resize (SIGINT from outside restores+exits in tty).
        const ev = try tui.event.next(&term);
        switch (ev) {
            // Soft quit (rare with current handlers that exit on SIGINT/SIGTERM).
            .quit => running = false,

            // User resized the window (SIGWINCH → we ioctl'd the new size).
            .resize => |new_size| {
                size = new_size; // remember for draw()
                try scr.resize(size); // realloc grids + mark dirty_all
                last_key = "resize"; // show what happened
                try draw(&scr, size, counter, last_key); // rebuild front
                try scr.present(&term); // full repaint on new geometry
            },

            // A decoded keypress.
            .key => |key| {
                switch (key) {
                    // Printable character (ASCII for now).
                    .char => |c| {
                        if (c == 'q' or c == 'Q') {
                            running = false; // clean exit via defer deinit
                            break; // leave the key switch
                        }
                        counter += 1;
                        // Format into last_key_buf; last_key borrows that buffer.
                        last_key = try std.fmt.bufPrint(&last_key_buf, "char '{c}'", .{@as(u8, @intCast(c))});
                    },
                    .enter => {
                        counter += 1;
                        last_key = "Enter"; // static string — no buffer needed
                    },
                    .esc => {
                        counter += 1;
                        last_key = "Esc";
                    },
                    .backspace => {
                        counter += 1;
                        last_key = "Backspace";
                    },
                    .tab => {
                        counter += 1;
                        last_key = "Tab";
                    },
                    .up => {
                        counter += 1;
                        last_key = "Up";
                    },
                    .down => {
                        counter += 1;
                        last_key = "Down";
                    },
                    .left => {
                        counter += 1;
                        last_key = "Left";
                    },
                    .right => {
                        counter += 1;
                        last_key = "Right";
                    },
                    // ISIG is off → Ctrl-C arrives as a byte, handled here (not as SIGINT).
                    .ctrl_c => {
                        running = false;
                        break;
                    },
                    .unknown => {
                        counter += 1;
                        last_key = "unknown";
                    },
                }
                // Redraw + present. Only cells that changed (counter, last key, …)
                // actually hit the wire — that is what avoids flicker.
                try draw(&scr, size, counter, last_key);
                try scr.present(&term);
            },
        }
    }
    // falling out of main → defers run → terminal restored
}

/// Rebuild the entire front buffer from current app state.
/// Cheap enough at this scale; the *diff* in present() is what stays fast on the wire.
fn draw(scr: *tui.Screen, size: tui.Size, counter: u64, last_key: []const u8) !void {
    // --- styles (indexed colors 0–15 = classic ANSI / bright) ---
    const bg = tui.Style{
        .fg = .{ .indexed = 7 }, // light gray text
        .bg = .{ .indexed = 0 }, // black background
    };
    const title_style = tui.Style{
        .fg = .{ .indexed = 15 }, // bright white
        .bg = .{ .indexed = 4 }, // blue bar
        .bold = true,
    };
    const accent = tui.Style{
        .fg = .{ .indexed = 10 }, // bright green
        .bg = .{ .indexed = 0 },
        .bold = true,
    };
    const dim = tui.Style{
        .fg = .{ .indexed = 8 }, // bright black ≈ gray
        .bg = .{ .indexed = 0 },
        .dim = true, // SGR 2
    };
    const footer_style = tui.Style{
        .fg = .{ .indexed = 0 }, // black text
        .bg = .{ .indexed = 7 }, // light gray bar
    };

    // Paint every cell with the default body style first.
    scr.clearStyle(bg);

    // Title row (y = 0): full-width bar, then text on top.
    fillRow(scr, 0, title_style);
    scr.putStr(2, 0, "rv tui demo", title_style); // x=2 indent

    // Scratch buffer for formatted lines (reused — each bufPrint overwrites it).
    var line_buf: [128]u8 = undefined;

    // Guard every putStr with a row check so tiny terminals don't panic us.
    const l1 = try std.fmt.bufPrint(&line_buf, "terminal size: {d} x {d}", .{ size.cols, size.rows });
    if (2 < size.rows) scr.putStr(2, 2, l1, bg);

    const l2 = try std.fmt.bufPrint(&line_buf, "key events:   {d}", .{counter});
    if (3 < size.rows) scr.putStr(2, 3, l2, accent);

    const l3 = try std.fmt.bufPrint(&line_buf, "last key:     {s}", .{last_key});
    if (4 < size.rows) scr.putStr(2, 4, l3, bg);

    // Help text (only if the window is tall enough).
    if (6 < size.rows) {
        scr.putStr(2, 6, "Press any key to increment the counter.", dim);
        scr.putStr(2, 7, "Resize the terminal — size updates without flicker.", dim);
        scr.putStr(2, 8, "Press q (or Ctrl-C) to quit and restore the terminal.", dim);
    }

    // Footer on the last row.
    if (size.rows > 0) {
        const fy: u16 = size.rows - 1; // bottom row index
        fillRow(scr, fy, footer_style);
        scr.putStr(2, fy, "q quit  |  arrows / keys update counter  |  resize ok", footer_style);
    }

    // We don't need a caret for this demo.
    scr.hideCursor();
}

/// Fill one entire row with spaces of the given style (a solid bar).
fn fillRow(scr: *tui.Screen, y: u16, style: tui.Style) void {
    var x: u16 = 0;
    while (x < scr.cols) : (x += 1) {
        // Explicit cell write — same as putStr of spaces, but clear intent.
        scr.setCell(x, y, .{ .char = ' ', .width = 1, .style = style });
    }
}
