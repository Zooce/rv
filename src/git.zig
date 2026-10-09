//! Load a parsed `Diff` by shelling out to `git` (no libgit2).
//!
//! ## Default (local only)
//!
//! Three groups, in this order, each file tagged (`diff.File.group`):
//!
//! 1. **unstaged** — `git diff --find-renames` (worktree vs index)
//! 2. **untracked** — `git ls-files --others --exclude-standard`, each path
//!    turned into a new-file unified diff via
//!    `git diff --no-index -- /dev/null <path>`
//! 3. **staged** — `git diff --find-renames --cached` (index vs HEAD)
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
//! `git diff HEAD` is a different patch: staged and unstaged are one blob,
//! and untracked files are omitted. The line oracle compares parsed hunk
//! lines to the blobs these loaders parse.
//!
//! ## Intra-line spans
//!
//! After parsing the unified diff, `worddiff.attachSpans` writes changed-token
//! ranges onto add/delete lines (`Line.spans`). Display rows borrow those
//! slices. One-sided files, one-sided hunks, and blank unpaired lines keep
//! `null` spans and the solid add/delete fill. An empty list means every token
//! on that line is also on the paired line: dim grey, no red or green.
//!
//! ## Explicit range
//!
//! `loadRangeDiff` runs `git diff --find-renames <range>` with the range
//! string as written (no `...` / `..` rewrite). Untracked files are not
//! appended. An empty result is an empty `Diff`. Invalid range is `GitFailed`.
//!
//! ## Commit
//!
//! `loadCommitDiff` verifies `<commit>^{commit}` then runs
//! `git diff-tree -p --root --find-renames --no-commit-id --first-parent <commit>`.
//! That is the patch the commit introduced (parent → commit), not worktree vs
//! that rev. Untracked files are not appended. An empty commit is an empty
//! `Diff`. Invalid commit-ish is `GitFailed`. Root commits work (`--root`).
//! Merge commits diff against the first parent (unified).
//!
//! ## Empty diffs
//!
//! No matching changes yields an empty `Diff` (zero files), **not** an error.
//! That covers a clean worktree with no untracked files, a repo with no
//! commits and no untracked files, and an empty commit.
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
//! ## Expand
//!
//! `survivingFileText` is the bytes `Diff.expandHunk` needs: worktree for
//! unstaged/untracked, index blob for staged, new-side blob for a range or
//! commit load; deleted files use the old side. Does not re-run `git diff`.
//! `Origin` is this load (`local` / range / commit).
//!
//! ## Path reload
//!
//! `reloadPaths` loads a fresh local diff of those paths and splices them
//! into the previous `Diff`. Other files stay as loaded, including expanded
//! hunks. Intra-line spans on the reloaded path are computed from the fresh
//! hunk lines.
//!
//! A path reload skips the work-tree check and `HEAD` verify (the session
//! already loaded this repo; stage does not move `HEAD`). It also skips
//! untracked listing unless a staged new file on those paths could become
//! untracked again. Unstaged and staged diffs still run: git may regroup
//! neighbors after `apply --cached`.
//!
//! ## Errors
//!
//! - `NotARepository` — cwd is not inside a git work tree.
//! - `GitNotFound` — `git` executable missing from `PATH`.
//! - `GitFailed` — git exited non-zero (or crashed) on a required command,
//!   or the action is not allowed on that group.

const std = @import("std");
const diff = @import("diff");
const worddiff = @import("worddiff");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Where this diff was loaded from. Range and commit strings are as given.
pub const Origin = union(enum) {
    local,
    range: []const u8,
    commit: []const u8,
};

pub const Error = error{
    NotARepository,
    GitNotFound,
    GitFailed,
} || diff.ParseError;

/// Short message for a load or mutate `Error`.
pub fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        error.NotARepository => "not a git repository (run from a work tree)",
        error.GitNotFound => "git executable not found in PATH",
        error.GitFailed => "git command failed",
        error.OutOfMemory => "out of memory",
        error.BadHunkHeader => "failed to parse unified diff (bad hunk header)",
    };
}

/// Load the local-only default diff for the process current working directory.
pub fn loadDefaultDiff(alloc: Allocator, io: Io) Error!diff.Diff {
    return loadDefaultDiffCwd(alloc, io, .inherit);
}

/// Unified blobs for the local load, in group order. Empty slices (still
/// owned by `alloc`) when that group was not run.
pub const DefaultTexts = struct {
    unstaged: []u8,
    untracked: []u8,
    staged: []u8,

    pub fn deinit(self: DefaultTexts, alloc: Allocator) void {
        alloc.free(self.unstaged);
        alloc.free(self.untracked);
        alloc.free(self.staged);
    }
};

