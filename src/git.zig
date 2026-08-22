//! Load a parsed `Diff` by shelling out to `git` (no libgit2).
//!
//! ## Default (local only)
//!
//! Three groups, in this order, each file tagged (`diff.File.group`):
//!
//! 1. **unstaged** — `git diff` (worktree vs index)
//! 2. **untracked** — `git ls-files --others --exclude-standard`, each path
//!    turned into a new-file unified diff via
//!    `git diff --no-index -- /dev/null <path>`
//! 3. **staged** — `git diff --cached` (index vs HEAD)
//!
//! Empty groups are omitted. A path with both staged and unstaged hunks
//! appears twice (unstaged remainder, then later the staged hunks).
//! Empty untracked files appear as new-file headers (often zero hunks).
//! Binary untracked files follow the same binary placeholder rules as
//! tracked binary adds. Local untracked alone (no tracked changes) is
//! still this path. With no `HEAD` yet, only untracked content is
//! considered (staged is empty).
//!
//! A clean worktree (no local / untracked) yields an empty `Diff`. There is
//! no fall-through to branch-vs-base (`git diff <base>...HEAD`).
//!
//! ## Explicit range
//!
//! `loadRangeDiff` runs `git diff <range>` with the range string as written
//! (no `...` / `..` rewrite). Untracked files are not appended. An empty
//! result is an empty `Diff`. Invalid range is `GitFailed`.
//!
//! ## Empty diffs
//!
//! No matching changes yields an empty `Diff` (zero files), **not** an error.
//! That covers a clean worktree with no untracked files, and a repo with no
//! commits and no untracked files.
//!
//! ## Mutations
//!
//! `mutate` stages, unstages, or discards one path, or one hunk of that path.
//! Allowed combinations:
//!
//! | Action   | Group               | Whole file | One hunk |
//! |----------|---------------------|------------|----------|
//! | stage    | unstaged, untracked | `git add -- <path>` | `git apply --cached` |
//! | unstage  | staged              | `git restore --staged -- <path>` | `git apply --reverse --cached` |
//! | discard  | unstaged            | `git restore --worktree -- <path>` | `git apply --reverse` |
//! | discard  | untracked           | `git clean -f -- <path>` | `git apply --reverse` |
//!
//! Hunk patches are rebuilt from the loaded `diff.Hunk` (and file paths) so
//! what the user saw is what git apply receives. Untracked / new-file hunks
//! use `--- /dev/null` and `new file mode`.
//!
//! Discard on staged is refused (`GitFailed`) so index and worktree are not
//! thrown away in one step. Other disallowed action/group pairs also return
//! `GitFailed`. On `GitFailed` from git itself, `MutateOpts.fail_output` (when
//! set) receives owned stderr, or stdout if stderr is empty.
//!
//! ## Errors
//!
//! - `NotARepository` — cwd is not inside a git work tree.
//! - `GitNotFound` — `git` executable missing from `PATH`.
//! - `GitFailed` — git exited non-zero (or crashed) on a required command,
//!   or the action is not allowed on that group.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    NotARepository,
    GitNotFound,
    GitFailed,
} || diff.ParseError;

/// Load the local-only default diff for the process current working directory.
pub fn loadDefaultDiff(alloc: Allocator, io: Io) Error!diff.Diff {
    return loadDefaultDiffCwd(alloc, io, .inherit);
}

/// Same as `loadDefaultDiff`, but run git with an explicit child cwd.
pub fn loadDefaultDiffCwd(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) Error!diff.Diff {
    try ensureInsideWorkTree(alloc, io, cwd);

    const untracked = try untrackedDiff(alloc, io, cwd);
    defer if (untracked) |u| alloc.free(u);

    var unstaged: ?[]u8 = null;
    defer if (unstaged) |s| alloc.free(s);
    var staged: ?[]u8 = null;
    defer if (staged) |s| alloc.free(s);

    if (try revExists(alloc, io, cwd, "HEAD")) {
        unstaged = try git(alloc, io, cwd, .{ .argv = &.{ "git", "diff" } });
        staged = try git(alloc, io, cwd, .{ .argv = &.{ "git", "diff", "--cached" } });
    }

    return try diff.parsePieces(alloc, &.{
        .{ .text = unstaged orelse "", .group = .unstaged },
        .{ .text = untracked orelse "", .group = .untracked },
        .{ .text = staged orelse "", .group = .staged },
    });
}

