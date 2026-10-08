//! Named-step wall timings for load → flatten → paint → present → approve.
//!
//! Each step is `Io.Clock.awake` around a public API, plus requested bytes
//! and git spawn counts. This is not a sampling profiler; attach `samply`
//! or `perf` to a real `rv` for that (see README).
//!
//! Generates git fixtures under `/tmp`. No controlling terminal.

const std = @import("std");
const git = @import("git");
const diff = @import("diff");
const worddiff = @import("worddiff");
const view = @import("view");
const tui = @import("tui");
const approve = @import("approve");
const Frame = @import("Frame");
const IsolatedTmp = @import("isolated_tmp").IsolatedTmp;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const untracked_n: usize = 200;
const large_lines: usize = 2000;
const large_stride: usize = 12;
const term_size: tui.Size = .{ .cols = 100, .rows = 32 };

const default_baseline = "bench/baseline.json";

const usage_text =
    \\rv-bench — load / paint / present / approve timings
    \\
    \\  mise run bench --
    \\  mise run bench -- --json
    \\  mise run bench -- --fixture small
    \\  mise run bench -- --compare
    \\  mise run bench -- --compare bench/baseline.json
    \\  mise run bench -- --write-baseline bench/baseline.json
    \\
    \\Fixtures: small, untracked, large, large_file.
    \\Each step is a monotonic clock around one API (not a sampling profiler).
    \\
;

const Kind = enum { small, untracked, large, large_file };

const Step = struct {
    name: []const u8,
    ns: u64,
    bytes: usize,
    spawns: usize,
};

const Run = struct {
    name: []const u8,
    files: usize,
    hunks: usize,
    rows: usize,
    steps: []Step,
};

const CountAlloc = struct {
    parent: Allocator,
    bytes: usize = 0,

    fn allocator(self: *CountAlloc) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn reset(self: *CountAlloc) void {
        self.bytes = 0;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        const p = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr) orelse return null;
        self.bytes += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        if (!self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) self.bytes += new_len - memory.len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        const p = self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) self.bytes += new_len - memory.len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var json = false;
    var compare_path: ?[]const u8 = null;
    var write_baseline: ?[]const u8 = null;
    var want: std.EnumSet(Kind) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var buf: [1024]u8 = undefined;
            var w = std.Io.File.stdout().writer(io, &buf);
            try w.interface.writeAll(usage_text);
            try w.interface.flush();
            return 0;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--compare")) {
            compare_path = default_baseline;
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                i += 1;
                compare_path = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--write-baseline")) {
            write_baseline = default_baseline;
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                i += 1;
                write_baseline = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--fixture")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("rv-bench: --fixture needs a name\n", .{});
                return 2;
            }
            const k = std.meta.stringToEnum(Kind, argv[i]) orelse {
                std.debug.print("rv-bench: unknown fixture '{s}'\n", .{argv[i]});
                return 2;
            };
            want.insert(k);
            continue;
        }
        std.debug.print("rv-bench: unknown argument '{s}'\n", .{arg});
        return 2;
    }
    if (want.count() == 0) {
        want = .full;
    }

    var runs: std.ArrayList(Run) = .empty;
    defer {
        for (runs.items) |run| alloc.free(run.steps);
        runs.deinit(alloc);
    }

    var kinds = want.iterator();
    while (kinds.next()) |kind| {
        const run = try benchFixture(alloc, io, kind);
        try runs.append(alloc, run);
    }

    var out_buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    if (json) {
        try writeJson(out, runs.items);
    } else {
        try writeTable(out, runs.items);
    }
    if (write_baseline) |path| {
        try writeBaselineFile(alloc, io, path, runs.items);
        if (!json) {
            try out.print("wrote {s}\n", .{path});
        }
    }
    var rc: u8 = 0;
    if (compare_path) |path| {
        if (json) try out.writeByte('\n');
        rc = try writeCompare(alloc, io, out, path, runs.items);
    }
    try out.flush();
    return rc;
}

