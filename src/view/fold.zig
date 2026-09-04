//! Session folds: hide hunk bodies and file contents after flatten.
//! Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;
const row_mod = @import("row.zig");
const Row = row_mod.Row;
const clampCursor = row_mod.clampCursor;
const nav = @import("nav.zig");

/// File identity: `displayPath()` + group. `path` is owned in `Set`, borrowed
/// in `Target`.
pub const FileId = struct {
    path: []const u8,
    group: ?diff.Group,
};

/// Hunk identity: file identity + `@@` `old_start`/`new_start`. `path` is
/// owned in `Set`, borrowed in `Target`.
pub const HunkId = struct {
    path: []const u8,
    group: ?diff.Group,
    old_start: u32,
    new_start: u32,
};

/// Innermost fold target at the cursor.
pub const Target = union(enum) {
    file: FileId,
    hunk: HunkId,
};

/// Collapsed files and hunks for this session. Paths are owned.
pub const Set = struct {
    files: std.ArrayList(FileId) = .empty,
    hunks: std.ArrayList(HunkId) = .empty,

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.files.items) |id| alloc.free(id.path);
        for (self.hunks.items) |id| alloc.free(id.path);
        self.files.deinit(alloc);
        self.hunks.deinit(alloc);
    }

    pub fn containsFile(self: *const Set, path: []const u8, group: ?diff.Group) bool {
        for (self.files.items) |id| {
            if (id.group == group and std.mem.eql(u8, id.path, path)) return true;
        }
        return false;
    }

    pub fn containsHunk(
        self: *const Set,
        path: []const u8,
        group: ?diff.Group,
        old_start: u32,
        new_start: u32,
    ) bool {
        for (self.hunks.items) |id| {
            if (id.group == group and id.old_start == old_start and id.new_start == new_start and
                std.mem.eql(u8, id.path, path)) return true;
        }
        return false;
    }

    /// Innermost toggle target, or `null` when `za` is a no-op (section,
    /// empty list, hunk-less file, empty hunk). Already-folded headers are
    /// always a target so they can expand.
    pub fn targetAt(self: *const Set, rows: []const Row, cursor: usize) ?Target {
        if (rows.len == 0) return null;
        const cur = clampCursor(cursor, rows.len);
        switch (rows[cur]) {
            .section_header => return null,
            .file_header => |fh| {
                if (!self.containsFile(fh.path, fh.group) and !fileHasHunks(rows, cur)) return null;
                return .{ .file = .{ .path = fh.path, .group = fh.group } };
            },
            .hunk_header => |hh| {
                const fi = nav.currentFileStart(rows, cur) orelse return null;
                const fh = rows[fi].file_header;
                if (!self.containsHunk(fh.path, fh.group, hh.old_start, hh.new_start) and
                    !hunkHasLines(rows, cur)) return null;
                return .{ .hunk = .{
                    .path = fh.path,
                    .group = fh.group,
                    .old_start = hh.old_start,
                    .new_start = hh.new_start,
                } };
            },
            .line => {
                const hi = nav.currentHunkInFile(rows, cur) orelse return null;
                const hh = rows[hi].hunk_header;
                const fi = nav.currentFileStart(rows, cur) orelse return null;
                const fh = rows[fi].file_header;
                return .{ .hunk = .{
                    .path = fh.path,
                    .group = fh.group,
                    .old_start = hh.old_start,
                    .new_start = hh.new_start,
                } };
            },
        }
    }

    /// Add the target if absent, remove it if present. Dupes `path` on add.
    pub fn toggle(self: *Set, alloc: Allocator, target: Target) Allocator.Error!void {
        switch (target) {
            .file => |f| {
                if (self.containsFile(f.path, f.group)) {
                    self.removeFile(alloc, f.path, f.group);
                } else {
                    try self.addFile(alloc, f.path, f.group);
                }
            },
            .hunk => |h| {
                if (self.containsHunk(h.path, h.group, h.old_start, h.new_start)) {
                    self.removeHunk(alloc, h.path, h.group, h.old_start, h.new_start);
                } else {
                    try self.addHunk(alloc, h.path, h.group, h.old_start, h.new_start);
                }
            },
        }
    }

    /// Collapse every file that has hunks. Per-hunk folds are kept.
    pub fn collapseAllFiles(self: *Set, alloc: Allocator, flatten: []const Row) Allocator.Error!void {
        const start = self.files.items.len;
        errdefer {
            while (self.files.items.len > start) {
                alloc.free(self.files.swapRemove(self.files.items.len - 1).path);
            }
        }
        for (flatten, 0..) |item, i| {
            switch (item) {
                .file_header => |fh| {
                    if (self.containsFile(fh.path, fh.group)) continue;
                    if (!fileHasHunks(flatten, i)) continue;
                    try self.addFile(alloc, fh.path, fh.group);
                },
                else => {},
            }
        }
    }

    /// Drop every file and hunk fold.
    pub fn expandAll(self: *Set, alloc: Allocator) void {
        for (self.files.items) |id| alloc.free(id.path);
        for (self.hunks.items) |id| alloc.free(id.path);
        self.files.clearRetainingCapacity();
        self.hunks.clearRetainingCapacity();
    }

    /// Clear folds that hide `flatten_i`. File headers and sections are
    /// already visible. Opening a file fold also collapses every other hunk
    /// in that file so only the landing hunk body is shown. Returns true
    /// when the set changed.
    pub fn expandTo(self: *Set, alloc: Allocator, flatten: []const Row, flatten_i: usize) Allocator.Error!bool {
        if (flatten.len == 0) return false;
        const cur = clampCursor(flatten_i, flatten.len);
        switch (flatten[cur]) {
            .section_header, .file_header => return false,
            .hunk_header, .line => {},
        }
        const fi = nav.currentFileStart(flatten, cur) orelse return false;
        const fh = flatten[fi].file_header;
        const hi = nav.currentHunkInFile(flatten, cur);
        var changed = false;
        if (self.containsFile(fh.path, fh.group)) {
            if (hi) |keep| try self.foldOtherHunks(alloc, flatten, fi, keep);
            self.removeFile(alloc, fh.path, fh.group);
            changed = true;
        }
        if (flatten[cur] == .line) {
            if (hi) |hunk_i| {
                const hh = flatten[hunk_i].hunk_header;
                if (self.containsHunk(fh.path, fh.group, hh.old_start, hh.new_start)) {
                    self.removeHunk(alloc, fh.path, fh.group, hh.old_start, hh.new_start);
                    changed = true;
                }
            }
        }
        return changed;
    }

    fn foldOtherHunks(self: *Set, alloc: Allocator, flatten: []const Row, file_i: usize, keep_hunk_i: usize) Allocator.Error!void {
        const fh = flatten[file_i].file_header;
        const start = self.hunks.items.len;
        errdefer {
            while (self.hunks.items.len > start) {
                alloc.free(self.hunks.swapRemove(self.hunks.items.len - 1).path);
            }
        }
        var i = file_i + 1;
        while (i < flatten.len) : (i += 1) {
            switch (flatten[i]) {
                .file_header, .section_header => return,
                .hunk_header => |hh| {
                    if (i == keep_hunk_i) continue;
                    if (self.containsHunk(fh.path, fh.group, hh.old_start, hh.new_start)) continue;
                    try self.addHunk(alloc, fh.path, fh.group, hh.old_start, hh.new_start);
                },
                .line => {},
            }
        }
    }

    /// Drop identities that are not in `flatten`. Stale paths are freed.
    pub fn prune(self: *Set, alloc: Allocator, flatten: []const Row) void {
        var fi: usize = 0;
        while (fi < self.files.items.len) {
            const id = self.files.items[fi];
            if (fileInFlatten(flatten, id.path, id.group)) {
                fi += 1;
            } else {
                alloc.free(self.files.swapRemove(fi).path);
            }
        }
        var hi: usize = 0;
        while (hi < self.hunks.items.len) {
            const id = self.hunks.items[hi];
            if (hunkInFlatten(flatten, id)) {
                hi += 1;
            } else {
                alloc.free(self.hunks.swapRemove(hi).path);
            }
        }
    }

    fn addFile(self: *Set, alloc: Allocator, path: []const u8, group: ?diff.Group) Allocator.Error!void {
        const owned = try alloc.dupe(u8, path);
        errdefer alloc.free(owned);
        try self.files.append(alloc, .{ .path = owned, .group = group });
    }

    fn removeFile(self: *Set, alloc: Allocator, path: []const u8, group: ?diff.Group) void {
        for (self.files.items, 0..) |id, i| {
            if (id.group == group and std.mem.eql(u8, id.path, path)) {
                alloc.free(self.files.swapRemove(i).path);
                return;
            }
        }
    }

    fn addHunk(
        self: *Set,
        alloc: Allocator,
        path: []const u8,
        group: ?diff.Group,
        old_start: u32,
        new_start: u32,
    ) Allocator.Error!void {
        const owned = try alloc.dupe(u8, path);
        errdefer alloc.free(owned);
        try self.hunks.append(alloc, .{
            .path = owned,
            .group = group,
            .old_start = old_start,
            .new_start = new_start,
        });
    }

    fn removeHunk(
        self: *Set,
        alloc: Allocator,
        path: []const u8,
        group: ?diff.Group,
        old_start: u32,
        new_start: u32,
    ) void {
        for (self.hunks.items, 0..) |id, i| {
            if (id.group == group and id.old_start == old_start and id.new_start == new_start and
                std.mem.eql(u8, id.path, path))
            {
                alloc.free(self.hunks.swapRemove(i).path);
                return;
            }
        }
    }
};