/// Load `git diff <range>`. `range` is passed through as written (no
/// `...` / `..` rewrite). Pass `.inherit` for the process cwd.
pub fn loadRangeDiff(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, range: []const u8) Error!diff.Diff {
    try ensureInsideWorkTree(alloc, io, cwd);
    const out = try git(alloc, io, cwd, .{ .argv = &.{ "git", "diff", range } });
    defer alloc.free(out);
    return try diff.parse(alloc, out);
}

pub const Action = enum { stage, unstage, discard };

/// Mutation of one file, or one hunk of that file. `path` is the work-tree
/// path (`File.displayPath()`).
pub const MutateOpts = struct {
    action: Action,
    path: []const u8,
    group: diff.Group,
    /// When set, apply this loaded hunk instead of the whole file.
    hunk: ?*const diff.Hunk = null,
    /// Loaded file for hunk headers (`old_path` / `new_path`). Used when
    /// `hunk` is set; ignored for whole-file mutations.
    file: ?*const diff.File = null,
    /// On `error.GitFailed`, filled with owned git stderr (stdout if stderr
    /// is empty). Caller frees. Unchanged on success and other errors.
    fail_output: ?*[]u8 = null,
};

/// Stage, unstage, or discard one path (or one hunk) in `cwd`. See module
/// docs for the allowed action/group table. Pass `.inherit` for the process cwd.
pub fn mutate(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, opts: MutateOpts) Error!void {
    try ensureInsideWorkTree(alloc, io, cwd);

    const allowed = switch (opts.action) {
        .stage => switch (opts.group) {
            .unstaged, .untracked => true,
            .staged => false,
        },
        .unstage => opts.group == .staged,
        .discard => switch (opts.group) {
            .unstaged, .untracked => true,
            .staged => false,
        },
    };
    if (!allowed) {
        if (opts.fail_output) |slot| {
            slot.* = try alloc.dupe(u8, "action not allowed for this group");
        }
        return error.GitFailed;
    }

    if (opts.hunk) |hunk| {
        const patch = try hunkPatch(alloc, opts.path, opts.group, opts.file, hunk.*);
        defer alloc.free(patch);
        const argv: []const []const u8 = switch (opts.action) {
            .stage => &.{ "git", "apply", "--cached", "-" },
            .unstage => &.{ "git", "apply", "--reverse", "--cached", "-" },
            .discard => &.{ "git", "apply", "--reverse", "-" },
        };
        const out = try git(alloc, io, cwd, .{
            .argv = argv,
            .stdin = patch,
            .fail_output = opts.fail_output,
        });
        alloc.free(out);
        return;
    }

    const argv: []const []const u8 = switch (opts.action) {
        .stage => &.{ "git", "add", "--", opts.path },
        .unstage => &.{ "git", "restore", "--staged", "--", opts.path },
        .discard => switch (opts.group) {
            .unstaged => &.{ "git", "restore", "--worktree", "--", opts.path },
            .untracked => &.{ "git", "clean", "-f", "--", opts.path },
            .staged => unreachable,
        },
    };
    const out = try git(alloc, io, cwd, .{
        .argv = argv,
        .fail_output = opts.fail_output,
    });
    alloc.free(out);
}

// --- internals -----------------------------------------------------------

