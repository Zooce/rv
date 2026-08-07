//! Flatten a parsed `Diff` into navigable display rows and keep a cursor
//! inside a scroll viewport. Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;

/// One renderable row in the review list. String slices borrow from the
/// parent `Diff` arena (or are static); free only the row slice itself.
pub const Row = union(enum) {
    file_header: struct {
        path: []const u8,
        is_binary: bool,
    },
    hunk_header: struct {
        old_start: u32,
        old_count: ?u32,
        new_start: u32,
        new_count: ?u32,
        section: []const u8,
    },
    line: struct {
        kind: diff.LineKind,
        text: []const u8,
        /// Display path of the owning file (borrowed from `Diff`).
        path: []const u8,
        /// 1-based old-file line when this line exists on the old side.
        old_no: ?u32 = null,
        /// 1-based new-file line when this line exists on the new side.
        new_no: ?u32 = null,
    },
};

/// Line-comment target at the cursor (path + line numbers). `null` on headers
/// and meta lines (not commentable in MVP-1).
pub const Anchor = struct {
    path: []const u8,
    old_line: ?u32,
    new_line: ?u32,
};

/// Build an owned list of rows from `d`. Caller's `alloc` owns the slice;
/// free with `alloc.free(rows)`. Nested string data is borrowed from `d`.
pub fn flatten(alloc: Allocator, d: *const diff.Diff) Allocator.Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(alloc);

    for (d.files) |f| {
        try rows.append(alloc, .{ .file_header = .{
            .path = f.displayPath(),
            .is_binary = f.is_binary,
        } });
        for (f.hunks) |h| {
            try rows.append(alloc, .{ .hunk_header = .{
                .old_start = h.old_start,
                .old_count = h.old_count,
                .new_start = h.new_start,
                .new_count = h.new_count,
                .section = h.section,
            } });
            for (h.lines) |ln| {
                try rows.append(alloc, .{ .line = .{
                    .kind = ln.kind,
                    .text = ln.text,
                    .path = f.displayPath(),
                    .old_no = ln.old_no,
                    .new_no = ln.new_no,
                } });
            }
        }
    }
    return try rows.toOwnedSlice(alloc);
}

/// Clamp `cursor` into `[0, len)` (or `0` when the list is empty).
pub fn clampCursor(cursor: usize, len: usize) usize {
    if (len == 0) return 0;
    if (cursor >= len) return len - 1;
    return cursor;
}

/// Move `scroll` so `cursor` is visible in a viewport of `height` rows.
/// Also clamps scroll so the last page is not overscrolled when possible.
pub fn ensureVisible(scroll: usize, cursor: usize, height: usize, row_count: usize) usize {
    if (height == 0 or row_count == 0) return 0;
    var s = scroll;
    if (cursor < s) s = cursor;
    if (cursor >= s + height) s = cursor + 1 - height;
    const max_scroll = if (row_count > height) row_count - height else 0;
    if (s > max_scroll) s = max_scroll;
    return s;
}

// --- horizontal scroll -------------------------------------------------

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
    const header = currentHunkInFile(rows, cursor) orelse return .{};
    var end = header + 1;
    while (end < rows.len) : (end += 1) {
        switch (rows[end]) {
            .line => {},
            .hunk_header, .file_header => break,
        }
    }
    return .{
        .header = header,
        .body_start = header + 1,
        .body_end = end,
    };
}

// --- sticky file headers -----------------------------------------------

/// Display-row index to pin above the scrollable content area.
/// `file_idx` is `null` when nothing is sticky. Hunk headers are never sticky
/// (they scroll with the body so transitions stay one row at a time).
pub const Sticky = struct {
    file_idx: ?usize = null,

    /// How many screen rows sticky headers need (0–1).
    pub fn reserved(self: Sticky) usize {
        return if (self.file_idx != null) 1 else 0;
    }
};

/// Row index of the last `.file_header` at or before `cursor`, or `null`.
pub fn currentFileStart(rows: []const Row, cursor: usize) ?usize {
    if (rows.len == 0) return null;
    var i = clampCursor(cursor, rows.len);
    while (true) {
        if (rows[i] == .file_header) return i;
        if (i == 0) return null;
        i -= 1;
    }
}

