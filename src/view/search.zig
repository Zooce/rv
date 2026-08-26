//! Substring search over diff body text and file-header paths.
//! Not comment next/prev. Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
const row_mod = @import("row.zig");
const Row = row_mod.Row;
const clampCursor = row_mod.clampCursor;
const rowMatches = row_mod.rowMatches;
const rowPathMatches = row_mod.rowPathMatches;

/// Result of a text search step. `wrapped` is true when the walk crossed
/// the end (or start) of the row list to find the hit.
pub const SearchHit = struct {
    index: usize,
    wrapped: bool,
};

/// First match at or after `cursor`, wrapping from the top if needed.
/// Empty query or no hits → `null`. Used when Enter commits a `/` query.
pub fn firstMatch(rows: []const Row, query: []const u8, cursor: usize) ?SearchHit {
    if (query.len == 0 or rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i < rows.len) : (i += 1) {
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = false };
    }
    i = 0;
    while (i < cur) : (i += 1) {
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = true };
    }
    return null;
}

/// Next match strictly after `cursor`, wrapping around to the start.
/// Unchanged semantics for the caller when `null` (no query / no hits).
pub fn nextMatch(rows: []const Row, query: []const u8, cursor: usize) ?SearchHit {
    if (query.len == 0 or rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    var i = cur + 1;
    while (i < rows.len) : (i += 1) {
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = false };
    }
    i = 0;
    while (i <= cur) : (i += 1) {
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = true };
    }
    return null;
}

/// Previous match strictly before `cursor`, wrapping around to the end.
/// A sole match on `cursor` returns that index with `wrapped = true`.
pub fn prevMatch(rows: []const Row, query: []const u8, cursor: usize) ?SearchHit {
    if (query.len == 0 or rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = false };
    }
    // Wrap: scan from the last row down through `cur` (inclusive).
    i = rows.len;
    while (i > cur) {
        i -= 1;
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = true };
    }
    return null;
}

/// First file-header path match at or after `cursor`, wrapping from the top.
/// Empty query or no hits → `null`. Multi-match: first hit from the cursor
/// (same walk as `firstMatch`).
pub fn firstPathMatch(rows: []const Row, query: []const u8, cursor: usize) ?SearchHit {
    if (query.len == 0 or rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i < rows.len) : (i += 1) {
        if (rowPathMatches(rows[i], query)) return .{ .index = i, .wrapped = false };
    }
    i = 0;
    while (i < cur) : (i += 1) {
        if (rowPathMatches(rows[i], query)) return .{ .index = i, .wrapped = true };
    }
    return null;
}

const testing = std.testing;

test "firstMatch nextMatch prevMatch wrap" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,4 +1,4 @@
        \\ alpha
        \\-beta
        \\+beta2
        \\ gamma alpha
        \\ tail
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk, 2 "alpha", 3 "beta", 4 "beta2", 5 "gamma alpha", 6 "tail"

    const first = firstMatch(rows, "alpha", 0).?;
    try testing.expectEqual(2, first.index);
    try testing.expect(!first.wrapped);

    // Inclusive of cursor when already on a match.
    try testing.expectEqual(2, firstMatch(rows, "alpha", 2).?.index);

    // From after first alpha → second (gamma alpha).
    const n1 = nextMatch(rows, "alpha", 2).?;
    try testing.expectEqual(5, n1.index);
    try testing.expect(!n1.wrapped);

    // Wrap from last alpha back to first.
    const n2 = nextMatch(rows, "alpha", 5).?;
    try testing.expectEqual(2, n2.index);
    try testing.expect(n2.wrapped);

    const p1 = prevMatch(rows, "alpha", 5).?;
    try testing.expectEqual(2, p1.index);
    try testing.expect(!p1.wrapped);

    const p2 = prevMatch(rows, "alpha", 2).?;
    try testing.expectEqual(5, p2.index);
    try testing.expect(p2.wrapped);

    try testing.expect(firstMatch(rows, "nope", 0) == null);
    try testing.expect(firstMatch(rows, "", 0) == null);
    // Headers not searchable.
    try testing.expect(firstMatch(rows, "@@", 0) == null);
}

test "firstPathMatch is file headers only" {
    const fixture =
        \\diff --git a/src/app/main.zig b/src/app/main.zig
        \\--- a/src/app/main.zig
        \\+++ b/src/app/main.zig
        \\@@ -1 +1 @@
        \\-oldMain
        \\+newMain
        \\diff --git a/src/view.zig b/src/view.zig
        \\--- a/src/view.zig
        \\+++ b/src/view.zig
        \\@@ -1 +1 @@
        \\-oldView
        \\+newView
        \\diff --git a/lib/util.zig b/lib/util.zig
        \\--- a/lib/util.zig
        \\+++ b/lib/util.zig
        \\@@ -1 +1 @@
        \\-oldUtil
        \\+newUtil
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 main hdr, 1 hunk, 2 del, 3 add,
    // 4 view hdr, 5 hunk, 6 del, 7 add,
    // 8 util hdr, 9 hunk, 10 del, 11 add

    const unique = firstPathMatch(rows, "util", 0).?;
    try testing.expectEqual(8, unique.index);
    try testing.expect(!unique.wrapped);

    // Inclusive of cursor when already on a matching header.
    try testing.expectEqual(0, firstPathMatch(rows, "src/", 0).?.index);

    // From after first src file → next src file (not wrap).
    const next_src = firstPathMatch(rows, "src/", 1).?;
    try testing.expectEqual(4, next_src.index);
    try testing.expect(!next_src.wrapped);

    // From past the last src file → wrap to the first.
    const wrap = firstPathMatch(rows, "src/", 5).?;
    try testing.expectEqual(0, wrap.index);
    try testing.expect(wrap.wrapped);

    try testing.expect(firstPathMatch(rows, "nope", 0) == null);
    try testing.expect(firstPathMatch(rows, "", 0) == null);
    // Body text is not a path hit.
    try testing.expect(firstPathMatch(rows, "oldMain", 0) == null);
}
