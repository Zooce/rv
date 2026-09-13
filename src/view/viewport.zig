//! What is on screen: vertical scroll, column pan, sticky file headers.
//! Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
const row = @import("row.zig");
const Row = row.Row;
const clampCursor = row.clampCursor;
const layout_mod = @import("layout.zig");
const SbsSlot = layout_mod.SbsSlot;
const sbsSlotForRow = layout_mod.sbsSlotForRow;
const nav = @import("nav.zig");
const wrap_mod = @import("wrap.zig");

/// Screen rows for one display row. Headers stay 1; body lines wrap when `wrap_on`.
pub fn rowScreenHeight(r: Row, text_w: usize, wrap_on: bool) usize {
    if (!wrap_on) return 1;
    return switch (r) {
        .line => |ln| wrap_mod.lineCount(ln.text, text_w),
        else => 1,
    };
}

/// Screen rows for one side-by-side slot. Pair height is the taller pane.
pub fn slotScreenHeight(
    slot: SbsSlot,
    rows: []const Row,
    left_tw: usize,
    right_tw: usize,
    full_tw: usize,
    wrap_on: bool,
) usize {
    if (!wrap_on) return 1;
    return switch (slot) {
        .header => 1,
        .body => |ri| if (ri < rows.len) rowScreenHeight(rows[ri], full_tw, true) else 1,
        .pair => |p| blk: {
            const lh: usize = if (p.left) |ri| rowScreenHeight(rows[ri], left_tw, true) else 1;
            const rh: usize = if (p.right) |ri| rowScreenHeight(rows[ri], right_tw, true) else 1;
            break :blk @max(lh, rh);
        },
    };
}

const RowHeights = struct {
    rows: []const Row,
    text_w: usize,
    wrap_on: bool,
};

fn rowHeightAt(ctx: RowHeights, i: usize) usize {
    if (i >= ctx.rows.len) return 1;
    return rowScreenHeight(ctx.rows[i], ctx.text_w, ctx.wrap_on);
}

const SlotHeights = struct {
    slots: []const SbsSlot,
    rows: []const Row,
    left_tw: usize,
    right_tw: usize,
    full_tw: usize,
    wrap_on: bool,
};

fn slotHeightAt(ctx: SlotHeights, i: usize) usize {
    if (i >= ctx.slots.len) return 1;
    return slotScreenHeight(ctx.slots[i], ctx.rows, ctx.left_tw, ctx.right_tw, ctx.full_tw, ctx.wrap_on);
}

/// Move `scroll` so `cursor` is visible in a viewport of `height` rows.
/// Also clamps scroll so the last page is not overscrolled when possible.
pub fn ensureVisible(scroll: usize, cursor: usize, height: usize, row_count: usize) usize {
    const Unit = struct {
        fn h(_: void, _: usize) usize {
            return 1;
        }
    };
    return ensureByHeight(scroll, cursor, height, row_count, {}, Unit.h);
}

/// Like `ensureVisible`, but item `i` occupies `itemHeight(ctx, i)` screen rows.
/// A cursor row taller than `height` is pinned at the top of the window.
fn ensureByHeight(
    scroll: usize,
    cursor: usize,
    height: usize,
    n: usize,
    ctx: anytype,
    comptime itemHeight: fn (@TypeOf(ctx), usize) usize,
) usize {
    if (height == 0 or n == 0) return 0;
    const cur = if (cursor >= n) n - 1 else cursor;

    var need = itemHeight(ctx, cur);
    var min_s = cur;
    while (min_s > 0) {
        const prev = itemHeight(ctx, min_s - 1);
        if (need + prev > height) break;
        need += prev;
        min_s -= 1;
    }

    var s = scroll;
    if (cur < s) s = cur;
    if (s < min_s) s = min_s;

    var acc: usize = 0;
    var max_s: usize = 0;
    var i = n;
    while (i > 0) {
        i -= 1;
        acc += itemHeight(ctx, i);
        if (acc >= height) {
            max_s = i;
            break;
        }
    }
    if (s > max_s) s = max_s;
    return s;
}

