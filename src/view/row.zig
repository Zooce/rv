//! Display row model: flatten a parsed `Diff` into `[]Row`. `flattenPlaced`
//! drops lines an approved claim covers. A row answers kind, searchable
//! text, commentable location, and line width. No drawing.

const std = @import("std");
const diff = @import("diff");
const tui = @import("tui");
const approve = @import("approve");
const Allocator = std.mem.Allocator;

/// File-header payload. `path` is identity (`File.displayPath()`). `old_path`
/// / `new_path` are borrowed from `Diff.File` (`null` on a `/dev/null` side).
pub const FileHeader = struct {
    path: []const u8,
    is_binary: bool,
    group: ?diff.Group = null,
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
};

/// One renderable row in the review list. String slices borrow from the
/// parent `Diff` arena (or are static); free only the row slice itself.
pub const Row = union(enum) {
    /// Group divider. Local load only.
    section_header: diff.Group,
    file_header: FileHeader,
    hunk_header: struct {
        /// Display path of the owning file (borrowed from `Diff`).
        path: []const u8,
        old_start: u32,
        old_count: ?u32,
        new_start: u32,
        new_count: ?u32,
        section: []const u8,
        group: ?diff.Group = null,
        can_grow: bool = true,
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
        /// Changed bytes in `text`. Borrowed from the diff line.
        /// `null`: word spans were not computed; an add/delete line keeps the solid fill.
        /// Empty: word-diff found no changed bytes. The row is dim grey, with no red or green.
        spans: ?[]const diff.Span = null,
    },
};

/// Line-comment target at the cursor (path + line numbers). `null` on headers
/// and meta lines (not commentable in MVP-1).
pub const Anchor = struct {
    path: []const u8,
    old_line: ?u32,
    new_line: ?u32,
};

/// Old vs new side of a diff line.
pub const CommentSide = enum { old, new };

/// Append one file: a group divider when `f.group` changes, the file header,
/// then each kept hunk and its lines. `keep_hunks == null` keeps every hunk.
/// Otherwise it is one flag per hunk in `f.hunks`; false omits that hunk.
/// `omit_lines == null` keeps every line of a kept hunk. Otherwise one slice
/// per hunk; a true bit skips that line. The caller skips a file that should
/// not appear at all. `flatten` and `flattenPlaced` both call this, so a
/// line row is built once.
pub fn appendFile(
    alloc: Allocator,
    rows: *std.ArrayList(Row),
    f: diff.File,
    prev_group: *?diff.Group,
    keep_hunks: ?[]const bool,
    omit_lines: ?[]const []const bool,
) Allocator.Error!void {
    if (f.group) |g| {
        if (prev_group.* == null or prev_group.*.? != g) {
            try rows.append(alloc, .{ .section_header = g });
            prev_group.* = g;
        }
    }
    const path = f.displayPath();
    try rows.append(alloc, .{ .file_header = .{
        .path = path,
        .is_binary = f.is_binary,
        .group = f.group,
        .old_path = f.old_path,
        .new_path = f.new_path,
    } });
    for (f.hunks, 0..) |h, i| {
        if (keep_hunks) |keep| {
            if (!keep[i]) continue;
        }
        try rows.append(alloc, .{ .hunk_header = .{
            .path = path,
            .old_start = h.old_start,
            .old_count = h.old_count,
            .new_start = h.new_start,
            .new_count = h.new_count,
            .section = h.section,
            .group = f.group,
            .can_grow = h.can_grow,
        } });
        for (h.lines, 0..) |ln, li| {
            if (omit_lines) |masks| {
                if (i < masks.len and li < masks[i].len and masks[i][li]) continue;
            }
            try rows.append(alloc, .{ .line = .{
                .kind = ln.kind,
                .text = ln.text,
                .path = path,
                .old_no = ln.old_no,
                .new_no = ln.new_no,
                .spans = ln.spans,
            } });
        }
    }
}

/// Build an owned list of rows from `d`. Caller's `alloc` owns the slice;
/// free with `alloc.free(rows)`. Nested string data and span slices are
/// borrowed from `d`.
pub fn flatten(alloc: Allocator, d: *const diff.Diff) Allocator.Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(alloc);

    var prev_group: ?diff.Group = null;
    for (d.files) |f| {
        try appendFile(alloc, &rows, f, &prev_group, null, null);
    }
    return try rows.toOwnedSlice(alloc);
}

