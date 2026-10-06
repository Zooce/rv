//! Display/review-list topic: comment helpers on rows.
//! Row model is `row.zig`; window math is `window.zig`; side-by-side layout
//! is `layout.zig`; structural nav is `nav.zig`; search is `search.zig`;
//! body wrap is `wrap.zig` (a tab uses the screen's 4-column stops). No terminal drawing.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;

pub const row = @import("row.zig");
pub const window = @import("window.zig");
pub const layout = @import("layout.zig");
pub const nav = @import("nav.zig");
pub const search = @import("search.zig");
pub const wrap = @import("wrap.zig");

/// Comment target for `want` at `cursor`, or null if that side is missing.
/// File header: path-only (both sides the same). Hunk header: both starts,
/// no side (old and new keys are the same). Unified: current row.
/// Side-by-side: slot left (`old`) / right (`new`); file-header, hunk-header,
/// and full-width body slots use the row itself. Section headers are not
/// commentable. Line anchors carry only the chosen side’s line number.
pub fn commentAnchor(
    rows: []const row.Row,
    slots: []const layout.SbsSlot,
    effective: layout.EffectiveLayout,
    cursor: usize,
    want: row.CommentSide,
) ?row.DiffLoc {
    if (rows.len == 0) return null;
    const cur = row.clampCursor(cursor, rows.len);
    const src: usize = switch (effective) {
        .unified => cur,
        .side_by_side => blk: {
            const si = layout.sbsSlotForRow(slots, cur) orelse return null;
            switch (slots[si]) {
                .header, .body => |hi| break :blk hi,
                .pair => |p| {
                    const pane: ?usize = switch (want) {
                        .old => p.left,
                        .new => p.right,
                    };
                    break :blk pane orelse return null;
                },
            }
        },
    };
    switch (rows[src]) {
        .file_header => |fh| return .{ .file = fh.path },
        .hunk_header => |hh| return .{
            .hunk = .{ .path = hh.path, .old_start = hh.old_start, .new_start = hh.new_start },
        },
        else => {},
    }
    const a = row.anchorAt(rows, src) orelse return null;
    return switch (want) {
        .old => if (a.old_line) |n| .{
            .line = .{ .path = a.path, .side = .old, .line = n },
        } else null,
        .new => if (a.new_line) |n| .{
            .line = .{ .path = a.path, .side = .new, .line = n },
        } else null,
    };
}

pub const DiffLoc = row.DiffLoc;
pub const rowForComment = row.rowForComment;

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test {
    _ = row;
    _ = window;
    _ = layout;
    _ = nav;
    _ = search;
    _ = wrap;
}