fn benchFixture(alloc: Allocator, io: Io, kind: Kind) !Run {
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();
    try makeFixture(alloc, io, tmp, kind);

    // Warm the page cache and git before the timed pass.
    {
        var d = try git.loadDefaultDiffCwd(alloc, io, cwd);
        defer d.deinit();
        const rows = try view.row.flatten(alloc, &d);
        defer alloc.free(rows);
        const slots = try view.layout.pairSideBySide(alloc, rows);
        defer alloc.free(slots);
        _ = view.row.lineNumberWidth(rows);
        timeHunkWidths(rows);
    }

    var count: CountAlloc = .{ .parent = alloc };
    const timed = count.allocator();
    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(alloc);

    var stats: git.LoadStats = .{};
    count.reset();
    var t0 = nano(io);
    const texts = try git.loadDefaultTexts(timed, io, .{ .cwd = cwd, .stats = &stats });
    try steps.append(alloc, step("git_stdout", t0, io, &count, stats.spawns));
    defer texts.deinit(timed);

    count.reset();
    t0 = nano(io);
    var parsed = try diff.parsePieces(timed, &.{
        .{ .text = texts.unstaged, .group = .unstaged },
        .{ .text = texts.untracked, .group = .untracked },
        .{ .text = texts.staged, .group = .staged },
    });
    try steps.append(alloc, step("parse", t0, io, &count, 0));
    defer parsed.deinit();

    count.reset();
    t0 = nano(io);
    try worddiff.attachSpans(timed, &parsed);
    try steps.append(alloc, step("attach_spans", t0, io, &count, 0));

    count.reset();
    t0 = nano(io);
    const rows = try view.row.flatten(timed, &parsed);
    try steps.append(alloc, step("flatten", t0, io, &count, 0));
    defer timed.free(rows);

    count.reset();
    t0 = nano(io);
    const slots = try view.layout.pairSideBySide(timed, rows);
    try steps.append(alloc, step("pair_side_by_side", t0, io, &count, 0));
    defer timed.free(slots);

    count.reset();
    t0 = nano(io);
    _ = view.row.lineNumberWidth(rows);
    try steps.append(alloc, step("line_number_width", t0, io, &count, 0));

    count.reset();
    t0 = nano(io);
    timeHunkWidths(rows);
    try steps.append(alloc, step("hunk_max_line_width", t0, io, &count, 0));

    const n_files = parsed.files.len;
    const n_hunks = hunkCount(&parsed);
    const n_rows = rows.len;

    // Paint into a 100×32 Screen; present writes CSI to /dev/null.
    const marked = try timed.alloc(bool, rows.len);
    defer timed.free(marked);
    @memset(marked, false);

    var scr = try tui.Screen.init(timed, term_size);
    defer scr.deinit();
    const frame: Frame = .{};
    const shown = shownFor(rows, slots, marked);

    const null_fd = try openDevNull();
    defer _ = std.posix.system.close(null_fd);
    var sink: tui.Tty = .{
        .fd = null_fd,
        .original = undefined,
    };

    count.reset();
    t0 = nano(io);
    frame.paint(&scr, term_size, shown);
    try steps.append(alloc, step("paint", t0, io, &count, 0));

    count.reset();
    t0 = nano(io);
    try scr.present(&sink);
    try steps.append(alloc, step("present", t0, io, &count, 0));

    count.reset();
    t0 = nano(io);
    frame.paint(&scr, term_size, shown);
    try steps.append(alloc, step("paint_noop", t0, io, &count, 0));

    count.reset();
    t0 = nano(io);
    try scr.present(&sink);
    try steps.append(alloc, step("present_noop", t0, io, &count, 0));

    if (kind == .large_file) {
        try benchApproveFile(alloc, io, timed, &count, &steps, frame, &scr, tmp);
    } else if (firstStageTarget(&parsed)) |target| {
        var approved = approve.initEmpty(alloc);
        defer approved.deinit();
        const path = try alloc.dupe(u8, target.path);
        defer alloc.free(path);
        var hashes: std.ArrayList(approve.Hash) = .empty;
        defer hashes.deinit(alloc);
        for (target.hunk.identityHunks()) |id| {
            try hashes.append(alloc, approve.fingerprintHunk(id));
        }

        var mutate_stats: git.LoadStats = .{};
        count.reset();
        t0 = nano(io);
        try mutateOrPrint(timed, io, cwd, .{
            .action = .stage,
            .path = path,
            .group = target.group,
            .hunk = target.hunk,
            .file = target.file,
            .stats = &mutate_stats,
        });
        try steps.append(alloc, step("mutate", t0, io, &count, mutate_stats.spawns));

        const paths = [_][]const u8{path};
        var reload_stats: git.LoadStats = .{};
        count.reset();
        t0 = nano(io);
        var live = try git.reloadPaths(timed, io, cwd, &parsed, &paths, &reload_stats);
        try steps.append(alloc, step("reload_paths", t0, io, &count, reload_stats.spawns));
        defer live.deinit();

        count.reset();
        t0 = nano(io);
        for (hashes.items) |hash| {
            try approved.append(path, hash);
        }
        try approve.save(&approved, timed, io, tmp.dir);
        try steps.append(alloc, step("approve_save", t0, io, &count, 0));

        count.reset();
        t0 = nano(io);
        const placed = try approve.place(timed, io, tmp.dir, &live, &approved);
        try steps.append(alloc, step("place", t0, io, &count, 0));
        defer timed.free(placed);

        count.reset();
        t0 = nano(io);
        const omitted = try view.row.flattenPlaced(timed, &live, placed);
        try steps.append(alloc, step("flatten_placed", t0, io, &count, 0));
        defer timed.free(omitted);

        count.reset();
        t0 = nano(io);
        const omitted_slots = try view.layout.pairSideBySide(timed, omitted);
        try steps.append(alloc, step("pair_rebuild", t0, io, &count, 0));
        defer timed.free(omitted_slots);

        count.reset();
        t0 = nano(io);
        try paintRows(timed, frame, &scr, omitted, omitted_slots);
        try steps.append(alloc, step("paint_approve", t0, io, &count, 0));

        // Remaining unstaged hunks in this tree, as repeated `a`. Large only:
        // 166 more hunks in one file, store growing, git may regroup staged lines.
        if (kind == .large) {
            var rest_stats: git.LoadStats = .{};
            count.reset();
            t0 = nano(io);
            while (firstStageTarget(&live) != null) {
                try stageAndHideHunk(timed, io, cwd, tmp.dir, &live, &approved, &rest_stats, frame, &scr);
            }
            try steps.append(alloc, step("approve_rest", t0, io, &count, rest_stats.spawns));
        }
    }

    return .{
        .name = @tagName(kind),
        .files = n_files,
        .hunks = n_hunks,
        .rows = n_rows,
        .steps = try steps.toOwnedSlice(alloc),
    };
}

