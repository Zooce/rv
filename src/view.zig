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
    },
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
/// if none). Unchanged when there is no later hunk.
pub fn nextHunk(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const search_from: usize = if (currentHunkStart(rows, cursor)) |s| s + 1 else 0;
    var i = search_from;
    while (i < rows.len) : (i += 1) {
        if (rows[i] == .hunk_header) return landOnHunk(rows, i);
    }
    return clampCursor(cursor, rows.len);
}

/// Jump to the previous hunk before the one containing `cursor`. Unchanged
/// when already on the first hunk (or before any hunk).
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
    try testing.expect(rows[3] == .line);
    try testing.expectEqual(diff.LineKind.add, rows[3].line.kind);
    try testing.expectEqualStrings("new", rows[3].line.text);
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
