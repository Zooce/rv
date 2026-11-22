//! Session fold state for file and hunk headers.
//!
//! Keys are owned path copies, so they survive a row rebuild. `project`
//! copies the rows that stay on screen and marks folded headers. Call it
//! when the set changes. With no keys, the caller keeps the original row
//! slice and does not call `project`.

const std = @import("std");
const diff = @import("diff");
const row_mod = @import("row.zig");
const nav = @import("nav.zig");

const Allocator = std.mem.Allocator;
const Row = row_mod.Row;

const FileKey = struct {
    path: []u8,
    group: ?diff.Group,
};

const HunkKey = struct {
    path: []u8,
    group: ?diff.Group,
    old_start: u32,
    new_start: u32,
};

pub const Fold = struct {
    files: std.ArrayList(FileKey) = .empty,
    hunks: std.ArrayList(HunkKey) = .empty,

    pub fn deinit(self: *Fold, alloc: Allocator) void {
        for (self.files.items) |key| alloc.free(key.path);
        for (self.hunks.items) |key| alloc.free(key.path);
        self.files.deinit(alloc);
        self.hunks.deinit(alloc);
        self.* = .{};
    }

    pub fn active(self: *const Fold) bool {
        return self.files.items.len != 0 or self.hunks.items.len != 0;
    }

    /// Hide the hunk body at `full_i`. False when there is no body, or it is already hidden.
    pub fn closeHunk(self: *Fold, alloc: Allocator, rows: []const Row, full_i: usize) Allocator.Error!bool {
        const hi = hunkAt(rows, full_i) orelse return false;
        if (!hasHunkBody(rows, hi)) return false;
        const hh = rows[hi].hunk_header;
        if (self.hunkClosed(hh.path, hh.group, hh.old_start, hh.new_start)) return false;
        const path = try alloc.dupe(u8, hh.path);
        errdefer alloc.free(path);
        try self.hunks.append(alloc, .{
            .path = path,
            .group = hh.group,
            .old_start = hh.old_start,
            .new_start = hh.new_start,
        });
        return true;
    }

    /// Show the hunk body at `full_i`. False when it is not folded.
    pub fn openHunk(self: *Fold, alloc: Allocator, rows: []const Row, full_i: usize) bool {
        const hi = hunkAt(rows, full_i) orelse return false;
        const hh = rows[hi].hunk_header;
        for (self.hunks.items, 0..) |key, i| {
            if (!sameHunk(key, hh.path, hh.group, hh.old_start, hh.new_start)) continue;
            alloc.free(self.hunks.orderedRemove(i).path);
            return true;
        }
        return false;
    }

    /// Hide every hunk of the file at `full_i`. False on a section header, a file
    /// with no body, or a file that is already folded.
    pub fn closeFile(self: *Fold, alloc: Allocator, rows: []const Row, full_i: usize) Allocator.Error!bool {
        const fi = fileAt(rows, full_i) orelse return false;
        if (!hasFileBody(rows, fi)) return false;
        const fh = rows[fi].file_header;
        if (self.fileClosed(fh)) return false;
        const path = try alloc.dupe(u8, fh.path);
        errdefer alloc.free(path);
        try self.files.append(alloc, .{ .path = path, .group = fh.group });
        return true;
    }

    /// Show the file at `full_i`. Hunks folded on their own stay folded.
    pub fn openFile(self: *Fold, alloc: Allocator, rows: []const Row, full_i: usize) bool {
        const fi = fileAt(rows, full_i) orelse return false;
        const fh = rows[fi].file_header;
        for (self.files.items, 0..) |key, i| {
            if (key.group != fh.group or !std.mem.eql(u8, key.path, fh.path)) continue;
            alloc.free(self.files.orderedRemove(i).path);
            return true;
        }
        return false;
    }

    /// Open the file at `full_i` and every hunk fold in that file.
    /// False when that file and its hunks are already open, or `full_i` is a section header.
    pub fn openInFile(self: *Fold, alloc: Allocator, rows: []const Row, full_i: usize) bool {
        const fi = fileAt(rows, full_i) orelse return false;
        const fh = rows[fi].file_header;
        var changed = false;
        var i = self.files.items.len;
        while (i > 0) {
            i -= 1;
            const key = self.files.items[i];
            if (key.group != fh.group or !std.mem.eql(u8, key.path, fh.path)) continue;
            alloc.free(self.files.orderedRemove(i).path);
            changed = true;
        }
        i = self.hunks.items.len;
        while (i > 0) {
            i -= 1;
            const key = self.hunks.items[i];
            if (key.group != fh.group or !std.mem.eql(u8, key.path, fh.path)) continue;
            alloc.free(self.hunks.orderedRemove(i).path);
            changed = true;
        }
        return changed;
    }

    /// Open the file and the hunk that hide `full_i`. False when that row is not folded away.
    pub fn reveal(self: *Fold, alloc: Allocator, rows: []const Row, full_i: usize) bool {
        const file_opened = self.openFile(alloc, rows, full_i);
        const hunk_opened = self.openHunk(alloc, rows, full_i);
        return file_opened or hunk_opened;
    }

    /// Drop keys that match no row in `rows`.
    pub fn prune(self: *Fold, alloc: Allocator, rows: []const Row) void {
        var i = self.files.items.len;
        while (i > 0) {
            i -= 1;
            if (fileListed(rows, self.files.items[i])) continue;
            alloc.free(self.files.orderedRemove(i).path);
        }
        i = self.hunks.items.len;
        while (i > 0) {
            i -= 1;
            if (hunkListed(rows, self.hunks.items[i])) continue;
            alloc.free(self.hunks.orderedRemove(i).path);
        }
    }

    /// Rows that stay on screen. Folded headers are marked. The caller frees the slice.
    /// Source rows are not modified.
    pub fn project(self: *const Fold, alloc: Allocator, rows: []const Row) Allocator.Error![]Row {
        var out: std.ArrayList(Row) = .empty;
        errdefer out.deinit(alloc);
        var i: usize = 0;
        while (i < rows.len) {
            switch (rows[i]) {
                .section_header => {
                    try out.append(alloc, rows[i]);
                    i += 1;
                },
                .file_header => |fh| {
                    if (self.fileClosed(fh) and hasFileBody(rows, i)) {
                        var row = rows[i];
                        row.file_header.folded = true;
                        try out.append(alloc, row);
                        i = nextFile(rows, i);
                    } else {
                        try out.append(alloc, rows[i]);
                        i += 1;
                    }
                },
                .hunk_header => |hh| {
                    if (self.hunkClosed(hh.path, hh.group, hh.old_start, hh.new_start) and hasHunkBody(rows, i)) {
                        var row = rows[i];
                        row.hunk_header.folded = true;
                        try out.append(alloc, row);
                        i = nextHunk(rows, i);
                    } else {
                        try out.append(alloc, rows[i]);
                        i += 1;
                    }
                },
                .line => {
                    try out.append(alloc, rows[i]);
                    i += 1;
                },
            }
        }
        return try out.toOwnedSlice(alloc);
    }

    fn fileClosed(self: *const Fold, fh: row_mod.FileHeader) bool {
        for (self.files.items) |key| {
            if (key.group == fh.group and std.mem.eql(u8, key.path, fh.path)) return true;
        }
        return false;
    }

    fn hunkClosed(self: *const Fold, path: []const u8, group: ?diff.Group, old_start: u32, new_start: u32) bool {
        for (self.hunks.items) |key| {
            if (sameHunk(key, path, group, old_start, new_start)) return true;
        }
        return false;
    }
};