const StageTarget = struct {
    path: []const u8,
    group: diff.Group,
    hunk: *const diff.Hunk,
    file: *const diff.File,
};

fn firstStageTarget(d: *const diff.Diff) ?StageTarget {
    for (d.files) |*f| {
        const group = f.group orelse continue;
        switch (group) {
            .unstaged, .untracked => {},
            .staged => continue,
        }
        if (f.hunks.len == 0) continue;
        return .{
            .path = f.displayPath(),
            .group = group,
            .hunk = &f.hunks[0],
            .file = f,
        };
    }
    return null;
}

fn shownFor(
    rows: []const view.row.Row,
    slots: []const view.layout.SbsSlot,
    marked: []const bool,
) Frame.Shown {
    return .{
        .rows = rows,
        .slots = slots,
        .cursor = 0,
        .scroll = 0,
        .col_scroll = 0,
        .pans = &.{},
        .wrap = false,
        .show_line_numbers = true,
        .layout_pref = .side_by_side,
        .marked = marked,
        .title = "rv-bench",
        .show_footer = true,
        .source_label = "HEAD",
        .empty_label = "HEAD · empty",
        .open_n = 0,
        .hints = .{},
        .area = .init(term_size, 1),
    };
}

fn paintRows(
    alloc: Allocator,
    frame: Frame,
    scr: *tui.Screen,
    rows: []const view.row.Row,
    slots: []const view.layout.SbsSlot,
) !void {
    const marked = try alloc.alloc(bool, rows.len);
    defer alloc.free(marked);
    @memset(marked, false);
    frame.paint(scr, term_size, shownFor(rows, slots, marked));
}