/// Rows for `d` with `placed` claims removed. `placed` is `approve.place`
/// (file, then hunk, then the run's first line). A null span drops that
/// hunk. A hunk whose add and delete lines are all claimed is dropped, then
/// a file with nothing left, then an empty section. A partial claim leaves
/// the hunk header, context, and the other changes. Same row shape as `flatten`.
pub fn flattenPlaced(
    alloc: Allocator,
    d: *const diff.Diff,
    placed: []const approve.Placement,
) Allocator.Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(alloc);
    var prev_group: ?diff.Group = null;
    var pi: usize = 0;

    for (d.files, 0..) |f, fi| {
        while (pi < placed.len and placed[pi].file_i < fi) pi += 1;
        const begin = pi;
        while (pi < placed.len and placed[pi].file_i == fi) pi += 1;
        const file_places = placed[begin..pi];

        // A claimed hunk-less file does not appear.
        if (f.hunks.len == 0) {
            if (file_places.len > 0) continue;
            try appendFile(alloc, &rows, f, &prev_group, null, null);
            continue;
        }

        const keep = try alloc.alloc(bool, f.hunks.len);
        defer alloc.free(keep);
        @memset(keep, true);

        const masks = try alloc.alloc([]bool, f.hunks.len);
        defer alloc.free(masks);
        var allocated: usize = 0;
        defer for (masks[0..allocated]) |m| alloc.free(m);
        for (f.hunks, 0..) |h, hi| {
            masks[hi] = try alloc.alloc(bool, h.lines.len);
            allocated += 1;
            @memset(masks[hi], false);
        }

        // Mark claimed lines. A null span drops the whole hunk.
        for (file_places) |p| {
            const hi = p.hunk_i orelse continue;
            if (p.span == null) {
                keep[hi] = false;
                continue;
            }
            p.mark(masks[hi], f.hunks[hi].lines);
        }

        // Drop a hunk only when every add/delete line is claimed. A context-only
        // hunk stays unless its own tag-only hash was claimed above.
        for (f.hunks, 0..) |h, hi| {
            if (!keep[hi]) continue;
            var changes: usize = 0;
            var visible: usize = 0;
            for (h.lines, 0..) |ln, li| {
                switch (ln.kind) {
                    .add, .delete => {
                        changes += 1;
                        if (!masks[hi][li]) visible += 1;
                    },
                    .context, .meta => {},
                }
            }
            if (changes > 0 and visible == 0) keep[hi] = false;
        }

        var any = false;
        for (keep) |k| if (k) {
            any = true;
            break;
        };
        if (!any) continue;

        const omit = try alloc.alloc([]const bool, f.hunks.len);
        defer alloc.free(omit);
        for (masks, 0..) |m, hi| omit[hi] = m;
        try appendFile(alloc, &rows, f, &prev_group, keep, omit);
    }
    return try rows.toOwnedSlice(alloc);
}

/// Clamp `cursor` into `[0, len)` (or `0` when the list is empty).
pub fn clampCursor(cursor: usize, len: usize) usize {
    if (len == 0) return 0;
    if (cursor >= len) return len - 1;
    return cursor;
}

/// Digit columns for old/new numbers: width of the largest `old_no` / `new_no`
/// in `rows`. At least 1 so blank fields still line up when nothing is numbered.
pub fn lineNumberWidth(rows: []const Row) usize {
    var max: u32 = 0;
    for (rows) |row| {
        switch (row) {
            .line => |ln| {
                if (ln.old_no) |n| max = @max(max, n);
                if (ln.new_no) |n| max = @max(max, n);
            },
            else => {},
        }
    }
    return decimalDigits(max);
}

fn decimalDigits(n: u32) usize {
    var w: usize = 1;
    var x = n;
    while (x >= 10) {
        x /= 10;
        w += 1;
    }
    return w;
}

/// Widest line text in `[body_start, body_end)`. Gutter excluded. 0 if empty.
/// Width uses the same column rules as the screen, so pan matches paint.
pub fn hunkMaxLineWidth(rows: []const Row, body_start: usize, body_end: usize) usize {
    var max_w: usize = 0;
    var i = body_start;
    while (i < body_end) : (i += 1) {
        switch (rows[i]) {
            .line => |ln| max_w = @max(max_w, tui.screen.displayWidth(ln.text)),
            else => {},
        }
    }
    return max_w;
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
        .file_header, .hunk_header, .section_header => null,
    };
}

