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
//! ## Explicit range
//!
//! `loadRangeDiff` runs `git diff --find-renames <range>` with the range
//! string as written (no `...` / `..` rewrite). Untracked files are not
//! appended. An empty result is an empty `Diff`. Invalid range is `GitFailed`.
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
//! ## Cursor targeting
//!
//! `indexTargetAt` and `groupSpanAt` map a flatten cursor to the file, hunk,
//! or group to mutate. Neighbor marks restore the cursor after that span is
//! gone. Rows answer structure and geometry; these types are not a view API.
//!
//! `applyAtCursor` / `applyGroupAtCursor` run `mutate`, reload the local diff
//! (hiding approved hunks), restore the cursor, and call comment remap (and
//! discard comment delete).
//! `discardTargetAt` is the allowed discard; staged is a no-op. `stagePlan` /
//! `confirmNext` are what the app loop dispatches. Overlay paint stays in the
//! TUI.
//!
//! ## Errors
//!
//! - `NotARepository` — cwd is not inside a git work tree.
//! - `GitNotFound` — `git` executable missing from `PATH`.
//! - `GitFailed` — git exited non-zero (or crashed) on a required command,
//!   or the action is not allowed on that group.

const std = @import("std");
const diff = @import("diff");
const view = @import("view");
const store = @import("store");
const comments = @import("comments");
const approve = @import("approve");
const Allocator = std.mem.Allocator;
const Io = std.Io;

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
        unstaged = try git(alloc, io, cwd, .{ .argv = &.{ "git", "diff", "--find-renames" } });
        staged = try git(alloc, io, cwd, .{ .argv = &.{ "git", "diff", "--find-renames", "--cached" } });
    }

    return try diff.parsePieces(alloc, &.{
        .{ .text = unstaged orelse "", .group = .unstaged },
        .{ .text = untracked orelse "", .group = .untracked },
        .{ .text = staged orelse "", .group = .staged },
    });
}

/// Load `git diff --find-renames <range>`. `range` is passed through as
/// written (no `...` / `..` rewrite). Pass `.inherit` for the process cwd.
pub fn loadRangeDiff(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, range: []const u8) Error!diff.Diff {
    try ensureInsideWorkTree(alloc, io, cwd);
    const out = try git(alloc, io, cwd, .{ .argv = &.{ "git", "diff", "--find-renames", range } });
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

/// File or hunk to stage/unstage at `cursor`. `path` borrows from `rows`.
/// `whole_file` selects the containing file (`Space S` / `Space x` from a hunk). On a file
/// header, the target is always the file. `null` on empty lists, section
/// headers, and untagged (range) rows.
pub const IndexTarget = struct {
    path: []const u8,
    group: diff.Group,
    /// 0-based hunk in this file; `null` means the whole file.
    hunk_i: ?usize,
    first: usize,
    last: usize,
};

pub fn indexTargetAt(rows: []const view.row.Row, cursor: usize, whole_file: bool) ?IndexTarget {
    if (rows.len == 0) return null;
    const cur = view.row.clampCursor(cursor, rows.len);
    if (rows[cur] == .section_header) return null;
    const fi = view.nav.currentFileStart(rows, cur) orelse return null;
    const fh = rows[fi].file_header;
    const group = fh.group orelse return null;
    const in_hunk = view.nav.currentHunkInFile(rows, cur);
    if (whole_file or in_hunk == null) {
        return .{
            .path = fh.path,
            .group = group,
            .hunk_i = null,
            .first = fi,
            .last = rowSpanLast(rows, fi, true),
        };
    }
    const hi = in_hunk.?;
    return .{
        .path = fh.path,
        .group = group,
        .hunk_i = hunkIndexInFile(rows, fi, hi),
        .first = hi,
        .last = rowSpanLast(rows, hi, false),
    };
}

/// Remaining change to land on after the target is removed from this load.
/// `path` borrows from `rows`. `hunk_i` is the index in that file *after*
/// removing a same-file hunk target (unchanged for a different file).
pub const NeighborMark = struct {
    path: []const u8,
    group: diff.Group,
    hunk_i: ?usize,
};

/// Prefer the next file/hunk header after `target.last`; else the previous
/// header before `target.first`. `null` when the target is the only change.
pub fn neighborMark(rows: []const view.row.Row, target: IndexTarget) ?NeighborMark {
    if (headerAfter(rows, target.last)) |idx| {
        return markAtHeader(rows, idx, target);
    }
    if (target.first > 0) {
        if (headerBefore(rows, target.first)) |idx| {
            return markAtHeader(rows, idx, target);
        }
    }
    return null;
}

/// Section under the cursor and the last row of its last file. `null` when
/// `cursor` is not a section header.
pub const GroupSpan = struct {
    group: diff.Group,
    first: usize,
    last: usize,
};

pub fn groupSpanAt(rows: []const view.row.Row, cursor: usize) ?GroupSpan {
    if (rows.len == 0) return null;
    const cur = view.row.clampCursor(cursor, rows.len);
    const group = switch (rows[cur]) {
        .section_header => |g| g,
        else => return null,
    };
    var i = cur + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .section_header => return .{ .group = group, .first = cur, .last = i - 1 },
            else => {},
        }
    }
    return .{ .group = group, .first = cur, .last = rows.len - 1 };
}

