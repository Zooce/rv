//! Side-by-side layout: preference vs terminal width, pane widths, pairing,
//! and slot stepping. Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;
const row_mod = @import("row.zig");
const Row = row_mod.Row;
const clampCursor = row_mod.clampCursor;

/// User layout preference for the session (not the forced narrow fallback).
///
/// - `side_by_side` (default): use two panes when the terminal is wide enough;
///   auto-fall back to unified when narrow; restore side-by-side on widen.
/// - `unified`: user explicitly chose unified; stay unified even when wide.
pub const LayoutPref = enum {
    side_by_side,
    unified,
};

/// What paint actually uses after applying preference + terminal width.
pub const EffectiveLayout = enum {
    side_by_side,
    unified,
};

/// Minimum usable content columns per side-by-side pane (text + gutter).
pub const min_pane_cols: usize = 24;

/// Center separator between the two panes (one column).
pub const sbs_gutter_cols: usize = 1;

/// Terminal content width below which side-by-side is not usable.
/// `2 * min_pane_cols + sbs_gutter_cols` (currently 49).
pub const min_side_by_side_cols: usize = min_pane_cols * 2 + sbs_gutter_cols;

/// Resolve paint layout from session preference and terminal column count.
///
/// `term_cols` is the full terminal width (same as `Size.cols`). When the
/// user prefers side-by-side but columns are below `min_side_by_side_cols`,
/// returns unified. Explicit unified preference always returns unified.
pub fn effectiveLayout(pref: LayoutPref, term_cols: usize) EffectiveLayout {
    return switch (pref) {
        .unified => .unified,
        .side_by_side => if (term_cols >= min_side_by_side_cols)
            .side_by_side
        else
            .unified,
    };
}

/// Flip session preference (side-by-side ↔ unified). Does not consider width;
/// call `effectiveLayout` after to see what paint will use.
pub fn toggleLayoutPref(pref: LayoutPref) LayoutPref {
    return switch (pref) {
        .side_by_side => .unified,
        .unified => .side_by_side,
    };
}

/// Left/right pane widths for a terminal of `cols` columns (1-cell gutter).
pub const SbsPanes = struct {
    left_w: u16,
    right_w: u16,
    /// Column index of the center gutter cell.
    gutter_x: u16,
};

/// Split `cols` into left | gutter | right. When `cols <= 1`, left takes all
/// columns and right/gutter are zero (not a usable side-by-side layout).
pub fn sbsPaneWidths(cols: u16) SbsPanes {
    if (cols <= 1) {
        return .{ .left_w = cols, .right_w = 0, .gutter_x = 0 };
    }
    const inner: u16 = cols - 1;
    const left: u16 = inner / 2;
    return .{
        .left_w = left,
        .right_w = inner - left,
        .gutter_x = left,
    };
}

/// One screen row in side-by-side layout. Indices refer into the unified
/// `rows` from `flatten` (same lifetime; slots do not own string data).
pub const SbsSlot = union(enum) {
    /// Full-width file, hunk, or section header.
    header: usize,
    /// Body: left pane (old) and/or right pane (new). Context uses the same
    /// index on both sides. An empty pane is `null`.
    pair: struct {
        left: ?usize = null,
        right: ?usize = null,
    },

    /// True when this slot references unified row `row_idx`.
    pub fn containsRow(self: SbsSlot, row_idx: usize) bool {
        return switch (self) {
            .header => |h| h == row_idx,
            .pair => |p| (if (p.left) |L| L == row_idx else false) or
                (if (p.right) |R| R == row_idx else false),
        };
    }
};

/// Primary unified row for cursor mapping: header index, else left, else right.
/// Pair slots always have at least one side set.
pub fn sbsPrimaryRow(slot: SbsSlot) usize {
    return switch (slot) {
        .header => |h| h,
        .pair => |p| p.left orelse p.right.?,
    };
}

/// Index of the first slot that contains unified row `row_idx`, or `null`.
pub fn sbsSlotForRow(slots: []const SbsSlot, row_idx: usize) ?usize {
    for (slots, 0..) |s, i| {
        if (s.containsRow(row_idx)) return i;
    }
    return null;
}