fn sameHunk(key: HunkKey, path: []const u8, group: ?diff.Group, old_start: u32, new_start: u32) bool {
    return key.group == group and key.old_start == old_start and key.new_start == new_start and
        std.mem.eql(u8, key.path, path);
}

fn fileAt(rows: []const Row, full_i: usize) ?usize {
    if (rows.len == 0) return null;
    const cur = row_mod.clampCursor(full_i, rows.len);
    if (rows[cur] == .section_header) return null;
    return nav.currentFileStart(rows, cur);
}

fn hunkAt(rows: []const Row, full_i: usize) ?usize {
    if (rows.len == 0) return null;
    return nav.currentHunkInFile(rows, full_i);
}

fn hasFileBody(rows: []const Row, header: usize) bool {
    if (header + 1 >= rows.len) return false;
    return switch (rows[header + 1]) {
        .section_header, .file_header => false,
        else => true,
    };
}

fn hasHunkBody(rows: []const Row, header: usize) bool {
    if (header + 1 >= rows.len) return false;
    return rows[header + 1] == .line;
}

fn nextFile(rows: []const Row, header: usize) usize {
    var i = header + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .file_header, .section_header => return i,
            else => {},
        }
    }
    return rows.len;
}

fn nextHunk(rows: []const Row, header: usize) usize {
    var i = header + 1;
    while (i < rows.len) : (i += 1) {
        if (rows[i] != .line) return i;
    }
    return rows.len;
}

fn fileListed(rows: []const Row, key: FileKey) bool {
    for (rows) |row| {
        switch (row) {
            .file_header => |fh| if (key.group == fh.group and std.mem.eql(u8, key.path, fh.path)) return true,
            else => {},
        }
    }
    return false;
}