/// Hunk header that owns `cursor` within the same file, or `null`.
/// Unlike `currentHunkStart`, stops at a file header so a later file's
/// header/body does not inherit the previous file's last hunk.
pub fn currentHunkInFile(rows: []const Row, cursor: usize) ?usize {
    if (rows.len == 0) return null;
    var i = clampCursor(cursor, rows.len);
    while (true) {
        switch (rows[i]) {
            .hunk_header => return i,
            .file_header => return null,
            .line => {},
        }
        if (i == 0) return null;
        i -= 1;
    }
}

/// Drop the file pin when the terminal is too short for sticky + a body row.
fn clampStickyToHeight(sticky: Sticky, content_height: usize) Sticky {
    if (content_height == 0) return .{};
    if (sticky.reserved() >= content_height) return .{};
    return sticky;
}

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
    return clampStickyToHeight(s, content_height);
}

/// Scroll + sticky set so `cursor` stays visible below reserved sticky rows.
/// Iterates because sticky depends on scroll and reserved height depends on sticky.
pub fn ensureVisibleSticky(
    scroll: usize,
    cursor: usize,
    content_height: usize,
    rows: []const Row,
) struct { scroll: usize, sticky: Sticky } {
    if (content_height == 0 or rows.len == 0) {
        return .{ .scroll = 0, .sticky = .{} };
    }
    const cur = clampCursor(cursor, rows.len);
    var s = scroll;
    var sticky: Sticky = .{};
    // Sticky ↔ height feedback is small (at most two rows); a few passes settle.
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        sticky = stickyHeaders(rows, s, content_height);
        const h = content_height - sticky.reserved();
        const next = ensureVisible(s, cur, h, rows.len);
        if (next == s) break;
        s = next;
    }
    sticky = stickyHeaders(rows, s, content_height);
    return .{ .scroll = s, .sticky = sticky };
}

// --- hunk jump + status (MVP-0.4) ----------------------------------------

/// Location context for the status footer. Slices borrow from `rows`.
pub const Status = struct {
    /// Display path of the file containing the cursor (`""` if none).
    path: []const u8,
    /// 1-based index of the current hunk among all hunks; `0` when not in a hunk.
    hunk_i: usize,
    /// Total number of hunk headers in `rows`.
    hunk_n: usize,
    /// 1-based cursor row among all display rows; `0` when empty.
    row_i: usize,
    /// Total display rows.
    row_n: usize,
};

/// Row index of the last `.hunk_header` at or before `cursor`, or `null`.
pub fn currentHunkStart(rows: []const Row, cursor: usize) ?usize {
    if (rows.len == 0) return null;
    var i = clampCursor(cursor, rows.len);
    while (true) {
        if (rows[i] == .hunk_header) return i;
        if (i == 0) return null;
        i -= 1;
    }
}

/// Land on the first add/delete line of the hunk starting at `hunk_start`,
/// or on the hunk header itself when the hunk has no changed lines.
pub fn landOnHunk(rows: []const Row, hunk_start: usize) usize {
    if (hunk_start >= rows.len or rows[hunk_start] != .hunk_header) {
        return clampCursor(hunk_start, rows.len);
    }
    var i = hunk_start + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .line => |ln| switch (ln.kind) {
                .add, .delete => return i,
                .context, .meta => {},
            },
            .hunk_header, .file_header => break,
        }
    }
    return hunk_start;
}

/// Jump to the next hunk after the one containing `cursor` (or the first hunk
/// if none). Lands on the first add/delete line. Unchanged when there is no
/// later hunk.
pub fn nextHunk(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const search_from: usize = if (currentHunkStart(rows, cursor)) |s| s + 1 else 0;
    var i = search_from;
    while (i < rows.len) : (i += 1) {
        if (rows[i] == .hunk_header) return landOnHunk(rows, i);
    }
    return clampCursor(cursor, rows.len);
}

/// Jump to the previous hunk before the one containing `cursor`. Lands on the
/// first add/delete line. Unchanged when already on the first hunk (or before
/// any hunk).
pub fn prevHunk(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = currentHunkStart(rows, cursor) orelse return clampCursor(cursor, rows.len);
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (rows[i] == .hunk_header) return landOnHunk(rows, i);
    }
    return clampCursor(cursor, rows.len);
}

/// Jump to the next `.hunk_header` row after `cursor`. Lands on the header
/// itself (not the first add/delete). Unchanged when none follows.
pub fn nextHunkHeader(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur + 1;
    while (i < rows.len) : (i += 1) {
        if (rows[i] == .hunk_header) return i;
    }
    return cur;
}