/// Remaining section or file after a whole-group mutation. `path` borrows
/// from `rows`.
pub const GroupNeighborMark = union(enum) {
    section: diff.Group,
    file: struct { path: []const u8, group: diff.Group },
};

/// Prefer the following section or file after `span.last`; else the previous
/// section or file before `span.first`. `null` when this group is the only
/// change.
pub fn groupNeighborMark(rows: []const view.row.Row, span: GroupSpan) ?GroupNeighborMark {
    var i = span.last + 1;
    while (i < rows.len) : (i += 1) {
        if (sectionOrFileMark(rows, i)) |m| return m;
    }
    i = span.first;
    while (i > 0) {
        i -= 1;
        if (sectionOrFileMark(rows, i)) |m| return m;
    }
    return null;
}

/// Land on `mark`'s section or file after reload. Missing mark → row 0.
pub fn restoreGroupNeighbor(rows: []const view.row.Row, mark: GroupNeighborMark) usize {
    if (rows.len == 0) return 0;
    switch (mark) {
        .section => |g| {
            for (rows, 0..) |row, i| {
                switch (row) {
                    .section_header => |sg| if (sg == g) return i,
                    else => {},
                }
            }
        },
        .file => |f| {
            for (rows, 0..) |row, i| {
                switch (row) {
                    .file_header => |fh| {
                        const g = fh.group orelse continue;
                        if (g == f.group and std.mem.eql(u8, fh.path, f.path)) return i;
                    },
                    else => {},
                }
            }
        },
    }
    return 0;
}

/// Land on `mark`'s file (and hunk, if set) after reload. Missing hunk → that
/// file's header. Missing file → row 0.
pub fn restoreNeighbor(rows: []const view.row.Row, mark: NeighborMark) usize {
    if (rows.len == 0) return 0;
    for (rows, 0..) |row, i| {
        switch (row) {
            .file_header => |fh| {
                const g = fh.group orelse continue;
                if (g != mark.group or !std.mem.eql(u8, fh.path, mark.path)) continue;
                const want = mark.hunk_i orelse return i;
                var n: usize = 0;
                var j = i + 1;
                while (j < rows.len) : (j += 1) {
                    switch (rows[j]) {
                        .hunk_header => {
                            if (n == want) return j;
                            n += 1;
                        },
                        .file_header, .section_header => break,
                        .line => {},
                    }
                }
                return i;
            },
            else => {},
        }
    }
    return 0;
}

fn sectionOrFileMark(rows: []const view.row.Row, idx: usize) ?GroupNeighborMark {
    switch (rows[idx]) {
        .section_header => |g| return .{ .section = g },
        .file_header => |fh| {
            const g = fh.group orelse return null;
            return .{ .file = .{ .path = fh.path, .group = g } };
        },
        .hunk_header, .line => return null,
    }
}

fn rowSpanLast(rows: []const view.row.Row, start: usize, whole_file: bool) usize {
    var i = start + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .file_header, .section_header => return i - 1,
            .hunk_header => if (!whole_file) return i - 1,
            .line => {},
        }
    }
    return rows.len - 1;
}

fn hunkIndexInFile(rows: []const view.row.Row, file_start: usize, hunk_row: usize) usize {
    var n: usize = 0;
    var i = file_start;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .hunk_header => {
                if (i == hunk_row) return n;
                n += 1;
            },
            .file_header => if (i != file_start) return n,
            .section_header => return n,
            .line => {},
        }
    }
    return n;
}