/// One remaining unstaged hunk: stage, reload, append, save, omit, paint.
/// Same work as `a` after the first hunk; timers sit around the whole loop.
fn stageAndHideHunk(
    alloc: Allocator,
    io: Io,
    cwd: std.process.Child.Cwd,
    root: Io.Dir,
    live: *diff.Diff,
    approved: *approve.Approved,
    stats: *git.LoadStats,
    frame: Frame,
    scr: *tui.Screen,
) !void {
    const target = firstStageTarget(live) orelse return;
    const path = try alloc.dupe(u8, target.path);
    defer alloc.free(path);
    var hashes: std.ArrayList(approve.Hash) = .empty;
    defer hashes.deinit(alloc);
    for (target.hunk.identityHunks()) |id| {
        try hashes.append(alloc, approve.fingerprintHunk(id));
    }
    try mutateOrPrint(alloc, io, cwd, .{
        .action = .stage,
        .path = path,
        .group = target.group,
        .hunk = target.hunk,
        .file = target.file,
        .stats = stats,
    });
    const paths = [_][]const u8{path};
    const next = try git.reloadPaths(alloc, io, cwd, live, &paths, stats);
    live.deinit();
    live.* = next;
    for (hashes.items) |hash| {
        try approved.append(path, hash);
    }
    try approve.save(approved, alloc, io, root);
    const placed = try approve.place(alloc, io, root, live, approved);
    defer alloc.free(placed);
    const omitted = try view.row.flattenPlaced(alloc, live, placed);
    defer alloc.free(omitted);
    const omitted_slots = try view.layout.pairSideBySide(alloc, omitted);
    defer alloc.free(omitted_slots);
    try paintRows(alloc, frame, scr, omitted, omitted_slots);
}

/// `A` on the large file: one `git add`, reload, fingerprint every hunk, omit.
fn benchApproveFile(
    alloc: Allocator,
    io: Io,
    timed: Allocator,
    count: *CountAlloc,
    steps: *std.ArrayList(Step),
    frame: Frame,
    scr: *tui.Screen,
    tmp: IsolatedTmp,
) !void {
    const cwd = tmp.cwd();
    var live = try git.loadDefaultDiffCwd(alloc, io, cwd);
    defer live.deinit();
    const target = firstStageTarget(&live) orelse return;
    const path = try alloc.dupe(u8, target.path);
    defer alloc.free(path);
    const group = target.group;

    var stats: git.LoadStats = .{};
    count.reset();
    const t0 = nano(io);
    try mutateOrPrint(timed, io, cwd, .{
        .action = .stage,
        .path = path,
        .group = group,
        .stats = &stats,
    });
    const paths = [_][]const u8{path};
    const next = try git.reloadPaths(timed, io, cwd, &live, &paths, &stats);
    live.deinit();
    live = next;
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    for (live.files) |f| {
        const g = f.group orelse continue;
        if (g != .staged) continue;
        if (!std.mem.eql(u8, f.displayPath(), path)) continue;
        try approved.appendFile(timed, io, tmp.dir, f);
        break;
    }
    try approve.save(&approved, timed, io, tmp.dir);
    const placed = try approve.place(timed, io, tmp.dir, &live, &approved);
    defer timed.free(placed);
    const omitted = try view.row.flattenPlaced(timed, &live, placed);
    defer timed.free(omitted);
    const omitted_slots = try view.layout.pairSideBySide(timed, omitted);
    defer timed.free(omitted_slots);
    try paintRows(timed, frame, scr, omitted, omitted_slots);
    try steps.append(alloc, step("approve_file", t0, io, count, stats.spawns));
}