/// How many `git` processes a load started. Passed through `LoadOpts.stats`.
pub const LoadStats = struct {
    spawns: usize = 0,
};

/// Local unified-diff load. `only` limits every command to those paths;
/// `null` is the whole work tree and checks that cwd is inside one.
pub const LoadOpts = struct {
    cwd: std.process.Child.Cwd,
    only: ?[]const []const u8 = null,
    stats: ?*LoadStats = null,
    /// When false, skip `ls-files` / `--no-index`. Path reload after a
    /// mutation that cannot leave the path untracked.
    untracked: bool = true,
};

/// `only` limits every command to those paths. `null` is the whole work tree
/// and checks that cwd is inside one. A one-path reload passes the path.
/// Path-limited loads skip the work-tree check and `HEAD` verify.
pub fn loadDefaultTexts(alloc: Allocator, io: Io, opts: LoadOpts) Error!DefaultTexts {
    const cwd = opts.cwd;
    const only = opts.only;
    const stats = opts.stats;
    if (only == null) try ensureInsideWorkTree(alloc, io, cwd, stats);

    const untracked = blk: {
        if (!opts.untracked) break :blk try alloc.alloc(u8, 0);
        break :blk (try untrackedDiff(alloc, io, cwd, only, stats)) orelse try alloc.alloc(u8, 0);
    };
    errdefer alloc.free(untracked);

    // Full load: no HEAD means only untracked content. Path reload skips
    // this verify (HEAD does not move on stage) and runs both diffs; they
    // succeed with no commits too.
    if (only == null and !try revExists(alloc, io, cwd, "HEAD", stats)) {
        const unstaged = try alloc.alloc(u8, 0);
        errdefer alloc.free(unstaged);
        return .{
            .unstaged = unstaged,
            .untracked = untracked,
            .staged = try alloc.alloc(u8, 0),
        };
    }

    const unstaged = try worktreeDiff(alloc, io, cwd, false, only, stats);
    errdefer alloc.free(unstaged);
    return .{
        .unstaged = unstaged,
        .untracked = untracked,
        .staged = try worktreeDiff(alloc, io, cwd, true, only, stats),
    };
}

/// `git diff --find-renames` (or `--cached`) stdout. `only` adds a pathspec.
fn worktreeDiff(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    cached: bool,
    only: ?[]const []const u8,
    stats: ?*LoadStats,
) Error![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "diff", "--find-renames" });
    if (cached) try argv.append(alloc, "--cached");
    if (only) |paths| {
        try argv.append(alloc, "--");
        try argv.appendSlice(alloc, paths);
    }
    return try git(alloc, io, cwd, .{ .argv = argv.items, .stats = stats });
}

/// Same as `loadDefaultDiff`, but run git with an explicit child cwd.
pub fn loadDefaultDiffCwd(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) Error!diff.Diff {
    const texts = try loadDefaultTexts(alloc, io, .{ .cwd = cwd });
    defer texts.deinit(alloc);
    var parsed = try diff.parsePieces(alloc, &.{
        .{ .text = texts.unstaged, .group = .unstaged },
        .{ .text = texts.untracked, .group = .untracked },
        .{ .text = texts.staged, .group = .staged },
    });
    errdefer parsed.deinit();
    try worddiff.attachSpans(alloc, &parsed);
    return parsed;
}

/// `git diff --find-renames <range>` stdout. Caller frees.
fn rangeDiffText(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, range: []const u8) Error![]u8 {
    try ensureInsideWorkTree(alloc, io, cwd, null);
    return try git(alloc, io, cwd, .{
        .argv = &.{ "git", "diff", "--find-renames", range },
    });
}

/// Load `git diff --find-renames <range>`. `range` is passed through as
/// written (no `...` / `..` rewrite). Pass `.inherit` for the process cwd.
pub fn loadRangeDiff(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, range: []const u8) Error!diff.Diff {
    const out = try rangeDiffText(alloc, io, cwd, range);
    defer alloc.free(out);
    var parsed = try diff.parse(alloc, out);
    errdefer parsed.deinit();
    try worddiff.attachSpans(alloc, &parsed);
    return parsed;
}

/// `git diff-tree` patch for `commit` (parent → commit). Caller frees.
/// The commit-ish must peel to a commit.
fn commitDiffText(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, commit: []const u8) Error![]u8 {
    try ensureInsideWorkTree(alloc, io, cwd, null);
    const as_commit = try std.fmt.allocPrint(alloc, "{s}^{{commit}}", .{commit});
    defer alloc.free(as_commit);
    const peeled = try git(alloc, io, cwd, .{
        .argv = &.{ "git", "rev-parse", "--verify", as_commit },
    });
    alloc.free(peeled);

    return try git(alloc, io, cwd, .{
        .argv = &.{
            "git",
            "diff-tree",
            "-p",
            "--root",
            "--find-renames",
            "--no-commit-id",
            "--first-parent",
            commit,
        },
    });
}