fn threeGroupFixture(alloc: Allocator) !struct { d: diff.Diff, rows: []row.Row } {
    const unstaged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const untracked_txt =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    const staged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1,2 @@
        \\ same
        \\+staged
    ;
    var d = try diff.parsePieces(alloc, &.{
        .{ .text = unstaged_txt, .group = .unstaged },
        .{ .text = untracked_txt, .group = .untracked },
        .{ .text = staged_txt, .group = .staged },
    });
    errdefer d.deinit();
    const rows = try row.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "flatten inserts section headers at group boundaries" {
    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    // Unstaged (1) + file/hunk/del/add (4) + Untracked (1) + file/hunk/add (3)
    // + Staged (1) + file/hunk/ctx/add (4) = 14.
    try testing.expectEqual(14, rows.len);

    try testing.expectEqual(diff.Group.unstaged, rows[0].section_header);
    try testing.expectEqualStrings("a", rows[1].file_header.path);

    try testing.expectEqual(diff.Group.untracked, rows[5].section_header);
    try testing.expectEqualStrings("u", rows[6].file_header.path);

    try testing.expectEqual(diff.Group.staged, rows[9].section_header);
    try testing.expectEqualStrings("a", rows[10].file_header.path);

    const slots = try layout.pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    for ([_]usize{ 0, 5, 9 }) |ri| {
        const si = layout.sbsSlotForRow(slots, ri).?;
        try testing.expect(slots[si] == .header);
        try testing.expectEqual(ri, slots[si].header);
    }

    try testing.expectEqual(1, nav.nextFileHeader(rows, 0));
    try testing.expectEqual(6, nav.nextFileHeader(rows, 1));
    try testing.expectEqual(6, nav.nextFileHeader(rows, 5));
    try testing.expectEqual(10, nav.nextFileHeader(rows, 6));
    try testing.expectEqual(6, nav.prevFileHeader(rows, 9));
    try testing.expectEqual(6, nav.prevFileHeader(rows, 10));
    try testing.expectEqual(1, nav.prevFileHeader(rows, 6));
    try testing.expectEqual(1, nav.prevFileHeader(rows, 5));

    try testing.expectEqualStrings("", nav.cursorLocAt(rows, 0).path);
    try testing.expectEqualStrings("a", nav.cursorLocAt(rows, 5).path);
    try testing.expect(nav.currentHunkInFile(rows, 0) == null);
    try testing.expect(nav.currentHunkInFile(rows, 5) == null);
    try testing.expect(row.anchorAt(rows, 0) == null);
    try testing.expect(row.searchText(rows[0]) == null);
    try testing.expect(row.searchPath(rows[0]) == null);
}

test "commentAnchor unified add delete context header" {
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
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const empty: []const layout.SbsSlot = &.{};

    const file_new = commentAnchor(rows, empty, .unified, 0, .new).?;
    try testing.expectEqualStrings("f", file_new.file);
    const file_old = commentAnchor(rows, empty, .unified, 0, .old).?;
    try testing.expectEqualStrings("f", file_old.file);
    const hunk_new = commentAnchor(rows, empty, .unified, 1, .new).?;
    try testing.expectEqualStrings("f", hunk_new.hunk.path);
    try testing.expectEqual(1, hunk_new.hunk.old_start);
    try testing.expectEqual(1, hunk_new.hunk.new_start);
    const hunk_old = commentAnchor(rows, empty, .unified, 1, .old).?;
    try testing.expectEqual(1, hunk_old.hunk.old_start);
    try testing.expectEqual(1, hunk_old.hunk.new_start);

    const ctx_new = commentAnchor(rows, empty, .unified, 2, .new).?;
    try testing.expectEqualStrings("f", ctx_new.line.path);
    try testing.expectEqual(.new, ctx_new.line.side);
    try testing.expectEqual(1, ctx_new.line.line);
    const ctx_old = commentAnchor(rows, empty, .unified, 2, .old).?;
    try testing.expectEqual(.old, ctx_old.line.side);
    try testing.expectEqual(1, ctx_old.line.line);

    try testing.expect(commentAnchor(rows, empty, .unified, 3, .new) == null);
    const del = commentAnchor(rows, empty, .unified, 3, .old).?;
    try testing.expectEqual(.old, del.line.side);
    try testing.expectEqual(2, del.line.line);

    const add = commentAnchor(rows, empty, .unified, 4, .new).?;
    try testing.expectEqual(.new, add.line.side);
    try testing.expectEqual(2, add.line.line);
    try testing.expect(commentAnchor(rows, empty, .unified, 4, .old) == null);

    try testing.expect(commentAnchor(&.{}, empty, .unified, 0, .new) == null);
    try testing.expect(commentAnchor(&.{}, empty, .unified, 0, .old) == null);
}

test "commentAnchor side-by-side pair empty pane header" {
    const pair_fix =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, pair_fix);
    defer d.deinit();
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try layout.pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    const file_new = commentAnchor(rows, slots, .side_by_side, 0, .new).?;
    try testing.expectEqualStrings("f", file_new.file);
    const file_old = commentAnchor(rows, slots, .side_by_side, 0, .old).?;
    try testing.expectEqualStrings("f", file_old.file);
    const hunk_new = commentAnchor(rows, slots, .side_by_side, 1, .new).?;
    try testing.expectEqualStrings("f", hunk_new.hunk.path);
    try testing.expectEqual(1, hunk_new.hunk.old_start);
    try testing.expectEqual(1, hunk_new.hunk.new_start);
    const hunk_old = commentAnchor(rows, slots, .side_by_side, 1, .old).?;
    try testing.expectEqual(1, hunk_old.hunk.old_start);
    try testing.expectEqual(1, hunk_old.hunk.new_start);

    // Cursor on the delete (slot primary) or the add (same slot) → same sides.
    const from_del_new = commentAnchor(rows, slots, .side_by_side, 2, .new).?;
    try testing.expectEqualStrings("f", from_del_new.line.path);
    try testing.expectEqual(.new, from_del_new.line.side);
    try testing.expectEqual(1, from_del_new.line.line);
    const from_del_old = commentAnchor(rows, slots, .side_by_side, 2, .old).?;
    try testing.expectEqual(.old, from_del_old.line.side);
    try testing.expectEqual(1, from_del_old.line.line);
    const from_add_new = commentAnchor(rows, slots, .side_by_side, 3, .new).?;
    try testing.expectEqual(.new, from_add_new.line.side);
    try testing.expectEqual(1, from_add_new.line.line);
    const from_add_old = commentAnchor(rows, slots, .side_by_side, 3, .old).?;
    try testing.expectEqual(.old, from_add_old.line.side);
    try testing.expectEqual(1, from_add_old.line.line);

    const leftover =
        \\diff --git a/g b/g
        \\--- a/g
        \\+++ b/g
        \\@@ -1,2 +1 @@
        \\-a
        \\-b
        \\+c
    ;
    var d2 = try diff.parse(testing.allocator, leftover);
    defer d2.deinit();
    const rows2 = try row.flatten(testing.allocator, &d2);
    defer testing.allocator.free(rows2);
    const slots2 = try layout.pairSideBySide(testing.allocator, rows2);
    defer testing.allocator.free(slots2);
    // leftover delete `b` is left-only (row 3)
    try testing.expect(commentAnchor(rows2, slots2, .side_by_side, 3, .new) == null);
    const left_only = commentAnchor(rows2, slots2, .side_by_side, 3, .old).?;
    try testing.expectEqual(.old, left_only.line.side);
    try testing.expectEqual(2, left_only.line.line);

    const leftover_add =
        \\diff --git a/h b/h
        \\--- a/h
        \\+++ b/h
        \\@@ -1 +1,2 @@
        \\-x
        \\+y
        \\+z
    ;
    var d3 = try diff.parse(testing.allocator, leftover_add);
    defer d3.deinit();
    const rows3 = try row.flatten(testing.allocator, &d3);
    defer testing.allocator.free(rows3);
    const slots3 = try layout.pairSideBySide(testing.allocator, rows3);
    defer testing.allocator.free(slots3);
    // leftover add `z` is right-only (row 4)
    const right_only = commentAnchor(rows3, slots3, .side_by_side, 4, .new).?;
    try testing.expectEqual(.new, right_only.line.side);
    try testing.expectEqual(2, right_only.line.line);
    try testing.expect(commentAnchor(rows3, slots3, .side_by_side, 4, .old) == null);

    try testing.expect(commentAnchor(&.{}, &.{}, .side_by_side, 0, .new) == null);
}

