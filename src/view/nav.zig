//! Structural navigation: next/prev hunk, file, and change; status; cursor
//! mark/restore after reload. Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;
const row_mod = @import("row.zig");
const Row = row_mod.Row;
const clampCursor = row_mod.clampCursor;
const CommentSide = row_mod.CommentSide;

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
            .file_header, .section_header => return null,
            .line => {},
        }
        if (i == 0) return null;
        i -= 1;
    }
}

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
            .hunk_header, .file_header, .section_header => break,
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

/// True when `item` is an add or delete body line (not context/meta/headers).
fn isChangedLine(item: Row) bool {
    return switch (item) {
        .line => |ln| switch (ln.kind) {
            .add, .delete => true,
            .context, .meta => false,
        },
        .file_header, .hunk_header, .section_header => false,
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

/// Enough of a cursor to restore after a reload. `path` (and line numbers)
/// borrow from the `rows` passed to `cursorMarkAt`.
pub const CursorMark = struct {
    path: []const u8,
    side: ?CommentSide = null,
    line: ?u32 = null,
};

/// Snapshot of `cursor` for `restoreCursor`. `null` when `rows` is empty.
pub fn cursorMarkAt(rows: []const Row, cursor: usize) ?CursorMark {
    if (rows.len == 0) return null;
    const i = clampCursor(cursor, rows.len);
    switch (rows[i]) {
        .file_header => |fh| return .{ .path = fh.path },
        .section_header => return null,
        .hunk_header => {
            const fi = currentFileStart(rows, i) orelse return null;
            return switch (rows[fi]) {
                .file_header => |fh| .{ .path = fh.path },
                else => null,
            };
        },
        .line => |ln| {
            if (ln.new_no) |n| return .{ .path = ln.path, .side = .new, .line = n };
            if (ln.old_no) |n| return .{ .path = ln.path, .side = .old, .line = n };
            return .{ .path = ln.path };
        },
    }
}

/// Best-effort cursor after reload: same path + side + line, else that file's
/// header, else row 0.
pub fn restoreCursor(rows: []const Row, mark: CursorMark) usize {
    if (rows.len == 0) return 0;
    if (mark.side) |side| {
        if (mark.line) |line| {
            for (rows, 0..) |item, i| {
                switch (item) {
                    .line => |ln| {
                        if (!std.mem.eql(u8, ln.path, mark.path)) continue;
                        const no = switch (side) {
                            .old => ln.old_no,
                            .new => ln.new_no,
                        };
                        if (no == line) return i;
                    },
                    .file_header, .hunk_header, .section_header => {},
                }
            }
        }
    }
    for (rows, 0..) |item, i| {
        switch (item) {
            .file_header => |fh| if (std.mem.eql(u8, fh.path, mark.path)) return i,
            else => {},
        }
    }
    return 0;
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
            .line, .section_header => {},
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

const testing = std.testing;

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
    const rows = try row_mod.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
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
    const rows = try row_mod.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
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
    const rows = try row_mod.flatten(alloc, &d);
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

test "cursorMarkAt empty file hunk line" {
    try testing.expect(cursorMarkAt(&.{}, 0) == null);

    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk, 2 keep, 3 del, 4 add, 5 tail

    const file = cursorMarkAt(rows, 0).?;
    try testing.expectEqualStrings("f", file.path);
    try testing.expect(file.side == null);
    try testing.expect(file.line == null);

    const hunk = cursorMarkAt(rows, 1).?;
    try testing.expectEqualStrings("f", hunk.path);
    try testing.expect(hunk.side == null);
    try testing.expect(hunk.line == null);

    const ctx = cursorMarkAt(rows, 2).?;
    try testing.expectEqualStrings("f", ctx.path);
    try testing.expectEqual(.new, ctx.side.?);
    try testing.expectEqual(1, ctx.line.?);

    const del = cursorMarkAt(rows, 3).?;
    try testing.expectEqual(.old, del.side.?);
    try testing.expectEqual(2, del.line.?);

    const add = cursorMarkAt(rows, 4).?;
    try testing.expectEqual(.new, add.side.?);
    try testing.expectEqual(2, add.line.?);
}

test "restoreCursor exact file fallback gone" {
    try testing.expectEqual(0, restoreCursor(&.{}, .{ .path = "f" }));

    const before =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
        \\diff --git a/g b/g
        \\--- a/g
        \\+++ b/g
        \\@@ -1 +1 @@
        \\-gone
        \\+here
    ;
    var d0 = try diff.parse(testing.allocator, before);
    defer d0.deinit();
    const old_rows = try row_mod.flatten(testing.allocator, &d0);
    defer testing.allocator.free(old_rows);
    // f: 0 file, 1 hunk, 2 keep, 3 del, 4 add, 5 tail
    // g: 6 file, 7 hunk, 8 del, 9 add

    const after =
        \\diff --git a/e b/e
        \\--- a/e
        \\+++ b/e
        \\@@ -1 +1 @@
        \\-x
        \\+y
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
    ;
    var d1 = try diff.parse(testing.allocator, after);
    defer d1.deinit();
    const new_rows = try row_mod.flatten(testing.allocator, &d1);
    defer testing.allocator.free(new_rows);
    // e: 0 file, 1 hunk, 2 del, 3 add
    // f: 4 file, 5 hunk, 6 keep, 7 del, 8 add, 9 tail

    try testing.expectEqual(8, restoreCursor(new_rows, cursorMarkAt(old_rows, 4).?));
    try testing.expectEqual(4, restoreCursor(new_rows, cursorMarkAt(old_rows, 0).?));
    try testing.expectEqual(4, restoreCursor(new_rows, cursorMarkAt(old_rows, 1).?));
    try testing.expectEqual(0, restoreCursor(new_rows, cursorMarkAt(old_rows, 6).?));
    try testing.expectEqual(0, restoreCursor(new_rows, .{ .path = "gone" }));
}