fn hunkListed(rows: []const Row, key: HunkKey) bool {
    for (rows) |row| {
        switch (row) {
            .hunk_header => |hh| if (sameHunk(key, hh.path, hh.group, hh.old_start, hh.new_start)) return true,
            else => {},
        }
    }
    return false;
}

fn sameRow(a: Row, b: Row) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .section_header => |g| g == b.section_header,
        .file_header => |fh| fh.group == b.file_header.group and std.mem.eql(u8, fh.path, b.file_header.path),
        .hunk_header => |hh| hh.group == b.hunk_header.group and hh.old_start == b.hunk_header.old_start and
            hh.new_start == b.hunk_header.new_start and std.mem.eql(u8, hh.path, b.hunk_header.path),
        .line => |ln| ln.kind == b.line.kind and ln.old_no == b.line.old_no and ln.new_no == b.line.new_no and
            std.mem.eql(u8, ln.path, b.line.path) and std.mem.eql(u8, ln.text, b.line.text),
    };
}

/// Index of `full_i` in `shown`. A hidden row lands on the header that still shows it.
pub fn shownIndex(full: []const Row, shown: []const Row, full_i: usize) usize {
    if (shown.len == 0 or full.len == 0) return 0;
    const want = row_mod.clampCursor(full_i, full.len);
    var s: usize = 0;
    var last: usize = 0;
    for (full, 0..) |row, f| {
        if (s >= shown.len) break;
        if (!sameRow(row, shown[s])) continue;
        if (f > want) break;
        if (f == want) return s;
        last = s;
        s += 1;
    }
    return last;
}

const testing = std.testing;

const two_hunks =
    \\diff --git a/f b/f
    \\--- a/f
    \\+++ b/f
    \\@@ -1,3 +1,3 @@
    \\ keep
    \\-OLD1
    \\+NEW1
    \\ tail
    \\@@ -10,3 +10,3 @@
    \\ keep2
    \\-OLD2
    \\+NEW2
    \\ tail2
;