/// Searchable text for one display row, or `null` if `/` does not search it.
///
/// In scope (v1): add / delete / context **body** line text only. File headers,
/// hunk headers, and meta lines are excluded.
pub fn searchText(row: Row) ?[]const u8 {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .add, .delete, .context => ln.text,
            .meta => null,
        },
        .file_header, .hunk_header, .section_header => null,
    };
}

/// Path string for a `.file_header` row, or `null` on non-header rows.
/// Lands on the file header itself (not the first body/change line).
/// Identity path (`displayPath()`), not the `old -> new` file-line label.
pub fn searchPath(row: Row) ?[]const u8 {
    return switch (row) {
        .file_header => |fh| fh.path,
        .hunk_header, .line, .section_header => null,
    };
}

/// File-line path: `old -> new` when both sides exist and differ, else `path`.
pub fn fileHeaderPathLabel(fh: FileHeader, buf: []u8) []const u8 {
    const old = fh.old_path orelse return fh.path;
    const newp = fh.new_path orelse return fh.path;
    if (std.mem.eql(u8, old, newp)) return fh.path;
    return std.fmt.bufPrint(buf, "{s} -> {s}", .{ old, newp }) catch fh.path;
}

/// Case-sensitive substring match against `searchText` for this row.
pub fn rowMatches(row: Row, query: []const u8) bool {
    if (query.len == 0) return false;
    const t = searchText(row) orelse return false;
    return std.mem.indexOf(u8, t, query) != null;
}

/// Case-sensitive substring match against a file-header path. Hits identity
/// `path`, `old_path`, `new_path`, and the `old -> new` file-line label.
pub fn rowPathMatches(row: Row, query: []const u8) bool {
    if (query.len == 0) return false;
    switch (row) {
        .file_header => |fh| {
            var buf: [512]u8 = undefined;
            if (std.mem.indexOf(u8, fileHeaderPathLabel(fh, &buf), query) != null) return true;
            if (fh.old_path) |old| {
                if (std.mem.indexOf(u8, old, query) != null) return true;
            }
            if (fh.new_path) |newp| {
                if (std.mem.indexOf(u8, newp, query) != null) return true;
            }
            return false;
        },
        .hunk_header, .line, .section_header => return false,
    }
}

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
    try testing.expect(rows[0].file_header.group == null);
    try testing.expect(rows[1] == .hunk_header);
    try testing.expectEqualStrings("f", rows[1].hunk_header.path);
    try testing.expect(rows[1].hunk_header.group == null);
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

test "flatten copies file group onto headers and hunks" {
    const unstaged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const staged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1,2 @@
        \\ same
        \\+staged
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = unstaged_txt, .group = .unstaged },
        .{ .text = staged_txt, .group = .staged },
    });
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    // Unstaged header + file/hunk/lines, Staged header + file/hunk/lines.
    try testing.expectEqual(10, rows.len);
    try testing.expect(rows[0] == .section_header);
    try testing.expectEqual(diff.Group.unstaged, rows[0].section_header);
    try testing.expect(rows[1] == .file_header);
    try testing.expect(rows[2] == .hunk_header);
    try testing.expect(rows[5] == .section_header);
    try testing.expectEqual(diff.Group.staged, rows[5].section_header);
    try testing.expect(rows[6] == .file_header);
    try testing.expect(rows[7] == .hunk_header);
    try testing.expectEqual(diff.Group.unstaged, rows[1].file_header.group.?);
    try testing.expectEqual(diff.Group.unstaged, rows[2].hunk_header.group.?);
    try testing.expectEqualStrings("a", rows[2].hunk_header.path);
    try testing.expectEqualStrings("a", rows[1].file_header.path);
    try testing.expectEqual(diff.Group.staged, rows[6].file_header.group.?);
    try testing.expectEqual(diff.Group.staged, rows[7].hunk_header.group.?);
    try testing.expectEqualStrings("a", rows[7].hunk_header.path);
    try testing.expectEqualStrings("a", rows[6].file_header.path);
}