fn headerAfter(rows: []const view.row.Row, last: usize) ?usize {
    var i = last + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .file_header, .hunk_header => return i,
            .section_header, .line => {},
        }
    }
    return null;
}

fn headerBefore(rows: []const view.row.Row, first: usize) ?usize {
    var i = first;
    while (i > 0) {
        i -= 1;
        switch (rows[i]) {
            .file_header, .hunk_header => return i,
            .section_header, .line => {},
        }
    }
    return null;
}

fn markAtHeader(rows: []const view.row.Row, idx: usize, target: IndexTarget) ?NeighborMark {
    const fi = view.nav.currentFileStart(rows, idx) orelse return null;
    const fh = rows[fi].file_header;
    const group = fh.group orelse return null;
    var hunk_i: ?usize = null;
    if (rows[idx] == .hunk_header) {
        hunk_i = hunkIndexInFile(rows, fi, idx);
        if (target.hunk_i) |t| {
            if (std.mem.eql(u8, fh.path, target.path) and group == target.group) {
                if (hunk_i.? > t) hunk_i = hunk_i.? - 1;
            }
        }
    }
    return .{ .path = fh.path, .group = group, .hunk_i = hunk_i };
}

/// File or hunk at `cursor` that discard may run. `null` on empty, section,
/// untagged, or staged rows (unstage first).
pub fn discardTargetAt(rows: []const view.row.Row, cursor: usize, whole_file: bool) ?IndexTarget {
    const target = indexTargetAt(rows, cursor, whole_file) orelse return null;
    return switch (target.group) {
        .staged => null,
        .unstaged, .untracked => target,
    };
}

/// Whether discard of the cursor target would also delete live comments.
pub fn discardHasComments(
    review: *const store.Review,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    whole_file: bool,
) bool {
    const target = discardTargetAt(rows, cursor, whole_file) orelse return false;
    const file = fileForTarget(d, target) orelse return false;
    return comments.hasMatching(review, file, diffHunkIndex(file, rows, target));
}

/// What stage/unstage at `cursor` should do. Section header (when not
/// `whole_file`) is a group confirm; otherwise the file or hunk under the
/// cursor. `none` when there is no target.
pub const StagePlan = union(enum) {
    none,
    group: diff.Group,
    cursor,
};

pub fn stagePlan(rows: []const view.row.Row, cursor: usize, whole_file: bool) StagePlan {
    if (!whole_file) {
        if (groupSpanAt(rows, cursor)) |span| return .{ .group = span.group };
    }
    if (indexTargetAt(rows, cursor, whole_file) != null) return .cursor;
    return .none;
}

pub const ConfirmKind = enum { discard, group };

/// Next step after the user answers a confirm overlay (`yes` is the selected
/// choice). `comments_phase` is whether the comments question is already showing.
pub const ConfirmNext = union(enum) {
    close,
    comments,
    group,
    discard: bool,
};

pub fn confirmNext(
    kind: ConfirmKind,
    comments_phase: bool,
    yes: bool,
    review: *const store.Review,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    whole_file: bool,
) ConfirmNext {
    return switch (kind) {
        .group => if (yes) .group else .close,
        .discard => {
            if (!comments_phase and !yes) return .close;
            if (!comments_phase and discardHasComments(review, d, rows, cursor, whole_file)) return .comments;
            return .{ .discard = comments_phase and yes };
        },
    };
}

/// Diff hunk index for a hunk `target` (match `@@` starts on the row). `null`
/// when the target is the whole file or the header is gone from `rows`.
fn diffHunkIndex(file: *const diff.File, rows: []const view.row.Row, target: IndexTarget) ?usize {
    if (target.hunk_i == null) return null;
    if (target.first >= rows.len) return null;
    return switch (rows[target.first]) {
        .hunk_header => |hh| approve.hunkAt(file.*, hh.old_start, hh.new_start),
        else => null,
    };
}

/// Parsed file matching `target`. `null` when path/group is missing or the hunk is out of range.
fn fileForTarget(d: *const diff.Diff, target: IndexTarget) ?*const diff.File {
    for (d.files) |*f| {
        const g = f.group orelse continue;
        if (g != target.group) continue;
        if (!std.mem.eql(u8, f.displayPath(), target.path)) continue;
        if (target.hunk_i) |hi| {
            if (hi >= f.hunks.len) return null;
        }
        return f;
    }
    return null;
}

pub const MutationKind = enum { stage_unstage, discard };