/// Largest first-visible display column for content of `content_w` columns
/// in a viewport of `viewport_w` columns. Zero when everything fits.
pub fn maxColScroll(content_w: usize, viewport_w: usize) usize {
    if (viewport_w == 0 or content_w <= viewport_w) return 0;
    return content_w - viewport_w;
}

/// Clamp `col_scroll` into a valid range for the given content and viewport.
pub fn clampColScroll(col_scroll: usize, content_w: usize, viewport_w: usize) usize {
    return @min(col_scroll, maxColScroll(content_w, viewport_w));
}

/// First-visible column so the end of a `content_w`-wide row is on screen
/// (or 0 when the row fits). Same as `maxColScroll`.
pub fn colScrollToEnd(content_w: usize, viewport_w: usize) usize {
    return maxColScroll(content_w, viewport_w);
}

/// Body of the hunk that owns `cursor` (half-open `[body_start, body_end)`).
/// File/hunk headers are never in the body. Empty when not inside a hunk
/// (e.g. cursor on a file header before any `@@` in that file).
pub const HunkSpan = struct {
    /// Index of the owning `.hunk_header`, or `null` when not in a hunk.
    header: ?usize = null,
    /// First `.line` row after the header (equals `body_end` if the hunk is empty).
    body_start: usize = 0,
    /// Exclusive end: next file/hunk header, or `rows.len`.
    body_end: usize = 0,

    pub fn containsBody(self: HunkSpan, i: usize) bool {
        return i >= self.body_start and i < self.body_end;
    }
};

/// Hunk body span for horizontal pan: only lines in this range should scroll.
/// Uses `currentHunkInFile` so a file header does not inherit the previous file's hunk.
pub fn hunkSpanAt(rows: []const Row, cursor: usize) HunkSpan {
    const header = nav.currentHunkInFile(rows, cursor) orelse return .{};
    var end = header + 1;
    while (end < rows.len) : (end += 1) {
        switch (rows[end]) {
            .line => {},
            .hunk_header, .file_header, .section_header => break,
        }
    }
    return .{
        .header = header,
        .body_start = header + 1,
        .body_end = end,
    };
}

/// Display-row index to pin above the scrollable content area.
/// `file_idx` is `null` when nothing is sticky. Hunk headers are never sticky
/// (they scroll with the body so transitions stay one row at a time).
pub const Sticky = struct {
    file_idx: ?usize = null,

    /// How many screen rows sticky headers need (0–1).
    pub fn reserved(self: Sticky) usize {
        return if (self.file_idx != null) 1 else 0;
    }

    /// Drop the file pin when the terminal is too short for sticky + a body row.
    pub fn clampedToHeight(self: Sticky, content_height: usize) Sticky {
        if (content_height == 0) return .{};
        if (self.reserved() >= content_height) return .{};
        return self;
    }
};

/// Which file header pins above the body for the scroll window.
///
/// Pins the **last** file header that has scrolled **strictly above** the
/// window (`idx < scroll`). The next file header (at `scroll` or below) stays
/// a normal body row until it too scrolls above. Hunk headers are never
/// sticky — they scroll in the body one row at a time.
/// `content_height` caps pins so the cursor can still occupy a body row.
pub fn stickyHeaders(
    rows: []const Row,
    scroll: usize,
    content_height: usize,
) Sticky {
    if (rows.len == 0 or content_height == 0 or scroll == 0) return .{};
    var s: Sticky = .{};
    var i: usize = 0;
    while (i < scroll) : (i += 1) {
        if (rows[i] == .file_header) s.file_idx = i;
    }
    return s.clampedToHeight(content_height);
}