test "flatten untracked-only still emits one section header" {
    const untracked_txt =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = "", .group = .unstaged },
        .{ .text = untracked_txt, .group = .untracked },
        .{ .text = "", .group = .staged },
    });
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expect(rows[0] == .section_header);
    try testing.expectEqual(diff.Group.untracked, rows[0].section_header);
    try testing.expectEqualStrings("u", rows[1].file_header.path);
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

test "lineNumberWidth is max digits and at least 1" {
    try testing.expectEqual(1, lineNumberWidth(&.{}));
    const headers: []const Row = &.{
        .{ .file_header = .{ .path = "f", .is_binary = false } },
    };
    try testing.expectEqual(1, lineNumberWidth(headers));
    const mixed: []const Row = &.{
        .{ .line = .{ .kind = .context, .text = "a", .path = "f", .old_no = 9, .new_no = 9 } },
        .{ .line = .{ .kind = .add, .text = "b", .path = "f", .new_no = 10 } },
    };
    try testing.expectEqual(2, lineNumberWidth(mixed));
    const wide: []const Row = &.{
        .{ .line = .{ .kind = .delete, .text = "c", .path = "f", .old_no = 100 } },
    };
    try testing.expectEqual(3, lineNumberWidth(wide));
}

test "hunkMaxLineWidth is text only" {
    const rows: []const Row = &.{
        .{ .hunk_header = .{
            .path = "f",
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .section = "",
        } },
        .{ .line = .{ .kind = .context, .text = "hello", .path = "f", .old_no = 1, .new_no = 1 } },
    };
    try testing.expectEqual(5, hunkMaxLineWidth(rows, 1, 2));
}

test "searchText is body lines only" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@ section
        \\ keep
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // file, hunk, context, delete, add
    try testing.expect(searchText(rows[0]) == null);
    try testing.expect(searchText(rows[1]) == null);
    try testing.expectEqualStrings("keep", searchText(rows[2]).?);
    try testing.expectEqualStrings("old", searchText(rows[3]).?);
    try testing.expectEqualStrings("new", searchText(rows[4]).?);
    try testing.expect(rowMatches(rows[3], "old"));
    try testing.expect(!rowMatches(rows[3], "OLD"));
    try testing.expect(!rowMatches(rows[0], "f"));
}

test "searchPath is file headers only" {
    const fixture =
        \\diff --git a/src/app/main.zig b/src/app/main.zig
        \\--- a/src/app/main.zig
        \\+++ b/src/app/main.zig
        \\@@ -1 +1 @@
        \\-oldMain
        \\+newMain
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expectEqualStrings("src/app/main.zig", searchPath(rows[0]).?);
    try testing.expect(searchPath(rows[1]) == null);
    try testing.expect(searchPath(rows[2]) == null);
    try testing.expect(searchPath(rows[3]) == null);
    try testing.expect(rowPathMatches(rows[0], "app/main"));
    try testing.expect(!rowPathMatches(rows[0], "APP"));
    try testing.expect(!rowPathMatches(rows[2], "app/main"));
    try testing.expect(!rowPathMatches(rows[2], "oldMain"));
    try testing.expect(!rowPathMatches(rows[0], ""));
}

test "flatten rename keeps identity path and both sides" {
    const fixture =
        \\diff --git a/old_name.txt b/new_name.txt
        \\similarity index 95%
        \\rename from old_name.txt
        \\rename to new_name.txt
        \\--- a/old_name.txt
        \\+++ b/new_name.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expect(rows[0] == .file_header);
    try testing.expectEqualStrings("new_name.txt", rows[0].file_header.path);
    try testing.expectEqualStrings("old_name.txt", rows[0].file_header.old_path.?);
    try testing.expectEqualStrings("new_name.txt", rows[0].file_header.new_path.?);
    try testing.expectEqualStrings("new_name.txt", rows[2].line.path);
}

test "flatten 100% rename is header only with both paths" {
    const fixture =
        \\diff --git a/old_name.txt b/new_name.txt
        \\similarity index 100%
        \\rename from old_name.txt
        \\rename to new_name.txt
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expectEqual(1, rows.len);
    try testing.expectEqualStrings("new_name.txt", rows[0].file_header.path);
    try testing.expectEqualStrings("old_name.txt", rows[0].file_header.old_path.?);
    try testing.expectEqualStrings("new_name.txt", rows[0].file_header.new_path.?);
}