fn mutateOrPrint(alloc: Allocator, io: Io, cwd: std.process.Child.Cwd, opts: git.MutateOpts) !void {
    var fail: []u8 = &.{};
    var copy = opts;
    copy.fail_output = &fail;
    git.mutate(alloc, io, cwd, copy) catch |err| {
        std.debug.print("rv-bench: git mutate failed ({s}): {s}\n", .{ @errorName(err), fail });
        if (fail.len > 0) alloc.free(fail);
        return err;
    };
}

fn hunkCount(d: *const diff.Diff) usize {
    var n: usize = 0;
    for (d.files) |f| n += f.hunks.len;
    return n;
}

fn timeHunkWidths(rows: []const view.row.Row) void {
    var i: usize = 0;
    while (i < rows.len) : (i += 1) {
        if (rows[i] != .hunk_header) continue;
        const span = view.window.hunkSpanAt(rows, i);
        _ = view.row.hunkMaxLineWidth(rows, span.body_start, span.body_end);
    }
}

fn step(name: []const u8, t0: i96, io: Io, count: *CountAlloc, spawns: usize) Step {
    const dt = nano(io) - t0;
    const ns: u64 = if (dt > 0) @intCast(dt) else 0;
    return .{
        .name = name,
        .ns = ns,
        .bytes = count.bytes,
        .spawns = spawns,
    };
}

fn nano(io: Io) i96 {
    // Awake clock: monotonic, excludes suspend. Wall-clock `real` jumps.
    return Io.Clock.awake.now(io).nanoseconds;
}

fn openDevNull() !std.posix.fd_t {
    const flags: std.posix.O = .{
        .ACCMODE = .WRONLY,
        .CLOEXEC = true,
    };
    return std.posix.openat(std.posix.AT.FDCWD, "/dev/null", flags, 0);
}

fn gitOk(io: Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.GitFailed;
    defer child.kill(io);
    const term = child.wait(io) catch return error.GitFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

fn initRepo(io: Io, cwd: std.process.Child.Cwd) !void {
    try gitOk(io, cwd, &.{ "git", "init", "-b", "main" });
    try gitOk(io, cwd, &.{ "git", "config", "user.email", "rv@bench" });
    try gitOk(io, cwd, &.{ "git", "config", "user.name", "rv bench" });
}

fn makeFixture(alloc: Allocator, io: Io, tmp: IsolatedTmp, kind: Kind) !void {
    const cwd = tmp.cwd();
    try initRepo(io, cwd);
    switch (kind) {
        .small => try makeSmall(io, tmp),
        .untracked => try makeUntracked(alloc, io, tmp),
        .large, .large_file => try makeLarge(alloc, io, tmp),
    }
}

fn makeSmall(io: Io, tmp: IsolatedTmp) !void {
    const cwd = tmp.cwd();
    try tmp.write(io, "readme.txt", "alpha\nbeta\ngamma\n");
    try tmp.write(io, "tracked.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n");
    try gitOk(io, cwd, &.{ "git", "add", "readme.txt", "tracked.txt" });
    try gitOk(io, cwd, &.{ "git", "commit", "-m", "init" });

    try tmp.write(io, "tracked.txt", "one\ntwo edited\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten plus\n");
    try tmp.write(io, "staged.txt", "staged body\n");
    try gitOk(io, cwd, &.{ "git", "add", "staged.txt" });
    try tmp.write(io, "readme.txt", "alpha\nbeta slow\ngamma\n");
    try gitOk(io, cwd, &.{ "git", "add", "readme.txt" });
    try tmp.write(io, "readme.txt", "alpha\nbeta slow\ngamma extra\n");
    try tmp.write(io, "new.zig", "const x = 1;\n");
}

fn makeUntracked(alloc: Allocator, io: Io, tmp: IsolatedTmp) !void {
    const cwd = tmp.cwd();
    try tmp.write(io, "tracked.txt", "keep\n");
    try gitOk(io, cwd, &.{ "git", "add", "tracked.txt" });
    try gitOk(io, cwd, &.{ "git", "commit", "-m", "init" });

    var name_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < untracked_n) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "u{d:0>3}.txt", .{i});
        const body = try std.fmt.allocPrint(alloc, "untracked {d}\n", .{i});
        defer alloc.free(body);
        try tmp.write(io, name, body);
    }
}