/// Load the patch `<commit>` introduced (parent → that commit).
/// `commit` is a commit-ish as given; it must peel to a commit.
pub fn loadCommitDiff(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, commit: []const u8) Error!diff.Diff {
    const out = try commitDiffText(alloc, io, cwd, commit);
    defer alloc.free(out);
    var parsed = try diff.parse(alloc, out);
    errdefer parsed.deinit();
    try worddiff.attachSpans(alloc, &parsed);
    return parsed;
}

/// Surviving-side file bytes for expand. Caller frees.
///
/// Local: worktree for unstaged/untracked, `git show :path` for staged.
/// Deleted unstaged reads the index; deleted staged reads `HEAD`.
/// Range: new-side blob (`git show <rev>:path`), or worktree when the range
/// is a single rev (`git diff <rev>` is vs the worktree). Deleted: old side.
/// Commit: blob at the commit (new side), or first parent when deleted.
pub fn survivingFileText(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    file: *const diff.File,
    origin: Origin,
) Error![]u8 {
    switch (origin) {
        .range => |r| return rangeFileText(alloc, io, cwd, file, r),
        .commit => |c| return commitFileText(alloc, io, cwd, file, c),
        .local => {},
    }

    // New path: worktree (unstaged/untracked) or index (staged).
    if (file.new_path) |path| {
        return switch (file.group orelse .unstaged) {
            .unstaged, .untracked => readWorktreeFile(alloc, io, cwd, path),
            .staged => gitShowPath(alloc, io, cwd, ":", path),
        };
    }
    // Deleted: index still has the unstaged file; staged delete is HEAD.
    const path = file.old_path orelse return error.GitFailed;
    return switch (file.group orelse .unstaged) {
        .unstaged => gitShowPath(alloc, io, cwd, ":", path),
        .staged => gitShowPath(alloc, io, cwd, "HEAD", path),
        .untracked => error.GitFailed,
    };
}

fn rangeFileText(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    file: *const diff.File,
    range: []const u8,
) Error![]u8 {
    const three = std.mem.indexOf(u8, range, "...");
    const two = if (three == null) std.mem.indexOf(u8, range, "..") else null;
    const dotted = three != null or two != null;

    // New side of A..B / A...B is the right rev; a single rev is vs worktree.
    if (file.new_path) |path| {
        if (dotted) return gitShowPath(alloc, io, cwd, rangeRightRev(range), path);
        return readWorktreeFile(alloc, io, cwd, path);
    }
    const path = file.old_path orelse return error.GitFailed;
    if (three) |i| {
        const left = if (range[0..i].len == 0) "HEAD" else range[0..i];
        const right = rangeRightRev(range);
        const mb = try git(alloc, io, cwd, .{ .argv = &.{ "git", "merge-base", left, right } });
        defer alloc.free(mb);
        return gitShowPath(alloc, io, cwd, std.mem.trim(u8, mb, " \t\r\n"), path);
    }
    if (two) |i| {
        const left = if (range[0..i].len == 0) "HEAD" else range[0..i];
        return gitShowPath(alloc, io, cwd, left, path);
    }
    return gitShowPath(alloc, io, cwd, range, path);
}

fn commitFileText(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    file: *const diff.File,
    commit: []const u8,
) Error![]u8 {
    if (file.new_path) |path| return gitShowPath(alloc, io, cwd, commit, path);
    const path = file.old_path orelse return error.GitFailed;
    const parent = try std.fmt.allocPrint(alloc, "{s}^", .{commit});
    defer alloc.free(parent);
    return gitShowPath(alloc, io, cwd, parent, path);
}

fn rangeRightRev(range: []const u8) []const u8 {
    if (std.mem.indexOf(u8, range, "...")) |i| {
        const rest = range[i + 3 ..];
        return if (rest.len == 0) "HEAD" else rest;
    }
    if (std.mem.indexOf(u8, range, "..")) |i| {
        const rest = range[i + 2 ..];
        return if (rest.len == 0) "HEAD" else rest;
    }
    return range;
}

fn gitShowPath(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    rev: []const u8,
    path: []const u8,
) Error![]u8 {
    const spec = if (std.mem.eql(u8, rev, ":"))
        try std.fmt.allocPrint(alloc, ":{s}", .{path})
    else
        try std.fmt.allocPrint(alloc, "{s}:{s}", .{ rev, path });
    defer alloc.free(spec);
    return git(alloc, io, cwd, .{ .argv = &.{ "git", "show", spec } });
}

