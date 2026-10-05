//! Overlay panel: centered rect, fill, box, title, optional scrollbar.
//! Drawing only — not a widget or a key handler.

const std = @import("std");
const screen = @import("screen.zig");

const Color = screen.Color;
const Rect = screen.Rect;
const Screen = screen.Screen;
const Style = screen.Style;

const bg: Color = .{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } };
const fg: Color = .{ .rgb = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 } };

/// Vertical scrollbar thumb in a track of `track` rows.
/// Returns half-open `[start, start+len)` of track rows for the thumb.
pub fn scrollbarThumb(total: usize, visible: usize, scroll: usize, track: usize) struct { start: usize, len: usize } {
    if (track == 0 or total <= visible) return .{ .start = 0, .len = 0 };

    var thumb_len = (visible * track) / total;
    if (thumb_len == 0) thumb_len = 1;
    if (thumb_len > track) thumb_len = track;

    const max_s = total - visible;
    const s = @min(scroll, max_s);
    const travel = track - thumb_len;
    const start = if (max_s == 0) 0 else (s * travel) / max_s;
    return .{ .start = start, .len = thumb_len };
}

/// Centered overlay. Width up to 120; height grows with `n` content rows,
/// clamped to 25–70% of the terminal. Always leaves at least 2 cells on
/// every side.
pub const Panel = struct {
    rect: Rect,
    inner: Rect,

    pub const body = Style{ .fg = fg, .bg = bg };
    pub const frame = Style{
        .fg = .{ .rgb = .{ .r = 0x5d, .g = 0x81, .b = 0xb7 } },
        .bg = bg,
        .bold = true,
    };
    pub const row_cur = Style{
        .fg = fg,
        .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x30 } },
        .bold = true,
    };
    pub const bar_track = Style{
        .fg = .{ .rgb = .{ .r = 0x6a, .g = 0x7a, .b = 0x9a } },
        .bg = bg,
        .dim = true,
    };
    pub const bar_thumb = Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
        .bg = .{ .rgb = .{ .r = 0x4a, .g = 0x6a, .b = 0x9a } },
        .bold = true,
    };

    pub fn overlay(cols: u16, rows: u16, n: usize) Panel {
        return fromRect(overlayRect(cols, rows, n));
    }

    pub fn fromRect(rect: Rect) Panel {
        return .{ .rect = rect, .inner = rect.inset(1) };
    }

    /// Fill, box, and title in the frame.
    pub fn paint(self: Panel, scr: *Screen, title: []const u8) void {
        scr.fillRect(self.rect, ' ', body);
        scr.drawBox(self.rect, frame);
        if (self.rect.h > 0 and self.rect.w > 2) {
            scr.putStr(self.rect.x + 2, self.rect.y, title, frame, 0, self.rect);
        }
    }

    /// Clip rect for content: inner, minus two columns when a bar will show.
    pub fn text(self: Panel, total: usize) Rect {
        if (total > self.inner.h)
            return .{ .x = self.inner.x, .y = self.inner.y, .w = self.inner.w -| 2, .h = self.inner.h };
        return self.inner;
    }

    /// Right-edge scrollbar when `total` exceeds inner height. No-op otherwise.
    pub fn paintBar(self: Panel, scr: *Screen, total: usize, scroll: usize) void {
        if (self.inner.h == 0 or self.inner.w == 0) return;
        if (total <= self.inner.h) return;
        const bar_x: u16 = self.inner.x + self.inner.w - 1;
        const thumb = scrollbarThumb(total, self.inner.h, scroll, self.inner.h);
        var br: u16 = 0;
        while (br < self.inner.h) : (br += 1) {
            const in_thumb = br >= thumb.start and br < thumb.start + thumb.len;
            const st = if (in_thumb) bar_thumb else bar_track;
            const ch: u21 = if (in_thumb) '█' else '│';
            scr.setCell(bar_x, self.inner.y + br, .{ .char = ch, .width = 1, .style = st });
        }
    }
};

fn overlayRect(cols: u16, rows: u16, n: usize) Rect {
    const n16: u16 = std.math.cast(u16, n) orelse std.math.maxInt(u16);
    const max_w: u16 = 120;
    const avail_h: u16 = rows -| 4;
    const rows_n: u32 = rows;
    const min_pct: u16 = @intCast(rows_n / 4);
    const max_pct: u16 = @intCast(rows_n * 7 / 10);
    const min_h: u16 = @min(avail_h, @max(3, min_pct));
    const max_h: u16 = @min(avail_h, @max(min_h, max_pct));
    const want_w: u16 = @min(cols -| 4, max_w);
    const content_h: u16 = @max(3, n16 +| 2);
    const want_h: u16 = @min(max_h, @max(min_h, content_h));
    return Rect.centered(cols, rows, want_w, want_h);
}

test "overlayRect width cap, height band, and margin" {
    const wide = Panel.overlay(200, 40, 10);
    try std.testing.expectEqual(120, wide.rect.w);
    try std.testing.expect(wide.rect.x >= 2);
    try std.testing.expect(wide.rect.y >= 2);
    try std.testing.expect(wide.rect.x + wide.rect.w + 2 <= 200);
    try std.testing.expect(wide.rect.y + wide.rect.h + 2 <= 40);

    const tall = Panel.overlay(80, 24, 100);
    try std.testing.expectEqual(16, tall.rect.h); // 70% of 24
    try std.testing.expectEqual(76, tall.rect.w);

    const empty = Panel.overlay(80, 24, 0);
    try std.testing.expectEqual(6, empty.rect.h); // 25% of 24
}

test "scrollbarThumb extremes" {
    const top = scrollbarThumb(10, 4, 0, 4);
    try std.testing.expectEqual(0, top.start);
    try std.testing.expect(top.len >= 1);

    const bot = scrollbarThumb(10, 4, 6, 4);
    try std.testing.expectEqual(4, bot.start + bot.len);

    const none = scrollbarThumb(3, 4, 0, 4);
    try std.testing.expectEqual(0, none.len);
}

test "Panel.paint fills the box and writes the title" {
    const alloc = std.testing.allocator;
    var scr = try Screen.init(alloc, .{ .cols = 20, .rows = 10 });
    defer scr.deinit();

    const panel = Panel.fromRect(.{ .x = 2, .y = 1, .w = 12, .h = 6 });
    panel.paint(&scr, " title ");

    try std.testing.expectEqual('┌', scr.getCell(2, 1).char);
    try std.testing.expect(scr.getCell(2, 1).style.fg.eql(Panel.frame.fg));
    try std.testing.expectEqual('t', scr.getCell(5, 1).char);
    try std.testing.expectEqual(' ', scr.getCell(5, 2).char);
    try std.testing.expect(scr.getCell(5, 2).style.bg.eql(bg));
}

test "Panel.paintBar draws a thumb only when content overflows" {
    const alloc = std.testing.allocator;
    var scr = try Screen.init(alloc, .{ .cols = 20, .rows = 10 });
    defer scr.deinit();

    const panel = Panel.fromRect(.{ .x = 0, .y = 0, .w = 8, .h = 6 });
    panel.paint(&scr, " x ");
    panel.paintBar(&scr, 4, 0);
    try std.testing.expectEqual(' ', scr.getCell(6, 1).char);

    panel.paintBar(&scr, 20, 0);
    try std.testing.expectEqual('█', scr.getCell(6, 1).char);
}

test "panel frame color is the shared RGB" {
    try std.testing.expect(Panel.frame.fg.eql(.{ .rgb = .{ .r = 0x5d, .g = 0x81, .b = 0xb7 } }));
}