/// Move cursor to the primary unified row of the next side-by-side slot.
/// Unchanged when already on the last slot (or slots/rows empty).
pub fn nextSbsCursor(slots: []const SbsSlot, rows: []const Row, cursor: usize) usize {
    if (slots.len == 0 or rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    const si = sbsSlotForRow(slots, cur) orelse return cur;
    if (si + 1 >= slots.len) return cur;
    return sbsPrimaryRow(slots[si + 1]);
}

/// Move cursor to the primary unified row of the previous side-by-side slot.
/// Unchanged when already on the first slot (or slots/rows empty).
pub fn prevSbsCursor(slots: []const SbsSlot, rows: []const Row, cursor: usize) usize {
    if (slots.len == 0 or rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    const si = sbsSlotForRow(slots, cur) orelse return cur;
    if (si == 0) return cur;
    return sbsPrimaryRow(slots[si - 1]);
}

fn isDeleteLine(row: Row) bool {
    return switch (row) {
        .line => |ln| ln.kind == .delete,
        else => false,
    };
}

fn isAddLine(row: Row) bool {
    return switch (row) {
        .line => |ln| ln.kind == .add,
        else => false,
    };
}

/// Build side-by-side display slots from unified `rows`.
///
/// Pairing within a change run (git-style `-` then `+` block):
/// consecutive deletes followed by consecutive adds are zip-paired;
/// leftover deletes or adds alone get an empty opposite pane. Context
/// lines occupy both panes (same source row). Meta lines sit on the left
/// pane only (v1). File/hunk headers are full-width slots.
///
/// Caller owns the returned slice (`alloc.free`). Nested indices borrow `rows`.
pub fn pairSideBySide(alloc: Allocator, rows: []const Row) Allocator.Error![]SbsSlot {
    var out: std.ArrayList(SbsSlot) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < rows.len) {
        switch (rows[i]) {
            .file_header, .hunk_header, .section_header => {
                try out.append(alloc, .{ .header = i });
                i += 1;
            },
            .line => |ln| switch (ln.kind) {
                .context => {
                    try out.append(alloc, .{ .pair = .{ .left = i, .right = i } });
                    i += 1;
                },
                .meta => {
                    try out.append(alloc, .{ .pair = .{ .left = i, .right = null } });
                    i += 1;
                },
                .delete => {
                    const d0 = i;
                    while (i < rows.len and isDeleteLine(rows[i])) : (i += 1) {}
                    const d1 = i;
                    const a0 = i;
                    while (i < rows.len and isAddLine(rows[i])) : (i += 1) {}
                    const a1 = i;
                    const nd = d1 - d0;
                    const na = a1 - a0;
                    const n = @max(nd, na);
                    var j: usize = 0;
                    while (j < n) : (j += 1) {
                        try out.append(alloc, .{ .pair = .{
                            .left = if (j < nd) d0 + j else null,
                            .right = if (j < na) a0 + j else null,
                        } });
                    }
                },
                .add => {
                    // Pure inserts (no preceding deletes in this run).
                    const a0 = i;
                    while (i < rows.len and isAddLine(rows[i])) : (i += 1) {}
                    var j = a0;
                    while (j < i) : (j += 1) {
                        try out.append(alloc, .{ .pair = .{ .left = null, .right = j } });
                    }
                },
            },
        }
    }
    return try out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "min_side_by_side_cols formula" {
    try testing.expectEqual(min_pane_cols * 2 + sbs_gutter_cols, min_side_by_side_cols);
    try testing.expectEqual(49, min_side_by_side_cols);
}

test "sbsPaneWidths splits evenly with gutter" {
    const p = sbsPaneWidths(49);
    try testing.expectEqual(24, p.left_w);
    try testing.expectEqual(24, p.right_w);
    try testing.expectEqual(24, p.gutter_x);
    try testing.expectEqual(49, p.left_w + 1 + p.right_w);

    const odd = sbsPaneWidths(50);
    try testing.expectEqual(24, odd.left_w);
    try testing.expectEqual(25, odd.right_w);
    try testing.expectEqual(50, odd.left_w + 1 + odd.right_w);

    const tiny = sbsPaneWidths(1);
    try testing.expectEqual(1, tiny.left_w);
    try testing.expectEqual(0, tiny.right_w);
}

test "effectiveLayout prefers side-by-side when wide enough" {
    try testing.expectEqual(EffectiveLayout.side_by_side, effectiveLayout(.side_by_side, min_side_by_side_cols));
    try testing.expectEqual(EffectiveLayout.side_by_side, effectiveLayout(.side_by_side, 120));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.side_by_side, min_side_by_side_cols - 1));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.side_by_side, 0));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.side_by_side, 40));
}

