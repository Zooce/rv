//! Comment store: `.rv/reviews/<id>.json` (default `current`). Arena-owned;
//! missing file → empty; `save` is atomic. Anchors: path + optional lines/side.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;

pub const default_review_id = "current";
pub const schema_version: u32 = 1;

pub const State = enum { open, resolved };
pub const Side = enum { old, new, context };

pub const Comment = struct {
    id: []const u8,
    path: []const u8,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    side: ?Side = null,
    body: []const u8,
    state: State = .open,
};

pub const Review = struct {
    arena: ArenaAllocator,
    id: []const u8,
    comments: std.ArrayList(Comment),
    next_seq: u64,

    pub fn deinit(self: *Review) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn openCount(self: *const Review) usize {
        var n: usize = 0;
        for (self.comments.items) |c| {
            if (c.state == .open) n += 1;
        }
        return n;
    }

    /// First live comment in store order at this path matching the given line(s).
    /// `firstAt(path, null, null)` matches only path-only (file) rows. A lookup
    /// with any line number never hits a file comment.
    pub fn firstAt(self: *const Review, path: []const u8, old_line: ?u32, new_line: ?u32) ?usize {
        const want_file = old_line == null and new_line == null;
        for (self.comments.items, 0..) |c, i| {
            if (c.state != .open) continue;
            if (!std.mem.eql(u8, c.path, path)) continue;
            const file_comment = c.old_line == null and c.new_line == null;
            if (want_file) {
                if (file_comment) return i;
            } else if (!file_comment) {
                if (lineMatch(c.old_line, old_line) or lineMatch(c.new_line, new_line)) return i;
            }
        }
        return null;
    }

    pub fn addOpen(
        self: *Review,
        path: []const u8,
        old_line: ?u32,
        new_line: ?u32,
        side: ?Side,
        body: []const u8,
    ) Allocator.Error![]const u8 {
        const alloc = self.arena.allocator();
        const id = try std.fmt.allocPrint(alloc, "{d}", .{self.next_seq});
        self.next_seq += 1;
        try self.comments.append(alloc, .{
            .id = id,
            .path = try alloc.dupe(u8, path),
            .old_line = old_line,
            .new_line = new_line,
            .side = side,
            .body = try alloc.dupe(u8, body),
            .state = .open,
        });
        return id;
    }

    /// Overwrite `body` only. Path, lines, side, id, and state stay put.
    pub fn setBody(self: *Review, id: []const u8, body: []const u8) (error{NotFound} || Allocator.Error)!void {
        const i = self.findIndex(id) orelse return error.NotFound;
        self.comments.items[i].body = try self.arena.allocator().dupe(u8, body);
    }

    /// Overwrite old/new line and side. Path, body, id, and state stay put.
    pub fn setLines(
        self: *Review,
        id: []const u8,
        old_line: ?u32,
        new_line: ?u32,
        side: ?Side,
    ) error{NotFound}!void {
        const i = self.findIndex(id) orelse return error.NotFound;
        self.comments.items[i].old_line = old_line;
        self.comments.items[i].new_line = new_line;
        self.comments.items[i].side = side;
    }

    /// Comment with `id`, or null if none.
    pub fn find(self: *const Review, id: []const u8) ?*const Comment {
        return if (self.findIndex(id)) |i| &self.comments.items[i] else null;
    }

    fn findIndex(self: *const Review, id: []const u8) ?usize {
        for (self.comments.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.id, id)) return i;
        }
        return null;
    }

    /// Delete every id. All must exist before any write (all-or-nothing).
    /// Remaining comments keep store order. Duplicate ids delete once.
    pub fn remove(self: *Review, ids: []const []const u8) error{NotFound}!void {
        for (ids) |id| {
            if (self.findIndex(id) == null) return error.NotFound;
        }
        var i = self.comments.items.len;
        while (i > 0) {
            i -= 1;
            const cid = self.comments.items[i].id;
            for (ids) |id| {
                if (std.mem.eql(u8, cid, id)) {
                    _ = self.comments.orderedRemove(i);
                    break;
                }
            }
        }
    }
};

fn lineMatch(a: ?u32, b: ?u32) bool {
    return (a orelse return false) == (b orelse return false);
}

