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
//! Floating panels are the same buffer: paint the background, then fill + box
//! + clipped text on top. `o` toggles them.

const std = @import("std");
const tui = @import("tui"); // our module (see tui/root.zig)

pub fn main() !void {
    // DebugAllocator tracks leaks in Debug builds (Zig 0.16 name for the old GPA).
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit(); // returns .leak if something was not freed
    const alloc = gpa_state.allocator(); // the Allocator interface we pass to Screen

    // open(): /dev/tty + raw termios + alt screen + signal handlers.
    // defer deinit(): always restore the shell, even if we return via error.
    var term = try tui.Tty.open();
    defer term.deinit();

    // Ask the kernel how big the window is right now.
    var size = try term.getSize();
    // Allocate front/back cell grids matching that size.
    var scr = try tui.Screen.init(alloc, size);
    defer scr.deinit();

    // --- app state (immediate-mode: screen is rebuilt from this each time) ---
    var counter: u64 = 0; // how many keys we've seen
    var last_key: []const u8 = "(none)"; // label shown in the UI
    var last_key_buf: [64]u8 = undefined; // storage for formatted "char 'x'" labels
    var show_panels = true; // floating overlays on top of the background
    var running = true; // main loop flag

    // First paint: dirty_all is true, so present writes every cell once.
    try draw(&scr, size, counter, last_key, show_panels); // fill front buffer from state
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
                try draw(&scr, size, counter, last_key, show_panels); // rebuild front
                try scr.present(&term); // full repaint on new geometry
            },

            // A decoded keypress.
            .key => |key| {
                switch (key) {
                    // Printable character (ASCII for now).
                    .char => |c| {
                        if (c == 'q' or c == 'Q') {
                            running = false; // clean exit via defer deinit
                            break; // leave the event loop
                        }
                        if (c == 'o' or c == 'O') {
                            show_panels = !show_panels;
                            last_key = if (show_panels) "overlay on" else "overlay off";
                        } else {
                            counter += 1;
                            // Format into last_key_buf; last_key borrows that buffer.
                            last_key = try std.fmt.bufPrint(&last_key_buf, "char '{u}'", .{c});
                        }
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
                try draw(&scr, size, counter, last_key, show_panels);
                try scr.present(&term);
            },
        }
    }
    // falling out of main → defers run → terminal restored
}