/// Scroll + sticky set so `cursor` stays visible below reserved sticky rows.
/// Iterates because sticky depends on scroll and reserved height depends on sticky.
/// When `wrap_on`, item heights are wrapped body lines at `text_w`.
pub fn ensureVisibleSticky(
    scroll: usize,
    cursor: usize,
    content_height: usize,
    rows: []const Row,
    wrap_on: bool,
    text_w: usize,
) struct { scroll: usize, sticky: Sticky } {
    if (content_height == 0 or rows.len == 0) {
        return .{ .scroll = 0, .sticky = .{} };
    }
    const cur = clampCursor(cursor, rows.len);
    const heights = RowHeights{ .rows = rows, .text_w = text_w, .wrap_on = wrap_on };
    var s = scroll;
    var sticky: Sticky = .{};
    // Sticky ↔ height feedback is small (at most two rows); a few passes settle.
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        sticky = stickyHeaders(rows, s, content_height);
        const h = content_height - sticky.reserved();
        const next = ensureByHeight(s, cur, h, rows.len, heights, rowHeightAt);
        if (next == s) break;
        s = next;
    }
    sticky = stickyHeaders(rows, s, content_height);
    return .{ .scroll = s, .sticky = sticky };
}

/// Sticky file header for side-by-side scroll (slot index space).
/// Pins the last file-header **slot** strictly above `scroll`; `file_idx` is
/// still the unified row index (for formatting).
pub fn stickyHeadersSbs(
    slots: []const SbsSlot,
    rows: []const Row,
    scroll: usize,
    content_height: usize,
) Sticky {
    if (slots.len == 0 or content_height == 0 or scroll == 0) return .{};
    var s: Sticky = .{};
    var i: usize = 0;
    while (i < scroll and i < slots.len) : (i += 1) {
        switch (slots[i]) {
            .header => |ri| if (ri < rows.len and rows[ri] == .file_header) {
                s.file_idx = ri;
            },
            .pair, .body => {},
        }
    }
    return s.clampedToHeight(content_height);
}

/// Like `ensureVisibleSticky`, but scroll/cursor visibility use side-by-side
/// **slot** indices. `cursor_row` is still a unified row index.
pub fn ensureVisibleStickySbs(
    scroll: usize,
    cursor_row: usize,
    content_height: usize,
    slots: []const SbsSlot,
    rows: []const Row,
    wrap_on: bool,
    left_tw: usize,
    right_tw: usize,
    full_tw: usize,
) struct { scroll: usize, sticky: Sticky } {
    if (content_height == 0 or slots.len == 0) {
        return .{ .scroll = 0, .sticky = .{} };
    }
    const cur_row = clampCursor(cursor_row, rows.len);
    const slot_cur = sbsSlotForRow(slots, cur_row) orelse 0;
    const heights = SlotHeights{
        .slots = slots,
        .rows = rows,
        .left_tw = left_tw,
        .right_tw = right_tw,
        .full_tw = full_tw,
        .wrap_on = wrap_on,
    };
    var s = scroll;
    var sticky: Sticky = .{};
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        sticky = stickyHeadersSbs(slots, rows, s, content_height);
        const h = content_height - sticky.reserved();
        const next = ensureByHeight(s, slot_cur, h, slots.len, heights, slotHeightAt);
        if (next == s) break;
        s = next;
    }
    sticky = stickyHeadersSbs(slots, rows, s, content_height);
    return .{ .scroll = s, .sticky = sticky };
}

const testing = std.testing;
const Allocator = std.mem.Allocator;

test "ensureVisible scrolls with cursor" {
    // height 3, 10 rows: cursor at 0 → scroll 0
    try testing.expectEqual(0, ensureVisible(0, 0, 3, 10));
    // cursor moves below window → scroll so cursor is last visible
    try testing.expectEqual(1, ensureVisible(0, 3, 3, 10));
    // cursor above scroll → pull scroll up
    try testing.expectEqual(2, ensureVisible(5, 2, 3, 10));
    // near end: do not overscroll past last page
    try testing.expectEqual(7, ensureVisible(0, 9, 3, 10));
    try testing.expectEqual(0, ensureVisible(0, 0, 3, 2));
    try testing.expectEqual(0, ensureVisible(0, 0, 0, 10));
}

