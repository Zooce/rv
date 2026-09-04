//! `?` overlay: grouped key catalog, scroll, keys, and paint.

const Help = @This();

const std = @import("std");
const tui = @import("tui");
const comment_input = @import("comment_input");

pub const Result = enum { open, closed, quit };

const Row = union(enum) {
    group: []const u8,
    item: struct { key: []const u8, label: []const u8 },
    blank,
};

const rows = [_]Row{
    .{ .group = "Motion" },
    .{ .item = .{ .key = "j/k", .label = "line (also arrows)" } },
    .{ .item = .{ .key = "h/l", .label = "pan current hunk" } },
    .{ .item = .{ .key = "0/$", .label = "pan home / end" } },
    .{ .item = .{ .key = "J/K", .label = "next / prev change" } },
    .{ .item = .{ .key = "[/]", .label = "hunk header" } },
    .{ .item = .{ .key = "{/}", .label = "file header" } },
    .{ .item = .{ .key = "(/)", .label = "prev / next comment" } },
    .blank,
    .{ .group = "Search" },
    .{ .item = .{ .key = "/", .label = "text in the diff" } },
    .{ .item = .{ .key = "n/N", .label = "next / prev match" } },
    .{ .item = .{ .key = "Space f", .label = "file list" } },
    .{ .item = .{ .key = "Space l", .label = "comment list" } },
    .blank,
    .{ .group = "Comments" },
    .{ .item = .{ .key = "i/c/a/Enter", .label = "create / edit new" } },
    .{ .item = .{ .key = "I/C/A", .label = "create / edit old" } },
    .{ .item = .{ .key = "d/D", .label = "dismiss new / old" } },
    .blank,
    .{ .group = "Local review" },
    .{ .item = .{ .key = "sections", .label = "Unstaged, Untracked, Staged" } },
    .{ .item = .{ .key = "Space Space", .label = "stage / unstage file, hunk, or group" } },
    .{ .item = .{ .key = "Space S", .label = "file from hunk (until Ctrl)" } },
    .{ .item = .{ .key = "Space d", .label = "discard file or hunk" } },
    .{ .item = .{ .key = "Space x", .label = "discard file from hunk (until Ctrl)" } },
    .blank,
    .{ .group = "Session" },
    .{ .item = .{ .key = "t", .label = "layout" } },
    .{ .item = .{ .key = "#", .label = "line numbers" } },
    .{ .item = .{ .key = "r", .label = "reload" } },
    .{ .item = .{ .key = "?", .label = "this help" } },
    .{ .item = .{ .key = "q", .label = "quit" } },
    .blank,
    .{ .group = "In a prompt" },
    .{ .item = .{ .key = "comment", .label = "Enter save · Esc cancel · arrows move" } },
    .{ .item = .{ .key = "search", .label = "Enter jump · Esc cancel" } },
    .{ .item = .{ .key = "list", .label = "j/k move · Enter jump · Esc close" } },
    .{ .item = .{ .key = "discard", .label = "No/yes · comments no/Yes · Esc cancel" } },
};

const key_w: u16 = blk: {
    var w: u16 = 0;
    for (rows) |row| {
        switch (row) {
            .item => |it| {
                const n: u16 = @intCast(it.key.len);
                if (n > w) w = n;
            },
            else => {},
        }
    }
    break :blk w;
};

scroll: usize = 0,

pub fn handleKey(self: *Help, key: tui.Key) Result {
    switch (key) {
        .esc => return .closed,
        .char => |c| {
            if (c == 'q' or c == 'Q') return .quit;
            if (c == '?') return .closed;
            if (c == 'j') {
                self.scroll += 1;
            } else if (c == 'k') {
                self.scroll -|= 1;
            }
        },
        .down => self.scroll += 1,
        .up => self.scroll -|= 1,
        .ctrl_c => return .quit,
        else => {},
    }
    return .open;
}

