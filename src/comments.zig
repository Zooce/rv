//! Live-comment location, next/prev walk, remap after the diff changes,
//! file/hunk matching, and the live comment on a cursor side. Persistence is
//! `store`. Rows answer which row holds a location (`view.rowForComment`) and
//! the open-comment target (`view.commentAnchor`). The parsed diff is a tool
//! for remap and file/hunk matching.

const std = @import("std");
const store = @import("store");
const view = @import("view");
const diff = @import("diff");

/// Display target for a live comment. File: path only. Hunk: both starts, no
/// side. Line: side + line. Null when resolved, or when the store row has no
/// usable loc.
pub fn loc(c: store.Comment) ?view.CommentLoc {
    if (c.state != .open) return null;
    if (c.old_line == null and c.new_line == null) {
        if (c.side != null) return null;
        return .{ .path = c.path };
    }
    if (c.side == null) {
        if (c.old_line) |o| {
            if (c.new_line) |n| return .{
                .path = c.path,
                .hunk = .{ .old_start = o, .new_start = n },
            };
        }
    }
    if (c.side) |s| {
        switch (s) {
            .old => if (c.old_line) |n| return .{ .path = c.path, .side = .old, .line = n },
            .new => if (c.new_line) |n| return .{ .path = c.path, .side = .new, .line = n },
            .context => {
                if (c.new_line) |n| return .{ .path = c.path, .side = .new, .line = n };
                if (c.old_line) |n| return .{ .path = c.path, .side = .old, .line = n };
            },
        }
        return null;
    }
    if (c.new_line) |n| return .{ .path = c.path, .side = .new, .line = n };
    if (c.old_line) |n| return .{ .path = c.path, .side = .old, .line = n };
    return null;
}

/// Next/prev live-comment landing: display row, and whether the walk wrapped.
pub const Walk = struct {
    row: usize,
    wrapped: bool,
};

/// Display order: row, then old before new, then store order.
const Rank = struct {
    row: usize,
    side: u1,
    i: usize,

    fn less(a: Rank, b: Rank) bool {
        if (a.row != b.row) return a.row < b.row;
        if (a.side != b.side) return a.side < b.side;
        return a.i < b.i;
    }
};

fn rankOf(c: store.Comment, i: usize, rows: []const view.row.Row) ?Rank {
    const found = loc(c) orelse return null;
    const row = view.rowForComment(rows, found) orelse return null;
    const side: u1 = if (found.side) |s| switch (s) {
        .old => 0,
        .new => 1,
    } else 0;
    return .{
        .row = row,
        .side = side,
        .i = i,
    };
}

/// Next live comment strictly after `cursor` in display order. Wraps to the
/// first comment when none follow. Null when no live comment resolves to a row.
pub fn next(review: *const store.Review, rows: []const view.row.Row, cursor: usize) ?Walk {
    if (rows.len == 0 or review.comments.items.len == 0) return null;
    const cur = view.row.clampCursor(cursor, rows.len);
    var best_after: ?Rank = null;
    var best_wrap: ?Rank = null;
    for (review.comments.items, 0..) |c, i| {
        const rank = rankOf(c, i, rows) orelse continue;
        if (rank.row > cur) {
            if (best_after == null or rank.less(best_after.?)) best_after = rank;
        } else {
            if (best_wrap == null or rank.less(best_wrap.?)) best_wrap = rank;
        }
    }
    if (best_after) |r| return .{ .row = r.row, .wrapped = false };
    if (best_wrap) |r| return .{ .row = r.row, .wrapped = true };
    return null;
}

/// Previous live comment strictly before `cursor` in display order. Wraps to
/// the last comment when none precede. Null when no live comment resolves to a row.
pub fn prev(review: *const store.Review, rows: []const view.row.Row, cursor: usize) ?Walk {
    if (rows.len == 0 or review.comments.items.len == 0) return null;
    const cur = view.row.clampCursor(cursor, rows.len);
    var best_before: ?Rank = null;
    var best_wrap: ?Rank = null;
    for (review.comments.items, 0..) |c, i| {
        const rank = rankOf(c, i, rows) orelse continue;
        if (rank.row < cur) {
            if (best_before == null or best_before.?.less(rank)) best_before = rank;
        } else {
            if (best_wrap == null or best_wrap.?.less(rank)) best_wrap = rank;
        }
    }
    if (best_before) |r| return .{ .row = r.row, .wrapped = false };
    if (best_wrap) |r| return .{ .row = r.row, .wrapped = true };
    return null;
}