test "commentAnchor side-by-side one-sided body" {
    const added =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d = try diff.parse(testing.allocator, added);
    defer d.deinit();
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try layout.pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    try testing.expect(slots[2] == .body);

    const file = commentAnchor(rows, slots, .side_by_side, 0, .new).?;
    try testing.expectEqualStrings("new.txt", file.file);
    try testing.expect(commentAnchor(rows, slots, .side_by_side, 2, .old) == null);
    const add = commentAnchor(rows, slots, .side_by_side, 2, .new).?;
    try testing.expectEqualStrings("new.txt", add.line.path);
    try testing.expectEqual(.new, add.line.side);
    try testing.expectEqual(1, add.line.line);

    const deleted =
        \\diff --git a/gone.txt b/gone.txt
        \\deleted file mode 100644
        \\--- a/gone.txt
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-bye
    ;
    var d2 = try diff.parse(testing.allocator, deleted);
    defer d2.deinit();
    const rows2 = try row.flatten(testing.allocator, &d2);
    defer testing.allocator.free(rows2);
    const slots2 = try layout.pairSideBySide(testing.allocator, rows2);
    defer testing.allocator.free(slots2);
    try testing.expect(slots2[2] == .body);

    try testing.expect(commentAnchor(rows2, slots2, .side_by_side, 2, .new) == null);
    const del = commentAnchor(rows2, slots2, .side_by_side, 2, .old).?;
    try testing.expectEqualStrings("gone.txt", del.line.path);
    try testing.expectEqual(.old, del.line.side);
    try testing.expectEqual(1, del.line.line);
}