fn ensureInsideWorkTree(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) Error!void {
    const out = git(alloc, io, cwd, .{ .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" } }) catch |err| switch (err) {
        error.GitFailed => return error.NotARepository,
        else => return err,
    };
    defer alloc.free(out);
    if (std.mem.eql(u8, std.mem.trim(u8, out, " \t\r\n"), "true")) return;
    return error.NotARepository;
}

fn revExists(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, rev: []const u8) Error!bool {
    // `--verify` fails when the rev is missing; `--quiet` suppresses noise.
    // Append `^{commit}` so the rev must resolve to a commit object (git
    // syntax: peel tags/refs down to a commit).
    const as_commit = try std.fmt.allocPrint(alloc, "{s}^{{commit}}", .{rev});
    defer alloc.free(as_commit);

    const out = git(alloc, io, cwd, .{
        .argv = &.{ "git", "rev-parse", "--verify", "--quiet", as_commit },
    }) catch |err| switch (err) {
        error.GitFailed => return false,
        else => return err,
    };
    alloc.free(out);
    return true;
}

/// Unified-diff text for untracked, non-ignored paths (exclude-standard).
/// `null` when there are none. Caller frees a non-null result.
fn untrackedDiff(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) Error!?[]u8 {
    const listing = try git(alloc, io, cwd, .{
        .argv = &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" },
    });
    defer alloc.free(listing);
    if (listing.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, listing, 0);
    while (it.next()) |path| {
        if (path.len == 0) continue;
        // Exit 1 is normal when files differ (always for a real new file).
        const piece = try git(alloc, io, cwd, .{
            .argv = &.{ "git", "diff", "--no-index", "--", "/dev/null", path },
            .allowed_error_code = 1,
        });
        defer alloc.free(piece);
        try out.appendSlice(alloc, piece);
    }
    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

/// Unified patch for one loaded hunk, including `diff --git` / `---` / `+++`
/// headers. `file` supplies old/new paths when present; otherwise untracked
/// is treated as a new file against `/dev/null`.
fn hunkPatch(
    alloc: Allocator,
    path: []const u8,
    group: diff.Group,
    file: ?*const diff.File,
    hunk: diff.Hunk,
) Allocator.Error![]u8 {
    const old_path: ?[]const u8 = if (file) |f| f.old_path else if (group == .untracked) null else path;
    const new_path: ?[]const u8 = if (file) |f| f.new_path else path;
    const a_name = old_path orelse new_path orelse path;
    const b_name = new_path orelse old_path orelse path;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.print(alloc, "diff --git a/{s} b/{s}\n", .{ a_name, b_name });
    if (old_path == null) {
        try out.appendSlice(alloc, "new file mode 100644\n");
    } else if (new_path == null) {
        try out.appendSlice(alloc, "deleted file mode 100644\n");
    }
    if (old_path) |p| {
        try out.print(alloc, "--- a/{s}\n", .{p});
    } else {
        try out.appendSlice(alloc, "--- /dev/null\n");
    }
    if (new_path) |p| {
        try out.print(alloc, "+++ b/{s}\n", .{p});
    } else {
        try out.appendSlice(alloc, "+++ /dev/null\n");
    }

    try out.appendSlice(alloc, "@@ -");
    if (hunk.old_count) |c| {
        try out.print(alloc, "{d},{d}", .{ hunk.old_start, c });
    } else {
        try out.print(alloc, "{d}", .{hunk.old_start});
    }
    try out.appendSlice(alloc, " +");
    if (hunk.new_count) |c| {
        try out.print(alloc, "{d},{d}", .{ hunk.new_start, c });
    } else {
        try out.print(alloc, "{d}", .{hunk.new_start});
    }
    if (hunk.section.len > 0) {
        try out.print(alloc, " @@ {s}\n", .{hunk.section});
    } else {
        try out.appendSlice(alloc, " @@\n");
    }

    for (hunk.lines) |line| {
        if (line.kind == .meta) {
            try out.appendSlice(alloc, "\\ ");
            try out.appendSlice(alloc, line.text);
            try out.append(alloc, '\n');
            continue;
        }
        const marker: u8 = switch (line.kind) {
            .context => ' ',
            .add => '+',
            .delete => '-',
            .meta => unreachable,
        };
        try out.append(alloc, marker);
        try out.appendSlice(alloc, line.text);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Options for `git`. Field defaults match a strict exit-0 success.
const GitOpts = struct {
    argv: []const []const u8,
    /// One additional non-zero exit code treated as success (alongside 0).
    /// Example: `1` for `git diff --no-index`, which exits 1 when the sides
    /// differ. `null` = only exit 0. Not a range — only this exact code.
    allowed_error_code: ?u8 = null,
    /// When set, written to the child's stdin (e.g. a patch for `git apply -`).
    stdin: ?[]const u8 = null,
    /// On `error.GitFailed`, filled with owned stderr (stdout if stderr is
    /// empty). Caller frees. Unchanged on success and other errors.
    fail_output: ?*[]u8 = null,
};

/// Run a `git …` command. On exit 0 (or `allowed_error_code` when set), returns
/// owned stdout (caller frees). Any other exit / crash → `GitFailed`; missing
/// binary → `GitNotFound`.
fn git(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, opts: GitOpts) Error![]u8 {
    var child = std.process.spawn(io, .{
        .argv = opts.argv,
        .cwd = cwd,
        .stdin = if (opts.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.GitNotFound,
        else => return error.GitFailed,
    };
    defer child.kill(io);

    if (opts.stdin) |data| {
        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(io, data) catch {};
            stdin.close(io);
            child.stdin = null;
        }
    }

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const stdout_limit: usize = 64 * 1024 * 1024;
    const stderr_limit: usize = 1024 * 1024;

    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > stdout_limit) return error.GitFailed;
        if (stderr_reader.buffered().len > stderr_limit) return error.GitFailed;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.GitFailed,
    }

    multi_reader.checkAnyError() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GitFailed,
    };

    const term = child.wait(io) catch return error.GitFailed;
    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer alloc.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);

    const success = switch (term) {
        .exited => |code| blk: {
            if (code == 0) break :blk true;
            const allowed = opts.allowed_error_code orelse break :blk false;
            break :blk code == allowed;
        },
        else => false,
    };
    if (success) {
        alloc.free(stderr_slice);
        return stdout_slice;
    }

    defer {
        alloc.free(stderr_slice);
        alloc.free(stdout_slice);
    }
    if (opts.fail_output) |slot| {
        const src = if (stderr_slice.len > 0) stderr_slice else stdout_slice;
        slot.* = try alloc.dupe(u8, src);
    }
    return error.GitFailed;
}

// --- tests ---------------------------------------------------------------
//
// Fixtures use IsolatedTmp under `/tmp` (not `.zig-cache/tmp`). Nested dirs
// inside this project still belong to the rv work tree, so `git rev-parse`
// would walk up and succeed even without a local `.git`.

const testing = std.testing;
const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

/// `git init -b main` plus local user.name / user.email (required for commits).
fn initTestRepo(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) !void {
    try expectGitOk(alloc, io, cwd, &.{ "git", "init", "-b", "main" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "config", "user.email", "rv@test" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "config", "user.name", "rv test" });
}

fn expectGitOk(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !void {
    const out = git(alloc, io, cwd, .{ .argv = argv }) catch |err| {
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

fn expectFileAt(d: diff.Diff, i: usize, path: []const u8, group: diff.Group) !void {
    try testing.expectEqualStrings(path, d.files[i].displayPath());
    try testing.expectEqual(group, d.files[i].group.?);
}

fn hasFile(d: diff.Diff, path: []const u8, group: diff.Group) bool {
    for (d.files) |f| {
        if (f.group) |g| {
            if (g == group and std.mem.eql(u8, f.displayPath(), path)) return true;
        }
    }
    return false;
}

fn findFile(d: diff.Diff, path: []const u8, group: diff.Group) !diff.File {
    for (d.files) |f| {
        if (f.group) |g| {
            if (g == group and std.mem.eql(u8, f.displayPath(), path)) return f;
        }
    }
    return error.TestExpectedEqual;
}

const ten_lines = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n";
const mixed_staged = "line1\nline2 staged\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n";
const mixed_both = "line1\nline2 staged\nline3\nline4\nline5\nline6\nline7\nline8 unstaged\nline9\nline10\n";

fn makeMixedTracked(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, tmp: IsolatedTmp) !void {
    try expectGitOk(alloc, io, cwd, &.{ "git", "restore", "--source=HEAD", "--worktree", "--staged", "--", "tracked.txt" });
    try tmp.write(io, "tracked.txt", mixed_staged);
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "tracked.txt" });
    try tmp.write(io, "tracked.txt", mixed_both);
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

test "dirty worktree: unstaged, untracked, then staged" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "mixed.txt", "base\n");
    try tmp.write(io, "tracked.txt", "line1\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "mixed.txt", "tracked.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    // Unstaged-only change.
    try tmp.write(io, "tracked.txt", "line1\nunstaged\n");
    // Mixed path: stage one edit, then a further unstaged edit.
    try tmp.write(io, "mixed.txt", "base\nstaged change\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "mixed.txt" });
    try tmp.write(io, "mixed.txt", "base\nstaged change\nunstaged change\n");
    // Staged-only new file.
    try tmp.write(io, "staged.txt", "staged body\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "staged.txt" });
    // Untracked.
    try tmp.write(io, "extra.zig", "const x = 1;\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    try testing.expectEqual(5, d.files.len);
    try expectFileAt(d, 0, "mixed.txt", .unstaged);
    try expectFileAt(d, 1, "tracked.txt", .unstaged);
    try expectFileAt(d, 2, "extra.zig", .untracked);
    try expectFileAt(d, 3, "mixed.txt", .staged);
    try expectFileAt(d, 4, "staged.txt", .staged);
}

test "clean feature branch: empty model (no local changes)" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);

    try tmp.write(io, "shared.txt", "on main\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on main" });

    // Commits ahead of main, worktree clean: default stays empty (no branch
    // fall-through).
    try expectGitOk(alloc, io, cwd, &.{ "git", "checkout", "-b", "feature" });
    try tmp.write(io, "feature-only.txt", "only on feature\n");
    try tmp.write(io, "shared.txt", "on main\nedited on feature\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "feature-only.txt", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on feature" });

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    try testing.expectEqual(0, d.files.len);
    try testing.expectEqual(0, d.hunk_count);
}

test "clean worktree: empty model" {
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

test "dirty tracked plus untracked file: both in local stream" {
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

    try tmp.write(io, "tracked.txt", "line1\nedited\n");
    try tmp.write(io, "new.zig", "pub fn main() void {}\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    try testing.expectEqual(2, d.files.len);
    try expectFileAt(d, 0, "tracked.txt", .unstaged);
    try expectFileAt(d, 1, "new.zig", .untracked);
}

test "ignored untracked path is not included" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "only.txt", "x\n");
    try tmp.write(io, ".gitignore", "ignored.txt\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "only.txt", ".gitignore" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    // Matches .gitignore → exclude-standard must omit it from the local stream.
    try tmp.write(io, "ignored.txt", "should not appear\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();
    try testing.expectEqual(0, d.files.len);
}

test "untracked-only worktree: non-empty local stream" {
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

    // Tracked tree is clean; only an untracked source file.
    try tmp.write(io, "brand_new.zig", "const x = 1;\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    try testing.expectEqual(1, d.files.len);
    try expectFileAt(d, 0, "brand_new.zig", .untracked);
    try testing.expect(d.hunk_count >= 1);
}

test "no HEAD: untracked-only still loads" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "newbie.txt", "no commits yet\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    try testing.expectEqual(1, d.files.len);
    try expectFileAt(d, 0, "newbie.txt", .untracked);
}

test "range main...HEAD: commits ahead of main" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "shared.txt", "on main\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on main" });

    try expectGitOk(alloc, io, cwd, &.{ "git", "checkout", "-b", "feature" });
    try tmp.write(io, "feature-only.txt", "only on feature\n");
    try tmp.write(io, "shared.txt", "on main\nedited on feature\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "feature-only.txt", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on feature" });

    var d = try loadRangeDiff(alloc, io, cwd, "main...HEAD");
    defer d.deinit();

    try testing.expectEqual(2, d.files.len);
    try testing.expectEqual(2, d.hunk_count);
    try expectHasDisplayPath(d, "feature-only.txt");
    try expectHasDisplayPath(d, "shared.txt");
    try testing.expect(d.files[0].group == null);
    try testing.expect(d.files[1].group == null);
}