pub const LoadError = error{ InvalidJson, InvalidState, InvalidSide } ||
    Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError;

pub const SaveError = error{WriteFailed} || Allocator.Error ||
    Io.Dir.CreateFileAtomicError || Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

pub fn initEmpty(alloc: Allocator, review_id: []const u8) Allocator.Error!Review {
    var arena = ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    // Allocate before moving `arena` (field order would snapshot empty state).
    const id = try arena.allocator().dupe(u8, review_id);
    return .{ .arena = arena, .id = id, .comments = .empty, .next_seq = 1 };
}

pub fn load(alloc: Allocator, io: Io, root: Io.Dir, review_id: []const u8) LoadError!Review {
    const rel = try reviewRelPath(alloc, review_id);
    defer alloc.free(rel);
    const raw = root.readFileAlloc(io, rel, alloc, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return try initEmpty(alloc, review_id),
        else => return err,
    };
    defer alloc.free(raw);
    return try parseJson(alloc, raw, review_id);
}

pub fn save(self: *const Review, alloc: Allocator, io: Io, root: Io.Dir) SaveError!void {
    const rel = try reviewRelPath(alloc, self.id);
    defer alloc.free(rel);
    const bytes = try stringify(self, alloc);
    defer alloc.free(bytes);
    var af = try root.createFileAtomic(io, rel, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    af.file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
    try af.replace(io);
}

pub fn reviewRelPath(alloc: Allocator, review_id: []const u8) Allocator.Error![]u8 {
    return try std.fmt.allocPrint(alloc, ".rv/reviews/{s}.json", .{review_id});
}

const WireComment = struct {
    id: []const u8,
    path: []const u8,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    side: ?[]const u8 = null,
    body: []const u8,
    state: []const u8 = "open",
};

const WireReview = struct {
    version: u32 = schema_version,
    id: []const u8,
    comments: []const WireComment = &.{},
};

fn parseJson(alloc: Allocator, raw: []const u8, fallback_id: []const u8) LoadError!Review {
    var parsed = std.json.parseFromSlice(WireReview, alloc, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();
    const wire = parsed.value;

    var review = try initEmpty(alloc, if (wire.id.len > 0) wire.id else fallback_id);
    errdefer review.deinit();
    var max_seq: u64 = 0;
    for (wire.comments) |wc| {
        const state = std.meta.stringToEnum(State, wc.state) orelse return error.InvalidState;
        if (std.fmt.parseInt(u64, wc.id, 10) catch null) |n| {
            if (n > max_seq) max_seq = n;
        }
        // Do not migrate resolved rows back to open.
        if (state == .resolved) continue;
        const side: ?Side = if (wc.side) |s|
            (std.meta.stringToEnum(Side, s) orelse return error.InvalidSide)
        else
            null;
        try review.comments.append(review.arena.allocator(), .{
            .id = try review.arena.allocator().dupe(u8, wc.id),
            .path = try review.arena.allocator().dupe(u8, wc.path),
            .old_line = wc.old_line,
            .new_line = wc.new_line,
            .side = side,
            .body = try review.arena.allocator().dupe(u8, wc.body),
            .state = state,
        });
    }
    review.next_seq = max_seq + 1;
    return review;
}

fn stringify(self: *const Review, alloc: Allocator) Allocator.Error![]u8 {
    var wire_comments: std.ArrayList(WireComment) = .empty;
    defer wire_comments.deinit(alloc);
    try wire_comments.ensureTotalCapacity(alloc, self.comments.items.len);
    for (self.comments.items) |c| {
        wire_comments.appendAssumeCapacity(.{
            .id = c.id,
            .path = c.path,
            .old_line = c.old_line,
            .new_line = c.new_line,
            .side = if (c.side) |s| @tagName(s) else null,
            .body = c.body,
            .state = @tagName(c.state),
        });
    }
    const wire: WireReview = .{
        .version = schema_version,
        .id = self.id,
        .comments = wire_comments.items,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(wire, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

const testing = std.testing;
const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

test "addOpen firstAt and roundtrip" {
    var r = try initEmpty(testing.allocator, default_review_id);
    defer r.deinit();
    try testing.expectEqualStrings("1", try r.addOpen("a.zig", null, 10, .new, "fix"));
    try testing.expect(r.firstAt("a.zig", null, 10) != null);
    try testing.expect(r.firstAt("a.zig", null, 11) == null);
    try testing.expectEqual(1, r.openCount());
    const bad =
        \\{"version":1,"id":"current","comments":[{"id":"1","path":"f","body":"x","state":"nope"}]}
    ;
    try testing.expectError(error.InvalidState, parseJson(testing.allocator, bad, default_review_id));

    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    var empty = try load(alloc, io, tmp.dir, default_review_id);
    defer empty.deinit();
    try testing.expectEqual(0, empty.comments.items.len);
    try save(&r, alloc, io, tmp.dir);
    var loaded = try load(alloc, io, tmp.dir, default_review_id);
    defer loaded.deinit();
    try testing.expectEqualStrings("a.zig", loaded.comments.items[0].path);
    try testing.expectEqual(10, loaded.comments.items[0].new_line.?);
    try testing.expectEqualStrings("fix", loaded.comments.items[0].body);
    try testing.expectEqualStrings("2", try loaded.addOpen("b.zig", 1, null, .old, "x"));
}

test "find" {
    var review = try initEmpty(testing.allocator, default_review_id);
    defer review.deinit();
    const id1 = try review.addOpen("a.zig", null, 1, .new, "one");
    _ = try review.addOpen("b.zig", null, 2, .new, "two");

    try testing.expect(review.find("nope") == null);
    try testing.expectEqualStrings("one", review.find(id1).?.body);
    try testing.expectEqual(State.open, review.find(id1).?.state);
}

test "remove all-or-nothing preserves remaining order" {
    var review = try initEmpty(testing.allocator, default_review_id);
    defer review.deinit();
    const id1 = try review.addOpen("a.zig", null, 1, .new, "one");
    const id2 = try review.addOpen("b.zig", null, 2, .new, "two");
    const id3 = try review.addOpen("c.zig", null, 3, .new, "three");

    try testing.expectError(error.NotFound, review.remove(&.{ id2, "ghost" }));
    try testing.expectEqual(3, review.comments.items.len);
    try testing.expectEqualStrings("two", review.find(id2).?.body);

    try review.remove(&.{id2});
    try testing.expect(review.find(id2) == null);
    try testing.expectEqual(2, review.comments.items.len);
    try testing.expectEqualStrings(id1, review.comments.items[0].id);
    try testing.expectEqualStrings(id3, review.comments.items[1].id);

    try review.remove(&.{ id1, id1 });
    try testing.expect(review.find(id1) == null);
    try testing.expectEqual(1, review.comments.items.len);
    try testing.expectEqualStrings(id3, review.comments.items[0].id);

    try review.remove(&.{id3});
    try testing.expectEqual(0, review.comments.items.len);
    try testing.expectError(error.NotFound, review.remove(&.{"ghost"}));
}

test "load drops resolved comments and keeps next_seq" {
    const raw =
        \\{"version":1,"id":"current","comments":[{"id":"1","path":"a.zig","body":"keep","state":"open"},{"id":"5","path":"b.zig","body":"gone","state":"resolved"}]}
    ;
    var review = try parseJson(testing.allocator, raw, default_review_id);
    defer review.deinit();
    try testing.expectEqual(1, review.comments.items.len);
    try testing.expectEqualStrings("keep", review.find("1").?.body);
    try testing.expect(review.find("5") == null);
    try testing.expectEqual(6, review.next_seq);
    try testing.expectEqual(1, review.openCount());
}

test "firstAt store order and opposite side" {
    var review = try initEmpty(testing.allocator, default_review_id);
    defer review.deinit();
    _ = try review.addOpen("f.zig", null, 10, .new, "new first");
    _ = try review.addOpen("f.zig", 10, null, .old, "old");
    _ = try review.addOpen("f.zig", null, 10, .new, "new second");

    try testing.expectEqual(0, review.firstAt("f.zig", null, 10).?);
    try testing.expectEqual(1, review.firstAt("f.zig", 10, null).?);
    try testing.expect(review.firstAt("f.zig", null, 11) == null);
    try testing.expect(review.firstAt("g.zig", null, 10) == null);

    try review.remove(&.{"1"});
    try testing.expectEqual(1, review.firstAt("f.zig", null, 10).?);
}

test "firstAt path-only is not a line" {
    var review = try initEmpty(testing.allocator, default_review_id);
    defer review.deinit();
    _ = try review.addOpen("f.zig", null, null, null, "file");
    _ = try review.addOpen("f.zig", null, 10, .new, "line");
    _ = try review.addOpen("f.zig", null, null, null, "file second");

    try testing.expectEqual(0, review.firstAt("f.zig", null, null).?);
    try testing.expectEqual(1, review.firstAt("f.zig", null, 10).?);
    try testing.expect(review.firstAt("f.zig", 10, null) == null);
    try testing.expect(review.firstAt("g.zig", null, null) == null);

    try review.remove(&.{"1"});
    try testing.expectEqual(1, review.firstAt("f.zig", null, null).?);
    try testing.expectEqual(0, review.firstAt("f.zig", null, 10).?);
}

test "setBody overwrites body only" {
    var review = try initEmpty(testing.allocator, default_review_id);
    defer review.deinit();
    const id1 = try review.addOpen("a.zig", null, 10, .new, "one");
    const id2 = try review.addOpen("b.zig", 2, null, .old, "other");

    try testing.expectError(error.NotFound, review.setBody("ghost", "x"));
    try review.setBody(id1, "two");

    const c = review.find(id1).?;
    try testing.expectEqualStrings(id1, c.id);
    try testing.expectEqualStrings("a.zig", c.path);
    try testing.expect(c.old_line == null);
    try testing.expectEqual(10, c.new_line.?);
    try testing.expectEqual(Side.new, c.side.?);
    try testing.expectEqual(State.open, c.state);
    try testing.expectEqualStrings("two", c.body);
    try testing.expectEqualStrings("other", review.find(id2).?.body);

    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try save(&review, alloc, io, tmp.dir);
    var loaded = try load(alloc, io, tmp.dir, default_review_id);
    defer loaded.deinit();
    try testing.expectEqualStrings("two", loaded.find(id1).?.body);
    try testing.expectEqualStrings(id1, loaded.find(id1).?.id);
    try testing.expectEqual(10, loaded.find(id1).?.new_line.?);
    try testing.expectEqual(Side.new, loaded.find(id1).?.side.?);
}

test "setLines overwrites lines and side only" {
    var review = try initEmpty(testing.allocator, default_review_id);
    defer review.deinit();
    const id1 = try review.addOpen("a.zig", null, 10, .new, "one");
    const id2 = try review.addOpen("b.zig", 2, null, .old, "other");

    try testing.expectError(error.NotFound, review.setLines("ghost", 1, 2, .context));
    try review.setLines(id1, 4, 8, .context);

    const c = review.find(id1).?;
    try testing.expectEqualStrings(id1, c.id);
    try testing.expectEqualStrings("a.zig", c.path);
    try testing.expectEqual(4, c.old_line.?);
    try testing.expectEqual(8, c.new_line.?);
    try testing.expectEqual(Side.context, c.side.?);
    try testing.expectEqual(State.open, c.state);
    try testing.expectEqualStrings("one", c.body);
    try testing.expectEqualStrings("other", review.find(id2).?.body);

    try review.setLines(id1, 9, null, .old);
    try testing.expectEqual(9, review.find(id1).?.old_line.?);
    try testing.expect(review.find(id1).?.new_line == null);
    try testing.expectEqual(Side.old, review.find(id1).?.side.?);

    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try save(&review, alloc, io, tmp.dir);
    var loaded = try load(alloc, io, tmp.dir, default_review_id);
    defer loaded.deinit();
    try testing.expectEqualStrings("one", loaded.find(id1).?.body);
    try testing.expectEqual(9, loaded.find(id1).?.old_line.?);
    try testing.expect(loaded.find(id1).?.new_line == null);
    try testing.expectEqual(Side.old, loaded.find(id1).?.side.?);
    try testing.expectEqualStrings("a.zig", loaded.find(id1).?.path);
}
