//! `rv` entry point — full-screen read-only diff review (MVP-0.3).
//!
//! Load smart-default git diff → flatten rows → immediate-mode TUI:
//! highlight current line, `j`/`k` move, viewport follows, resize, `q` quit.

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

    var d = git.loadDefaultDiff(alloc, io) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NotARepository => "not a git repository",
            error.GitNotFound => "git executable not found",
            error.GitFailed => "git command failed",
            error.OutOfMemory => "out of memory",
            error.BadHunkHeader => "failed to parse unified diff (bad hunk header)",
        };
        std.debug.print("rv: {s}\n", .{msg});
        std.process.exit(1);
    };
    defer d.deinit();

    if (d.files.len == 0) {
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
fn paint(
    scr: *tui.Screen,
    size: tui.Size,
    rows: []const view.Row,
    cursor: usize,
    scroll: *usize,
) void {
    const body = tui.Style{
        .fg = .{ .indexed = 7 },
        .bg = .{ .indexed = 0 },
    };
    const title_style = tui.Style{
        .fg = .{ .indexed = 15 },
        .bg = .{ .indexed = 4 },
        .bold = true,
    };
    const file_style = tui.Style{
        .fg = .{ .indexed = 15 },
        .bg = .{ .indexed = 0 },
        .bold = true,
    };
    const hunk_style = tui.Style{
        .fg = .{ .indexed = 6 },
        .bg = .{ .indexed = 0 },
        .dim = true,
    };
    const add_style = tui.Style{
        .fg = .{ .indexed = 10 },
        .bg = .{ .indexed = 0 },
    };
    const del_style = tui.Style{
        .fg = .{ .indexed = 9 },
        .bg = .{ .indexed = 0 },
    };
    const meta_style = tui.Style{
        .fg = .{ .indexed = 8 },
        .bg = .{ .indexed = 0 },
        .dim = true,
    };
    const cur_style = tui.Style{
        .fg = .{ .indexed = 0 },
        .bg = .{ .indexed = 7 },
        .bold = true,
    };

    scr.clearStyle(body);

    // Title row.
    if (size.rows > 0) {
        fillRow(scr, 0, title_style);
        scr.putStr(1, 0, "rv  j/k move  q quit", title_style);
    }

    // Content area is everything below the title.
    const content_rows: usize = if (size.rows > 1) size.rows - 1 else 0;
    const cur = view.clampCursor(cursor, rows.len);
    scroll.* = view.ensureVisible(scroll.*, cur, content_rows, rows.len);

    var line_buf: [512]u8 = undefined;
    var screen_y: u16 = 1;
    var i: usize = scroll.*;
    while (i < rows.len and screen_y < size.rows) : (i += 1) {
        const is_cur = i == cur;
        const text = formatRow(&line_buf, rows[i]);
        const base = baseStyle(rows[i], body, file_style, hunk_style, add_style, del_style, meta_style);
        const st = if (is_cur) cur_style else base;
        fillRow(scr, screen_y, st);
        scr.putStr(0, screen_y, text, st);
        screen_y += 1;
    }

    scr.hideCursor();
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