fn readWorktreeFile(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    path: []const u8,
) Error![]u8 {
    const limit: Io.Limit = .limited(8 * 1024 * 1024);
    switch (cwd) {
        .inherit => {
            const dir: Io.Dir = .cwd();
            return dir.readFileAlloc(io, path, alloc, limit) catch return error.GitFailed;
        },
        .path => |p| {
            const dir = Io.Dir.openDirAbsolute(io, p, .{}) catch return error.GitFailed;
            defer dir.close(io);
            return dir.readFileAlloc(io, path, alloc, limit) catch return error.GitFailed;
        },
        .dir => |dir| {
            return dir.readFileAlloc(io, path, alloc, limit) catch return error.GitFailed;
        },
    }
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
    /// When set, incremented once per spawned `git` process.
    stats: ?*LoadStats = null,
};

/// Stage, unstage, or discard one path (or one hunk) in `cwd`. See module
/// docs for the allowed action/group table. Pass `.inherit` for the process cwd.
/// Does not re-check that cwd is a work tree; the apply/add command fails if
/// it is not.
pub fn mutate(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, opts: MutateOpts) Error!void {
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
            .stats = opts.stats,
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
        .stats = opts.stats,
    });
    alloc.free(out);
}

/// Replace `paths` in `old` with a fresh local diff of those paths. Other
/// files are copied. Intra-line spans on the fresh hunks come from those lines.
pub fn reloadPaths(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    old: *const diff.Diff,
    paths: []const []const u8,
    stats: ?*LoadStats,
) Error!diff.Diff {
    const texts = try loadDefaultTexts(alloc, io, .{
        .cwd = cwd,
        .only = paths,
        .stats = stats,
        .untracked = stagedNewOnPaths(old, paths),
    });
    defer texts.deinit(alloc);
    var fresh = try diff.parsePieces(alloc, &.{
        .{ .text = texts.unstaged, .group = .unstaged },
        .{ .text = texts.untracked, .group = .untracked },
        .{ .text = texts.staged, .group = .staged },
    });
    defer fresh.deinit();
    try worddiff.attachSpans(alloc, &fresh);
    return try old.replacePaths(alloc, paths, &fresh);
}

/// Unstaging a staged new file can leave it untracked. Other mutations on
/// `paths` cannot.
fn stagedNewOnPaths(old: *const diff.Diff, paths: []const []const u8) bool {
    for (old.files) |f| {
        const g = f.group orelse continue;
        if (g != .staged) continue;
        if (f.old_path != null) continue;
        const p = f.new_path orelse continue;
        for (paths) |want| {
            if (std.mem.eql(u8, p, want)) return true;
        }
    }
    return false;
}

// --- internals -----------------------------------------------------------

fn ensureInsideWorkTree(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, stats: ?*LoadStats) Error!void {
    const out = git(alloc, io, cwd, .{
        .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" },
        .stats = stats,
    }) catch |err| switch (err) {
        error.GitFailed => return error.NotARepository,
        else => return err,
    };
    defer alloc.free(out);
    if (std.mem.eql(u8, std.mem.trim(u8, out, " \t\r\n"), "true")) return;
    return error.NotARepository;
}

fn revExists(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, rev: []const u8, stats: ?*LoadStats) Error!bool {
    // `--verify` fails when the rev is missing; `--quiet` suppresses noise.
    // Append `^{commit}` so the rev must resolve to a commit object (git
    // syntax: peel tags/refs down to a commit).
    const as_commit = try std.fmt.allocPrint(alloc, "{s}^{{commit}}", .{rev});
    defer alloc.free(as_commit);

    const out = git(alloc, io, cwd, .{
        .argv = &.{ "git", "rev-parse", "--verify", "--quiet", as_commit },
        .stats = stats,
    }) catch |err| switch (err) {
        error.GitFailed => return false,
        else => return err,
    };
    alloc.free(out);
    return true;
}