/// Jump to the previous `.hunk_header` row before `cursor`. Lands on the
/// header itself. From a hunk body this is the current hunk's `@@` row.
/// Unchanged when none precedes.
pub fn prevHunkHeader(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (rows[i] == .hunk_header) return i;
    }
    return cur;
}

/// Jump to the next `.file_header` row after `cursor`. Lands on the file
/// header itself. Unchanged when none follows.
pub fn nextFileHeader(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur + 1;
    while (i < rows.len) : (i += 1) {
        if (rows[i] == .file_header) return i;
    }
    return cur;
}

/// Jump to the previous `.file_header` row before `cursor`. Lands on the
/// file header itself. From a file body this is the current file's header.
/// Unchanged when none precedes.
pub fn prevFileHeader(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (rows[i] == .file_header) return i;
    }
    return cur;
}

/// True when `row` is an add or delete body line (not context/meta/headers).
fn isChangedLine(row: Row) bool {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .add, .delete => true,
            .context, .meta => false,
        },
        .file_header, .hunk_header => false,
    };
}

/// First row of the contiguous add/delete run containing `idx`, or `null`
/// when `rows[idx]` is not a changed line. A group is maximal: broken only by
/// context, meta, or headers (same-hunk groups with context between count
/// as separate groups).
fn changeGroupStart(rows: []const Row, idx: usize) ?usize {
    if (idx >= rows.len or !isChangedLine(rows[idx])) return null;
    var i = idx;
    while (i > 0 and isChangedLine(rows[i - 1])) : (i -= 1) {}
    return i;
}

/// Jump to the first line of the next change *group* after `cursor`. A group
/// is a contiguous run of add/delete rows; consecutive changed lines are one
/// group (unlike one-row `j`). Skips context, meta, and headers. Unchanged
/// when no later group exists.
pub fn nextChange(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur + 1;
    // Leave the rest of the current group so J ≠ j on multi-line edits.
    if (isChangedLine(rows[cur])) {
        while (i < rows.len and isChangedLine(rows[i])) : (i += 1) {}
    }
    while (i < rows.len) : (i += 1) {
        if (isChangedLine(rows[i])) return i;
    }
    return cur;
}

/// Jump to the first line of the previous change group (or the start of the
/// current group when mid-group). Unchanged when none precedes.
pub fn prevChange(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    if (changeGroupStart(rows, cur)) |start| {
        if (start < cur) return start;
        // On the first line of this group: step to the previous group.
        var i = start;
        while (i > 0) {
            i -= 1;
            if (isChangedLine(rows[i])) return changeGroupStart(rows, i).?;
        }
        return cur;
    }
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (isChangedLine(rows[i])) return changeGroupStart(rows, i).?;
    }
    return cur;
}