/// Prior line/side for a comment remapped after stage/unstage (save-failure restore).
pub const AnchorSnap = struct {
    id: []const u8,
    old_line: ?u32,
    new_line: ?u32,
    side: ?store.Side,
};

const RemapAnchor = struct {
    old_line: ?u32,
    new_line: ?u32,
    side: ?store.Side,
};

fn hunkBodyEql(a: []const diff.Line, b: []const diff.Line) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.kind != y.kind) return false;
        if (!std.mem.eql(u8, x.text, y.text)) return false;
    }
    return true;
}

fn commentSide(c: store.Comment) store.Side {
    return c.side orelse if (c.new_line != null) .new else .old;
}

fn lineOnSide(ln: diff.Line, side: store.Side) bool {
    return switch (side) {
        .old => ln.old_no != null,
        .new => ln.new_no != null,
        .context => ln.old_no != null and ln.new_no != null,
    };
}

fn commentLineIndex(c: store.Comment, hunk: diff.Hunk) ?usize {
    const side = commentSide(c);
    for (hunk.lines, 0..) |ln, i| {
        const old_hit = blk: {
            const o = c.old_line orelse break :blk false;
            const lo = ln.old_no orelse break :blk false;
            break :blk lo == o;
        };
        const new_hit = blk: {
            const n = c.new_line orelse break :blk false;
            const nn = ln.new_no orelse break :blk false;
            break :blk nn == n;
        };
        const hit = switch (side) {
            .old => old_hit,
            .new => new_hit,
            .context => old_hit or new_hit,
        };
        if (hit) return i;
    }
    return null;
}

fn destHunk(
    dest: *const diff.Diff,
    path: []const u8,
    body: []const diff.Line,
) ?diff.Hunk {
    for (dest.files) |f| {
        if (!std.mem.eql(u8, f.displayPath(), path)) continue;
        for (f.hunks) |h| {
            if (hunkBodyEql(h.lines, body)) return h;
        }
    }
    return null;
}

fn destLineByText(
    dest: *const diff.Diff,
    path: []const u8,
    side: store.Side,
    text: []const u8,
) ?diff.Line {
    var found: ?diff.Line = null;
    for (dest.files) |f| {
        if (!std.mem.eql(u8, f.displayPath(), path)) continue;
        for (f.hunks) |h| {
            for (h.lines) |ln| {
                if (!lineOnSide(ln, side)) continue;
                if (!std.mem.eql(u8, ln.text, text)) continue;
                if (found != null) return null;
                found = ln;
            }
        }
    }
    return found;
}

fn remapAnchorFromLine(ln: diff.Line, side: store.Side) ?RemapAnchor {
    return switch (side) {
        .new => .{ .old_line = null, .new_line = ln.new_no orelse return null, .side = .new },
        .old => .{ .old_line = ln.old_no orelse return null, .new_line = null, .side = .old },
        .context => if (ln.old_no == null and ln.new_no == null)
            null
        else
            .{ .old_line = ln.old_no, .new_line = ln.new_no, .side = .context },
    };
}