/// Unified-diff text for untracked, non-ignored paths (exclude-standard).
/// `only` limits the listing to those paths. `null` lists the whole tree.
/// Returns `null` when there are none. Caller frees a non-null result.
fn untrackedDiff(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    only: ?[]const []const u8,
    stats: ?*LoadStats,
) Error!?[]u8 {
    var list_argv: std.ArrayList([]const u8) = .empty;
    defer list_argv.deinit(alloc);
    try list_argv.appendSlice(alloc, &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" });
    if (only) |paths| {
        try list_argv.append(alloc, "--");
        try list_argv.appendSlice(alloc, paths);
    }
    const listing = try git(alloc, io, cwd, .{ .argv = list_argv.items, .stats = stats });
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
            .stats = stats,
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
    /// When set, incremented once per spawned `git` process.
    stats: ?*LoadStats = null,
};

/// Run a `git …` command. On exit 0 (or `allowed_error_code` when set), returns
/// owned stdout (caller frees). Any other exit / crash → `GitFailed`; missing
/// binary → `GitNotFound`.
fn git(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, opts: GitOpts) Error![]u8 {
    if (opts.stats) |s| s.spawns += 1;
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    try testing.expectError(
        error.NotARepository,
        loadDefaultDiffCwd(alloc, io, tmp.cwd()),
    );
}

test "dirty worktree: unstaged, untracked, then staged" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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

test "local load spawn count: HEAD and one untracked" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "a.txt", "base\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "a.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "extra.txt", "untracked\n");

    var stats: LoadStats = .{};
    const texts = try loadDefaultTexts(alloc, io, .{ .cwd = cwd, .stats = &stats });
    defer texts.deinit(alloc);
    // inside-work-tree, ls-files, one --no-index, HEAD verify, unstaged diff, staged diff
    try testing.expectEqual(6, stats.spawns);
}

test "local load spawn count: HEAD and no untracked" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "a.txt", "base\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "a.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    var stats: LoadStats = .{};
    const texts = try loadDefaultTexts(alloc, io, .{ .cwd = cwd, .stats = &stats });
    defer texts.deinit(alloc);
    // inside-work-tree, ls-files, HEAD verify, unstaged diff, staged diff
    try testing.expectEqual(5, stats.spawns);
}

test "mutate spawn count: one git process" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "a.txt", "base\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "a.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "a.txt", "base\nedit\n");

    var stats: LoadStats = .{};
    try mutate(alloc, io, cwd, .{
        .action = .stage,
        .path = "a.txt",
        .group = .unstaged,
        .stats = &stats,
    });
    try testing.expectEqual(1, stats.spawns);
}

test "reloadPaths spawn count: tracked path skips untracked and HEAD" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "a.txt", "base\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "a.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "a.txt", "base\nedit\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();
    try mutate(alloc, io, cwd, .{ .action = .stage, .path = "a.txt", .group = .unstaged });

    var stats: LoadStats = .{};
    const paths = [_][]const u8{"a.txt"};
    var next = try reloadPaths(alloc, io, cwd, &d, &paths, &stats);
    defer next.deinit();
    // unstaged diff, staged diff
    try testing.expectEqual(2, stats.spawns);
    try testing.expect(hasFile(next, "a.txt", .staged));
    try testing.expect(!hasFile(next, "a.txt", .unstaged));
}

test "reloadPaths: unstage new file still lists untracked" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "only.txt", "x\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "only.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "extra.zig", "const x = 1;\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "extra.zig" });

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();
    try testing.expect(hasFile(d, "extra.zig", .staged));

    try mutate(alloc, io, cwd, .{ .action = .unstage, .path = "extra.zig", .group = .staged });

    var stats: LoadStats = .{};
    const paths = [_][]const u8{"extra.zig"};
    var next = try reloadPaths(alloc, io, cwd, &d, &paths, &stats);
    defer next.deinit();
    // ls-files, --no-index, unstaged diff, staged diff
    try testing.expectEqual(4, stats.spawns);
    try testing.expect(hasFile(next, "extra.zig", .untracked));
    try testing.expect(!hasFile(next, "extra.zig", .staged));
}

test "reloadPaths: stage untracked with no HEAD shows staged" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "newbie.txt", "no commits yet\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();
    try testing.expect(hasFile(d, "newbie.txt", .untracked));

    try mutate(alloc, io, cwd, .{ .action = .stage, .path = "newbie.txt", .group = .untracked });

    const paths = [_][]const u8{"newbie.txt"};
    var next = try reloadPaths(alloc, io, cwd, &d, &paths, null);
    defer next.deinit();
    try testing.expect(hasFile(next, "newbie.txt", .staged));
    try testing.expect(!hasFile(next, "newbie.txt", .untracked));
}

test "clean feature branch: empty model (no local changes)" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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

test "load finds rename when diff.renames is false" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try expectGitOk(alloc, io, cwd, &.{ "git", "config", "diff.renames", "false" });
    try tmp.write(io, "old_name.txt", "hello\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "old_name.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "mv", "old_name.txt", "new_name.txt" });

    {
        var d = try loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        try testing.expectEqual(1, d.files.len);
        const f = try findFile(d, "new_name.txt", .staged);
        try testing.expectEqualStrings("old_name.txt", f.old_path.?);
        try testing.expectEqualStrings("new_name.txt", f.new_path.?);
    }

    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "rename" });
    var ranged = try loadRangeDiff(alloc, io, cwd, "HEAD~1...HEAD");
    defer ranged.deinit();
    try testing.expectEqual(1, ranged.files.len);
    try testing.expectEqualStrings("old_name.txt", ranged.files[0].old_path.?);
    try testing.expectEqualStrings("new_name.txt", ranged.files[0].new_path.?);
}