test "ensureVisibleSticky wrap pins a tall body row" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+this line is long enough to wrap
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk, 2 keep, 3 del, 4 add. text_w=8 → add wraps to several lines.
    const text_w: usize = 8;
    try testing.expect(rowScreenHeight(rows[4], text_w, true) > 1);
    try testing.expectEqual(1, rowScreenHeight(rows[4], text_w, false));
    try testing.expectEqual(1, rowScreenHeight(rows[0], text_w, true));

    const r = ensureVisibleSticky(0, 4, 3, rows, true, text_w);
    try testing.expectEqual(4, r.scroll);

    const slots = try layout_mod.pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    const sbs = ensureVisibleStickySbs(0, 4, 3, slots, rows, true, text_w, text_w, text_w);
    const add_slot = sbsSlotForRow(slots, 4).?;
    try testing.expectEqual(add_slot, sbs.scroll);
}

test "maxColScroll and clampColScroll" {
    try testing.expectEqual(0, maxColScroll(10, 20));
    try testing.expectEqual(0, maxColScroll(10, 10));
    try testing.expectEqual(5, maxColScroll(15, 10));
    try testing.expectEqual(0, maxColScroll(15, 0));
    try testing.expectEqual(0, clampColScroll(0, 15, 10));
    try testing.expectEqual(3, clampColScroll(3, 15, 10));
    try testing.expectEqual(5, clampColScroll(99, 15, 10));
    try testing.expectEqual(0, clampColScroll(3, 5, 10));
    try testing.expectEqual(5, colScrollToEnd(15, 10));
    try testing.expectEqual(0, colScrollToEnd(5, 10));
}

/// Two files, two hunks each. Indices:
/// 0 file A, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add,
/// 7 file B, 8 h2, 9 del, 10 add.
fn twoFileFixture(alloc: Allocator) !struct { d: diff.Diff, rows: []Row } {
    const fixture =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-oldA1
        \\+newA1
        \\@@ -10 +10 @@
        \\-oldA2
        \\+newA2
        \\diff --git a/b b/b
        \\--- a/b
        \\+++ b/b
        \\@@ -1 +1 @@
        \\-oldB
        \\+newB
    ;
    var d = try diff.parse(alloc, fixture);
    errdefer d.deinit();
    const rows = try row.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "stickyHeaders pins last file above scroll only" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    // 0 fileA, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add, 7 fileB, 8 h2, 9 del, 10 add
    const tall: usize = 20;

    // scroll 0: nothing above the window.
    try testing.expect(stickyHeaders(rows, 0, tall).file_idx == null);

    // Mid file A: file sticky; hunks never sticky.
    const mid = stickyHeaders(rows, 3, tall);
    try testing.expectEqual(0, mid.file_idx.?);
    try testing.expectEqual(1, mid.reserved());

    // Hunk boundary inside A: still only file sticky.
    const h1_at_top = stickyHeaders(rows, 4, tall);
    try testing.expectEqual(0, h1_at_top.file_idx.?);

    // File B header at body top: keep sticky file A (B enters as body).
    const on_b = stickyHeaders(rows, 7, tall);
    try testing.expectEqual(0, on_b.file_idx.?);

    // Past file B header: sticky file B.
    const past_b = stickyHeaders(rows, 8, tall);
    try testing.expectEqual(7, past_b.file_idx.?);

    // Deep in file B.
    try testing.expectEqual(7, stickyHeaders(rows, 10, tall).file_idx.?);
}

test "stickyHeaders drops pin on short content height" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    // height 1 keeps only a body row → drop file pin.
    try testing.expectEqual(0, stickyHeaders(rows, 3, 1).reserved());
    // height 2 → file pin fits.
    try testing.expectEqual(1, stickyHeaders(rows, 3, 2).reserved());
    try testing.expectEqual(0, stickyHeaders(rows, 3, 2).file_idx.?);
    try testing.expectEqual(0, stickyHeaders(rows, 3, 0).reserved());
}