fn makeLarge(alloc: Allocator, io: Io, tmp: IsolatedTmp) !void {
    const cwd = tmp.cwd();
    const base = try fillLines(alloc, large_lines, "base");
    defer alloc.free(base);
    try tmp.write(io, "big.txt", base);
    try gitOk(io, cwd, &.{ "git", "add", "big.txt" });
    try gitOk(io, cwd, &.{ "git", "commit", "-m", "init" });

    const edited = try fillLinesEdited(alloc, large_lines);
    defer alloc.free(edited);
    try tmp.write(io, "big.txt", edited);
}

fn fillLines(alloc: Allocator, n: usize, word: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try out.print(alloc, "line {d:0>4} the quick brown fox {s}\n", .{ i, word });
    }
    return out.toOwnedSlice(alloc);
}

fn fillLinesEdited(alloc: Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const word: []const u8 = if (i % large_stride == 0) "edit" else "base";
        try out.print(alloc, "line {d:0>4} the quick brown fox {s}\n", .{ i, word });
    }
    return out.toOwnedSlice(alloc);
}

fn writeTable(out: *std.Io.Writer, runs: []const Run) !void {
    try out.writeAll("fixture     files  hunks   rows  step                    ms     alloc  spawns\n");
    for (runs) |run| {
        for (run.steps) |s| {
            try out.print(
                "{s:<11} {d:5} {d:6} {d:6}  {s:<20} {d:8.2} {s:>9} {d:7}\n",
                .{
                    run.name,
                    run.files,
                    run.hunks,
                    run.rows,
                    s.name,
                    ms(s.ns),
                    fmtBytes(s.bytes),
                    s.spawns,
                },
            );
        }
    }
}

fn writeJson(out: *std.Io.Writer, runs: []const Run) !void {
    try out.writeAll("{\"fixtures\":[");
    for (runs, 0..) |run, ri| {
        if (ri > 0) try out.writeByte(',');
        try out.print(
            "{{\"name\":\"{s}\",\"files\":{d},\"hunks\":{d},\"rows\":{d},\"steps\":[",
            .{ run.name, run.files, run.hunks, run.rows },
        );
        for (run.steps, 0..) |s, si| {
            if (si > 0) try out.writeByte(',');
            try out.print(
                "{{\"name\":\"{s}\",\"ns\":{d},\"bytes\":{d},\"spawns\":{d}}}",
                .{ s.name, s.ns, s.bytes, s.spawns },
            );
        }
        try out.writeAll("]}");
    }
    try out.writeAll("]}\n");
}

fn writeBaselineFile(alloc: Allocator, io: Io, path: []const u8, runs: []const Run) !void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();
    try writeJson(&buf.writer, runs);
    const bytes = try buf.toOwnedSlice();
    defer alloc.free(bytes);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch {
        std.debug.print("rv-bench: failed to write {s}\n", .{path});
        return error.WriteFailed;
    };
}