test "invalid range: GitFailed" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    try testing.expectError(
        error.NotARepository,
        loadRangeDiff(alloc, io, tmp.cwd(), "HEAD"),
    );
}

test "commit load is the commit patch, not the worktree" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "committed.txt", "committed\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "committed.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    try tmp.write(io, "committed.txt", "dirty\n");
    try tmp.write(io, "untracked.txt", "must not appear\n");

    var d = try loadCommitDiff(alloc, io, cwd, "HEAD");
    defer d.deinit();
    try testing.expectEqual(1, d.files.len);
    try expectHasDisplayPath(d, "committed.txt");
    try testing.expect(d.files[0].group == null);

    const blob = try survivingFileText(alloc, io, cwd, &d.files[0], .{ .commit = "HEAD" });
    defer alloc.free(blob);
    try testing.expectEqualStrings("committed\n", blob);

    const peeled = try git(alloc, io, cwd, .{ .argv = &.{ "git", "rev-parse", "HEAD" } });
    defer alloc.free(peeled);
    const hash = std.mem.trim(u8, peeled, " \t\r\n");
    var hashed = try loadCommitDiff(alloc, io, cwd, hash);
    defer hashed.deinit();
    try testing.expectEqual(1, hashed.files.len);
    try expectHasDisplayPath(hashed, "committed.txt");
}

test "empty commit loads empty Diff" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "only.txt", "x\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "only.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "--allow-empty", "-m", "empty" });

    var d = try loadCommitDiff(alloc, io, cwd, "HEAD");
    defer d.deinit();
    try testing.expectEqual(0, d.files.len);
    try testing.expectEqual(0, d.hunk_count);
}

test "invalid commit: GitFailed" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "only.txt", "x\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "only.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    try testing.expectError(
        error.GitFailed,
        loadCommitDiff(alloc, io, cwd, "this-ref-does-not-exist"),
    );
}

// Line oracle: parsed hunk lines vs the unified blobs the loaders parse.
// A body line is ` `, `+`, `-`, or `\` after `@@`, until the next `diff --git`.
// The marker is stripped. A blank line is not body text.

const BodyLine = struct {
    kind: diff.LineKind,
    text: []const u8,
};

fn appendUnifiedBody(alloc: Allocator, lines: *std.ArrayList(BodyLine), text: []const u8) !void {
    var in_hunk = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            in_hunk = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            continue;
        }
        if (!in_hunk or line.len == 0) continue;
        switch (line[0]) {
            ' ', '+', '-' => {
                const kind: diff.LineKind = switch (line[0]) {
                    ' ' => .context,
                    '+' => .add,
                    '-' => .delete,
                    else => unreachable,
                };
                try lines.append(alloc, .{ .kind = kind, .text = line[1..] });
            },
            '\\' => {
                const body = if (std.mem.startsWith(u8, line, "\\ ")) line[2..] else line[1..];
                try lines.append(alloc, .{ .kind = .meta, .text = body });
            },
            else => {},
        }
    }
}

fn expectDiffMatchesStream(alloc: Allocator, d: *const diff.Diff, parts: []const []const u8) !void {
    var body: std.ArrayList(BodyLine) = .empty;
    defer body.deinit(alloc);
    for (parts) |text| try appendUnifiedBody(alloc, &body, text);

    var seen: usize = 0;
    for (d.files) |f| {
        for (f.hunks) |h| {
            for (h.lines) |ln| {
                if (seen >= body.items.len) {
                    std.debug.print(
                        "line oracle: diff body line {d} past unified stream ({d} lines)\n",
                        .{ seen, body.items.len },
                    );
                    return error.TestExpectedEqual;
                }
                const want = body.items[seen];
                if (want.kind != ln.kind or !std.mem.eql(u8, want.text, ln.text)) {
                    std.debug.print(
                        "line oracle mismatch at body line {d}\n  unified: {t} \"{s}\"\n  diff:    {t} \"{s}\"\n",
                        .{ seen, want.kind, want.text, ln.kind, ln.text },
                    );
                    return error.TestExpectedEqual;
                }
                seen += 1;
            }
        }
    }
    if (seen != body.items.len) {
        std.debug.print(
            "line oracle: unified stream has {d} body lines, diff has {d}\n",
            .{ body.items.len, seen },
        );
        return error.TestExpectedEqual;
    }
}