/// Visible rows: flatten with folded file contents and hunk bodies omitted.
/// Copied `Row` values; strings still borrow from the parent `Diff`.
pub fn visibleRows(alloc: Allocator, flatten: []const Row, set: *const Set) Allocator.Error![]Row {
    var out: std.ArrayList(Row) = .empty;
    errdefer out.deinit(alloc);
    var filter: Filter = .{};
    for (flatten) |item| {
        if (filter.include(set, item)) try out.append(alloc, item);
    }
    return try out.toOwnedSlice(alloc);
}

/// Visible index for a flatten cursor. Hidden rows land on the header that
/// omitted them (last included row at or before `flatten_i`).
pub fn visibleIndex(flatten: []const Row, set: *const Set, flatten_i: usize) usize {
    if (flatten.len == 0) return 0;
    const want = if (flatten_i >= flatten.len) flatten.len - 1 else flatten_i;
    var vis: usize = 0;
    var last: usize = 0;
    var filter: Filter = .{};
    for (flatten, 0..) |item, i| {
        if (filter.include(set, item)) {
            last = vis;
            if (i == want) return vis;
            vis += 1;
        } else if (i == want) {
            return last;
        }
    }
    return last;
}

/// Flatten index of visible row `visible_i`. Out of range lands on the last
/// visible flatten row.
pub fn flattenIndex(flatten: []const Row, set: *const Set, visible_i: usize) usize {
    if (flatten.len == 0) return 0;
    var vis: usize = 0;
    var last_flat: usize = 0;
    var filter: Filter = .{};
    for (flatten, 0..) |item, i| {
        if (filter.include(set, item)) {
            last_flat = i;
            if (vis == visible_i) return i;
            vis += 1;
        }
    }
    return last_flat;
}

