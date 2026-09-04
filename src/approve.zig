//! Hunk/file fingerprints and `.rv/approved.json`.
//!
//! A hunk hash is add/delete lines in order, including kind so `-foo` ≠ `+foo`.
//! `@@` numbers, context, meta, section text, and git group are ignored. A
//! hunk-less file hashes its bytes with a distinct type tag.
//!
//! The store is a multiset of `{path, hash}` (hex on disk). Missing file → empty.
//! `save` is atomic. A live hunk/file is approved when `take` consumes a yet-unused
//! entry with the same path+hash. `unapprove` removes one match; `prune` drops
//! entries with no live match. Group is not part of identity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const diff = @import("diff");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [Sha256.digest_length]u8;
const hash_hex_len = Sha256.digest_length * 2;

const hunk_tag: u8 = 1;
const file_tag: u8 = 2;

/// SHA-256 of this hunk's add/delete lines (kind + length + text, in order).
pub fn fingerprintHunk(hunk: diff.Hunk) Hash {
    var hasher = Sha256.init(.{});
    hasher.update(&.{hunk_tag});
    for (hunk.lines) |line| {
        const kind_byte: u8 = switch (line.kind) {
            .add => '+',
            .delete => '-',
            .context, .meta => continue,
        };
        hasher.update(&.{kind_byte});
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(line.text.len), .little);
        hasher.update(&len_buf);
        hasher.update(line.text);
    }
    return hasher.finalResult();
}

/// SHA-256 of file bytes with a type tag that cannot collide with a hunk hash.
pub fn fingerprintFile(bytes: []const u8) Hash {
    var hasher = Sha256.init(.{});
    hasher.update(&.{file_tag});
    hasher.update(bytes);
    return hasher.finalResult();
}

pub const schema_version: u32 = 1;
pub const rel_path = ".rv/approved.json";

pub const Entry = struct {
    path: []const u8,
    hash: Hash,
};

pub const Approved = struct {
    arena: ArenaAllocator,
    entries: std.ArrayList(Entry),

    pub fn deinit(self: *Approved) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Path is copied into the arena. Duplicate path+hash pairs are kept (multiset).
    pub fn append(self: *Approved, path: []const u8, hash: Hash) Allocator.Error!void {
        const alloc = self.arena.allocator();
        try self.entries.append(alloc, .{
            .path = try alloc.dupe(u8, path),
            .hash = hash,
        });
    }

    /// First unused store entry with this path+hash. `used` is parallel to `entries`.
    pub fn take(self: *const Approved, used: []bool, path: []const u8, hash: Hash) bool {
        for (self.entries.items, used) |e, *u| {
            if (u.*) continue;
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (!std.mem.eql(u8, &e.hash, &hash)) continue;
            u.* = true;
            return true;
        }
        return false;
    }

    /// Remove one matching entry (store order). Remaining entries keep order.
    pub fn unapprove(self: *Approved, path: []const u8, hash: Hash) error{NotFound}!void {
        for (self.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (!std.mem.eql(u8, &e.hash, &hash)) continue;
            _ = self.entries.orderedRemove(i);
            return;
        }
        return error.NotFound;
    }

    /// Drop entries that do not consume a live identity (diff order, multiset).
    pub fn prune(self: *Approved, alloc: Allocator, live: []const Entry) Allocator.Error!void {
        const used = try alloc.alloc(bool, self.entries.items.len);
        defer alloc.free(used);
        @memset(used, false);
        for (live) |item| {
            _ = self.take(used, item.path, item.hash);
        }
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (!used[i]) _ = self.entries.orderedRemove(i);
        }
    }
};

pub const LoadError = error{ InvalidJson, InvalidHash } ||
    Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError;

pub const SaveError = error{WriteFailed} || Allocator.Error ||
    Io.Dir.CreateFileAtomicError || Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

pub fn initEmpty(alloc: Allocator) Approved {
    return .{ .arena = ArenaAllocator.init(alloc), .entries = .empty };
}

pub fn load(alloc: Allocator, io: Io, root: Io.Dir) LoadError!Approved {
    const raw = root.readFileAlloc(io, rel_path, alloc, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return initEmpty(alloc),
        else => return err,
    };
    defer alloc.free(raw);
    return try parseJson(alloc, raw);
}

