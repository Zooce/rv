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