/// Row index of `target`'s header in `rows`, or 0 when missing.
pub fn cursorForTarget(rows: []const Row, target: Target) usize {
    switch (target) {
        .file => |f| {
            for (rows, 0..) |item, i| {
                switch (item) {
                    .file_header => |fh| {
                        if (fh.group == f.group and std.mem.eql(u8, fh.path, f.path)) return i;
                    },
                    else => {},
                }
            }
        },
        .hunk => |h| {
            var path: []const u8 = "";
            var group: ?diff.Group = null;
            for (rows, 0..) |item, i| {
                switch (item) {
                    .file_header => |fh| {
                        path = fh.path;
                        group = fh.group;
                    },
                    .hunk_header => |hh| {
                        if (group == h.group and hh.old_start == h.old_start and hh.new_start == h.new_start and
                            std.mem.eql(u8, path, h.path)) return i;
                    },
                    else => {},
                }
            }
        },
    }
    return 0;
}

const Filter = struct {
    skip_file: bool = false,
    skip_hunk: bool = false,
    file_path: []const u8 = "",
    file_group: ?diff.Group = null,

    fn include(self: *Filter, set: *const Set, item: Row) bool {
        switch (item) {
            .section_header => {
                self.skip_file = false;
                self.skip_hunk = false;
                return true;
            },
            .file_header => |fh| {
                self.file_path = fh.path;
                self.file_group = fh.group;
                self.skip_file = set.containsFile(fh.path, fh.group);
                self.skip_hunk = false;
                return true;
            },
            .hunk_header => |hh| {
                if (self.skip_file) return false;
                self.skip_hunk = set.containsHunk(self.file_path, self.file_group, hh.old_start, hh.new_start);
                return true;
            },
            .line => return !(self.skip_file or self.skip_hunk),
        }
    }
};