pub fn paint(self: *Help, scr: *tui.Screen, size: tui.Size) void {
    const bg = tui.Color{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } };
    const fg = tui.Color{ .rgb = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 } };
    const panel_bg = tui.Style{ .fg = fg, .bg = bg };
    const panel_frame = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x5d, .g = 0x81, .b = 0xb7 } },
        .bg = bg,
        .bold = true,
    };
    const group_style = tui.Style{ .fg = fg, .bg = bg, .bold = true };
    const bar_track = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x6a, .g = 0x7a, .b = 0x9a } },
        .bg = bg,
        .dim = true,
    };
    const bar_thumb = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
        .bg = .{ .rgb = .{ .r = 0x4a, .g = 0x6a, .b = 0x9a } },
        .bold = true,
    };

    const panel = overlayRect(size.cols, size.rows, rows.len);
    scr.fillRect(panel, ' ', panel_bg);
    scr.drawBox(panel, panel_frame);
    if (panel.h > 0 and panel.w > 2) {
        scr.putStr(panel.x + 2, panel.y, " help ", panel_frame, panel);
    }
    const inner = panel.inset(1);
    if (inner.h == 0 or inner.w == 0) return;
    const view_h: usize = inner.h;
    const max_scroll = if (rows.len > view_h) rows.len - view_h else 0;
    if (self.scroll > max_scroll) self.scroll = max_scroll;
    const show_bar = rows.len > inner.h;
    const text_area = if (show_bar)
        tui.Rect{ .x = inner.x, .y = inner.y, .w = inner.w -| 2, .h = inner.h }
    else
        inner;
    const start = self.scroll;
    var row: u16 = 0;
    while (row < inner.h) : (row += 1) {
        const idx = start + row;
        if (idx >= rows.len) break;
        const y = inner.y + row;
        switch (rows[idx]) {
            .blank => {},
            .group => |name| scr.putStr(inner.x, y, name, group_style, text_area),
            .item => |it| {
                scr.putStr(inner.x + 2, y, it.key, panel_bg, text_area);
                const label_x = inner.x +| 2 +| key_w +| 2;
                scr.putStr(label_x, y, it.label, panel_bg, text_area);
            },
        }
    }
    if (show_bar) {
        const bar_x: u16 = inner.x + inner.w - 1;
        const thumb = comment_input.scrollbarThumb(rows.len, inner.h, start, inner.h);
        var br: u16 = 0;
        while (br < inner.h) : (br += 1) {
            const in_thumb = br >= thumb.start and br < thumb.start + thumb.len;
            const st = if (in_thumb) bar_thumb else bar_track;
            const ch: u21 = if (in_thumb) '█' else '│';
            scr.setCell(bar_x, inner.y + br, .{ .char = ch, .width = 1, .style = st });
        }
    }
}

/// Centered overlay. Width up to 120; height grows with rows, clamped to
/// 25–70% of the terminal. Always leaves at least 2 cells on every side.
fn overlayRect(cols: u16, rows_n: u16, n: usize) tui.Rect {
    const n16: u16 = std.math.cast(u16, n) orelse std.math.maxInt(u16);
    const max_w: u16 = 120;
    const avail_h: u16 = rows_n -| 4;
    const rows_u32: u32 = rows_n;
    const min_pct: u16 = @intCast(rows_u32 / 4);
    const max_pct: u16 = @intCast(rows_u32 * 7 / 10);
    const min_h: u16 = @min(avail_h, @max(3, min_pct));
    const max_h: u16 = @min(avail_h, @max(min_h, max_pct));
    const want_w: u16 = @min(cols -| 4, max_w);
    const content_h: u16 = @max(3, n16 +| 2);
    const want_h: u16 = @min(max_h, @max(min_h, content_h));
    return tui.Rect.centered(cols, rows_n, want_w, want_h);
}

test "help catalog includes normal bindings" {
    const required = [_][]const u8{
        "j/k",     "h/l",     "0/$", "J/K", "[/]", "{/}", "(/)", "/", "n/N",
        "Space f", "Space l", "Space Space", "Space S", "Space d", "Space x", "i", "I", "d", "D",
        "t",       "#",       "r",           "?", "q",
    };
    for (required) |token| {
        var found = false;
        for (rows) |row| {
            const key = switch (row) {
                .item => |it| it.key,
                else => continue,
            };
            if (std.mem.eql(u8, key, token)) {
                found = true;
                break;
            }
            var parts = std.mem.splitScalar(u8, key, '/');
            while (parts.next()) |part| {
                if (part.len > 0 and std.mem.eql(u8, part, token)) {
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        try std.testing.expect(found);
    }
}