/// New path+line for `c` in `dest`, or null if this comment is not on `src_file`
/// / the chosen hunk, or the line is gone. Path-only (file) comments stay as-is.
/// Hunk comments (both starts, `side` null) rewrite to the dest hunk’s starts
/// and keep `side` null, or stay put when that hunk body is gone.
fn destAnchor(
    c: store.Comment,
    src_file: *const diff.File,
    dest: *const diff.Diff,
    hunk_i: ?usize,
) ?RemapAnchor {
    if (c.state != .open) return null;
    if (!std.mem.eql(u8, c.path, src_file.displayPath())) return null;
    if (c.old_line == null and c.new_line == null) return null;
    if (c.side == null) {
        if (c.old_line) |o| {
            if (c.new_line) |n| {
                const hi = hunk_i orelse blk: {
                    for (src_file.hunks, 0..) |h, i| {
                        if (h.old_start == o and h.new_start == n) break :blk i;
                    }
                    return null;
                };
                if (hi >= src_file.hunks.len) return null;
                const src_hunk = src_file.hunks[hi];
                if (src_hunk.old_start != o or src_hunk.new_start != n) return null;
                const dest_hunk = destHunk(dest, src_file.displayPath(), src_hunk.lines) orelse return null;
                return .{
                    .old_line = dest_hunk.old_start,
                    .new_line = dest_hunk.new_start,
                    .side = null,
                };
            }
        }
    }
    const hi = hunk_i orelse blk: {
        for (src_file.hunks, 0..) |h, i| {
            if (commentLineIndex(c, h) != null) break :blk i;
        }
        return null;
    };
    if (hi >= src_file.hunks.len) return null;
    const src_hunk = src_file.hunks[hi];
    const line_i = commentLineIndex(c, src_hunk) orelse return null;
    const src_ln = src_hunk.lines[line_i];
    if (src_ln.kind == .meta) return null;
    const side = commentSide(c);

    if (destHunk(dest, src_file.displayPath(), src_hunk.lines)) |dest_hunk| {
        if (line_i < dest_hunk.lines.len) {
            const ln = dest_hunk.lines[line_i];
            if (std.mem.eql(u8, ln.text, src_ln.text) and lineOnSide(ln, side)) {
                return remapAnchorFromLine(ln, side);
            }
        }
    }
    const dest_ln = destLineByText(dest, src_file.displayPath(), side, src_ln.text) orelse return null;
    return remapAnchorFromLine(dest_ln, side);
}

/// Re-anchor live comments on `src_file` (optionally one hunk) to `dest`.
/// Appends a snap for each successful `setLines` so the caller can restore
/// on save failure.
pub fn remapMatching(
    review: *store.Review,
    src_file: *const diff.File,
    dest: *const diff.Diff,
    hunk_i: ?usize,
    alloc: std.mem.Allocator,
    priors: *std.ArrayList(AnchorSnap),
) std.mem.Allocator.Error!void {
    for (review.comments.items) |c| {
        const mapped = destAnchor(c, src_file, dest, hunk_i) orelse continue;
        try priors.append(alloc, .{
            .id = c.id,
            .old_line = c.old_line,
            .new_line = c.new_line,
            .side = c.side,
        });
        review.setLines(c.id, mapped.old_line, mapped.new_line, mapped.side) catch {
            _ = priors.pop();
        };
    }
}

/// Snapshot of a comment removed during discard, for save-failure restore.
pub const RemoveSnap = struct {
    idx: usize,
    comment: store.Comment,
};

fn lineInHunkRange(line: ?u32, start: u32, count: ?u32) bool {
    const n = line orelse return false;
    const len = count orelse 1;
    return n >= start and n - start < len;
}

fn hitsHunk(c: store.Comment, hunk: diff.Hunk) bool {
    return lineInHunkRange(c.old_line, hunk.old_start, hunk.old_count) or
        lineInHunkRange(c.new_line, hunk.new_start, hunk.new_count);
}

/// Live comment on `file`, and on `hunk_i` when that index is set.
/// Path-only (file) comments match whole-file (`hunk_i == null`) only.
/// Hunk comments (both starts, `side` null) match that hunk, and the whole file.
pub fn matches(c: store.Comment, file: *const diff.File, hunk_i: ?usize) bool {
    if (c.state != .open) return false;
    if (!std.mem.eql(u8, c.path, file.displayPath())) return false;
    const hunk_comment = c.old_line != null and c.new_line != null and c.side == null;
    if (hunk_i) |hi| {
        if (hi >= file.hunks.len) return false;
        const h = file.hunks[hi];
        if (hunk_comment) return c.old_line.? == h.old_start and c.new_line.? == h.new_start;
        return hitsHunk(c, h);
    }
    if (c.old_line == null and c.new_line == null) return true;
    if (hunk_comment) return true;
    for (file.hunks) |hunk| {
        if (hitsHunk(c, hunk)) return true;
    }
    return false;
}