/// Anchor for a line comment at `cursor`, or `null` if the row is not a
/// normal diff body line (file/hunk header or meta).
pub fn anchorAt(rows: []const Row, cursor: usize) ?Anchor {
    if (rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    return switch (rows[cur]) {
        .line => |ln| switch (ln.kind) {
            .meta => null,
            .context, .add, .delete => .{
                .path = ln.path,
                .old_line = ln.old_no,
                .new_line = ln.new_no,
            },
        },
        .file_header, .hunk_header => null,
    };
}

/// Status footer fields for `cursor` within `rows`.
pub fn statusAt(rows: []const Row, cursor: usize) Status {
    if (rows.len == 0) {
        return .{ .path = "", .hunk_i = 0, .hunk_n = 0, .row_i = 0, .row_n = 0 };
    }
    const cur = clampCursor(cursor, rows.len);
    var path: []const u8 = "";
    var hunk_n: usize = 0;
    var hunk_i: usize = 0;
    var i: usize = 0;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .file_header => |fh| {
                if (i <= cur) path = fh.path;
            },
            .hunk_header => {
                hunk_n += 1;
                if (i <= cur) hunk_i = hunk_n;
            },
            .line => {},
        }
    }
    return .{
        .path = path,
        .hunk_i = hunk_i,
        .hunk_n = hunk_n,
        .row_i = cur + 1,
        .row_n = rows.len,
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "flatten empty diff" {
    var d = try diff.parse(testing.allocator, "");
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    try testing.expectEqual(0, rows.len);
}

test "flatten file hunk and lines" {
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
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expectEqual(4, rows.len);
    try testing.expect(rows[0] == .file_header);
    try testing.expectEqualStrings("f", rows[0].file_header.path);
    try testing.expect(rows[1] == .hunk_header);
    try testing.expect(rows[2] == .line);
    try testing.expectEqual(diff.LineKind.delete, rows[2].line.kind);
    try testing.expectEqualStrings("old", rows[2].line.text);
    try testing.expectEqualStrings("f", rows[2].line.path);
    try testing.expectEqual(1, rows[2].line.old_no.?);
    try testing.expect(rows[2].line.new_no == null);
    try testing.expect(rows[3] == .line);
    try testing.expectEqual(diff.LineKind.add, rows[3].line.kind);
    try testing.expectEqualStrings("new", rows[3].line.text);
    try testing.expectEqual(1, rows[3].line.new_no.?);
    try testing.expect(rows[3].line.old_no == null);

    try testing.expect(anchorAt(rows, 0) == null);
    try testing.expect(anchorAt(rows, 1) == null);
    const a = anchorAt(rows, 2).?;
    try testing.expectEqualStrings("f", a.path);
    try testing.expectEqual(1, a.old_line.?);
    try testing.expect(a.new_line == null);
}

test "flatten binary file has header only" {
    const fixture =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expectEqual(1, rows.len);
    try testing.expect(rows[0] == .file_header);
    try testing.expect(rows[0].file_header.is_binary);
    try testing.expectEqualStrings("pic.png", rows[0].file_header.path);
}

test "clampCursor" {
    try testing.expectEqual(0, clampCursor(0, 0));
    try testing.expectEqual(0, clampCursor(5, 0));
    try testing.expectEqual(0, clampCursor(0, 3));
    try testing.expectEqual(2, clampCursor(2, 3));
    try testing.expectEqual(2, clampCursor(99, 3));
}

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

/// Two-hunk fixture: file, h0, del, add, h1, del, add → indices 0..6.
/// Caller owns `d` and `rows` (strings borrow from `d`).
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
    const rows = try flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "nextHunk and prevHunk land on first changed line" {
    var fix = try twoHunkFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(7, rows.len);

    // From file header → first hunk's first delete.
    try testing.expectEqual(2, nextHunk(rows, 0));
    // From first hunk body → second hunk's first delete.
    try testing.expectEqual(5, nextHunk(rows, 2));
    try testing.expectEqual(5, nextHunk(rows, 3));
    // No later hunk.
    try testing.expectEqual(5, nextHunk(rows, 5));
    try testing.expectEqual(6, nextHunk(rows, 6));

    // From second hunk → first hunk land.
    try testing.expectEqual(2, prevHunk(rows, 5));
    try testing.expectEqual(2, prevHunk(rows, 6));
    // Already on first hunk: stay.
    try testing.expectEqual(2, prevHunk(rows, 2));
    try testing.expectEqual(0, prevHunk(rows, 0));
}

// twoHunkFixture layout: 0 file, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add.
test "nextHunkHeader and prevHunkHeader land on @@ rows" {
    var fix = try twoHunkFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(7, rows.len);
    try testing.expect(rows[1] == .hunk_header);
    try testing.expect(rows[4] == .hunk_header);

    // From file header / first body → next is first then second header.
    try testing.expectEqual(1, nextHunkHeader(rows, 0));
    try testing.expectEqual(4, nextHunkHeader(rows, 1));
    try testing.expectEqual(4, nextHunkHeader(rows, 2));
    try testing.expectEqual(4, nextHunkHeader(rows, 3));
    // No later header: stay.
    try testing.expectEqual(4, nextHunkHeader(rows, 4));
    try testing.expectEqual(5, nextHunkHeader(rows, 5));
    try testing.expectEqual(6, nextHunkHeader(rows, 6));

    // From body → current hunk header; from header → previous header.
    try testing.expectEqual(4, prevHunkHeader(rows, 5));
    try testing.expectEqual(4, prevHunkHeader(rows, 6));
    try testing.expectEqual(1, prevHunkHeader(rows, 4));
    try testing.expectEqual(1, prevHunkHeader(rows, 2));
    try testing.expectEqual(1, prevHunkHeader(rows, 3));
    // No earlier header: stay.
    try testing.expectEqual(1, prevHunkHeader(rows, 1));
    try testing.expectEqual(0, prevHunkHeader(rows, 0));

    try testing.expectEqual(0, nextHunkHeader(&.{}, 0));
    try testing.expectEqual(0, prevHunkHeader(&.{}, 0));
}

test "statusAt path and hunk index" {
    var fix = try twoHunkFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    const s0 = statusAt(rows, 0);
    try testing.expectEqualStrings("f", s0.path);
    try testing.expectEqual(0, s0.hunk_i);
    try testing.expectEqual(2, s0.hunk_n);
    try testing.expectEqual(1, s0.row_i);
    try testing.expectEqual(7, s0.row_n);

    const s2 = statusAt(rows, 2);
    try testing.expectEqualStrings("f", s2.path);
    try testing.expectEqual(1, s2.hunk_i);
    try testing.expectEqual(2, s2.hunk_n);

    const s5 = statusAt(rows, 5);
    try testing.expectEqual(2, s5.hunk_i);
    try testing.expectEqual(2, s5.hunk_n);

    const empty = statusAt(&.{}, 0);
    try testing.expectEqual(0, empty.hunk_n);
    try testing.expectEqual(0, empty.row_i);
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
    const rows = try flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "currentFileStart and currentHunkInFile" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(11, rows.len);

    try testing.expectEqual(0, currentFileStart(rows, 0).?);
    try testing.expectEqual(0, currentFileStart(rows, 5).?);
    try testing.expectEqual(7, currentFileStart(rows, 7).?);
    try testing.expectEqual(7, currentFileStart(rows, 10).?);

    try testing.expect(currentHunkInFile(rows, 0) == null);
    try testing.expectEqual(1, currentHunkInFile(rows, 1).?);
    try testing.expectEqual(1, currentHunkInFile(rows, 3).?);
    try testing.expectEqual(4, currentHunkInFile(rows, 5).?);
    // On next file header: no hunk in this file yet.
    try testing.expect(currentHunkInFile(rows, 7) == null);
    try testing.expectEqual(8, currentHunkInFile(rows, 9).?);
}

// twoFileFixture: 0 fileA … 6, 7 fileB, 8 h2, 9 del, 10 add.
test "nextFileHeader and prevFileHeader land on file rows" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(11, rows.len);
    try testing.expect(rows[0] == .file_header);
    try testing.expect(rows[7] == .file_header);

    // Next file after A body / A header.
    try testing.expectEqual(7, nextFileHeader(rows, 0));
    try testing.expectEqual(7, nextFileHeader(rows, 3));
    try testing.expectEqual(7, nextFileHeader(rows, 6));
    // No later file: stay.
    try testing.expectEqual(7, nextFileHeader(rows, 7));
    try testing.expectEqual(9, nextFileHeader(rows, 9));
    try testing.expectEqual(10, nextFileHeader(rows, 10));

    // From B body → B header; from B header → A header.
    try testing.expectEqual(7, prevFileHeader(rows, 9));
    try testing.expectEqual(7, prevFileHeader(rows, 10));
    try testing.expectEqual(0, prevFileHeader(rows, 7));
    try testing.expectEqual(0, prevFileHeader(rows, 3));
    // No earlier file: stay.
    try testing.expectEqual(0, prevFileHeader(rows, 0));

    // Coexists with hunk-header jump (different landings from same cursor).
    try testing.expectEqual(4, nextHunkHeader(rows, 3));
    try testing.expectEqual(7, nextFileHeader(rows, 3));
    try testing.expectEqual(1, prevHunkHeader(rows, 3));
    try testing.expectEqual(0, prevFileHeader(rows, 3));

    try testing.expectEqual(0, nextFileHeader(&.{}, 0));
    try testing.expectEqual(0, prevFileHeader(&.{}, 0));
}