/// Local diff, rows, and restored cursor after a successful mutate.
/// Caller owns `diff` and `rows`. `approved_n` is live approved identities
/// still in `diff` after prune (0 when the store could not be loaded).
pub const Snapshot = struct {
    diff: diff.Diff,
    rows: []view.row.Row,
    cursor: usize,
    approved_n: usize = 0,

    pub fn deinit(self: Snapshot, alloc: Allocator) void {
        alloc.free(self.rows);
        var parsed = self.diff;
        parsed.deinit();
    }
};

pub const MutationResult = struct {
    snapshot: ?Snapshot = null,
    /// Owned git stderr (or fallback). Caller frees.
    fail_message: ?[]u8 = null,
    reload_err: ?Error = null,
    save_failed: bool = false,
};

pub const MutationStatus = union(enum) {
    noop,
    result: MutationResult,
};

/// Stage, unstage, or discard the file or hunk at `cursor`. On success, reload
/// the local diff and restore onto the neighbor change. Stage/unstage remaps
/// live comments on the target. `delete_comments` (discard only) removes
/// matching live comments after a successful mutate. Mutate failure leaves
/// the list and store unchanged.
pub fn applyAtCursor(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    review: *store.Review,
    whole_file: bool,
    kind: MutationKind,
    delete_comments: bool,
) Allocator.Error!MutationStatus {
    const target = indexTargetAt(rows, cursor, whole_file) orelse return .noop;
    const file = fileForTarget(d, target) orelse return .noop;
    const diff_hunk_i = diffHunkIndex(file, rows, target);
    if (target.hunk_i != null and diff_hunk_i == null) return .noop;
    const action: Action = switch (kind) {
        .stage_unstage => switch (target.group) {
            .unstaged, .untracked => .stage,
            .staged => .unstage,
        },
        .discard => switch (target.group) {
            .unstaged, .untracked => .discard,
            .staged => return .noop,
        },
    };
    const neighbor = neighborMark(rows, target);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    var saved: std.ArrayList(comments.RemoveSnap) = .empty;
    defer saved.deinit(alloc);
    if (delete_comments and kind == .discard) {
        try comments.collectMatching(review, file, diff_hunk_i, alloc, &ids, &saved);
    }
    var fail: []u8 = &.{};
    mutate(alloc, io, cwd, .{
        .action = action,
        .path = file.displayPath(),
        .group = target.group,
        .hunk = if (diff_hunk_i) |hi| &file.hunks[hi] else null,
        .file = if (diff_hunk_i != null) file else null,
        .fail_output = &fail,
    }) catch |err| switch (err) {
        error.OutOfMemory => {
            if (fail.len > 0) alloc.free(fail);
            return error.OutOfMemory;
        },
        error.NotARepository, error.GitNotFound, error.GitFailed, error.BadHunkHeader => {
            defer if (fail.len > 0) alloc.free(fail);
            return .{ .result = .{ .fail_message = try failMessage(alloc, fail, err) } };
        },
    };

    var save_failed = false;
    if (ids.items.len > 0) {
        save_failed = !removeMatchingComments(review, alloc, io, ids.items, saved.items);
    }

    const reloaded = reloadLocal(alloc, io, cwd) catch |err| {
        return .{ .result = .{ .reload_err = err, .save_failed = save_failed } };
    };
    var new_diff = reloaded.diff;
    const new_rows = reloaded.rows;
    errdefer {
        alloc.free(new_rows);
        new_diff.deinit();
    }

    if (kind == .stage_unstage) {
        var priors: std.ArrayList(comments.AnchorSnap) = .empty;
        defer priors.deinit(alloc);
        try comments.remapMatching(review, file, &new_diff, diff_hunk_i, alloc, &priors);
        if (!saveCommentRemap(review, alloc, io, priors.items)) save_failed = true;
    }

    const new_cursor: usize = if (neighbor) |m| restoreNeighbor(new_rows, m) else 0;
    return .{ .result = .{
        .snapshot = .{
            .diff = new_diff,
            .rows = new_rows,
            .cursor = new_cursor,
            .approved_n = reloaded.approved_n,
        },
        .save_failed = save_failed,
    } };
}

