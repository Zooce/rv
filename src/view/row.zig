//! Display row model: flatten a parsed `Diff` into `[]Row`. A row answers
//! kind, searchable text, and commentable location. Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
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

/// Build an owned list of rows from `d`. Caller's `alloc` owns the slice;
/// free with `alloc.free(rows)`. Nested string data is borrowed from `d`.
pub fn flatten(alloc: Allocator, d: *const diff.Diff) Allocator.Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(alloc);

    var prev_group: ?diff.Group = null;
    for (d.files) |f| {
        if (f.group) |g| {
            if (prev_group == null or prev_group.? != g) {
                try rows.append(alloc, .{ .section_header = g });
                prev_group = g;
            }
        }
        try rows.append(alloc, .{ .file_header = .{
            .path = f.displayPath(),
            .is_binary = f.is_binary,
            .group = f.group,
            .old_path = f.old_path,
            .new_path = f.new_path,
        } });
        for (f.hunks) |h| {
            try rows.append(alloc, .{ .hunk_header = .{
                .path = f.displayPath(),
                .old_start = h.old_start,
                .old_count = h.old_count,
                .new_start = h.new_start,
                .new_count = h.new_count,
                .section = h.section,
                .group = f.group,
                .can_grow = h.can_grow,
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