fn diffHasText(d: *const diff.Diff, text: []const u8) bool {
    for (d.files) |f| {
        for (f.hunks) |h| {
            for (h.lines) |ln| {
                if (std.mem.eql(u8, ln.text, text)) return true;
            }
        }
    }
    return false;
}

fn expectLineTokens(d: *const diff.Diff, present: []const []const u8, absent: []const []const u8) !void {
    for (present) |text| {
        if (!diffHasText(d, text)) {
            std.debug.print("line oracle: missing diff text \"{s}\"\n", .{text});
            return error.TestExpectedEqual;
        }
    }
    for (absent) |text| {
        if (diffHasText(d, text)) {
            std.debug.print("line oracle: unexpected diff text \"{s}\"\n", .{text});
            return error.TestExpectedEqual;
        }
    }
}

test "line oracle: local diff matches the unified body" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "unstaged.txt", "keep\nbase\n");
    try tmp.write(io, "staged.txt", "base\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "unstaged.txt", "staged.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    // Staged-only edit. The worktree matches the index, so the unstaged diff omits it.
    try tmp.write(io, "staged.txt", "staged-token\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "staged.txt" });

    // Unstaged edit with no trailing newline, so the stream includes a meta line.
    try tmp.write(io, "unstaged.txt", "keep\nunstaged-token");
    // Untracked. `git diff HEAD` does not include this file.
    try tmp.write(io, "extra.txt", "untracked-token\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    const texts = try loadDefaultTexts(alloc, io, .{ .cwd = cwd });
    defer texts.deinit(alloc);
    try expectDiffMatchesStream(alloc, &d, &.{ texts.unstaged, texts.untracked, texts.staged });
    try expectLineTokens(
        &d,
        &.{ "unstaged-token", "staged-token", "untracked-token", "No newline at end of file" },
        &.{},
    );
}

test "line oracle: range diff matches the unified body" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "shared.txt", "on main\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on main" });

    try expectGitOk(alloc, io, cwd, &.{ "git", "checkout", "-b", "feature" });
    try tmp.write(io, "shared.txt", "on main\nfeature-token\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on feature" });

    // Worktree dirt must stay out of a range load.
    try tmp.write(io, "shared.txt", "on main\nfeature-token\ndirty-token\n");
    try tmp.write(io, "extra.txt", "untracked-token\n");

    var d = try loadRangeDiff(alloc, io, cwd, "main...HEAD");
    defer d.deinit();

    const text = try rangeDiffText(alloc, io, cwd, "main...HEAD");
    defer alloc.free(text);
    try expectDiffMatchesStream(alloc, &d, &.{text});
    try expectLineTokens(&d, &.{"feature-token"}, &.{ "dirty-token", "untracked-token" });
}

test "line oracle: commit diff matches the unified body" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "committed.txt", "committed-token\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "committed.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });

    try tmp.write(io, "committed.txt", "dirty-token\n");
    try tmp.write(io, "extra.txt", "untracked-token\n");

    var d = try loadCommitDiff(alloc, io, cwd, "HEAD");
    defer d.deinit();

    const text = try commitDiffText(alloc, io, cwd, "HEAD");
    defer alloc.free(text);
    try expectDiffMatchesStream(alloc, &d, &.{text});
    try expectLineTokens(&d, &.{"committed-token"}, &.{ "dirty-token", "untracked-token" });
}

test "local load spans changed words on add and delete lines" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    const before =
        \\keep0
        \\word
        \\keep1
        \\keep2
        \\keep3
        \\keep4
        \\keep5
        \\keep6
        \\keep7
        \\keep8
        \\keep9
        \\other
        \\
    ;
    const after =
        \\keep0
        \\WORD
        \\keep1
        \\keep2
        \\keep3
        \\keep4
        \\keep5
        \\keep6
        \\keep7
        \\keep8
        \\keep9
        \\OTHER
        \\
    ;
    try tmp.write(io, "a.txt", before);
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "a.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "a.txt", after);

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();
    try expectLineSpan(d, "word", 0, 4);
    try expectLineSpan(d, "WORD", 0, 4);
    try expectLineSpan(d, "other", 0, 5);
    try expectLineSpan(d, "OTHER", 0, 5);
    try expectLineUnspanned(d, "keep0");
    try testing.expectEqual(1, d.files.len);
    try testing.expectEqual(diff.Group.unstaged, d.files[0].group.?);
    try testing.expectEqual(2, d.files[0].hunks.len);
}