test "flatten add and delete keep a single side" {
    const add_txt =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    const del_txt =
        \\diff --git a/gone.txt b/gone.txt
        \\deleted file mode 100644
        \\--- a/gone.txt
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-bye
    ;
    var added = try diff.parse(testing.allocator, add_txt);
    defer added.deinit();
    const add_rows = try flatten(testing.allocator, &added);
    defer testing.allocator.free(add_rows);
    try testing.expect(add_rows[0].file_header.old_path == null);
    try testing.expectEqualStrings("new.txt", add_rows[0].file_header.new_path.?);
    try testing.expectEqualStrings("new.txt", add_rows[0].file_header.path);

    var deleted = try diff.parse(testing.allocator, del_txt);
    defer deleted.deinit();
    const del_rows = try flatten(testing.allocator, &deleted);
    defer testing.allocator.free(del_rows);
    try testing.expectEqualStrings("gone.txt", del_rows[0].file_header.old_path.?);
    try testing.expect(del_rows[0].file_header.new_path == null);
    try testing.expectEqualStrings("gone.txt", del_rows[0].file_header.path);
}

test "fileHeaderPathLabel rename vs single path" {
    var buf: [64]u8 = undefined;
    const renamed: FileHeader = .{
        .path = "new_name.txt",
        .is_binary = false,
        .old_path = "old_name.txt",
        .new_path = "new_name.txt",
    };
    try testing.expectEqualStrings("old_name.txt -> new_name.txt", fileHeaderPathLabel(renamed, &buf));

    const same: FileHeader = .{
        .path = "a.zig",
        .is_binary = false,
        .old_path = "a.zig",
        .new_path = "a.zig",
    };
    try testing.expectEqualStrings("a.zig", fileHeaderPathLabel(same, &buf));

    const added: FileHeader = .{
        .path = "new.txt",
        .is_binary = false,
        .new_path = "new.txt",
    };
    try testing.expectEqualStrings("new.txt", fileHeaderPathLabel(added, &buf));

    const deleted: FileHeader = .{
        .path = "gone.txt",
        .is_binary = false,
        .old_path = "gone.txt",
    };
    try testing.expectEqualStrings("gone.txt", fileHeaderPathLabel(deleted, &buf));
}

test "rowPathMatches rename hits old new and label" {
    const fixture =
        \\diff --git a/old_name.txt b/new_name.txt
        \\similarity index 95%
        \\rename from old_name.txt
        \\rename to new_name.txt
        \\--- a/old_name.txt
        \\+++ b/new_name.txt
        \\@@ -1 +1 @@
        \\-oldBody
        \\+newBody
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expectEqualStrings("new_name.txt", searchPath(rows[0]).?);
    try testing.expect(rowPathMatches(rows[0], "old_name"));
    try testing.expect(rowPathMatches(rows[0], "new_name"));
    try testing.expect(rowPathMatches(rows[0], "old_name.txt -> new_name.txt"));
    try testing.expect(!rowPathMatches(rows[0], "oldBody"));
    try testing.expect(!rowPathMatches(rows[2], "old_name"));
}

const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

fn rowsFor(
    alloc: Allocator,
    root: std.Io.Dir,
    d: *const diff.Diff,
    approved: *const approve.Approved,
) ![]Row {
    const placed = try approve.place(alloc, testing.io, root, d, approved);
    defer alloc.free(placed);
    return flattenPlaced(alloc, d, placed);
}

fn twoHunkDiff(alloc: Allocator) !diff.Diff {
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parse(alloc, txt);
    errdefer d.deinit();
    try testing.expectEqual(1, d.files.len);
    try testing.expectEqual(2, d.files[0].hunks.len);
    return d;
}

fn threeGroupDiff(alloc: Allocator) !diff.Diff {
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
    return try diff.parsePieces(alloc, &.{
        .{ .text = unstaged_txt, .group = .unstaged },
        .{ .text = untracked_txt, .group = .untracked },
        .{ .text = staged_txt, .group = .staged },
    });
}

fn lineHas(rows: []const Row, text: []const u8) bool {
    for (rows) |row| {
        switch (row) {
            .line => |ln| if (std.mem.eql(u8, ln.text, text)) return true,
            else => {},
        }
    }
    return false;
}

