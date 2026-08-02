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

    fn alloc(self: *Review) Allocator {
        return self.arena.allocator();
    }

    pub fn openCount(self: *const Review) usize {
        var n: usize = 0;
        for (self.comments.items) |c| {
            if (c.state == .open) n += 1;
        }
        return n;
    }

    pub fn hasOpenAt(self: *const Review, path: []const u8, old_line: ?u32, new_line: ?u32) bool {
        for (self.comments.items) |c| {
            if (c.state != .open) continue;
            if (!std.mem.eql(u8, c.path, path)) continue;
            if (lineMatch(c.old_line, old_line) or lineMatch(c.new_line, new_line)) return true;
        }
        return false;
    }

    pub fn addOpen(
        self: *Review,
        path: []const u8,
        old_line: ?u32,
        new_line: ?u32,
        side: ?Side,
        body: []const u8,
    ) Allocator.Error![]const u8 {
        const a = self.alloc();
        const id = try std.fmt.allocPrint(a, "{d}", .{self.next_seq});
        self.next_seq += 1;
        try self.comments.append(a, .{
            .id = id,
            .path = try a.dupe(u8, path),
            .old_line = old_line,
            .new_line = new_line,
            .side = side,
            .body = try a.dupe(u8, body),
            .state = .open,
        });
        return id;
    }
};

fn lineMatch(a: ?u32, b: ?u32) bool {
    return (a orelse return false) == (b orelse return false);
}

pub const LoadError = error{ InvalidJson, InvalidState, InvalidSide } ||
    Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError;

pub const SaveError = error{WriteFailed} || Allocator.Error ||
    Io.Dir.CreateFileAtomicError || Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

pub fn initEmpty(gpa: Allocator, review_id: []const u8) Allocator.Error!Review {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    // Allocate before moving `arena` (field order would snapshot empty state).
    const id = try arena.allocator().dupe(u8, review_id);
    return .{ .arena = arena, .id = id, .comments = .empty, .next_seq = 1 };
}

pub fn load(gpa: Allocator, io: Io, root: Io.Dir, review_id: []const u8) LoadError!Review {
    const rel = try reviewRelPath(gpa, review_id);
    defer gpa.free(rel);
    const raw = root.readFileAlloc(io, rel, gpa, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return try initEmpty(gpa, review_id),
        else => return err,
    };
    defer gpa.free(raw);
    return try parseJson(gpa, raw, review_id);
}

pub fn save(self: *const Review, gpa: Allocator, io: Io, root: Io.Dir) SaveError!void {
    const rel = try reviewRelPath(gpa, self.id);
    defer gpa.free(rel);
    const bytes = try stringify(self, gpa);
    defer gpa.free(bytes);
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

fn parseJson(gpa: Allocator, raw: []const u8, fallback_id: []const u8) LoadError!Review {
    var parsed = std.json.parseFromSlice(WireReview, gpa, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();
    const wire = parsed.value;

    var review = try initEmpty(gpa, if (wire.id.len > 0) wire.id else fallback_id);
    errdefer review.deinit();
    const a = review.alloc();
    var max_seq: u64 = 0;
    for (wire.comments) |wc| {
        const state = std.meta.stringToEnum(State, wc.state) orelse return error.InvalidState;
        const side: ?Side = if (wc.side) |s|
            (std.meta.stringToEnum(Side, s) orelse return error.InvalidSide)
        else
            null;
        if (std.fmt.parseInt(u64, wc.id, 10) catch null) |n| {
            if (n > max_seq) max_seq = n;
        }
        try review.comments.append(a, .{
            .id = try a.dupe(u8, wc.id),
            .path = try a.dupe(u8, wc.path),
            .old_line = wc.old_line,
            .new_line = wc.new_line,
            .side = side,
            .body = try a.dupe(u8, wc.body),
            .state = state,
        });
    }
    review.next_seq = max_seq + 1;
    return review;
}

fn stringify(self: *const Review, gpa: Allocator) Allocator.Error![]u8 {
    var wire_comments: std.ArrayList(WireComment) = .empty;
    defer wire_comments.deinit(gpa);
    try wire_comments.ensureTotalCapacity(gpa, self.comments.items.len);
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
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    std.json.Stringify.value(wire, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

const testing = std.testing;
const builtin = @import("builtin");

test "addOpen hasOpenAt and roundtrip" {
    var r = try initEmpty(testing.allocator, default_review_id);
    defer r.deinit();
    try testing.expectEqualStrings("1", try r.addOpen("a.zig", null, 10, .new, "fix"));
    try testing.expect(r.hasOpenAt("a.zig", null, 10));
    try testing.expect(!r.hasOpenAt("a.zig", null, 11));
    try testing.expectEqual(1, r.openCount());
    const bad =
        \\{"version":1,"id":"current","comments":[{"id":"1","path":"f","body":"x","state":"nope"}]}
    ;
    try testing.expectError(error.InvalidState, parseJson(testing.allocator, bad, default_review_id));

    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    var name_buf: [12]u8 = undefined;
    const name = std.base64.url_safe.Encoder.encode(&name_buf, &rnd);
    const path = try std.fmt.allocPrint(alloc, "/tmp/rv-store-{s}", .{name});
    defer alloc.free(path);
    try Io.Dir.createDirAbsolute(io, path, .default_dir);
    defer Io.Dir.cwd().deleteTree(io, path) catch {};
    var dir = try Io.Dir.openDirAbsolute(io, path, .{});
    defer dir.close(io);

    var empty = try load(alloc, io, dir, default_review_id);
    defer empty.deinit();
    try testing.expectEqual(0, empty.comments.items.len);
    try save(&r, alloc, io, dir);
    var loaded = try load(alloc, io, dir, default_review_id);
    defer loaded.deinit();
    try testing.expectEqualStrings("a.zig", loaded.comments.items[0].path);
    try testing.expectEqual(10, loaded.comments.items[0].new_line.?);
    try testing.expectEqualStrings("fix", loaded.comments.items[0].body);
    try testing.expectEqualStrings("2", try loaded.addOpen("b.zig", 1, null, .old, "x"));
}