fn expectLineSpan(d: diff.Diff, text: []const u8, start: usize, end: usize) !void {
    for (d.files) |f| {
        for (f.hunks) |h| {
            for (h.lines) |ln| {
                if (!std.mem.eql(u8, ln.text, text)) continue;
                const sp = ln.spans orelse return error.TestExpectedEqual;
                try testing.expectEqual(1, sp.len);
                try testing.expectEqual(start, sp[0].start);
                try testing.expectEqual(end, sp[0].end);
                return;
            }
        }
    }
    std.debug.print("missing line \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

fn expectLineUnspanned(d: diff.Diff, text: []const u8) !void {
    for (d.files) |f| {
        for (f.hunks) |h| {
            for (h.lines) |ln| {
                if (!std.mem.eql(u8, ln.text, text)) continue;
                try testing.expect(ln.spans == null);
                return;
            }
        }
    }
    std.debug.print("missing line \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

test "range load spans changed words and omits worktree dirt" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "shared.txt", "keep alpha\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on main" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "checkout", "-b", "feature" });
    try tmp.write(io, "shared.txt", "keep BETA\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "shared.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "on feature" });
    try tmp.write(io, "shared.txt", "keep BETA\ndirt-token\n");
    try tmp.write(io, "extra.txt", "untracked-token\n");

    var d = try loadRangeDiff(alloc, io, cwd, "main...HEAD");
    defer d.deinit();
    try testing.expectEqual(1, d.files.len);
    try testing.expectEqual(1, d.files[0].hunks.len);
    try expectLineSpan(d, "keep alpha", 5, 10);
    try expectLineSpan(d, "keep BETA", 5, 9);
    try expectLineTokens(&d, &.{ "keep alpha", "keep BETA" }, &.{ "dirt-token", "untracked-token" });
}

test "commit load spans changed words and omits worktree dirt" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "committed.txt", "keep alpha\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "committed.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "committed.txt", "keep BETA\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "committed.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "edit" });
    try tmp.write(io, "committed.txt", "keep BETA\ndirt-token\n");
    try tmp.write(io, "extra.txt", "untracked-token\n");

    var d = try loadCommitDiff(alloc, io, cwd, "HEAD");
    defer d.deinit();
    try testing.expectEqual(1, d.files.len);
    try testing.expectEqual(1, d.files[0].hunks.len);
    try expectLineSpan(d, "keep alpha", 5, 10);
    try expectLineSpan(d, "keep BETA", 5, 9);
    try expectLineTokens(&d, &.{ "keep alpha", "keep BETA" }, &.{ "dirt-token", "untracked-token" });
}

test "mutate file: stage, unstage, discard; refuse discard staged" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    try testing.expectError(error.GitFailed, mutate(alloc, io, tmp.cwd(), .{
        .action = .stage,
        .path = "x",
        .group = .unstaged,
    }));
}

test "mutate: GitFailed fills fail_output from git stderr" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
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

test "survivingFileText unstaged is worktree, staged is index" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try initTestRepo(alloc, io, cwd);
    try tmp.write(io, "f.txt", "base\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "f.txt" });
    try expectGitOk(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "f.txt", "staged body\n");
    try expectGitOk(alloc, io, cwd, &.{ "git", "add", "f.txt" });
    try tmp.write(io, "f.txt", "worktree body\n");

    var d = try loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();

    const unstaged = try findFile(d, "f.txt", .unstaged);
    const staged = try findFile(d, "f.txt", .staged);
    const wt = try survivingFileText(alloc, io, cwd, &unstaged, .local);
    defer alloc.free(wt);
    const idx = try survivingFileText(alloc, io, cwd, &staged, .local);
    defer alloc.free(idx);
    try testing.expectEqualStrings("worktree body\n", wt);
    try testing.expectEqualStrings("staged body\n", idx);
}

test "attachSpans on a parsed hunk colors the changed tokens" {
    const text =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -8,3 +8,3 @@
        \\ other
        \\-old
        \\+new
        \\ other
        \\diff --git a/g.txt b/g.txt
        \\--- a/g.txt
        \\+++ b/g.txt
        \\@@ -1 +1 @@
        \\-gone
        \\+else
    ;
    const alloc = testing.allocator;
    var d = try diff.parsePieces(alloc, &.{.{ .text = text, .group = .unstaged }});
    defer d.deinit();
    try worddiff.attachSpans(alloc, &d);

    const old_sp = d.files[0].hunks[0].lines[1].spans.?;
    try testing.expectEqual(1, old_sp.len);
    try testing.expectEqual(0, old_sp[0].start);
    try testing.expectEqual(3, old_sp[0].end);
    try testing.expect(d.files[0].hunks[0].lines[0].spans == null);
    const gone = d.files[1].hunks[0].lines[0].spans.?;
    try testing.expectEqual(1, gone.len);
    try testing.expectEqual(0, gone[0].start);
    try testing.expectEqual(4, gone[0].end);
}