fn mergedNeighborDiff() []const u8 {
    return
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -5 +5 @@
        \\-l5
        \\+STAGED
    ;
}

fn mergedPieceDiff() []const u8 {
    return
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -6 +6 @@
        \\-l6
        \\+UNSTAGED
    ;
}

fn mergedHunkDiff() []const u8 {
    return
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -4,5 +4,5 @@
        \\ l4
        \\-l5
        \\-l6
        \\+STAGED
        \\+UNSTAGED
        \\ l7
    ;
}

fn parseOneHunk(input: []const u8) !diff.Diff {
    var d = try diff.parse(testing.allocator, input);
    errdefer d.deinit();
    try testing.expectEqual(1, d.files.len);
    try testing.expectEqual(1, d.files[0].hunks.len);
    return d;
}

test "flattenPlaced with an empty store matches flatten" {
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = approve.initEmpty(testing.allocator);
    defer approved.deinit();
    const hidden = try rowsFor(testing.allocator, .cwd(), &d, &approved);
    defer testing.allocator.free(hidden);
    const full = try flatten(testing.allocator, &d);
    defer testing.allocator.free(full);
    try testing.expectEqual(full.len, hidden.len);
    for (full, hidden) |a, b| {
        try testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    }
}

test "flattenPlaced one hunk keeps the file and the other hunk" {
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = approve.initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(d.files[0].displayPath(), approve.fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try rowsFor(testing.allocator, .cwd(), &d, &approved);
    defer testing.allocator.free(hidden);
    try testing.expectEqual(4, hidden.len);
    try testing.expect(hidden[0] == .file_header);
    try testing.expect(hidden[1] == .hunk_header);
    try testing.expectEqual(d.files[0].hunks[1].old_start, hidden[1].hunk_header.old_start);
    try testing.expect(hidden[2] == .line);
    try testing.expectEqualStrings("old2", hidden[2].line.text);
    try testing.expect(hidden[3] == .line);
    try testing.expectEqualStrings("new2", hidden[3].line.text);
}

test "flattenPlaced omits an approved run and keeps the other changes" {
    const alloc = testing.allocator;
    var piece = try parseOneHunk(mergedPieceDiff());
    defer piece.deinit();
    var merged = try parseOneHunk(mergedHunkDiff());
    defer merged.deinit();
    const path = merged.files[0].displayPath();
    const hash = approve.fingerprintHunk(piece.files[0].hunks[0]);

    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, hash);

    const hidden = try rowsFor(alloc, .cwd(), &merged, &approved);
    defer alloc.free(hidden);
    try testing.expectEqual(6, hidden.len);
    try testing.expect(hidden[0] == .file_header);
    try testing.expect(hidden[1] == .hunk_header);
    try testing.expectEqualStrings("l4", hidden[2].line.text);
    try testing.expectEqualStrings("l5", hidden[3].line.text);
    try testing.expectEqualStrings("STAGED", hidden[4].line.text);
    try testing.expectEqualStrings("l7", hidden[5].line.text);
    try testing.expect(!lineHas(hidden, "UNSTAGED"));
    try testing.expect(!lineHas(hidden, "l6"));
}

test "flattenPlaced drops a hunk when every change run is approved" {
    const alloc = testing.allocator;
    var neighbor = try parseOneHunk(mergedNeighborDiff());
    defer neighbor.deinit();
    var piece = try parseOneHunk(mergedPieceDiff());
    defer piece.deinit();
    var merged = try parseOneHunk(mergedHunkDiff());
    defer merged.deinit();
    const path = merged.files[0].displayPath();

    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, approve.fingerprintHunk(piece.files[0].hunks[0]));
    try approved.append(path, approve.fingerprintHunk(neighbor.files[0].hunks[0]));

    const hidden = try rowsFor(alloc, .cwd(), &merged, &approved);
    defer alloc.free(hidden);
    try testing.expectEqual(0, hidden.len);
}

test "flattenPlaced keeps a replacement that no longer matches" {
    const alloc = testing.allocator;
    const was =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const now =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+newer
    ;
    var dw = try parseOneHunk(was);
    defer dw.deinit();
    var dn = try parseOneHunk(now);
    defer dn.deinit();

    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(dn.files[0].displayPath(), approve.fingerprintHunk(dw.files[0].hunks[0]));

    const hidden = try rowsFor(alloc, .cwd(), &dn, &approved);
    defer alloc.free(hidden);
    try testing.expect(lineHas(hidden, "old"));
    try testing.expect(lineHas(hidden, "newer"));
    try testing.expect(!lineHas(hidden, "new"));
}