pub fn hasMatching(review: *const store.Review, file: *const diff.File, hunk_i: ?usize) bool {
    for (review.comments.items) |c| {
        if (matches(c, file, hunk_i)) return true;
    }
    return false;
}

pub fn collectMatching(
    review: *const store.Review,
    file: *const diff.File,
    hunk_i: ?usize,
    alloc: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    saved: *std.ArrayList(RemoveSnap),
) std.mem.Allocator.Error!void {
    for (review.comments.items, 0..) |c, i| {
        if (!matches(c, file, hunk_i)) continue;
        try ids.append(alloc, c.id);
        try saved.append(alloc, .{ .idx = i, .comment = c });
    }
}

/// Cursor-side open target, plus the first live comment there when one exists.
/// Null when that side is missing on the current row.
pub const AtSide = struct {
    anchor: view.row.Anchor,
    idx: ?usize,
};

pub fn atSide(
    review: *const store.Review,
    rows: []const view.row.Row,
    slots: []const view.layout.SbsSlot,
    layout: view.layout.EffectiveLayout,
    cursor: usize,
    want: view.row.CommentSide,
) ?AtSide {
    const a = view.commentAnchor(rows, slots, layout, cursor, want) orelse return null;
    const kind: store.CommentKind = if (a.old_line == null and a.new_line == null)
        .file
    else if (a.old_line != null and a.new_line != null)
        .hunk
    else
        .line;
    return .{
        .anchor = a,
        .idx = review.firstAt(a.path, a.old_line, a.new_line, kind),
    };
}

const testing = std.testing;

test "loc open sides context missing resolved" {
    const old_loc = loc(.{
        .id = "1",
        .path = "f",
        .old_line = 2,
        .side = .old,
        .body = "x",
    }).?;
    try testing.expectEqualStrings("f", old_loc.path);
    try testing.expectEqual(.old, old_loc.side.?);
    try testing.expectEqual(2, old_loc.line.?);

    const new_loc = loc(.{
        .id = "1",
        .path = "f",
        .new_line = 3,
        .side = .new,
        .body = "x",
    }).?;
    try testing.expectEqual(.new, new_loc.side.?);
    try testing.expectEqual(3, new_loc.line.?);

    const ctx = loc(.{
        .id = "1",
        .path = "f",
        .old_line = 1,
        .new_line = 4,
        .side = .context,
        .body = "x",
    }).?;
    try testing.expectEqual(.new, ctx.side.?);
    try testing.expectEqual(4, ctx.line.?);

    const ctx_old = loc(.{
        .id = "1",
        .path = "f",
        .old_line = 5,
        .side = .context,
        .body = "x",
    }).?;
    try testing.expectEqual(.old, ctx_old.side.?);
    try testing.expectEqual(5, ctx_old.line.?);

    try testing.expect(loc(.{
        .id = "1",
        .path = "f",
        .side = .new,
        .body = "x",
    }) == null);
    try testing.expect(loc(.{
        .id = "1",
        .path = "f",
        .new_line = 1,
        .side = .new,
        .body = "x",
        .state = .resolved,
    }) == null);

    const hunk_loc = loc(.{
        .id = "1",
        .path = "f",
        .old_line = 1,
        .new_line = 2,
        .body = "x",
    }).?;
    try testing.expectEqualStrings("f", hunk_loc.path);
    try testing.expect(hunk_loc.side == null);
    try testing.expect(hunk_loc.line == null);
    try testing.expectEqual(1, hunk_loc.hunk.?.old_start);
    try testing.expectEqual(2, hunk_loc.hunk.?.new_start);

    const implied_old = loc(.{
        .id = "1",
        .path = "f",
        .old_line = 8,
        .body = "x",
    }).?;
    try testing.expectEqual(.old, implied_old.side.?);
    try testing.expectEqual(8, implied_old.line.?);

    const file_loc = loc(.{
        .id = "1",
        .path = "f",
        .body = "x",
    }).?;
    try testing.expectEqualStrings("f", file_loc.path);
    try testing.expect(file_loc.side == null);
    try testing.expect(file_loc.line == null);

    try testing.expect(loc(.{
        .id = "1",
        .path = "f",
        .body = "x",
        .state = .resolved,
    }) == null);
}