fn fileHasHunks(rows: []const Row, file_i: usize) bool {
    var i = file_i + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .hunk_header => return true,
            .file_header, .section_header => return false,
            .line => {},
        }
    }
    return false;
}

fn hunkHasLines(rows: []const Row, hunk_i: usize) bool {
    var i = hunk_i + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .line => return true,
            .hunk_header, .file_header, .section_header => return false,
        }
    }
    return false;
}

fn fileInFlatten(flatten: []const Row, path: []const u8, group: ?diff.Group) bool {
    for (flatten) |item| {
        switch (item) {
            .file_header => |fh| {
                if (fh.group == group and std.mem.eql(u8, fh.path, path)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn hunkInFlatten(flatten: []const Row, id: HunkId) bool {
    var path: []const u8 = "";
    var group: ?diff.Group = null;
    for (flatten) |item| {
        switch (item) {
            .file_header => |fh| {
                path = fh.path;
                group = fh.group;
            },
            .hunk_header => |hh| {
                if (group == id.group and hh.old_start == id.old_start and hh.new_start == id.new_start and
                    std.mem.eql(u8, path, id.path)) return true;
            },
            else => {},
        }
    }
    return false;
}

const testing = std.testing;

/// 0 file, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add,
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

test "visibleRows empty set copies flatten" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    const vis = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(vis);
    try testing.expectEqual(fix.rows.len, vis.len);
    try testing.expect(vis[1] == .hunk_header);
    try testing.expect(vis[2] == .line);
}

test "toggle hunk hides body and lands on header" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);

    const target = set.targetAt(fix.rows, 2).?;
    try testing.expect(target == .hunk);
    try set.toggle(testing.allocator, target);

    const vis = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(vis);
    try testing.expectEqual(9, vis.len);
    try testing.expect(vis[0] == .file_header);
    try testing.expect(vis[1] == .hunk_header);
    try testing.expect(vis[2] == .hunk_header);
    try testing.expect(vis[3] == .line);
    try testing.expectEqual(1, cursorForTarget(vis, target));
    try testing.expectEqual(1, visibleIndex(fix.rows, &set, 2));
    try testing.expectEqual(1, visibleIndex(fix.rows, &set, 3));
}

test "toggle file hides hunks; hunk fold kept after expand" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);

    const hunk = set.targetAt(fix.rows, 1).?;
    try set.toggle(testing.allocator, hunk);
    const file = set.targetAt(fix.rows, 0).?;
    try testing.expect(file == .file);
    try set.toggle(testing.allocator, file);

    const collapsed = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(collapsed);
    try testing.expectEqual(5, collapsed.len);
    try testing.expect(collapsed[0] == .file_header);
    try testing.expect(collapsed[1] == .file_header);
    try testing.expectEqualStrings("b", collapsed[1].file_header.path);
    try testing.expectEqual(0, cursorForTarget(collapsed, file));

    try set.toggle(testing.allocator, file);
    const expanded = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(expanded);
    try testing.expectEqual(9, expanded.len);
    try testing.expect(expanded[1] == .hunk_header);
    try testing.expect(expanded[2] == .hunk_header);
}

test "section and hunk-less file are no-ops" {
    const binary =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var d = try diff.parse(testing.allocator, binary);
    defer d.deinit();
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    try testing.expect(set.targetAt(rows, 0) == null);
    try testing.expect(set.targetAt(&.{}, 0) == null);

    const grouped =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d2 = try diff.parsePieces(testing.allocator, &.{
        .{ .text = grouped, .group = .unstaged },
    });
    defer d2.deinit();
    const rows2 = try row_mod.flatten(testing.allocator, &d2);
    defer testing.allocator.free(rows2);
    try testing.expect(rows2[0] == .section_header);
    try testing.expect(set.targetAt(rows2, 0) == null);
    try testing.expect(set.targetAt(rows2, 2) != null);
}

test "prune drops identities gone from flatten" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    try set.toggle(testing.allocator, set.targetAt(fix.rows, 0).?);
    try set.toggle(testing.allocator, .{ .file = .{ .path = "gone", .group = null } });
    try testing.expect(set.containsFile("gone", null));
    set.prune(testing.allocator, fix.rows);
    try testing.expect(!set.containsFile("gone", null));
    try testing.expect(set.containsFile("a", null));
}