/// Rebuild the entire front buffer from current app state.
/// Cheap enough at this scale; the *diff* in present() is what stays fast on the wire.
fn draw(scr: *tui.Screen, size: tui.Size, counter: u64, last_key: []const u8, show_panels: bool) !void {
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
    const help = tui.Style{
        .fg = .{ .indexed = 7 }, // same light gray as body — dim+index-8 vanishes on black
        .bg = .{ .indexed = 0 },
    };
    const footer_style = tui.Style{
        .fg = .{ .indexed = 0 }, // black text
        .bg = .{ .indexed = 7 }, // light gray bar
    };

    // Paint every cell with the default body style first.
    scr.clearStyle(bg);

    // Title row (y = 0): full-width bar, then text on top.
    scr.fillRect(.{ .x = 0, .y = 0, .w = size.cols, .h = 1 }, ' ', title_style);
    scr.putStr(2, 0, "rv tui demo", title_style, null); // x=2 indent

    // Scratch buffer for formatted lines (reused — each bufPrint overwrites it).
    var line_buf: [128]u8 = undefined;

    // Guard every putStr with a row check so tiny terminals don't panic us.
    const l1 = try std.fmt.bufPrint(&line_buf, "terminal size: {d} x {d}", .{ size.cols, size.rows });
    if (2 < size.rows) scr.putStr(2, 2, l1, bg, null);

    const l2 = try std.fmt.bufPrint(&line_buf, "key events:   {d}", .{counter});
    if (3 < size.rows) scr.putStr(2, 3, l2, accent, null);

    const l3 = try std.fmt.bufPrint(&line_buf, "last key:     {s}", .{last_key});
    if (4 < size.rows) scr.putStr(2, 4, l3, bg, null);

    // Help text (only if the window is tall enough).
    if (6 < size.rows) {
        scr.putStr(2, 6, "Press any key to increment the counter.", help, null);
        scr.putStr(2, 7, "Press o to toggle floating panels (fill + box + clip).", help, null);
        scr.putStr(2, 8, "Resize the terminal — size updates without flicker.", help, null);
        scr.putStr(2, 9, "Press q (or Ctrl-C) to quit and restore the terminal.", help, null);
    }

    // Footer on the last row.
    if (size.rows > 0) {
        const fy: u16 = size.rows - 1; // bottom row index
        scr.fillRect(.{ .x = 0, .y = fy, .w = size.cols, .h = 1 }, ' ', footer_style);
        scr.putStr(2, fy, "q quit  |  o overlay  |  keys update counter  |  resize ok", footer_style, null);
    }

    if (show_panels) {
        const panel = tui.Rect.centered(size.cols, size.rows, @min(size.cols, 44), @min(size.rows, 9));
        const panel_bg = tui.Style{ .fg = .{ .indexed = 15 }, .bg = .{ .indexed = 6 } };
        const panel_frame = tui.Style{ .fg = .{ .indexed = 15 }, .bg = .{ .indexed = 6 }, .bold = true };
        const panel_dim = tui.Style{ .fg = .{ .indexed = 0 }, .bg = .{ .indexed = 6 } };
        scr.fillRect(panel, ' ', panel_bg);
        scr.drawBox(panel, panel_frame);
        const inner = panel.inset(1);
        scr.putStr(inner.x, inner.y, " centered panel ", panel_frame, inner);
        const s1 = try std.fmt.bufPrint(&line_buf, " size {d}x{d}  keys {d}", .{ size.cols, size.rows, counter });
        if (1 < inner.h) scr.putStr(inner.x, inner.y + 1, s1, panel_bg, inner);
        const s2 = try std.fmt.bufPrint(&line_buf, " last: {s}", .{last_key});
        if (2 < inner.h) scr.putStr(inner.x, inner.y + 2, s2, panel_bg, inner);
        if (3 < inner.h) scr.putStr(inner.x, inner.y + 3, " long line clipped at the panel edge -----------", panel_dim, inner);
        if (5 < inner.h) scr.putStr(inner.x, inner.y + 5, " o toggles overlays   q quits", panel_dim, inner);

        // Second panel starts at the first panel's center so they overlap.
        const note_w: u16 = @min(size.cols, 26);
        const note_h: u16 = @min(size.rows, 6);
        const note = tui.Rect{
            .x = @min(panel.x +| panel.w / 2, size.cols -| note_w),
            .y = @min(panel.y +| panel.h / 2 +| 2, size.rows -| note_h),
            .w = note_w,
            .h = note_h,
        };
        const note_bg = tui.Style{ .fg = .{ .indexed = 15 }, .bg = .{ .indexed = 5 } };
        const note_frame = tui.Style{ .fg = .{ .indexed = 15 }, .bg = .{ .indexed = 5 }, .bold = true };
        const note_dim = tui.Style{ .fg = .{ .indexed = 7 }, .bg = .{ .indexed = 5 } };
        scr.fillRect(note, ' ', note_bg);
        scr.drawBox(note, note_frame);
        const ninner = note.inset(1);
        scr.putStr(ninner.x, ninner.y, " second panel ", note_frame, ninner);
        if (1 < ninner.h) scr.putStr(ninner.x, ninner.y + 1, " painted last", note_bg, ninner);
        if (2 < ninner.h) scr.putStr(ninner.x, ninner.y + 2, " covers the first", note_dim, ninner);
    }

    // We don't need a caret for this demo.
    scr.hideCursor();
}