test "range does not append untracked files" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "shared.txt", "on main\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on main" });

    try expectGitOk(alloc, io, cwd, &.{ "git", "checkout", "-b", "feature" });
    try tmp.write(io, "feature-only.txt", "only on feature\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "feature-only.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on feature" });

    try tmp.write(io, "dirt.txt", "untracked, must not appear\n");

    var d = try loadRangeDiff(alloc, io, cwd, "main...HEAD");
    defer d.deinit();

    try testing.expectEqual(1, d.files.len);
    try expectHasDisplayPath(d, "feature-only.txt");
}

test "invalid range: GitFailed" {
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

    try testing.expectError(
        error.GitFailed,
        loadRangeDiff(alloc, io, cwd, "this-ref-does-not-exist"),
    );
}

test "range not a git repository" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);

    try testing.expectError(
        error.NotARepository,
        loadRangeDiff(alloc, io, tmp.cwd(), "HEAD"),
    );
}

test "mutate file: stage, unstage, discard; refuse discard staged" {
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

    try tmp.write(io, "tracked.txt", "line1\nedited\n");
    try tmp.write(io, "extra.zig", "const x = 1;\n");
    try tmp.write(io, "staged.txt", "staged body\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "staged.txt" });

    try mutate(alloc, io, cwd, .{ .action = .stage, .path = "tracked.txt", .group = .unstaged });
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "tracked.txt", .unstaged));
        try testing.expect(hasFile(d, "tracked.txt", .staged));
    }

    try mutate(alloc, io, cwd, .{ .action = .unstage, .path = "tracked.txt", .group = .staged });
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(hasFile(d, "tracked.txt", .unstaged));
        try testing.expect(!hasFile(d, "tracked.txt", .staged));
    }

    try mutate(alloc, io, cwd, .{ .action = .discard, .path = "tracked.txt", .group = .unstaged });
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "tracked.txt", .unstaged));
        var buf: [16]u8 = undefined;
        const got = try tmp.dir.readFile(io, "tracked.txt", &buf);
        try testing.expectEqualStrings("line1\n", got);
    }

    try mutate(alloc, io, cwd, .{ .action = .stage, .path = "extra.zig", .group = .untracked });
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "extra.zig", .untracked));
        try testing.expect(hasFile(d, "extra.zig", .staged));
    }

    try mutate(alloc, io, cwd, .{ .action = .unstage, .path = "extra.zig", .group = .staged });
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(hasFile(d, "extra.zig", .untracked));
        try testing.expect(!hasFile(d, "extra.zig", .staged));
    }

    try mutate(alloc, io, cwd, .{ .action = .discard, .path = "extra.zig", .group = .untracked });
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "extra.zig", .untracked));
    }

    try testing.expectError(error.GitFailed, mutate(alloc, io, cwd, .{
        .action = .discard,
        .path = "staged.txt",
        .group = .staged,
    }));
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(hasFile(d, "staged.txt", .staged));
    }
}

