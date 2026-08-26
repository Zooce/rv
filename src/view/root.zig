//! Display/review-list topic: comment helpers on rows.
//! Row model is `row.zig`; viewport is `viewport.zig`; side-by-side layout
//! is `layout.zig`; structural nav is `nav.zig`; search is `search.zig`.
//! Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;

pub const row = @import("row.zig");
pub const viewport = @import("viewport.zig");
pub const layout = @import("layout.zig");
pub const nav = @import("nav.zig");
pub const search = @import("search.zig");

/// Line-comment target for `want` at `cursor`, or null if that side is missing.
/// Unified: current row only. Side-by-side: current slot left (`old`) / right (`new`).
/// Returned Anchor carries only the chosen side’s line number.
pub fn commentAnchor(
    rows: []const row.Row,
    slots: []const layout.SbsSlot,
    effective: layout.EffectiveLayout,
    cursor: usize,
    want: row.CommentSide,
) ?row.Anchor {
    if (rows.len == 0) return null;
    const cur = row.clampCursor(cursor, rows.len);
    const src: usize = switch (effective) {
        .unified => cur,
        .side_by_side => blk: {
            const si = layout.sbsSlotForRow(slots, cur) orelse return null;
            switch (slots[si]) {
                .header => return null,
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
    const a = row.anchorAt(rows, src) orelse return null;
    return switch (want) {
        .old => if (a.old_line) |n| .{
            .path = a.path,
            .old_line = n,
            .new_line = null,
        } else null,
        .new => if (a.new_line) |n| .{
            .path = a.path,
            .old_line = null,
            .new_line = n,
        } else null,
    };
}

/// Path + side + line of a live comment. `line` is that side's 1-based number.
pub const CommentLoc = struct {
    path: []const u8,
    side: row.CommentSide,
    line: u32,
};

/// Unified row that holds `loc`, or null if that path/side/line is not in `rows`.
pub fn rowForComment(rows: []const row.Row, loc: CommentLoc) ?usize {
    for (rows, 0..) |item, i| {
        switch (item) {
            .line => |ln| {
                if (!std.mem.eql(u8, ln.path, loc.path)) continue;
                const no = switch (loc.side) {
                    .old => ln.old_no,
                    .new => ln.new_no,
                };
                if (no == loc.line) return i;
            },
            .file_header, .hunk_header, .section_header => {},
        }
    }
    return null;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test {
    _ = row;
    _ = viewport;
    _ = layout;
    _ = nav;
    _ = search;
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

    try testing.expectEqualStrings("", nav.statusAt(rows, 0).path);
    try testing.expectEqualStrings("a", nav.statusAt(rows, 5).path);
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

    try testing.expect(commentAnchor(rows, empty, .unified, 0, .new) == null);
    try testing.expect(commentAnchor(rows, empty, .unified, 0, .old) == null);
    try testing.expect(commentAnchor(rows, empty, .unified, 1, .new) == null);
    try testing.expect(commentAnchor(rows, empty, .unified, 1, .old) == null);

    const ctx_new = commentAnchor(rows, empty, .unified, 2, .new).?;
    try testing.expectEqualStrings("f", ctx_new.path);
    try testing.expectEqual(1, ctx_new.new_line.?);
    try testing.expect(ctx_new.old_line == null);
    const ctx_old = commentAnchor(rows, empty, .unified, 2, .old).?;
    try testing.expectEqual(1, ctx_old.old_line.?);
    try testing.expect(ctx_old.new_line == null);

    try testing.expect(commentAnchor(rows, empty, .unified, 3, .new) == null);
    const del = commentAnchor(rows, empty, .unified, 3, .old).?;
    try testing.expectEqual(2, del.old_line.?);
    try testing.expect(del.new_line == null);

    const add = commentAnchor(rows, empty, .unified, 4, .new).?;
    try testing.expectEqual(2, add.new_line.?);
    try testing.expect(add.old_line == null);
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

    try testing.expect(commentAnchor(rows, slots, .side_by_side, 0, .new) == null);
    try testing.expect(commentAnchor(rows, slots, .side_by_side, 0, .old) == null);
    try testing.expect(commentAnchor(rows, slots, .side_by_side, 1, .new) == null);
    try testing.expect(commentAnchor(rows, slots, .side_by_side, 1, .old) == null);

    // Cursor on the delete (slot primary) or the add (same slot) → same sides.
    const from_del_new = commentAnchor(rows, slots, .side_by_side, 2, .new).?;
    try testing.expectEqualStrings("f", from_del_new.path);
    try testing.expectEqual(1, from_del_new.new_line.?);
    try testing.expect(from_del_new.old_line == null);
    const from_del_old = commentAnchor(rows, slots, .side_by_side, 2, .old).?;
    try testing.expectEqual(1, from_del_old.old_line.?);
    try testing.expect(from_del_old.new_line == null);
    const from_add_new = commentAnchor(rows, slots, .side_by_side, 3, .new).?;
    try testing.expectEqual(1, from_add_new.new_line.?);
    try testing.expect(from_add_new.old_line == null);
    const from_add_old = commentAnchor(rows, slots, .side_by_side, 3, .old).?;
    try testing.expectEqual(1, from_add_old.old_line.?);
    try testing.expect(from_add_old.new_line == null);

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
    try testing.expectEqual(2, left_only.old_line.?);
    try testing.expect(left_only.new_line == null);

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
    try testing.expectEqual(2, right_only.new_line.?);
    try testing.expect(right_only.old_line == null);
    try testing.expect(commentAnchor(rows3, slots3, .side_by_side, 4, .old) == null);

    try testing.expect(commentAnchor(&.{}, &.{}, .side_by_side, 0, .new) == null);
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

    try testing.expectEqual(3, rowForComment(rows, .{ .path = "f", .side = .old, .line = 2 }).?);
    try testing.expectEqual(4, rowForComment(rows, .{ .path = "f", .side = .new, .line = 2 }).?);
    try testing.expectEqual(2, rowForComment(rows, .{ .path = "f", .side = .old, .line = 1 }).?);
    try testing.expectEqual(2, rowForComment(rows, .{ .path = "f", .side = .new, .line = 1 }).?);
    try testing.expect(rowForComment(rows, .{ .path = "f", .side = .new, .line = 99 }) == null);
    try testing.expect(rowForComment(rows, .{ .path = "gone", .side = .old, .line = 2 }) == null);
    try testing.expect(rowForComment(&.{}, .{ .path = "f", .side = .new, .line = 1 }) == null);
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
    try testing.expectEqual(2, rowForComment(rows, .{ .path = "f", .side = .old, .line = 1 }).?);
    try testing.expectEqual(3, rowForComment(rows, .{ .path = "f", .side = .new, .line = 1 }).?);
}

