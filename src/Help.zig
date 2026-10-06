//! `?` overlay: grouped key catalog, scroll, keys, and paint.

const Help = @This();

const std = @import("std");
const tui = @import("tui");

pub const Result = enum { open, closed, quit };

const Entry = union(enum) {
    group: []const u8,
    item: struct { key: []const u8, label: []const u8 },
    blank,
};

const entries = [_]Entry{
    .{ .group = "Motion" },
    .{ .item = .{ .key = "j/k", .label = "line (also arrows)" } },
    .{ .item = .{ .key = "h/l", .label = "pan current hunk" } },
    .{ .item = .{ .key = "wheel", .label = "scroll the window; shift or sideways pans the hunk under the pointer" } },
    .{ .item = .{ .key = "0/$", .label = "pan home / end" } },
    .{ .item = .{ .key = "J/K", .label = "next / prev change" } },
    .{ .item = .{ .key = "[/]", .label = "hunk header" } },
    .{ .item = .{ .key = "{/}", .label = "file header" } },
    .{ .item = .{ .key = "(/)", .label = "prev / next comment (unapproves if needed)" } },
    .blank,
    .{ .group = "Search" },
    .{ .item = .{ .key = "/", .label = "text in the diff" } },
    .{ .item = .{ .key = "n/N", .label = "next / prev match" } },
    .{ .item = .{ .key = "Space f", .label = "file list" } },
    .{ .item = .{ .key = "Space c", .label = "comment list" } },
    .{ .item = .{ .key = "Space a", .label = "approved list" } },
    .blank,
    .{ .group = "Comments" },
    .{ .item = .{ .key = "i/c/Enter", .label = "create / edit new" } },
    .{ .item = .{ .key = "I/C", .label = "create / edit old" } },
    .{ .item = .{ .key = "d/D", .label = "dismiss new / old" } },
    .blank,
    .{ .group = "Local review" },
    .{ .item = .{ .key = "sections", .label = "Unstaged, Untracked, Staged" } },
    .{ .item = .{ .key = "gs/gu/gd", .label = "stage / unstage / discard hunk" } },
    .{ .item = .{ .key = "gS/gU/gD", .label = "stage / unstage / discard file" } },
    .{ .item = .{ .key = "a/A", .label = "approve hunk / file (stages, then hides)" } },
    .blank,
    .{ .group = "Session" },
    .{ .item = .{ .key = "t", .label = "layout" } },
    .{ .item = .{ .key = "#", .label = "line numbers" } },
    .{ .item = .{ .key = "w", .label = "wrap" } },
    .{ .item = .{ .key = "e", .label = "expand hunk context" } },
    .{ .item = .{ .key = "r", .label = "reload" } },
    .{ .item = .{ .key = "?", .label = "this help" } },
    .{ .item = .{ .key = "q", .label = "quit" } },
    .blank,
    .{ .group = "In a prompt" },
    .{ .item = .{ .key = "comment", .label = "Enter save · Esc cancel · arrows move" } },
    .{ .item = .{ .key = "search", .label = "Enter jump · Esc cancel" } },
    .{ .item = .{ .key = "list", .label = "j/k move · Enter jump · Esc close" } },
    .{ .item = .{ .key = "approved", .label = "Enter unapprove (does not unstage) · jump · Esc close" } },
    .{ .item = .{ .key = "discard", .label = "No/yes · comments no/Yes · Esc cancel" } },
    .{ .item = .{ .key = "approve", .label = "No/yes · Esc cancel" } },
};

const key_w: u16 = blk: {
    var w: u16 = 0;
    for (entries) |entry| {
        switch (entry) {
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
    const group_style = tui.Style{ .fg = tui.Panel.body.fg, .bg = tui.Panel.body.bg, .bold = true };

    const panel = tui.Panel.overlay(size.cols, size.rows, entries.len);
    panel.paint(scr, " help ");
    const inner = panel.inner;
    if (inner.h == 0 or inner.w == 0) return;
    const view_h: usize = inner.h;
    const max_scroll = if (entries.len > view_h) entries.len - view_h else 0;
    if (self.scroll > max_scroll) self.scroll = max_scroll;
    const text_area = panel.text(entries.len);
    const start = self.scroll;
    var row: u16 = 0;
    while (row < inner.h) : (row += 1) {
        const idx = start + row;
        if (idx >= entries.len) break;
        const y = inner.y + row;
        switch (entries[idx]) {
            .blank => {},
            .group => |name| scr.putStr(inner.x, y, name, group_style, 0, text_area),
            .item => |it| {
                scr.putStr(inner.x + 2, y, it.key, tui.Panel.body, 0, text_area);
                const label_x = inner.x +| 2 +| key_w +| 2;
                scr.putStr(label_x, y, it.label, tui.Panel.body, 0, text_area);
            },
        }
    }
    panel.paintBar(scr, entries.len, start);
}

test "help catalog includes normal bindings" {
    const required = [_][]const u8{
        "j/k",     "h/l",     "0/$", "J/K", "[/]", "{/}", "(/)", "/", "n/N",
        "Space f", "Space c", "Space a", "gs", "gS", "a", "A", "i", "I", "d", "D",
        "t",       "#",       "w",           "e", "r", "?", "q", "approved", "approve",
    };
    for (required) |token| {
        var found = false;
        for (entries) |entry| {
            const key = switch (entry) {
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