test "mutate: not a git repository" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);

    try testing.expectError(error.NotARepository, mutate(alloc, io, tmp.cwd(), .{
        .action = .stage,
        .path = "x",
        .group = .unstaged,
    }));
}

test "mutate: GitFailed fills fail_output from git stderr" {
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

    var fail: []u8 = &.{};
    defer alloc.free(fail);
    try testing.expectError(error.GitFailed, mutate(alloc, io, cwd, .{
        .action = .discard,
        .path = "no-such-path.txt",
        .group = .unstaged,
        .fail_output = &fail,
    }));
    try testing.expect(fail.len > 0);
}

test "mutate hunk: mixed file, other group remains" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "tracked.txt", ten_lines);
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "tracked.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    try makeMixedTracked(alloc, io, cwd, tmp);
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        const f = try findFile(d, "tracked.txt", .unstaged);
        try testing.expect(f.hunks.len >= 1);
        try mutate(alloc, io, cwd, .{
            .action = .discard,
            .path = "tracked.txt",
            .group = .unstaged,
            .hunk = &f.hunks[0],
            .file = &f,
        });
    }
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "tracked.txt", .unstaged));
        try testing.expect(hasFile(d, "tracked.txt", .staged));
        var buf: [128]u8 = undefined;
        const got = try tmp.dir.readFile(io, "tracked.txt", &buf);
        try testing.expectEqualStrings(mixed_staged, got);
    }

    try makeMixedTracked(alloc, io, cwd, tmp);
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        const f = try findFile(d, "tracked.txt", .unstaged);
        try mutate(alloc, io, cwd, .{
            .action = .stage,
            .path = "tracked.txt",
            .group = .unstaged,
            .hunk = &f.hunks[0],
            .file = &f,
        });
    }
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "tracked.txt", .unstaged));
        try testing.expect(hasFile(d, "tracked.txt", .staged));
    }

    try makeMixedTracked(alloc, io, cwd, tmp);
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        const f = try findFile(d, "tracked.txt", .staged);
        try mutate(alloc, io, cwd, .{
            .action = .unstage,
            .path = "tracked.txt",
            .group = .staged,
            .hunk = &f.hunks[0],
            .file = &f,
        });
    }
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "tracked.txt", .staged));
        try testing.expect(hasFile(d, "tracked.txt", .unstaged));
    }
}

