//! Load a parsed `Diff` by shelling out to `git` (no libgit2).
//!
//! ## Smart default
//!
//! 1. **Local changes** — if `git diff HEAD` is non-empty, review that stream.
//!    This is staged **and** unstaged changes to tracked files in one unified
//!    diff (equivalent to combining `git diff` and `git diff --cached`).
//!    Untracked files are **not** included (v1).
//! 2. **Branch vs base** — otherwise compare the current branch to a base:
//!    - Prefer the configured upstream (`@{upstream}`) when it resolves.
//!    - Else `main`, then `master`, when that ref exists.
//!    Range is three-dot: `git diff <base>...HEAD` (merge-base → HEAD).
//!
//! ## Empty diffs
//!
//! No matching changes yields an empty `Diff` (zero files), **not** an error.
//! That covers a clean worktree with nothing ahead of base, and a repo with
//! no commits yet (no `HEAD`).
//!
//! ## Errors
//!
//! - `NotARepository` — cwd is not inside a git work tree.
//! - `GitNotFound` — `git` executable missing from `PATH`.
//! - `GitFailed` — git exited non-zero (or crashed) on a required command.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    NotARepository,
    GitNotFound,
    GitFailed,
} || diff.ParseError;

/// Load the smart-default diff for the process current working directory.
pub fn loadDefaultDiff(alloc: Allocator, io: Io) Error!diff.Diff {
    return loadDefaultDiffCwd(alloc, io, .inherit);
}

/// Same as `loadDefaultDiff`, but run git with an explicit child cwd.
pub fn loadDefaultDiffCwd(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) Error!diff.Diff {
    try ensureInsideWorkTree(alloc, io, cwd);

    // No commits yet → nothing to compare.
    if (!try revExists(alloc, io, cwd, "HEAD")) {
        return try diff.parse(alloc, "");
    }

    // 1. Local staged + unstaged vs HEAD.
    const local = try git(alloc, io, cwd, &.{ "git", "diff", "HEAD" });
    defer alloc.free(local);
    if (local.len > 0) {
        return try diff.parse(alloc, local);
    }

    // 2. Branch vs base (three-dot).
    const base = try resolveBase(alloc, io, cwd) orelse {
        return try diff.parse(alloc, "");
    };
    const range = try std.fmt.allocPrint(alloc, "{s}...HEAD", .{base});
    defer alloc.free(range);

    const branch = try git(alloc, io, cwd, &.{ "git", "diff", range });
    defer alloc.free(branch);
    return try diff.parse(alloc, branch);
}

// --- internals -----------------------------------------------------------

fn ensureInsideWorkTree(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) Error!void {
    const out = git(alloc, io, cwd, &.{ "git", "rev-parse", "--is-inside-work-tree" }) catch |err| switch (err) {
        error.GitFailed => return error.NotARepository,
        else => return err,
    };
    defer alloc.free(out);
    if (std.mem.eql(u8, std.mem.trim(u8, out, " \t\r\n"), "true")) return;
    return error.NotARepository;
}

fn resolveBase(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) Error!?[]const u8 {
    if (try revExists(alloc, io, cwd, "@{upstream}")) return "@{upstream}";
    if (try revExists(alloc, io, cwd, "main")) return "main";
    if (try revExists(alloc, io, cwd, "master")) return "master";
    return null;
}

fn revExists(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, rev: []const u8) Error!bool {
    // `--verify` fails when the rev is missing; `--quiet` suppresses noise.
    // Append `^{commit}` so the rev must resolve to a commit object (git
    // syntax: peel tags/refs down to a commit).
    const as_commit = try std.fmt.allocPrint(alloc, "{s}^{{commit}}", .{rev});
    defer alloc.free(as_commit);

    const out = git(alloc, io, cwd, &.{ "git", "rev-parse", "--verify", "--quiet", as_commit }) catch |err| switch (err) {
        error.GitFailed => return false,
        else => return err,
    };
    alloc.free(out);
    return true;
}

/// Run `argv` (typically a `git …` command). On exit 0, returns owned stdout
/// (caller frees). Non-zero exit / crash → `GitFailed`; missing binary →
/// `GitNotFound`. Pattern matches a small `proc.exec`-style helper.
fn git(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, argv: []const []const u8) Error![]u8 {
    const result = std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = cwd,
        // Diffs can be large in real repos; keep a high but finite cap.
        // Follow-up: stream / bound very large refactors (see goal backlog).
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.GitNotFound,
        else => return error.GitFailed,
    };
    defer {
        alloc.free(result.stderr);
        alloc.free(result.stdout);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }

    return try alloc.dupe(u8, result.stdout);
}