fn parseRows(alloc: Allocator, text: []const u8) !struct { d: diff.Diff, rows: []Row } {
    var d = try diff.parse(alloc, text);
    errdefer d.deinit();
    const rows = try row_mod.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

fn hasLine(rows: []const Row, text: []const u8) bool {
    for (rows) |row| {
        switch (row) {
            .line => |ln| if (std.mem.eql(u8, ln.text, text)) return true,
            else => {},
        }
    }
    return false;
}

test "folding a hunk hides its lines and leaves the header" {
    const alloc = testing.allocator;
    var parsed = try parseRows(alloc, two_hunks);
    defer parsed.d.deinit();
    defer alloc.free(parsed.rows);
    const rows = parsed.rows;

    var fold: Fold = .{};
    defer fold.deinit(alloc);
    try testing.expect(try fold.closeHunk(alloc, rows, 3));
    try testing.expect(!try fold.closeHunk(alloc, rows, 3));

    const shown = try fold.project(alloc, rows);
    defer alloc.free(shown);
    try testing.expect(!rows[1].hunk_header.folded);
    try testing.expect(shown[1].hunk_header.folded);
    try testing.expect(!hasLine(shown, "OLD1"));
    try testing.expect(!hasLine(shown, "NEW1"));
    try testing.expect(hasLine(shown, "OLD2"));
    try testing.expectEqual(1, shownIndex(rows, shown, 3));
    try testing.expectEqual(1, shownIndex(rows, shown, 1));

    try testing.expect(fold.openHunk(alloc, rows, 1));
    try testing.expect(!fold.active());
}

test "folding a file hides its hunks and keeps an inner hunk fold" {
    const alloc = testing.allocator;
    var parsed = try parseRows(alloc, two_hunks);
    defer parsed.d.deinit();
    defer alloc.free(parsed.rows);
    const rows = parsed.rows;

    var fold: Fold = .{};
    defer fold.deinit(alloc);
    try testing.expect(try fold.closeHunk(alloc, rows, 1));
    try testing.expect(try fold.closeFile(alloc, rows, 4));

    const closed = try fold.project(alloc, rows);
    defer alloc.free(closed);
    try testing.expectEqual(1, closed.len);
    try testing.expect(closed[0].file_header.folded);
    try testing.expect(!rows[0].file_header.folded);
    try testing.expectEqual(0, shownIndex(rows, closed, 4));

    try testing.expect(fold.openFile(alloc, rows, 0));
    const opened = try fold.project(alloc, rows);
    defer alloc.free(opened);
    try testing.expect(!hasLine(opened, "OLD1"));
    try testing.expect(hasLine(opened, "OLD2"));
    try testing.expect(opened[1].hunk_header.folded);
}

test "openInFile opens the file and every hunk in it" {
    const alloc = testing.allocator;
    var parsed = try parseRows(alloc, two_hunks);
    defer parsed.d.deinit();
    defer alloc.free(parsed.rows);
    const rows = parsed.rows;

    var first: ?usize = null;
    var second: ?usize = null;
    for (rows, 0..) |row, i| {
        if (row != .hunk_header) continue;
        if (first == null) {
            first = i;
        } else {
            second = i;
            break;
        }
    }
    const h0 = first orelse return error.TestUnexpectedResult;
    const h1 = second orelse return error.TestUnexpectedResult;

    var fold: Fold = .{};
    defer fold.deinit(alloc);
    try testing.expect(try fold.closeHunk(alloc, rows, h0));
    try testing.expect(try fold.closeHunk(alloc, rows, h1));
    try testing.expect(try fold.closeFile(alloc, rows, h0));

    // From the file header: the file fold and both hunk folds open.
    try testing.expect(fold.openInFile(alloc, rows, 0));
    try testing.expect(!fold.active());

    try testing.expect(try fold.closeHunk(alloc, rows, h0));
    try testing.expect(try fold.closeHunk(alloc, rows, h1));
    try testing.expect(fold.openInFile(alloc, rows, h1 + 1));
    try testing.expect(!fold.active());
    try testing.expect(!fold.openInFile(alloc, rows, h1 + 1));
}

test "a file header with no body and a section header do not fold" {
    const alloc = testing.allocator;
    const binary =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var parsed = try parseRows(alloc, binary);
    defer parsed.d.deinit();
    defer alloc.free(parsed.rows);

    var fold: Fold = .{};
    defer fold.deinit(alloc);
    try testing.expect(!try fold.closeFile(alloc, parsed.rows, 0));
    try testing.expect(!fold.active());

    var grouped = try diff.parsePieces(alloc, &.{
        .{ .text = two_hunks, .group = .unstaged },
        .{ .text = two_hunks, .group = .staged },
    });
    defer grouped.deinit();
    const grows = try row_mod.flatten(alloc, &grouped);
    defer alloc.free(grows);
    try testing.expect(!try fold.closeFile(alloc, grows, 0));
    var staged_at: ?usize = null;
    for (grows, 0..) |row, i| {
        switch (row) {
            .file_header => |fh| if (fh.group == .staged) {
                staged_at = i;
                break;
            },
            else => {},
        }
    }
    const staged = staged_at orelse return error.TestUnexpectedResult;
    try testing.expect(try fold.closeFile(alloc, grows, staged));
    try testing.expect(!try fold.closeFile(alloc, grows, staged));
    const shown = try fold.project(alloc, grows);
    defer alloc.free(shown);
    try testing.expect(hasLine(shown, "OLD1"));
    var staged_lines: usize = 0;
    var seen_staged = false;
    for (shown) |row| {
        switch (row) {
            .section_header => |g| seen_staged = g == .staged,
            .line => if (seen_staged) {
                staged_lines += 1;
            },
            .file_header => |fh| if (fh.group == .unstaged) {
                try testing.expect(!fh.folded);
            } else if (fh.group == .staged) {
                try testing.expect(fh.folded);
            },
            else => {},
        }
    }
    try testing.expectEqual(0, staged_lines);
}

test "prune drops a key the new rows do not contain" {
    const alloc = testing.allocator;
    var parsed = try parseRows(alloc, two_hunks);
    defer parsed.d.deinit();
    defer alloc.free(parsed.rows);

    var fold: Fold = .{};
    defer fold.deinit(alloc);
    try testing.expect(try fold.closeHunk(alloc, parsed.rows, 1));
    try testing.expect(try fold.closeFile(alloc, parsed.rows, 0));

    const binary =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var next = try parseRows(alloc, binary);
    defer next.d.deinit();
    defer alloc.free(next.rows);
    fold.prune(alloc, next.rows);
    try testing.expect(!fold.active());
}

test "reveal opens the file and the hunk that hide a line" {
    const alloc = testing.allocator;
    var parsed = try parseRows(alloc, two_hunks);
    defer parsed.d.deinit();
    defer alloc.free(parsed.rows);
    const rows = parsed.rows;

    var fold: Fold = .{};
    defer fold.deinit(alloc);
    try testing.expect(try fold.closeHunk(alloc, rows, 1));
    try testing.expect(try fold.closeFile(alloc, rows, 0));
    try testing.expect(fold.reveal(alloc, rows, 3));
    try testing.expect(!fold.active());
    try testing.expect(!fold.reveal(alloc, rows, 3));
}