/// Stage or unstage every file in the section at `cursor`. File-level mutate
/// in flatten order. Always reload after the loop (list matches git). A git
/// error is returned with that reload so the overlay can open.
pub fn applyGroupAtCursor(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    review: *store.Review,
) Allocator.Error!MutationStatus {
    const span = groupSpanAt(rows, cursor) orelse return .noop;
    const action: Action = switch (span.group) {
        .unstaged, .untracked => .stage,
        .staged => .unstage,
    };
    const neighbor = groupNeighborMark(rows, span);
    var fail: []u8 = &.{};
    const first_err: ?Error = blk: {
        for (d.files) |f| {
            const g = f.group orelse continue;
            if (g != span.group) continue;
            mutate(alloc, io, cwd, .{
                .action = action,
                .path = f.displayPath(),
                .group = span.group,
                .fail_output = &fail,
            }) catch |err| switch (err) {
                error.OutOfMemory => {
                    if (fail.len > 0) alloc.free(fail);
                    return error.OutOfMemory;
                },
                error.NotARepository, error.GitNotFound, error.GitFailed, error.BadHunkHeader => break :blk err,
            };
        }
        break :blk null;
    };

    var reload_err: ?Error = null;
    var next: ?Snapshot = null;
    var group_save_failed = false;
    if (reloadLocal(alloc, io, cwd)) |loaded| {
        var new_diff = loaded.diff;
        const new_rows = loaded.rows;
        var priors: std.ArrayList(comments.AnchorSnap) = .empty;
        defer priors.deinit(alloc);
        for (d.files) |*f| {
            const g = f.group orelse continue;
            if (g != span.group) continue;
            comments.remapMatching(review, f, &new_diff, null, alloc, &priors) catch |err| {
                alloc.free(new_rows);
                new_diff.deinit();
                if (fail.len > 0) alloc.free(fail);
                return err;
            };
        }
        const save_failed = !saveCommentRemap(review, alloc, io, priors.items);
        const new_cursor: usize = if (neighbor) |m| restoreGroupNeighbor(new_rows, m) else 0;
        next = .{
            .diff = new_diff,
            .rows = new_rows,
            .cursor = new_cursor,
            .approved_n = loaded.approved_n,
        };
        group_save_failed = save_failed;
    } else |err| {
        reload_err = err;
    }

    const fail_message: ?[]u8 = if (first_err) |err| try failMessage(alloc, fail, err) else null;
    if (fail.len > 0) alloc.free(fail);
    return .{ .result = .{
        .snapshot = next,
        .fail_message = fail_message,
        .reload_err = reload_err,
        .save_failed = group_save_failed,
    } };
}

fn failMessage(alloc: Allocator, fail: []const u8, err: Error) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, fail, " \t\r\n");
    if (trimmed.len > 0) return try alloc.dupe(u8, trimmed);
    return try alloc.dupe(u8, errorMessage(err));
}

fn reloadLocal(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd) Error!struct {
    diff: diff.Diff,
    rows: []view.row.Row,
    approved_n: usize,
} {
    var new_diff = try loadDefaultDiffCwd(alloc, io, cwd);
    errdefer new_diff.deinit();
    const vis = visibleLocal(alloc, io, cwd, &new_diff) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const new_rows = view.row.flatten(alloc, &new_diff) catch return error.OutOfMemory;
            return .{ .diff = new_diff, .rows = new_rows, .approved_n = 0 };
        },
    };
    return .{ .diff = new_diff, .rows = vis.rows, .approved_n = vis.approved_n };
}

fn visibleLocal(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    d: *const diff.Diff,
) approve.LoadError!approve.Visible {
    switch (cwd) {
        .inherit => return approve.loadVisible(alloc, io, .cwd(), d),
        .path => |p| {
            const dir = try Io.Dir.openDirAbsolute(io, p, .{});
            defer dir.close(io);
            return approve.loadVisible(alloc, io, dir, d);
        },
        .dir => |dir| return approve.loadVisible(alloc, io, dir, d),
    }
}

fn removeMatchingComments(
    review: *store.Review,
    alloc: Allocator,
    io: Io,
    ids: []const []const u8,
    saved: []const comments.RemoveSnap,
) bool {
    if (ids.len == 0) return true;
    review.remove(ids) catch return true;
    store.save(review, alloc, io, .cwd()) catch {
        for (saved) |s| {
            review.comments.insert(review.arena.allocator(), s.idx, s.comment) catch {};
        }
        return false;
    };
    return true;
}