test "mutate hunk: untracked stage and discard" {
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

    try tmp.write(io, "extra.zig", "const x = 1;\n");
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        const f = try findFile(d, "extra.zig", .untracked);
        try testing.expect(f.hunks.len >= 1);
        try mutate(alloc, io, cwd, .{
            .action = .stage,
            .path = "extra.zig",
            .group = .untracked,
            .hunk = &f.hunks[0],
            .file = &f,
        });
    }
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "extra.zig", .untracked));
        try testing.expect(hasFile(d, "extra.zig", .staged));
    }

    try tmp.write(io, "other.zig", "const y = 2;\n");
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        const f = try findFile(d, "other.zig", .untracked);
        try mutate(alloc, io, cwd, .{
            .action = .discard,
            .path = "other.zig",
            .group = .untracked,
            .hunk = &f.hunks[0],
            .file = &f,
        });
    }
    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expect(!hasFile(d, "other.zig", .untracked));
    }
}

test "mutate hunk: apply mismatch leaves prior content" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.create(alloc, io);
    defer tmp.cleanup(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "tracked.txt", ten_lines);
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "tracked.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "tracked.txt", mixed_both);

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();
    const f = try findFile(d, "tracked.txt", .unstaged);
    try testing.expect(f.hunks.len >= 1);

    const changed = "this no longer matches the loaded hunk\n";
    try tmp.write(io, "tracked.txt", changed);

    var fail: []u8 = &.{};
    defer alloc.free(fail);
    try testing.expectError(error.GitFailed, mutate(alloc, io, cwd, .{
        .action = .discard,
        .path = "tracked.txt",
        .group = .unstaged,
        .hunk = &f.hunks[0],
        .file = &f,
        .fail_output = &fail,
    }));
    try testing.expect(fail.len > 0);

    var buf: [64]u8 = undefined;
    const got = try tmp.dir.readFile(io, "tracked.txt", &buf);
    try testing.expectEqualStrings(changed, got);
}