pub fn save(self: *const Approved, alloc: Allocator, io: Io, root: Io.Dir) SaveError!void {
    const bytes = try stringify(self, alloc);
    defer alloc.free(bytes);
    var af = try root.createFileAtomic(io, rel_path, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    af.file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
    try af.replace(io);
}

const WireEntry = struct {
    path: []const u8,
    hash: []const u8,
};

const WireFile = struct {
    version: u32 = schema_version,
    entries: []const WireEntry = &.{},
};

fn parseHash(hex: []const u8) error{InvalidHash}!Hash {
    if (hex.len != hash_hex_len) return error.InvalidHash;
    var out: Hash = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidHash;
    return out;
}

fn parseJson(alloc: Allocator, raw: []const u8) LoadError!Approved {
    var parsed = std.json.parseFromSlice(WireFile, alloc, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();

    var approved = initEmpty(alloc);
    errdefer approved.deinit();
    for (parsed.value.entries) |we| {
        try approved.append(we.path, try parseHash(we.hash));
    }
    return approved;
}

fn stringify(self: *const Approved, alloc: Allocator) Allocator.Error![]u8 {
    const hex_bufs = try alloc.alloc([hash_hex_len]u8, self.entries.items.len);
    defer alloc.free(hex_bufs);
    var wire_entries: std.ArrayList(WireEntry) = .empty;
    defer wire_entries.deinit(alloc);
    try wire_entries.ensureTotalCapacity(alloc, self.entries.items.len);
    for (self.entries.items, 0..) |e, i| {
        hex_bufs[i] = std.fmt.bytesToHex(e.hash, .lower);
        wire_entries.appendAssumeCapacity(.{
            .path = e.path,
            .hash = &hex_bufs[i],
        });
    }
    const wire: WireFile = .{
        .version = schema_version,
        .entries = wire_entries.items,
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

fn parseOneHunk(input: []const u8) !diff.Diff {
    var d = try diff.parse(testing.allocator, input);
    errdefer d.deinit();
    try testing.expectEqual(1, d.files.len);
    try testing.expectEqual(1, d.files[0].hunks.len);
    return d;
}

test "same add/delete at a new @@ line is the same hash" {
    const a =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-old
        \\+new
    ;
    const b =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -40,3 +40,3 @@ later section
        \\ other context
        \\-old
        \\+new
        \\ more
    ;
    var da = try parseOneHunk(a);
    defer da.deinit();
    var db = try parseOneHunk(b);
    defer db.deinit();
    try testing.expectEqual(fingerprintHunk(da.files[0].hunks[0]), fingerprintHunk(db.files[0].hunks[0]));
}

test "edited add/delete is a different hash" {
    const orig =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const edited =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+changed
    ;
    var da = try parseOneHunk(orig);
    defer da.deinit();
    var db = try parseOneHunk(edited);
    defer db.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        &fingerprintHunk(da.files[0].hunks[0]),
        &fingerprintHunk(db.files[0].hunks[0]),
    ));
}

test "delete foo is not add foo" {
    const del =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +0,0 @@
        \\-foo
    ;
    const add =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -0,0 +1 @@
        \\+foo
    ;
    var da = try parseOneHunk(del);
    defer da.deinit();
    var db = try parseOneHunk(add);
    defer db.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        &fingerprintHunk(da.files[0].hunks[0]),
        &fingerprintHunk(db.files[0].hunks[0]),
    ));
}

test "context meta section and group are unused" {
    const with_noise =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,3 +1,3 @@ labeled
        \\ ctx
        \\-old
        \\+new
        \\\ No newline at end of file
        \\ more
    ;
    const bare =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -9 +9 @@
        \\-old
        \\+new
    ;
    var da = try parseOneHunk(with_noise);
    defer da.deinit();
    var db = try parseOneHunk(bare);
    defer db.deinit();
    try testing.expectEqual(fingerprintHunk(da.files[0].hunks[0]), fingerprintHunk(db.files[0].hunks[0]));

    var grouped = try diff.parsePieces(testing.allocator, &.{
        .{ .text = bare, .group = .staged },
    });
    defer grouped.deinit();
    try testing.expectEqual(diff.Group.staged, grouped.files[0].group.?);
    try testing.expectEqual(fingerprintHunk(db.files[0].hunks[0]), fingerprintHunk(grouped.files[0].hunks[0]));
}

test "hunk merge is a different hash from either piece" {
    const split =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\@@ -3 +3 @@
        \\-c
        \\+d
    ;
    const merged =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,3 +1,3 @@
        \\-a
        \\+b
        \\ ctx
        \\-c
        \\+d
    ;
    var ds = try diff.parse(testing.allocator, split);
    defer ds.deinit();
    var dm = try diff.parse(testing.allocator, merged);
    defer dm.deinit();
    try testing.expectEqual(2, ds.files[0].hunks.len);
    try testing.expectEqual(1, dm.files[0].hunks.len);
    const h0 = fingerprintHunk(ds.files[0].hunks[0]);
    const h1 = fingerprintHunk(ds.files[0].hunks[1]);
    const hm = fingerprintHunk(dm.files[0].hunks[0]);
    try testing.expect(!std.mem.eql(u8, &h0, &hm));
    try testing.expect(!std.mem.eql(u8, &h1, &hm));
    try testing.expect(!std.mem.eql(u8, &h0, &h1));
}

test "length-prefix: add a then delete b is not add a-b" {
    const two =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\+a
        \\-b
    ;
    const one =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -0,0 +1 @@
        \\+a-b
    ;
    var da = try parseOneHunk(two);
    defer da.deinit();
    var db = try parseOneHunk(one);
    defer db.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        &fingerprintHunk(da.files[0].hunks[0]),
        &fingerprintHunk(db.files[0].hunks[0]),
    ));
}