test "next prev display order wrap skip missing" {
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
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    // Store order is add then delete; display order is delete (3) then add (4).
    _ = try review.addOpen("f", null, 2, .new, "add");
    _ = try review.addOpen("f", 2, null, .old, "del");
    _ = try review.addOpen("gone", null, 1, .new, "missing");

    var empty = try store.initEmpty(testing.allocator, "t");
    defer empty.deinit();
    try testing.expect(next(&empty, rows, 0) == null);
    try testing.expect(prev(&empty, rows, 0) == null);
    try testing.expect(next(&review, &.{}, 0) == null);

    const n0 = next(&review, rows, 0).?;
    try testing.expectEqual(3, n0.row);
    try testing.expect(!n0.wrapped);

    const n1 = next(&review, rows, 3).?;
    try testing.expectEqual(4, n1.row);
    try testing.expect(!n1.wrapped);

    const n2 = next(&review, rows, 4).?;
    try testing.expectEqual(3, n2.row);
    try testing.expect(n2.wrapped);

    const p0 = prev(&review, rows, 5).?;
    try testing.expectEqual(4, p0.row);
    try testing.expect(!p0.wrapped);

    const p1 = prev(&review, rows, 4).?;
    try testing.expectEqual(3, p1.row);
    try testing.expect(!p1.wrapped);

    const p2 = prev(&review, rows, 3).?;
    try testing.expectEqual(4, p2.row);
    try testing.expect(p2.wrapped);
}

test "next on truncated rows skips a comment on an omitted hunk" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const full = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(full);
    // Omit the first hunk (file + @@ -1 body); keep @@ -10 and its lines.
    const hidden = full[4..];

    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, 1, .new, "on first hunk");
    _ = try review.addOpen("f", null, 10, .new, "on second hunk");

    try testing.expectEqual(view.rowForComment(hidden, .{ .path = "f", .side = .new, .line = 10 }).?, next(&review, hidden, 0).?.row);
    try testing.expectEqual(view.rowForComment(full, .{ .path = "f", .side = .new, .line = 1 }).?, next(&review, full, 0).?.row);
}

test "next same row is one stop then later row" {
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
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, 1, .new, "ctx new");
    _ = try review.addOpen("f", 1, null, .old, "ctx old");
    _ = try review.addOpen("f", null, 2, .new, "add");

    const n0 = next(&review, rows, 1).?;
    try testing.expectEqual(2, n0.row);
    try testing.expect(!n0.wrapped);

    const n1 = next(&review, rows, 2).?;
    try testing.expectEqual(4, n1.row);
    try testing.expect(!n1.wrapped);
}

