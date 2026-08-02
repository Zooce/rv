//! `rv` entry point — full-screen read-only diff review (MVP-0.4).
//!
//! Load smart-default git diff → flatten rows → immediate-mode TUI:
//! highlight current line, `j`/`k` move, `[`/`]` hunks, footer, `q` quit.
//! Failures and empty diffs print a message and exit without entering the TUI
//! (so the terminal is never left in raw / alt-screen mode).

const std = @import("std");
const git = @import("git");
const tui = @import("tui");
const view = @import("view");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Load before any TTY setup so error/empty paths never touch the terminal.
    var d = git.loadDefaultDiff(alloc, io) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NotARepository => "not a git repository (run from a work tree)",
            error.GitNotFound => "git executable not found in PATH",
            error.GitFailed => "git command failed",
            error.OutOfMemory => "out of memory",
            error.BadHunkHeader => "failed to parse unified diff (bad hunk header)",
        };
        std.debug.print("rv: {s}\n", .{msg});
        std.process.exit(1);
    };
    defer d.deinit();

    if (d.files.len == 0) {
        // Smart default found nothing: clean worktree and nothing ahead of base.
        std.debug.print("rv: no changes to review\n", .{});
        return;
    }

    const rows = try view.flatten(alloc, &d);
    defer alloc.free(rows);

    var term = try tui.Tty.open();
    defer term.deinit();

    var size = try term.getSize();
    var scr = try tui.Screen.init(alloc, size);
    defer scr.deinit();

    var cursor: usize = 0;
    var scroll: usize = 0;
    var running = true;

    paint(&scr, size, rows, cursor, &scroll);
    try scr.present(&term);

    while (running) {
        const ev = try tui.event.next(&term);
        switch (ev) {
            .quit => running = false,
            .resize => |new_size| {
                size = new_size;
                try scr.resize(size);
                paint(&scr, size, rows, cursor, &scroll);
                try scr.present(&term);
            },
            .key => |key| {
                switch (key) {
                    .char => |c| {
                        if (c == 'q' or c == 'Q') {
                            running = false;
                            break;
                        }
                        if (c == 'j') {
                            if (cursor + 1 < rows.len) cursor += 1;
                        } else if (c == 'k') {
                            if (cursor > 0) cursor -= 1;
                        } else if (c == ']') {
                            cursor = view.nextHunk(rows, cursor);
                        } else if (c == '[') {
                            cursor = view.prevHunk(rows, cursor);
                        }
                    },
                    .down => {
                        if (cursor + 1 < rows.len) cursor += 1;
                    },
                    .up => {
                        if (cursor > 0) cursor -= 1;
                    },
                    .ctrl_c => {
                        running = false;
                        break;
                    },
                    else => {},
                }
                paint(&scr, size, rows, cursor, &scroll);
                try scr.present(&term);
            },
        }
    }
}

/// Rebuild front buffer from rows + cursor; update `scroll` to keep cursor visible.
/// Layout: title (row 0) | content | footer (last row when height ≥ 2).
fn paint(
    scr: *tui.Screen,
    size: tui.Size,
    rows: []const view.Row,
    cursor: usize,
    scroll: *usize,
) void {
    // Forced dark palette (truecolor) so a light terminal theme cannot wash
    // out the review surface via ANSI index remapping.
    const bg = tui.Color{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } };
    const fg = tui.Color{ .rgb = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 } };
    const body = tui.Style{ .fg = fg, .bg = bg };
    const title_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
        .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x3f, .b = 0x5f } },
        .bold = true,
    };
    const footer_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
        .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x3f, .b = 0x5f } },
    };
    const file_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .bg = bg,
        .bold = true,
    };
    const hunk_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x6a, .g = 0xb8, .b = 0xc8 } },
        .bg = bg,
        .dim = true,
    };
    const add_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x6a, .g = 0xc4, .b = 0x6a } },
        .bg = bg,
    };
    const del_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xe0, .g = 0x6c, .b = 0x75 } },
        .bg = bg,
    };
    const meta_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x80, .g = 0x80, .b = 0x80 } },
        .bg = bg,
        .dim = true,
    };
    const cur_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } },
        .bg = .{ .rgb = .{ .r = 0xc8, .g = 0xc8, .b = 0xc8 } },
        .bold = true,
    };

    scr.clearStyle(body);

    // Title row.
    if (size.rows > 0) {
        fillRow(scr, 0, title_style);
        scr.putStr(1, 0, "rv  j/k move  [/] hunk  q quit", title_style);
    }

    // Footer on the last row when there is room (title + footer + optional body).
    const has_footer = size.rows >= 2;
    const footer_y: u16 = if (has_footer) size.rows - 1 else 0;
    const content_top: u16 = 1;
    const content_bottom: u16 = if (has_footer) footer_y else size.rows;
    const content_rows: usize = if (content_bottom > content_top)
        content_bottom - content_top
    else
        0;

    const cur = view.clampCursor(cursor, rows.len);
    scroll.* = view.ensureVisible(scroll.*, cur, content_rows, rows.len);

    var line_buf: [512]u8 = undefined;
    var screen_y: u16 = content_top;
    var i: usize = scroll.*;
    while (i < rows.len and screen_y < content_bottom) : (i += 1) {
        const is_cur = i == cur;
        const text = formatRow(&line_buf, rows[i]);
        const base = baseStyle(rows[i], body, file_style, hunk_style, add_style, del_style, meta_style);
        const st = if (is_cur) cur_style else base;
        fillRow(scr, screen_y, st);
        scr.putStr(0, screen_y, text, st);
        screen_y += 1;
    }

    if (has_footer) {
        fillRow(scr, footer_y, footer_style);
        const st = view.statusAt(rows, cur);
        const footer_text = formatFooter(&line_buf, st);
        scr.putStr(1, footer_y, footer_text, footer_style);
    }

    scr.hideCursor();
}