const JStep = struct {
    name: []const u8,
    ns: u64,
    bytes: usize,
    spawns: usize,
};
const JFix = struct {
    name: []const u8,
    files: usize = 0,
    hunks: usize = 0,
    rows: usize = 0,
    steps: []const JStep,
};
const JRoot = struct {
    fixtures: []const JFix,
};

fn writeCompare(
    alloc: Allocator,
    io: Io,
    out: *std.Io.Writer,
    path: []const u8,
    runs: []const Run,
) !u8 {
    const raw = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 * 1024 * 1024)) catch {
        std.debug.print("rv-bench: cannot read {s}\n", .{path});
        return 2;
    };
    defer alloc.free(raw);
    const parsed = std.json.parseFromSlice(JRoot, alloc, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        std.debug.print("rv-bench: invalid JSON in {s}\n", .{path});
        return 2;
    };
    defer parsed.deinit();

    try out.print("compare vs {s}\n", .{path});
    try out.writeAll("fixture     step                    base_ms    now_ms     d_ms  spawns\n");

    var spawn_mismatch: usize = 0;
    for (runs) |run| {
        const base_fix = findFix(parsed.value.fixtures, run.name);
        for (run.steps) |s| {
            const found = if (base_fix) |fix| findStep(fix.steps, s.name) else null;
            if (found) |hit| {
                const now_i: i64 = @intCast(s.ns);
                const base_i: i64 = @intCast(hit.ns);
                if (s.spawns != hit.spawns) spawn_mismatch += 1;
                try out.print(
                    "{s:<11} {s:<20} {d:8.2} {d:8.2} {s}{d:7.2} {d:3}{s}{d}\n",
                    .{
                        run.name,
                        s.name,
                        ms(hit.ns),
                        ms(s.ns),
                        if (now_i >= base_i) "+" else "-",
                        absMs(now_i - base_i),
                        hit.spawns,
                        if (s.spawns == hit.spawns) " = " else " -> ",
                        s.spawns,
                    },
                );
            } else {
                try out.print(
                    "{s:<11} {s:<20}      n/a {d:8.2}      n/a     -> {d}\n",
                    .{ run.name, s.name, ms(s.ns), s.spawns },
                );
            }
        }
    }

    for (parsed.value.fixtures) |fix| {
        const now = findRun(runs, fix.name);
        for (fix.steps) |s| {
            if (now) |run| {
                if (findNowStep(run.steps, s.name) != null) continue;
            }
            try out.print(
                "{s:<11} {s:<20} {d:8.2}      n/a      n/a {d:3} -> -\n",
                .{ fix.name, s.name, ms(s.ns), s.spawns },
            );
        }
    }

    try out.print("spawn mismatches: {d}\n", .{spawn_mismatch});
    return if (spawn_mismatch == 0) 0 else 1;
}

fn findFix(fixes: []const JFix, name: []const u8) ?JFix {
    for (fixes) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn findRun(runs: []const Run, name: []const u8) ?Run {
    for (runs) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

fn findStep(steps: []const JStep, name: []const u8) ?JStep {
    for (steps) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn findNowStep(steps: []const Step, name: []const u8) ?Step {
    for (steps) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn absMs(ns: i64) f64 {
    const mag: i64 = if (ns >= 0) ns else -ns;
    const as_f: f64 = @floatFromInt(mag);
    return as_f / 1_000_000.0;
}

fn ms(ns: u64) f64 {
    const as_f: f64 = @floatFromInt(ns);
    return as_f / 1_000_000.0;
}

var bytes_buf: [4][32]u8 = undefined;
var bytes_i: usize = 0;

fn fmtBytes(n: usize) []const u8 {
    const slot = &bytes_buf[bytes_i % bytes_buf.len];
    bytes_i += 1;
    if (n >= 1024) {
        return std.fmt.bufPrint(slot, "{d} KiB", .{n / 1024}) catch "?";
    }
    return std.fmt.bufPrint(slot, "{d} B", .{n}) catch "?";
}