test "file fold is path and group" {
    const txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = txt, .group = .unstaged },
        .{ .text = txt, .group = .staged },
    });
    defer d.deinit();
    const rows = try row_mod.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    try set.toggle(testing.allocator, set.targetAt(rows, 1).?);
    try testing.expect(set.containsFile("a", .unstaged));
    try testing.expect(!set.containsFile("a", .staged));
    const vis = try visibleRows(testing.allocator, rows, &set);
    defer testing.allocator.free(vis);
    try testing.expectEqual(7, vis.len);
    try testing.expect(vis[1] == .file_header);
    try testing.expect(vis[1].file_header.group == .unstaged);
    try testing.expect(vis[2] == .section_header);
    try testing.expect(vis[3] == .file_header);
    try testing.expect(vis[3].file_header.group == .staged);
    try testing.expect(vis[4] == .hunk_header);
}

test "collapseAllFiles then expandAll" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    try set.toggle(testing.allocator, set.targetAt(fix.rows, 1).?);
    try set.collapseAllFiles(testing.allocator, fix.rows);
    try testing.expect(set.containsFile("a", null));
    try testing.expect(set.containsFile("b", null));
    const collapsed = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(collapsed);
    try testing.expectEqual(2, collapsed.len);
    try testing.expect(collapsed[0] == .file_header);
    try testing.expect(collapsed[1] == .file_header);

    try set.toggle(testing.allocator, .{ .file = .{ .path = "a", .group = null } });
    const after_file = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(after_file);
    try testing.expectEqual(6, after_file.len);
    try testing.expect(after_file[1] == .hunk_header);
    try testing.expect(after_file[2] == .hunk_header);

    set.expandAll(testing.allocator);
    try testing.expectEqual(0, set.files.items.len);
    try testing.expectEqual(0, set.hunks.items.len);
    const open = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(open);
    try testing.expectEqual(fix.rows.len, open.len);
}

test "expandTo unhides a folded line; file header is a no-op" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    try set.toggle(testing.allocator, set.targetAt(fix.rows, 1).?);
    try set.toggle(testing.allocator, set.targetAt(fix.rows, 0).?);
    try testing.expect(!(try set.expandTo(testing.allocator, fix.rows, 0)));
    try testing.expect(set.containsFile("a", null));
    try testing.expect(try set.expandTo(testing.allocator, fix.rows, 2));
    try testing.expect(!set.containsFile("a", null));
    try testing.expect(!set.containsHunk("a", null, 1, 1));
    try testing.expect(set.containsHunk("a", null, 10, 10));
    const vis = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(vis);
    try testing.expect(vis[2] == .line);
    try testing.expectEqual(2, visibleIndex(fix.rows, &set, 2));
    try testing.expect(vis[4] == .hunk_header);
    try testing.expect(vis[5] == .file_header);
}

test "expandTo from a file fold opens only the hit hunk" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    try set.toggle(testing.allocator, set.targetAt(fix.rows, 0).?);
    try testing.expect(try set.expandTo(testing.allocator, fix.rows, 5));
    try testing.expect(!set.containsFile("a", null));
    try testing.expect(set.containsHunk("a", null, 1, 1));
    try testing.expect(!set.containsHunk("a", null, 10, 10));
    const vis = try visibleRows(testing.allocator, fix.rows, &set);
    defer testing.allocator.free(vis);
    try testing.expect(vis[1] == .hunk_header);
    try testing.expect(vis[2] == .hunk_header);
    try testing.expect(vis[3] == .line);
    try testing.expect(vis[5] == .file_header);
}

test "flattenIndex inverts visibleIndex on shown rows" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    var set: Set = .{};
    defer set.deinit(testing.allocator);
    try set.toggle(testing.allocator, set.targetAt(fix.rows, 1).?);
    try testing.expectEqual(0, flattenIndex(fix.rows, &set, 0));
    try testing.expectEqual(1, flattenIndex(fix.rows, &set, 1));
    try testing.expectEqual(4, flattenIndex(fix.rows, &set, 2));
    try testing.expectEqual(1, visibleIndex(fix.rows, &set, flattenIndex(fix.rows, &set, 1)));
    try testing.expectEqual(2, visibleIndex(fix.rows, &set, flattenIndex(fix.rows, &set, 2)));
}