test "ensureVisibleSticky reserves file row and keeps cursor in body" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    // Mid first hunk: file sticky; cursor in reduced body window.
    const r = ensureVisibleSticky(3, 3, 5, rows, false, 0);
    try testing.expectEqual(0, r.sticky.file_idx.?);
    try testing.expectEqual(1, r.sticky.reserved());
    const body_h = 5 - r.sticky.reserved();
    try testing.expect(r.scroll <= 3);
    try testing.expect(3 < r.scroll + body_h);

    // Deep in file A with a short window.
    const deep = ensureVisibleSticky(0, 6, 3, rows, false, 0);
    try testing.expect(deep.sticky.file_idx != null);
    try testing.expect(deep.scroll <= 6);
    try testing.expect(6 < deep.scroll + (3 - deep.sticky.reserved()));

    // At top of list: no sticky.
    const top = ensureVisibleSticky(0, 0, 5, rows, false, 0);
    try testing.expectEqual(0, top.scroll);
    try testing.expectEqual(0, top.sticky.reserved());

    const empty = ensureVisibleSticky(0, 0, 5, &.{}, false, 0);
    try testing.expectEqual(0, empty.scroll);
    try testing.expectEqual(0, empty.sticky.reserved());
}

test "ensureVisibleStickySbs uses slot indices" {
    // Zip-paired del|add → fewer slots than rows; cursor on add maps to pair slot.
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try layout_mod.pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    try testing.expectEqual(3, slots.len);

    // Cursor on add (row 3) → slot 2; short window should scroll to show it.
    const r = ensureVisibleStickySbs(0, 3, 2, slots, rows, false, 0, 0, 0);
    try testing.expectEqual(2, sbsSlotForRow(slots, 3).?);
    try testing.expect(r.scroll <= 2);
    try testing.expect(2 < r.scroll + (2 - r.sticky.reserved()));

    // File header sticky when scrolled past it (multi-file).
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const slots2 = try layout_mod.pairSideBySide(testing.allocator, fix.rows);
    defer testing.allocator.free(slots2);
    // Scroll past first file's slots; pin file A.
    const deep = ensureVisibleStickySbs(0, fix.rows.len - 1, 3, slots2, fix.rows, false, 0, 0, 0);
    try testing.expect(deep.sticky.file_idx != null or deep.scroll == 0);
}

test "stickyHeadersSbs pins file above one-sided body" {
    const added =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1,2 @@
        \\+a
        \\+b
    ;
    var d = try diff.parse(testing.allocator, added);
    defer d.deinit();
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try layout_mod.pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    try testing.expectEqual(4, slots.len);

    try testing.expect(stickyHeadersSbs(slots, rows, 0, 20).file_idx == null);
    try testing.expectEqual(0, stickyHeadersSbs(slots, rows, 2, 20).file_idx.?);
    try testing.expectEqual(0, stickyHeadersSbs(slots, rows, 3, 20).file_idx.?);
}

/// Two-hunk fixture: file, h0, del, add, h1, del, add → indices 0..6.
fn twoHunkFixture(alloc: Allocator) !struct { d: diff.Diff, rows: []Row } {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old1
        \\+new1
        \\@@ -10 +10 @@ section
        \\-old2
        \\+new2
    ;
    var d = try diff.parse(alloc, fixture);
    errdefer d.deinit();
    const rows = try row.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "hunkSpanAt body excludes headers and stops at next hunk/file" {
    // twoHunkFixture: 0 file, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add
    var fix = try twoHunkFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    // On file header: not in a hunk.
    const none = hunkSpanAt(rows, 0);
    try testing.expect(none.header == null);
    try testing.expectEqual(0, none.body_start);
    try testing.expectEqual(0, none.body_end);
    try testing.expect(!none.containsBody(2));

    // On first @@ or its lines: body is 2..4
    const h0 = hunkSpanAt(rows, 1);
    try testing.expectEqual(1, h0.header.?);
    try testing.expectEqual(2, h0.body_start);
    try testing.expectEqual(4, h0.body_end);
    try testing.expect(h0.containsBody(2));
    try testing.expect(h0.containsBody(3));
    try testing.expect(!h0.containsBody(1));
    try testing.expect(!h0.containsBody(4));

    const h0_line = hunkSpanAt(rows, 3);
    try testing.expectEqual(1, h0_line.header.?);
    try testing.expectEqual(2, h0_line.body_start);
    try testing.expectEqual(4, h0_line.body_end);

    // Second hunk
    const h1 = hunkSpanAt(rows, 5);
    try testing.expectEqual(4, h1.header.?);
    try testing.expectEqual(5, h1.body_start);
    try testing.expectEqual(7, h1.body_end);
}