test "destAnchor maps the commented line, not a neighbor hunk" {
    const src_txt =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1,3 +1,4 @@
        \\ context one
        \\-old two
        \\+fn commentedLine
        \\ context three
        \\@@ -10,2 +11,2 @@
        \\ keep
        \\-old tail
        \\+new tail
    ;
    const dest_same =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -20,3 +20,4 @@
        \\ context one
        \\-old two
        \\+fn commentedLine
        \\ context three
        \\@@ -40,2 +41,2 @@
        \\ keep
        \\-old tail
        \\+new tail
    ;
    const dest_resplit =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -20,3 +20,4 @@
        \\+extra context
        \\ context one
        \\-old two
        \\+fn commentedLine
        \\ context three
    ;
    const dest_other_hunk =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -40,2 +41,2 @@
        \\ keep
        \\-old tail
        \\+new tail
    ;

    var src = try diff.parsePieces(testing.allocator, &.{
        .{ .text = src_txt, .group = .unstaged },
    });
    defer src.deinit();
    const src_file = &src.files[0];
    const on_add = store.Comment{
        .id = "1",
        .path = "a.zig",
        .new_line = 2,
        .side = .new,
        .body = "x",
    };

    var dest_eq = try diff.parsePieces(testing.allocator, &.{
        .{ .text = dest_same, .group = .staged },
    });
    defer dest_eq.deinit();
    const same = destAnchor(on_add, src_file, &dest_eq, 0).?;
    try testing.expect(same.old_line == null);
    try testing.expectEqual(21, same.new_line.?);
    try testing.expectEqual(store.Side.new, same.side.?);

    var dest_untracked = try diff.parsePieces(testing.allocator, &.{
        .{ .text = dest_same, .group = .untracked },
    });
    defer dest_untracked.deinit();
    const via_untracked = destAnchor(on_add, src_file, &dest_untracked, 0).?;
    try testing.expectEqual(21, via_untracked.new_line.?);
    try testing.expectEqual(store.Side.new, via_untracked.side.?);

    const neighbor = store.Comment{
        .id = "2",
        .path = "a.zig",
        .new_line = 2,
        .side = .new,
        .body = "x",
    };
    try testing.expect(destAnchor(neighbor, src_file, &dest_eq, 1) == null);
    const neighbor_ok = destAnchor(
        store.Comment{ .id = "3", .path = "a.zig", .new_line = 12, .side = .new, .body = "x" },
        src_file,
        &dest_eq,
        1,
    ).?;
    try testing.expectEqual(42, neighbor_ok.new_line.?);

    var dest_split = try diff.parsePieces(testing.allocator, &.{
        .{ .text = dest_resplit, .group = .staged },
    });
    defer dest_split.deinit();
    const split = destAnchor(on_add, src_file, &dest_split, 0).?;
    try testing.expect(split.old_line == null);
    try testing.expectEqual(22, split.new_line.?);
    try testing.expectEqual(store.Side.new, split.side.?);

    var dest_other = try diff.parsePieces(testing.allocator, &.{
        .{ .text = dest_other_hunk, .group = .staged },
    });
    defer dest_other.deinit();
    try testing.expect(destAnchor(on_add, src_file, &dest_other, 0) == null);
}

test "path-only comments stay path-only on remap" {
    const src_txt =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const dest_txt =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -20 +20 @@
        \\-old
        \\+new
    ;
    const dest_gone =
        \\diff --git a/b.zig b/b.zig
        \\--- a/b.zig
        \\+++ b/b.zig
        \\@@ -1 +1 @@
        \\-x
        \\+y
    ;

    var src = try diff.parsePieces(testing.allocator, &.{
        .{ .text = src_txt, .group = .unstaged },
    });
    defer src.deinit();
    const src_file = &src.files[0];
    const file_c = store.Comment{ .id = "1", .path = "a.zig", .body = "file" };

    var dest_eq = try diff.parsePieces(testing.allocator, &.{
        .{ .text = dest_txt, .group = .staged },
    });
    defer dest_eq.deinit();
    try testing.expect(destAnchor(file_c, src_file, &dest_eq, null) == null);
    try testing.expect(destAnchor(file_c, src_file, &dest_eq, 0) == null);

    var dest_other = try diff.parsePieces(testing.allocator, &.{
        .{ .text = dest_gone, .group = .staged },
    });
    defer dest_other.deinit();
    try testing.expect(destAnchor(file_c, src_file, &dest_other, null) == null);

    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("a.zig", null, null, null, "file");
    _ = try review.addOpen("a.zig", null, 1, .new, "line");

    var priors: std.ArrayList(AnchorSnap) = .empty;
    defer priors.deinit(testing.allocator);
    try remapMatching(&review, src_file, &dest_eq, null, testing.allocator, &priors);

    const kept = review.find("1").?;
    try testing.expect(kept.old_line == null);
    try testing.expect(kept.new_line == null);
    try testing.expect(kept.side == null);
    const mapped = review.find("2").?;
    try testing.expect(mapped.old_line == null);
    try testing.expectEqual(20, mapped.new_line.?);
    try testing.expectEqual(store.Side.new, mapped.side.?);
}

