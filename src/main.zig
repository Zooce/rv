//! `rv` entry point.
//!
//! MVP-0.2: load the smart-default git diff and print a short summary.
//! No alt screen / TUI yet (that is MVP-0.3).

const std = @import("std");
const git = @import("git");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var d = git.loadDefaultDiff(alloc, io) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NotARepository => "not a git repository",
            error.GitNotFound => "git executable not found",
            error.GitFailed => "git command failed",
            error.OutOfMemory => "out of memory",
            error.BadHunkHeader => "failed to parse unified diff (bad hunk header)",
        };
        std.debug.print("rv: {s}\n", .{msg});
        std.process.exit(1);
    };
    defer d.deinit();

    if (d.files.len == 0) {
        std.debug.print("rv: no changes to review\n", .{});
        return;
    }

    std.debug.print("rv: {d} file(s), {d} hunk(s)\n", .{ d.files.len, d.hunk_count });
    for (d.files) |f| {
        std.debug.print("  {s}\n", .{f.displayPath()});
    }
}