test "effectiveLayout respects explicit unified preference" {
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.unified, 200));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.unified, min_side_by_side_cols));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.unified, 0));
}

test "toggleLayoutPref flips and restore uses side-by-side when wide" {
    try testing.expectEqual(LayoutPref.unified, toggleLayoutPref(.side_by_side));
    try testing.expectEqual(LayoutPref.side_by_side, toggleLayoutPref(.unified));

    // User forced unified → widen still unified.
    var pref = LayoutPref.side_by_side;
    pref = toggleLayoutPref(pref);
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(pref, 120));

    // Toggle back → side-by-side when wide, auto-unified when narrow.
    pref = toggleLayoutPref(pref);
    try testing.expectEqual(EffectiveLayout.side_by_side, effectiveLayout(pref, 120));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(pref, 30));
}

test "pairSideBySide empty" {
    const slots = try pairSideBySide(testing.allocator, &.{});
    defer testing.allocator.free(slots);
    try testing.expectEqual(0, slots.len);
}

test "pairSideBySide zips delete then add" {
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
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    // file, hunk, one paired body row (delete|add)
    try testing.expectEqual(3, slots.len);
    try testing.expectEqual(0, slots[0].header);
    try testing.expectEqual(1, slots[1].header);
    try testing.expectEqual(2, slots[2].pair.left.?);
    try testing.expectEqual(3, slots[2].pair.right.?);

    try testing.expectEqual(2, sbsSlotForRow(slots, 2).?);
    try testing.expectEqual(2, sbsSlotForRow(slots, 3).?);
    try testing.expectEqual(2, sbsPrimaryRow(slots[2]));
    try testing.expect(slots[2].containsRow(2));
    try testing.expect(slots[2].containsRow(3));
    try testing.expect(!slots[2].containsRow(0));
}

test "pairSideBySide context both panes same row" {
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
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    // 0 file, 1 hunk, 2 ctx, 3 del|add, 4 ctx
    try testing.expectEqual(5, slots.len);
    try testing.expectEqual(2, slots[2].pair.left.?);
    try testing.expectEqual(2, slots[2].pair.right.?);
    try testing.expectEqual(3, slots[3].pair.left.?);
    try testing.expectEqual(4, slots[3].pair.right.?);
    try testing.expectEqual(5, slots[4].pair.left.?);
    try testing.expectEqual(5, slots[4].pair.right.?);
}

test "pairSideBySide unequal change runs" {
    // 2 deletes + 1 add → pair then left-only leftover delete
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,2 +1 @@
        \\-a
        \\-b
        \\+c
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    try testing.expectEqual(4, slots.len); // file, hunk, pair, left-only
    try testing.expectEqual(2, slots[2].pair.left.?);
    try testing.expectEqual(4, slots[2].pair.right.?);
    try testing.expectEqual(3, slots[3].pair.left.?);
    try testing.expect(slots[3].pair.right == null);

    // 1 delete + 2 adds → pair then right-only leftover add
    const fixture2 =
        \\diff --git a/g b/g
        \\--- a/g
        \\+++ b/g
        \\@@ -1 +1,2 @@
        \\-x
        \\+y
        \\+z
    ;
    var d2 = try diff.parse(testing.allocator, fixture2);
    defer d2.deinit();
    const rows2 = try row_mod.flatten(testing.allocator, &d2);
    defer testing.allocator.free(rows2);
    const slots2 = try pairSideBySide(testing.allocator, rows2);
    defer testing.allocator.free(slots2);

    try testing.expectEqual(4, slots2.len);
    try testing.expectEqual(2, slots2[2].pair.left.?);
    try testing.expectEqual(3, slots2[2].pair.right.?);
    try testing.expect(slots2[3].pair.left == null);
    try testing.expectEqual(4, slots2[3].pair.right.?);
}