/// `path  hunk i/n  row i/n` (omits hunk segment when there are no hunks).
fn formatFooter(buf: []u8, st: view.Status) []const u8 {
    if (st.row_n == 0) return "no changes";
    if (st.hunk_n == 0) {
        return bufPrintTrunc(buf, "{s}  {d}/{d}", .{
            if (st.path.len > 0) st.path else "?",
            st.row_i,
            st.row_n,
        });
    }
    return bufPrintTrunc(buf, "{s}  hunk {d}/{d}  {d}/{d}", .{
        if (st.path.len > 0) st.path else "?",
        st.hunk_i,
        st.hunk_n,
        st.row_i,
        st.row_n,
    });
}

fn baseStyle(
    row: view.Row,
    body: tui.Style,
    file_style: tui.Style,
    hunk_style: tui.Style,
    add_style: tui.Style,
    del_style: tui.Style,
    meta_style: tui.Style,
) tui.Style {
    return switch (row) {
        .file_header => file_style,
        .hunk_header => hunk_style,
        .line => |ln| switch (ln.kind) {
            .add => add_style,
            .delete => del_style,
            .meta => meta_style,
            .context => body,
        },
    };
}

/// Format one row into `buf`. Oversized content is truncated (never errors).
fn formatRow(buf: []u8, row: view.Row) []const u8 {
    return switch (row) {
        .file_header => |fh| if (fh.is_binary)
            bufPrintTrunc(buf, " {s}  (binary)", .{fh.path})
        else
            bufPrintTrunc(buf, " {s}", .{fh.path}),
        .hunk_header => |hh| blk: {
            const oc = hh.old_count orelse 1;
            const nc = hh.new_count orelse 1;
            if (hh.section.len > 0) {
                break :blk bufPrintTrunc(buf, " @@ -{d},{d} +{d},{d} @@ {s}", .{
                    hh.old_start, oc, hh.new_start, nc, hh.section,
                });
            }
            break :blk bufPrintTrunc(buf, " @@ -{d},{d} +{d},{d} @@", .{
                hh.old_start, oc, hh.new_start, nc,
            });
        },
        .line => |ln| blk: {
            if (buf.len == 0) break :blk buf[0..0];
            const marker: u8 = switch (ln.kind) {
                .context => ' ',
                .add => '+',
                .delete => '-',
                .meta => '\\',
            };
            buf[0] = marker;
            const n = @min(ln.text.len, buf.len - 1);
            @memcpy(buf[1..][0..n], ln.text[0..n]);
            break :blk buf[0 .. n + 1];
        },
    };
}

fn bufPrintTrunc(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch {
        const msg = "...";
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        return buf[0..n];
    };
}

fn fillRow(scr: *tui.Screen, y: u16, style: tui.Style) void {
    var x: u16 = 0;
    while (x < scr.cols) : (x += 1) {
        scr.setCell(x, y, .{ .char = ' ', .width = 1, .style = style });
    }
}