test "hunk comments remap starts and stay hunk" {
    const src_txt =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    const dest_txt =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -20 +20 @@
        \\-old
        \\+new
        \\@@ -40 +40 @@
        \\-old2
        \\+new2
    ;
    const dest_gone =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -40 +40 @@
        \\-old2
        \\+new2
    ;

    var src = try diff.parsePieces(testing.allocator, &.{
        .{ .text = src_txt, .group = .unstaged },
    });
    defer src.deinit();
    const src_file = &src.files[0];
    const hunk_c = store.Comment{ .id = "1", .path = "a.zig", .old_line = 1, .new_line = 1, .body = "hunk" };

    var dest_eq = try diff.parsePieces(testing.allocator, &.{
        .{ .text = dest_txt, .group = .staged },
    });
    defer dest_eq.deinit();
    const moved = destAnchor(hunk_c, src_file, &dest_eq, null).?;
    try testing.expectEqual(20, moved.old_line.?);
    try testing.expectEqual(20, moved.new_line.?);
    try testing.expect(moved.side == null);
    const moved_hunk = destAnchor(hunk_c, src_file, &dest_eq, 0).?;
    try testing.expectEqual(20, moved_hunk.old_line.?);
    try testing.expect(moved_hunk.side == null);
    try testing.expect(destAnchor(hunk_c, src_file, &dest_eq, 1) == null);

    var dest_other = try diff.parsePieces(testing.allocator, &.{
        .{ .text = dest_gone, .group = .staged },
    });
    defer dest_other.deinit();
    try testing.expect(destAnchor(hunk_c, src_file, &dest_other, null) == null);

    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("a.zig", 1, 1, null, "hunk");
    _ = try review.addOpen("a.zig", null, 1, .new, "line");

    var priors: std.ArrayList(AnchorSnap) = .empty;
    defer priors.deinit(testing.allocator);
    try remapMatching(&review, src_file, &dest_eq, null, testing.allocator, &priors);

    const hunk_kept = review.find("1").?;
    try testing.expectEqual(20, hunk_kept.old_line.?);
    try testing.expectEqual(20, hunk_kept.new_line.?);
    try testing.expect(hunk_kept.side == null);
    const line_mapped = review.find("2").?;
    try testing.expect(line_mapped.old_line == null);
    try testing.expectEqual(20, line_mapped.new_line.?);
    try testing.expectEqual(store.Side.new, line_mapped.side.?);
}

test "matches this group's hunk lines" {
    var hunks = [_]diff.Hunk{
        .{ .old_start = 10, .old_count = 3, .new_start = 12, .new_count = 4 },
        .{ .old_start = 40, .old_count = 2, .new_start = 50, .new_count = 2 },
    };
    const file = diff.File{
        .new_path = "a.zig",
        .hunks = &hunks,
        .group = .unstaged,
    };
    const hit_new = store.Comment{ .id = "1", .path = "a.zig", .new_line = 13, .body = "x" };
    const hit_old = store.Comment{ .id = "2", .path = "a.zig", .old_line = 11, .body = "x" };
    const hit_second = store.Comment{ .id = "3", .path = "a.zig", .new_line = 51, .body = "x" };
    const other_line = store.Comment{ .id = "4", .path = "a.zig", .new_line = 80, .body = "x" };
    const other_path = store.Comment{ .id = "5", .path = "b.zig", .new_line = 13, .body = "x" };
    const resolved = store.Comment{
        .id = "6",
        .path = "a.zig",
        .new_line = 13,
        .body = "x",
        .state = .resolved,
    };

    try testing.expect(matches(hit_new, &file, 0));
    try testing.expect(matches(hit_old, &file, 0));
    try testing.expect(!matches(hit_second, &file, 0));
    try testing.expect(!matches(other_line, &file, 0));
    try testing.expect(!matches(other_path, &file, 0));
    try testing.expect(!matches(resolved, &file, 0));

    try testing.expect(matches(hit_new, &file, null));
    try testing.expect(matches(hit_second, &file, null));
    try testing.expect(!matches(other_line, &file, null));

    const file_c = store.Comment{ .id = "7", .path = "a.zig", .body = "file" };
    const resolved_file = store.Comment{
        .id = "8",
        .path = "a.zig",
        .body = "file",
        .state = .resolved,
    };
    const file_other = store.Comment{ .id = "9", .path = "b.zig", .body = "file" };
    try testing.expect(matches(file_c, &file, null));
    try testing.expect(!matches(file_c, &file, 0));
    try testing.expect(!matches(resolved_file, &file, null));
    try testing.expect(!matches(file_other, &file, null));

    const hunk_c = store.Comment{ .id = "11", .path = "a.zig", .old_line = 10, .new_line = 12, .body = "hunk" };
    const hunk_other = store.Comment{ .id = "12", .path = "a.zig", .old_line = 40, .new_line = 50, .body = "hunk2" };
    try testing.expect(matches(hunk_c, &file, 0));
    try testing.expect(!matches(hunk_c, &file, 1));
    try testing.expect(matches(hunk_c, &file, null));
    try testing.expect(matches(hunk_other, &file, 1));
    try testing.expect(!matches(hunk_other, &file, 0));

    const empty = diff.File{ .new_path = "pic.png", .is_binary = true };
    const bin_c = store.Comment{ .id = "10", .path = "pic.png", .body = "file" };
    try testing.expect(matches(bin_c, &empty, null));
    try testing.expect(!matches(bin_c, &empty, 0));
}