test "pairSideBySide pure adds and pure deletes" {
    const adds_only =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -0,0 +1,2 @@
        \\+a
        \\+b
    ;
    var d = try diff.parse(testing.allocator, adds_only);
    defer d.deinit();
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    try testing.expectEqual(4, slots.len);
    try testing.expect(slots[2].pair.left == null);
    try testing.expectEqual(2, slots[2].pair.right.?);
    try testing.expect(slots[3].pair.left == null);
    try testing.expectEqual(3, slots[3].pair.right.?);

    const dels_only =
        \\diff --git a/g b/g
        \\--- a/g
        \\+++ b/g
        \\@@ -1,2 +0,0 @@
        \\-a
        \\-b
    ;
    var d2 = try diff.parse(testing.allocator, dels_only);
    defer d2.deinit();
    const rows2 = try row_mod.flatten(testing.allocator, &d2);
    defer testing.allocator.free(rows2);
    const slots2 = try pairSideBySide(testing.allocator, rows2);
    defer testing.allocator.free(slots2);

    try testing.expectEqual(4, slots2.len);
    try testing.expectEqual(2, slots2[2].pair.left.?);
    try testing.expect(slots2[2].pair.right == null);
    try testing.expectEqual(3, slots2[3].pair.left.?);
    try testing.expect(slots2[3].pair.right == null);
}

test "pairSideBySide meta left only; slot lookup" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\\ No newline at end of file
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // file, hunk, del, meta, add — meta breaks the delete→add run
    try testing.expect(rows[3] == .line);
    try testing.expectEqual(diff.LineKind.meta, rows[3].line.kind);

    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    // file, hunk, left-only del, left-only meta, right-only add
    try testing.expectEqual(5, slots.len);
    try testing.expectEqual(2, slots[2].pair.left.?);
    try testing.expect(slots[2].pair.right == null);
    try testing.expectEqual(3, slots[3].pair.left.?);
    try testing.expect(slots[3].pair.right == null);
    try testing.expect(slots[4].pair.left == null);
    try testing.expectEqual(4, slots[4].pair.right.?);

    try testing.expectEqual(0, sbsSlotForRow(slots, 0).?);
    try testing.expectEqual(3, sbsSlotForRow(slots, 3).?);
    try testing.expect(sbsSlotForRow(slots, 99) == null);
}

test "nextSbsCursor and prevSbsCursor step by slot" {
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
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    // slots: file, hunk, ctx, del|add, ctx  (5 slots; rows 0..5)
    try testing.expectEqual(5, slots.len);

    // From file header → hunk header (primary = that header row).
    try testing.expectEqual(1, nextSbsCursor(slots, rows, 0));
    // From hunk → context row 2.
    try testing.expectEqual(2, nextSbsCursor(slots, rows, 1));
    // From context → paired change (primary = delete row 3, not add row 4).
    try testing.expectEqual(3, nextSbsCursor(slots, rows, 2));
    // From delete (or add in same slot) → tail context row 5 in one step.
    try testing.expectEqual(5, nextSbsCursor(slots, rows, 3));
    try testing.expectEqual(5, nextSbsCursor(slots, rows, 4));
    // Last slot stays put.
    try testing.expectEqual(5, nextSbsCursor(slots, rows, 5));

    try testing.expectEqual(3, prevSbsCursor(slots, rows, 5));
    try testing.expectEqual(2, prevSbsCursor(slots, rows, 3));
    try testing.expectEqual(2, prevSbsCursor(slots, rows, 4));
    try testing.expectEqual(0, prevSbsCursor(slots, rows, 0));
}