fn saveCommentRemap(
    review: *store.Review,
    alloc: Allocator,
    io: Io,
    priors: []const comments.AnchorSnap,
) bool {
    if (priors.len == 0) return true;
    store.save(review, alloc, io, .cwd()) catch {
        for (priors) |p| {
            review.setLines(p.id, p.old_line, p.new_line, p.side) catch {};
        }
        return false;
    };
    return true;
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
        const rows = try view.row.flatten(alloc, &d);
        defer alloc.free(rows);
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings(
            "old_name.txt -> new_name.txt",
            view.row.fileHeaderPathLabel(rows[1].file_header, &buf),
        );
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

fn threeGroupRows(alloc: Allocator) !struct { d: diff.Diff, rows: []view.row.Row } {
    const unstaged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const untracked_txt =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    const staged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1,2 @@
        \\ same
        \\+staged
    ;
    var d = try diff.parsePieces(alloc, &.{
        .{ .text = unstaged_txt, .group = .unstaged },
        .{ .text = untracked_txt, .group = .untracked },
        .{ .text = staged_txt, .group = .staged },
    });
    errdefer d.deinit();
    const rows = try view.row.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "indexTargetAt empty section and untagged" {
    try testing.expect(indexTargetAt(&.{}, 0, false) == null);

    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    try testing.expect(indexTargetAt(rows, 0, false) == null);
    try testing.expect(indexTargetAt(rows, 2, false) == null);

    var fix = try threeGroupRows(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    try testing.expect(indexTargetAt(fix.rows, 0, false) == null);
    try testing.expect(indexTargetAt(fix.rows, 5, true) == null);
}

test "indexTargetAt file hunk and file-from-hunk" {
    var fix = try threeGroupRows(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    // 0 Unstaged, 1 file a, 2 hunk, 3 del, 4 add, 5 Untracked, 6 file u, …
    // 9 Staged, 10 file a, 11 hunk, 12 ctx, 13 add.

    const file = indexTargetAt(rows, 1, false).?;
    try testing.expectEqualStrings("a", file.path);
    try testing.expectEqual(diff.Group.unstaged, file.group);
    try testing.expect(file.hunk_i == null);
    try testing.expectEqual(1, file.first);
    try testing.expectEqual(4, file.last);

    const hunk = indexTargetAt(rows, 3, false).?;
    try testing.expectEqualStrings("a", hunk.path);
    try testing.expectEqual(diff.Group.unstaged, hunk.group);
    try testing.expectEqual(0, hunk.hunk_i.?);
    try testing.expectEqual(2, hunk.first);
    try testing.expectEqual(4, hunk.last);

    const from_hunk = indexTargetAt(rows, 3, true).?;
    try testing.expect(from_hunk.hunk_i == null);
    try testing.expectEqual(1, from_hunk.first);
    try testing.expectEqual(4, from_hunk.last);

    const staged = indexTargetAt(rows, 12, false).?;
    try testing.expectEqualStrings("a", staged.path);
    try testing.expectEqual(diff.Group.staged, staged.group);
    try testing.expectEqual(0, staged.hunk_i.?);
}

test "neighborMark following hunk next file and only change" {
    const two_hunks =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-old1
        \\+new1
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = two_hunks, .group = .unstaged },
    });
    defer d.deinit();
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 Unstaged, 1 file, 2 h0, 3 del, 4 add, 5 h1, 6 del, 7 add.

    const first = indexTargetAt(rows, 3, false).?;
    const after_first = neighborMark(rows, first).?;
    try testing.expectEqualStrings("a", after_first.path);
    try testing.expectEqual(diff.Group.unstaged, after_first.group);
    try testing.expectEqual(0, after_first.hunk_i.?);

    const second = indexTargetAt(rows, 6, false).?;
    const before_second = neighborMark(rows, second).?;
    try testing.expectEqualStrings("a", before_second.path);
    try testing.expectEqual(0, before_second.hunk_i.?);

    var fix = try threeGroupRows(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const next_file = neighborMark(fix.rows, indexTargetAt(fix.rows, 3, false).?).?;
    try testing.expectEqualStrings("u", next_file.path);
    try testing.expectEqual(diff.Group.untracked, next_file.group);
    try testing.expect(next_file.hunk_i == null);

    const only =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d_only = try diff.parsePieces(testing.allocator, &.{
        .{ .text = only, .group = .untracked },
    });
    defer d_only.deinit();
    const only_rows = try view.row.flatten(testing.allocator, &d_only);
    defer testing.allocator.free(only_rows);
    // Whole file is the only change: no following or previous header.
    try testing.expect(neighborMark(only_rows, indexTargetAt(only_rows, 1, false).?) == null);
    // Only hunk: previous header is that file’s row.
    const prev_file = neighborMark(only_rows, indexTargetAt(only_rows, 2, false).?).?;
    try testing.expectEqualStrings("u", prev_file.path);
    try testing.expectEqual(diff.Group.untracked, prev_file.group);
    try testing.expect(prev_file.hunk_i == null);
}

test "restoreNeighbor dest hunk file fallback and gone" {
    try testing.expectEqual(0, restoreNeighbor(&.{}, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = 0,
    }));

    const remaining =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = remaining, .group = .unstaged },
    });
    defer d.deinit();
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 Unstaged, 1 file, 2 hunk, 3 del, 4 add.

    try testing.expectEqual(2, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = 0,
    }));
    try testing.expectEqual(1, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = 4,
    }));
    try testing.expectEqual(1, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = null,
    }));
    try testing.expectEqual(0, restoreNeighbor(rows, .{
        .path = "a",
        .group = .staged,
        .hunk_i = 0,
    }));
    try testing.expectEqual(0, restoreNeighbor(rows, .{
        .path = "gone",
        .group = .unstaged,
        .hunk_i = null,
    }));
}