test "atSide file line and hunk" {
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
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const empty: []const view.layout.SbsSlot = &.{};

    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, null, null, "file");
    _ = try review.addOpen("f", null, 1, .new, "line");
    _ = try review.addOpen("f", 1, 1, null, "hunk");

    const found = atSide(&review, rows, empty, .unified, 0, .new).?;
    try testing.expectEqualStrings("f", found.anchor.path);
    try testing.expect(found.anchor.old_line == null);
    try testing.expect(found.anchor.new_line == null);
    try testing.expectEqual(0, found.idx.?);

    const old_side = atSide(&review, rows, empty, .unified, 0, .old).?;
    try testing.expect(old_side.anchor.old_line == null);
    try testing.expect(old_side.anchor.new_line == null);
    try testing.expectEqual(0, old_side.idx.?);

    const line = atSide(&review, rows, empty, .unified, 3, .new).?;
    try testing.expectEqual(1, line.anchor.new_line.?);
    try testing.expectEqual(1, line.idx.?);

    const hunk_new = atSide(&review, rows, empty, .unified, 1, .new).?;
    try testing.expectEqualStrings("f", hunk_new.anchor.path);
    try testing.expectEqual(1, hunk_new.anchor.old_line.?);
    try testing.expectEqual(1, hunk_new.anchor.new_line.?);
    try testing.expectEqual(2, hunk_new.idx.?);
    const hunk_old = atSide(&review, rows, empty, .unified, 1, .old).?;
    try testing.expectEqual(1, hunk_old.anchor.old_line.?);
    try testing.expectEqual(1, hunk_old.anchor.new_line.?);
    try testing.expectEqual(2, hunk_old.idx.?);
}

test "next prev file comment lands on header" {
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
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, 1, .new, "line");
    _ = try review.addOpen("f", null, null, null, "file");

    const n0 = next(&review, rows, 0).?;
    try testing.expectEqual(3, n0.row);
    try testing.expect(!n0.wrapped);

    const n1 = next(&review, rows, 3).?;
    try testing.expectEqual(0, n1.row);
    try testing.expect(n1.wrapped);

    const p0 = prev(&review, rows, 1).?;
    try testing.expectEqual(0, p0.row);
    try testing.expect(!p0.wrapped);
}

test "next prev hunk comment lands on header" {
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
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, 1, .new, "line");
    _ = try review.addOpen("f", 1, 1, null, "hunk");

    const n0 = next(&review, rows, 0).?;
    try testing.expectEqual(1, n0.row);
    try testing.expect(!n0.wrapped);

    const n1 = next(&review, rows, 1).?;
    try testing.expectEqual(3, n1.row);
    try testing.expect(!n1.wrapped);

    const n2 = next(&review, rows, 3).?;
    try testing.expectEqual(1, n2.row);
    try testing.expect(n2.wrapped);

    const p0 = prev(&review, rows, 3).?;
    try testing.expectEqual(1, p0.row);
    try testing.expect(!p0.wrapped);
}