/// Multi-group fixture (groups can share a hunk when context sits between):
/// 0 file, 1 h0, 2 ctx, 3–5 group0 (del,del,add), 6 ctx, 7–8 group1 (del,add),
/// 9 ctx, 10 h1, 11–12 group2 (del,add).
fn changeNavFixture(alloc: Allocator) !struct { d: diff.Diff, rows: []Row } {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,6 +1,6 @@
        \\ keep
        \\-old1a
        \\-old1b
        \\+new1
        \\ mid
        \\-old2
        \\+new2
        \\ tail
        \\@@ -20 +20 @@
        \\-old3
        \\+new3
    ;
    var d = try diff.parse(alloc, fixture);
    errdefer d.deinit();
    const rows = try flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "nextChange and prevChange jump change groups not single lines" {
    var fix = try changeNavFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(13, rows.len);
    try testing.expect(rows[2] == .line and rows[2].line.kind == .context);
    try testing.expect(rows[3] == .line and rows[3].line.kind == .delete);
    try testing.expect(rows[4] == .line and rows[4].line.kind == .delete);
    try testing.expect(rows[5] == .line and rows[5].line.kind == .add);
    try testing.expect(rows[6] == .line and rows[6].line.kind == .context);
    try testing.expect(rows[7] == .line and rows[7].line.kind == .delete);
    try testing.expect(rows[8] == .line and rows[8].line.kind == .add);
    try testing.expect(rows[9] == .line and rows[9].line.kind == .context);
    try testing.expect(rows[10] == .hunk_header);
    try testing.expect(rows[11] == .line and rows[11].line.kind == .delete);
    try testing.expect(rows[12] == .line and rows[12].line.kind == .add);

    // From file/hunk/context → first group start.
    try testing.expectEqual(3, nextChange(rows, 0));
    try testing.expectEqual(3, nextChange(rows, 1));
    try testing.expectEqual(3, nextChange(rows, 2));
    // Mid multi-line group: J skips the whole run (not j-like line steps).
    try testing.expectEqual(7, nextChange(rows, 3));
    try testing.expectEqual(7, nextChange(rows, 4));
    try testing.expectEqual(7, nextChange(rows, 5));
    // Context between same-hunk groups → next group.
    try testing.expectEqual(7, nextChange(rows, 6));
    // Across hunk header → next group.
    try testing.expectEqual(11, nextChange(rows, 7));
    try testing.expectEqual(11, nextChange(rows, 8));
    try testing.expectEqual(11, nextChange(rows, 9));
    try testing.expectEqual(11, nextChange(rows, 10));
    // No later group: stay (including mid last group).
    try testing.expectEqual(11, nextChange(rows, 11));
    try testing.expectEqual(12, nextChange(rows, 12));

    // Mid group → current group start; on start → previous group start.
    try testing.expectEqual(11, prevChange(rows, 12));
    try testing.expectEqual(7, prevChange(rows, 11));
    try testing.expectEqual(7, prevChange(rows, 10));
    try testing.expectEqual(7, prevChange(rows, 9));
    try testing.expectEqual(7, prevChange(rows, 8));
    try testing.expectEqual(3, prevChange(rows, 7));
    try testing.expectEqual(3, prevChange(rows, 6));
    try testing.expectEqual(3, prevChange(rows, 5));
    try testing.expectEqual(3, prevChange(rows, 4));
    // No earlier group: stay.
    try testing.expectEqual(3, prevChange(rows, 3));
    try testing.expectEqual(2, prevChange(rows, 2));
    try testing.expectEqual(1, prevChange(rows, 1));
    try testing.expectEqual(0, prevChange(rows, 0));

    // Coexists with header jumps (different landings from mid group0).
    try testing.expectEqual(7, nextChange(rows, 4)); // J → next group
    try testing.expectEqual(10, nextHunkHeader(rows, 4)); // ] → next @@
    try testing.expectEqual(3, prevChange(rows, 4)); // K → group start
    try testing.expectEqual(1, prevHunkHeader(rows, 4)); // [ → @@

    try testing.expectEqual(0, nextChange(&.{}, 0));
    try testing.expectEqual(0, prevChange(&.{}, 0));
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
    const r = ensureVisibleSticky(3, 3, 5, rows);
    try testing.expectEqual(0, r.sticky.file_idx.?);
    try testing.expectEqual(1, r.sticky.reserved());
    const body_h = 5 - r.sticky.reserved();
    try testing.expect(r.scroll <= 3);
    try testing.expect(3 < r.scroll + body_h);

    // Deep in file A with a short window.
    const deep = ensureVisibleSticky(0, 6, 3, rows);
    try testing.expect(deep.sticky.file_idx != null);
    try testing.expect(deep.scroll <= 6);
    try testing.expect(6 < deep.scroll + (3 - deep.sticky.reserved()));

    // At top of list: no sticky.
    const top = ensureVisibleSticky(0, 0, 5, rows);
    try testing.expectEqual(0, top.scroll);
    try testing.expectEqual(0, top.sticky.reserved());

    const empty = ensureVisibleSticky(0, 0, 5, &.{});
    try testing.expectEqual(0, empty.scroll);
    try testing.expectEqual(0, empty.sticky.reserved());
}