test "groupSpanAt empty untagged and three groups" {
    try testing.expect(groupSpanAt(&.{}, 0) == null);

    const untagged =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, untagged);
    defer d.deinit();
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    try testing.expect(groupSpanAt(rows, 0) == null);

    var fix = try threeGroupRows(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    // 0 Unstaged, 1-4 file a, 5 Untracked, 6-8 file u, 9 Staged, 10-13 file a.
    try testing.expect(groupSpanAt(fix.rows, 1) == null);

    const unstaged = groupSpanAt(fix.rows, 0).?;
    try testing.expectEqual(diff.Group.unstaged, unstaged.group);
    try testing.expectEqual(0, unstaged.first);
    try testing.expectEqual(4, unstaged.last);

    const untracked = groupSpanAt(fix.rows, 5).?;
    try testing.expectEqual(diff.Group.untracked, untracked.group);
    try testing.expectEqual(5, untracked.first);
    try testing.expectEqual(8, untracked.last);

    const staged = groupSpanAt(fix.rows, 9).?;
    try testing.expectEqual(diff.Group.staged, staged.group);
    try testing.expectEqual(9, staged.first);
    try testing.expectEqual(13, staged.last);
}

test "groupNeighborMark following section previous file and only group" {
    var fix = try threeGroupRows(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);

    const after_unstaged = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 0).?).?;
    try testing.expect(after_unstaged == .section);
    try testing.expectEqual(diff.Group.untracked, after_unstaged.section);

    const after_untracked = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 5).?).?;
    try testing.expect(after_untracked == .section);
    try testing.expectEqual(diff.Group.staged, after_untracked.section);

    const before_staged = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 9).?).?;
    try testing.expect(before_staged == .file);
    try testing.expectEqualStrings("u", before_staged.file.path);
    try testing.expectEqual(diff.Group.untracked, before_staged.file.group);

    const only =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d_only = try diff.parsePieces(testing.allocator, &.{
        .{ .text = only, .group = .untracked },
    });
    defer d_only.deinit();
    const only_rows = try view.row.flatten(testing.allocator, &d_only);
    defer testing.allocator.free(only_rows);
    try testing.expect(groupNeighborMark(only_rows, groupSpanAt(only_rows, 0).?) == null);
}

test "restoreGroupNeighbor dest section file fallback and gone" {
    try testing.expectEqual(0, restoreGroupNeighbor(&.{}, .{ .section = .unstaged }));

    var fix = try threeGroupRows(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);

    try testing.expectEqual(5, restoreGroupNeighbor(fix.rows, .{ .section = .untracked }));
    try testing.expectEqual(6, restoreGroupNeighbor(fix.rows, .{
        .file = .{ .path = "u", .group = .untracked },
    }));
    try testing.expectEqual(0, restoreGroupNeighbor(fix.rows, .{
        .file = .{ .path = "gone", .group = .unstaged },
    }));

    const remaining =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1,2 @@
        \\ same
        \\+staged
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = remaining, .group = .staged },
    });
    defer d.deinit();
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    try testing.expectEqual(0, restoreGroupNeighbor(rows, .{ .section = .untracked }));
}