// --- tests ---------------------------------------------------------------
//
// Fixtures live under `/tmp`, not `.zig-cache/tmp`. Nested dirs inside this
// project still belong to the rv work tree, so `git rev-parse` would walk up
// and succeed even without a local `.git`.

const testing = std.testing;
const builtin = @import("builtin");

/// Temp dir outside any project work tree (`/tmp/rv-git-…`).
const IsolatedTmp = struct {
    path: []u8,
    dir: Io.Dir,

    fn create(alloc: Allocator, io: Io) !IsolatedTmp {
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var name_buf: [16]u8 = undefined;
        const name = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);
        const path = try std.fmt.allocPrint(alloc, "/tmp/rv-git-{s}", .{name});
        errdefer alloc.free(path);

        try Io.Dir.createDirAbsolute(io, path, .default_dir);
        errdefer Io.Dir.cwd().deleteTree(io, path) catch {};

        const dir = try Io.Dir.openDirAbsolute(io, path, .{});
        return .{ .path = path, .dir = dir };
    }

    fn cleanup(self: *IsolatedTmp, alloc: Allocator, io: Io) void {
        self.dir.close(io);
        // Best-effort remove; tests should not leave junk on success.
        Io.Dir.cwd().deleteTree(io, self.path) catch {};
        alloc.free(self.path);
        self.* = undefined;
    }

    fn cwd(self: IsolatedTmp) std.process.Child.Cwd {
        return .{ .path = self.path };
    }

    fn write(self: IsolatedTmp, io: Io, sub_path: []const u8, data: []const u8) !void {
        try self.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }
};

/// `git init -b main` plus local user.name / user.email (required for commits).
fn initTestRepo(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) !void {
    try expectGitOk(alloc, io, cwd, &.{ "git", "init", "-b", "main" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "config", "user.email", "rv@test" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "config", "user.name", "rv test" });
}

fn expectGitOk(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !void {
    const out = git(alloc, io, cwd, argv) catch |err| {
        std.debug.print("git failed: {s} ({t})\n", .{ argv[1], err });
        return error.TestUnexpectedResult;
    };
    alloc.free(out);
}

fn expectHasDisplayPath(d: diff.Diff, expected: []const u8) !void {
    for (d.files) |f| {
        if (std.mem.eql(u8, f.displayPath(), expected)) return;
    }
    return error.TestExpectedEqual;
}

test "not a git repository" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);

    try testing.expectError(
        error.NotARepository,
        loadDefaultDiffCwd(alloc, io, tmp.cwd()),
    );
}

test "dirty worktree: staged + unstaged as one stream" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "tracked.txt", "line1\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "tracked.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    // Unstaged change on an existing tracked file.
    try tmp.write(io, "tracked.txt", "line1\nunstaged\n");
    // Staged-only new file.
    try tmp.write(io, "staged.txt", "staged body\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "staged.txt" });

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    try testing.expectEqual(2, d.files.len);
    try expectHasDisplayPath(d, "tracked.txt");
    try expectHasDisplayPath(d, "staged.txt");
}

test "clean feature branch: diff is commits ahead of main only" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);

    // Base on main.
    try tmp.write(io, "shared.txt", "on main\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on main" });

    // Feature branch: add a file and edit the shared one (both should appear
    // in main...HEAD; nothing is local/uncommitted).
    try expectGitOk(alloc, io, cwd, &.{ "git", "checkout", "-b", "feature" });
    try tmp.write(io, "feature-only.txt", "only on feature\n");
    try tmp.write(io, "shared.txt", "on main\nedited on feature\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "feature-only.txt", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on feature" });

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    // Branch-vs-base: exactly the two files changed since main, no local dirt.
    try testing.expectEqual(2, d.files.len);
    try testing.expectEqual(2, d.hunk_count);
    try expectHasDisplayPath(d, "feature-only.txt");
    try expectHasDisplayPath(d, "shared.txt");
}

test "clean main with nothing ahead of base: empty model" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "only.txt", "x\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "only.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();
    try testing.expectEqual(0, d.files.len);
    try testing.expectEqual(0, d.hunk_count);
}