test "rowForComment add delete context missing" {
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
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk, 2 keep, 3 del, 4 add, 5 tail

    try testing.expectEqual(3, rowForComment(rows, .{ .line = .{ .path = "f", .side = .old, .line = 2 } }).?);
    try testing.expectEqual(4, rowForComment(rows, .{ .line = .{ .path = "f", .side = .new, .line = 2 } }).?);
    try testing.expectEqual(2, rowForComment(rows, .{ .line = .{ .path = "f", .side = .old, .line = 1 } }).?);
    try testing.expectEqual(2, rowForComment(rows, .{ .line = .{ .path = "f", .side = .new, .line = 1 } }).?);
    try testing.expect(rowForComment(rows, .{ .line = .{ .path = "f", .side = .new, .line = 99 } }) == null);
    try testing.expect(rowForComment(rows, .{ .line = .{ .path = "gone", .side = .old, .line = 2 } }) == null);
    try testing.expect(rowForComment(&.{}, .{ .line = .{ .path = "f", .side = .new, .line = 1 } }) == null);
}

test "rowForComment new side is not the pair's primary row" {
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
    const slots = try layout.pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    // 0 file, 1 hunk, 2 del, 3 add — one pair slot, primary is the delete.
    const pair_i = layout.sbsSlotForRow(slots, 2).?;
    try testing.expectEqual(2, layout.sbsPrimaryRow(slots[pair_i]));
    try testing.expectEqual(2, rowForComment(rows, .{ .line = .{ .path = "f", .side = .old, .line = 1 } }).?);
    try testing.expectEqual(3, rowForComment(rows, .{ .line = .{ .path = "f", .side = .new, .line = 1 } }).?);
}

test "rowForComment path-only lands on file header" {
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
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk, 2 keep, 3 del, 4 add, 5 tail

    try testing.expectEqual(0, rowForComment(rows, .{ .file = "f" }).?);
    try testing.expect(rowForComment(rows, .{ .file = "gone" }) == null);
    try testing.expectEqual(4, rowForComment(rows, .{ .line = .{ .path = "f", .side = .new, .line = 2 } }).?);
}

test "rowForComment hunk lands on header not body" {
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
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk @@ -1,3 +1,3, 2 keep, 3 del, 4 add, 5 tail

    try testing.expectEqual(1, rowForComment(rows, .{
        .hunk = .{ .path = "f", .old_start = 1, .new_start = 1 },
    }).?);
    try testing.expectEqual(2, rowForComment(rows, .{ .line = .{ .path = "f", .side = .old, .line = 1 } }).?);
    try testing.expectEqual(2, rowForComment(rows, .{ .line = .{ .path = "f", .side = .new, .line = 1 } }).?);
    try testing.expect(rowForComment(rows, .{
        .hunk = .{ .path = "f", .old_start = 99, .new_start = 1 },
    }) == null);
    try testing.expect(rowForComment(rows, .{
        .hunk = .{ .path = "gone", .old_start = 1, .new_start = 1 },
    }) == null);
}

test "commentAnchor binary and section header" {
    const binary =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var d = try diff.parse(testing.allocator, binary);
    defer d.deinit();
    const rows = try row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const empty: []const layout.SbsSlot = &.{};
    const slots = try layout.pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    const uni = commentAnchor(rows, empty, .unified, 0, .new).?;
    try testing.expectEqualStrings("pic.png", uni.file);
    const sbs = commentAnchor(rows, slots, .side_by_side, 0, .old).?;
    try testing.expectEqualStrings("pic.png", sbs.file);

    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    try testing.expect(commentAnchor(fix.rows, empty, .unified, 0, .new) == null);
    try testing.expect(commentAnchor(fix.rows, empty, .unified, 0, .old) == null);
    const grouped = commentAnchor(fix.rows, empty, .unified, 1, .new).?;
    try testing.expectEqualStrings("a", grouped.file);
}
