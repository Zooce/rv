//! Temp dir under `/tmp` for tests that must not nest inside the project work
//! tree (e.g. git fixtures where `rev-parse` would walk up into `.git`).
//! Test-only; import from `test` blocks, not production paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Temp dir outside any project work tree (`/tmp/rv-…`).
pub const IsolatedTmp = struct {
    path: []u8,
    dir: Io.Dir,

    pub fn create(alloc: Allocator, io: Io) !IsolatedTmp {
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var name_buf: [16]u8 = undefined;
        const name = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);
        const path = try std.fmt.allocPrint(alloc, "/tmp/rv-{s}", .{name});
        errdefer alloc.free(path);

        try Io.Dir.createDirAbsolute(io, path, .default_dir);
        errdefer Io.Dir.cwd().deleteTree(io, path) catch {};

        const dir = try Io.Dir.openDirAbsolute(io, path, .{});
        return .{ .path = path, .dir = dir };
    }

    pub fn cleanup(self: *IsolatedTmp, alloc: Allocator, io: Io) void {
        self.dir.close(io);
        // Best-effort remove; tests should not leave junk on success.
        Io.Dir.cwd().deleteTree(io, self.path) catch {};
        alloc.free(self.path);
        self.* = undefined;
    }

    pub fn cwd(self: IsolatedTmp) std.process.Child.Cwd {
        return .{ .path = self.path };
    }

    pub fn write(self: IsolatedTmp, io: Io, sub_path: []const u8, data: []const u8) !void {
        try self.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }
};