test "flattenPlaced drops a file when every hunk is approved" {
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = approve.initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(d.files[0].displayPath(), approve.fingerprintHunk(d.files[0].hunks[0]));
    try approved.append(d.files[0].displayPath(), approve.fingerprintHunk(d.files[0].hunks[1]));
    const hidden = try rowsFor(testing.allocator, .cwd(), &d, &approved);
    defer testing.allocator.free(hidden);
    try testing.expectEqual(0, hidden.len);
}

test "flattenPlaced drops an empty section and keeps a mixed file" {
    var d = try threeGroupDiff(testing.allocator);
    defer d.deinit();
    var approved = approve.initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append("a", approve.fingerprintHunk(d.files[0].hunks[0]));
    try approved.append("u", approve.fingerprintHunk(d.files[1].hunks[0]));
    const hidden = try rowsFor(testing.allocator, .cwd(), &d, &approved);
    defer testing.allocator.free(hidden);
    try testing.expect(hidden[0] == .section_header);
    try testing.expectEqual(diff.Group.staged, hidden[0].section_header);
    try testing.expect(hidden[1] == .file_header);
    try testing.expectEqualStrings("a", hidden[1].file_header.path);
    try testing.expect(hidden[2] == .hunk_header);
}

test "flattenPlaced one store entry hides the first matching file only" {
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = txt, .group = .unstaged },
        .{ .text = txt, .group = .staged },
    });
    defer d.deinit();
    var approved = approve.initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append("f.txt", approve.fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try rowsFor(testing.allocator, .cwd(), &d, &approved);
    defer testing.allocator.free(hidden);
    try testing.expect(hidden[0] == .section_header);
    try testing.expectEqual(diff.Group.staged, hidden[0].section_header);
    try testing.expect(hidden[1] == .file_header);
}

test "flattenPlaced drops a hunk-less file when worktree bytes match" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try tmp.write(io, "pic.png", "abc");
    const binary =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var d = try diff.parse(alloc, binary);
    defer d.deinit();
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append("pic.png", approve.fingerprintFile("abc"));
    const hidden = try rowsFor(alloc, tmp.dir, &d, &approved);
    defer alloc.free(hidden);
    try testing.expectEqual(0, hidden.len);
}

test "flattenPlaced approving one group leaves the other groups" {
    const alloc = testing.allocator;
    const io = testing.io;
    var d = try threeGroupDiff(alloc);
    defer d.deinit();
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.appendGroup(alloc, io, .cwd(), &d, .unstaged);
    const hidden = try rowsFor(alloc, .cwd(), &d, &approved);
    defer alloc.free(hidden);
    try testing.expect(hidden[0] == .section_header);
    try testing.expectEqual(diff.Group.untracked, hidden[0].section_header);
}

test "flattenPlaced after unapprove restores one hunk" {
    const alloc = testing.allocator;
    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const h0 = approve.fingerprintHunk(d.files[0].hunks[0]);
    const h1 = approve.fingerprintHunk(d.files[0].hunks[1]);
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, h0);
    try approved.append(path, h1);
    try approved.unapprove(path, h0);
    const rows = try rowsFor(alloc, .cwd(), &d, &approved);
    defer alloc.free(rows);
    try testing.expectEqual(4, rows.len);
    try testing.expectEqual(d.files[0].hunks[0].old_start, rows[1].hunk_header.old_start);
}

test "flattenPlaced identical hunks: unapprove restores the later hunk" {
    const alloc = testing.allocator;
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\@@ -10 +10 @@
        \\-a
        \\+b
    ;
    var d = try diff.parse(alloc, txt);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const hash = approve.fingerprintHunk(d.files[0].hunks[0]);
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, hash);
    try approved.append(path, hash);
    try approved.unapprove(path, hash);
    const rows = try rowsFor(alloc, .cwd(), &d, &approved);
    defer alloc.free(rows);
    try testing.expectEqual(4, rows.len);
    try testing.expectEqual(d.files[0].hunks[1].old_start, rows[1].hunk_header.old_start);
}