test "hunk-less file bytes change is a new hash" {
    try testing.expectEqual(fingerprintFile(""), fingerprintFile(""));
    try testing.expect(!std.mem.eql(u8, &fingerprintFile("abc"), &fingerprintFile("abd")));
    try testing.expect(!std.mem.eql(u8, &fingerprintFile(""), &fingerprintFile("x")));
}

test "hunk tag cannot collide with file tag" {
    const empty_hunk =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\ same
    ;
    var d = try parseOneHunk(empty_hunk);
    defer d.deinit();
    try testing.expect(!std.mem.eql(u8, &fingerprintHunk(d.files[0].hunks[0]), &fingerprintFile("")));
}

test "load missing file is empty" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    var approved = try load(alloc, io, tmp.dir);
    defer approved.deinit();
    try testing.expectEqual(0, approved.entries.items.len);
}

test "two identical entries roundtrip as a multiset" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    const hash = fingerprintFile("bytes");
    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append("bin.dat", hash);
    try approved.append("bin.dat", hash);
    try save(&approved, alloc, io, tmp.dir);

    var loaded = try load(alloc, io, tmp.dir);
    defer loaded.deinit();
    try testing.expectEqual(2, loaded.entries.items.len);
    try testing.expectEqualStrings("bin.dat", loaded.entries.items[0].path);
    try testing.expectEqualStrings("bin.dat", loaded.entries.items[1].path);
    try testing.expectEqual(hash, loaded.entries.items[0].hash);
    try testing.expectEqual(hash, loaded.entries.items[1].hash);

    const raw = try tmp.dir.readFileAlloc(io, rel_path, alloc, .limited(1024 * 1024));
    defer alloc.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"version\": 1") != null);
    const hex = std.fmt.bytesToHex(hash, .lower);
    try testing.expect(std.mem.indexOf(u8, raw, &hex) != null);
}

test "invalid json and invalid hash" {
    try testing.expectError(error.InvalidJson, parseJson(testing.allocator, "{"));
    const bad_len =
        \\{"version":1,"entries":[{"path":"f","hash":"abcd"}]}
    ;
    try testing.expectError(error.InvalidHash, parseJson(testing.allocator, bad_len));
    const bad_hex =
        \\{"version":1,"entries":[{"path":"f","hash":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}]}
    ;
    try testing.expectError(error.InvalidHash, parseJson(testing.allocator, bad_hex));
}

test "two identical hunks: approve one, one remains unmatched" {
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
    var d = try diff.parse(testing.allocator, txt);
    defer d.deinit();
    try testing.expectEqual(2, d.files[0].hunks.len);
    const path = d.files[0].displayPath();
    const h0 = fingerprintHunk(d.files[0].hunks[0]);
    const h1 = fingerprintHunk(d.files[0].hunks[1]);
    try testing.expectEqual(h0, h1);

    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(path, h0);
    var used = [_]bool{false};
    try testing.expect(approved.take(&used, path, h0));
    try testing.expect(!approved.take(&used, path, h1));
    try testing.expectEqual(1, approved.entries.items.len);
}

test "unapprove removes one matching entry" {
    const hash = fingerprintFile("x");
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append("f.txt", hash);
    try approved.append("f.txt", hash);
    try approved.unapprove("f.txt", hash);
    try testing.expectEqual(1, approved.entries.items.len);
    try approved.unapprove("f.txt", hash);
    try testing.expectEqual(0, approved.entries.items.len);
    try testing.expectError(error.NotFound, approved.unapprove("f.txt", hash));
}

test "prune drops entries with no live match" {
    const alloc = testing.allocator;
    const hunk_txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(alloc, hunk_txt);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const hunk_hash = fingerprintHunk(d.files[0].hunks[0]);
    const file_hash = fingerprintFile("abc");

    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, hunk_hash);
    try approved.append("bin.dat", file_hash);

    try approved.prune(alloc, &.{.{ .path = path, .hash = hunk_hash }});
    try testing.expectEqual(1, approved.entries.items.len);
    try testing.expectEqualStrings(path, approved.entries.items[0].path);
    try testing.expectEqual(hunk_hash, approved.entries.items[0].hash);

    try approved.prune(alloc, &.{.{ .path = "bin.dat", .hash = fingerprintFile("abd") }});
    try testing.expectEqual(0, approved.entries.items.len);
}

test "group is unused; path change does not match" {
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var unstaged = try diff.parsePieces(testing.allocator, &.{
        .{ .text = txt, .group = .unstaged },
    });
    defer unstaged.deinit();
    var staged = try diff.parsePieces(testing.allocator, &.{
        .{ .text = txt, .group = .staged },
    });
    defer staged.deinit();
    try testing.expectEqual(diff.Group.unstaged, unstaged.files[0].group.?);
    try testing.expectEqual(diff.Group.staged, staged.files[0].group.?);
    const hash = fingerprintHunk(unstaged.files[0].hunks[0]);
    try testing.expectEqual(hash, fingerprintHunk(staged.files[0].hunks[0]));

    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(unstaged.files[0].displayPath(), hash);
    var used = [_]bool{false};
    try testing.expect(approved.take(&used, staged.files[0].displayPath(), hash));

    used[0] = false;
    try testing.expect(!approved.take(&used, "renamed.txt", hash));
}
