//! Headless CLI for the comment store and local approved hunks/files.
//!
//! Subcommands: `status`, `approved`, `unapprove`, `list`, `show`, `resolve`,
//! `export`, `install-skill`, help. Comment-only commands do not load git.
//! `status`, `approved`, and `unapprove` load the local diff (staged /
//! unstaged / untracked). No raw TTY modes. Bare `rv`, `rv <commit>`, and
//! `rv <range>` launch the review TUI from `main` (`classify`). `resolve` deletes ids.
//! There is no reopen and no list/export filter.

const std = @import("std");
const store = @import("store");
const install_skill = @import("install_skill");
const git = @import("git");
const approve = @import("approve");
const diff = @import("diff");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Process env needed by install-skill (and future commands).
pub const Env = struct {
    home: ?[]const u8 = null,
    skill_dir: ?[]const u8 = null,
};

pub const exit_success: u8 = 0;
pub const exit_operational: u8 = 1;
pub const exit_usage: u8 = 2;

pub const ExportFormat = enum { md, json };

pub const ExportOpts = struct {
    format: ExportFormat = .md,
    out_path: ?[]const u8 = null,
};

pub const Command = union(enum) {
    help,
    status,
    approved,
    unapprove: []const u8,
    list,
    show: []const u8,
    resolve: []const []const u8,
    @"export": ExportOpts,
    install_skill: install_skill.Opts,
};

/// Where the TUI diff came from. Same type as `store.Source` (comments record it).
pub const Source = store.Source;

/// Status-strip text for `source`. `empty` is a clean worktree (no local
/// changes), not an approved-only hide. Local is `HEAD`; an explicit range
/// or commit stays the user-supplied string even if empty.
pub fn sourceLabel(source: Source, empty: bool) []const u8 {
    return switch (source) {
        .local => if (empty) "HEAD · empty" else "HEAD",
        .range, .commit => |s| s,
    };
}

/// How to start the process: TUI (with a recorded source) or a headless command.
pub const Launch = union(enum) {
    tui: Source,
    command: Command,
};

/// Classify argv after the program name.
pub fn classify(args: []const []const u8) error{Usage}!Launch {
    if (args.len == 0) return .{ .tui = .local };
    if (isCommand(args[0])) return .{ .command = try parse(args) };
    if (args.len == 1 and args[0].len > 0 and args[0][0] != '-') {
        const spec = args[0];
        if (std.mem.indexOf(u8, spec, "..") != null) {
            return .{ .tui = .{ .range = spec } };
        }
        return .{ .tui = .{ .commit = spec } };
    }
    return error.Usage;
}

fn isCommand(s: []const u8) bool {
    return isHelp(s) or
        std.mem.eql(u8, s, "status") or
        std.mem.eql(u8, s, "approved") or
        std.mem.eql(u8, s, "unapprove") or
        std.mem.eql(u8, s, "list") or
        std.mem.eql(u8, s, "show") or
        std.mem.eql(u8, s, "resolve") or
        std.mem.eql(u8, s, "export") or
        std.mem.eql(u8, s, "install-skill");
}

/// Parse a headless subcommand. argv after the program name, first token a command.
pub fn parse(args: []const []const u8) error{Usage}!Command {
    if (args.len == 0) return error.Usage;
    const cmd = args[0];
    if (isHelp(cmd)) {
        if (args.len != 1) return error.Usage;
        return .help;
    }
    if (std.mem.eql(u8, cmd, "status")) {
        if (args.len != 1) return error.Usage;
        return .status;
    }
    if (std.mem.eql(u8, cmd, "approved")) {
        if (args.len != 1) return error.Usage;
        return .approved;
    }
    if (std.mem.eql(u8, cmd, "unapprove")) {
        if (args.len != 2) return error.Usage;
        return .{ .unapprove = args[1] };
    }
    if (std.mem.eql(u8, cmd, "list")) {
        if (args.len != 1) return error.Usage;
        return .list;
    }
    if (std.mem.eql(u8, cmd, "show")) {
        if (args.len != 2) return error.Usage;
        return .{ .show = args[1] };
    }
    if (std.mem.eql(u8, cmd, "resolve")) {
        if (args.len < 2) return error.Usage;
        return .{ .resolve = args[1..] };
    }
    if (std.mem.eql(u8, cmd, "export")) {
        return .{ .@"export" = try parseExport(args[1..]) };
    }
    if (std.mem.eql(u8, cmd, "install-skill")) {
        return .{ .install_skill = try parseInstallSkill(args[1..]) };
    }
    return error.Usage;
}

fn isHelp(s: []const u8) bool {
    return std.mem.eql(u8, s, "help") or
        std.mem.eql(u8, s, "--help") or
        std.mem.eql(u8, s, "-h");
}

/// Flags may appear in any order. Default: md, stdout.
fn parseExport(args: []const []const u8) error{Usage}!ExportOpts {
    var opts: ExportOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            if (std.mem.eql(u8, args[i], "md")) {
                opts.format = .md;
            } else if (std.mem.eql(u8, args[i], "json")) {
                opts.format = .json;
            } else return error.Usage;
        } else if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.Usage;
            if (opts.out_path != null) return error.Usage;
            opts.out_path = args[i];
        } else return error.Usage;
    }
    return opts;
}

fn parseInstallSkill(args: []const []const u8) error{Usage}!install_skill.Opts {
    var opts: install_skill.Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list")) {
            if (opts.list) return error.Usage;
            opts.list = true;
        } else if (std.mem.eql(u8, a, "--uninstall")) {
            if (opts.uninstall) return error.Usage;
            opts.uninstall = true;
        } else if (std.mem.eql(u8, a, "--agent")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.Usage;
            if (opts.agent != null) return error.Usage;
            opts.agent = args[i];
        } else return error.Usage;
    }
    if (opts.list and opts.uninstall) return error.Usage;
    return opts;
}

pub const usage_text =
    \\usage: rv [<commit> | <range> | <command>] [args]
    \\
    \\With no args, opens the review TUI on local changes (staged, unstaged,
    \\and untracked). A clean worktree opens empty. A git commit-ish (for
    \\example HEAD or a hash) opens the patch that commit introduced. A range
    \\that contains .. or ... (for example main...HEAD) opens `git diff <range>`
    \\as written.
    \\
    \\Commands:
    \\  status                         live comment count, approved count, and store paths
    \\  approved                       list approved hunks and files
    \\  unapprove <n>                  drop the nth row from that list
    \\  list                           list comments
    \\  show <id>                      print one comment
    \\  resolve <id> [id…]             delete comments
    \\  export [options]               dump comments (default: markdown, stdout)
    \\    --format md|json             output format (default: md)
    \\    -o <path>                    write file instead of stdout
    \\  install-skill [options]        install bundled agent skill
    \\    --list                       show source, canonical, and agent links
    \\    --uninstall                  remove skill symlinks
    \\    --agent <name>               only grok|claude|codex|cursor
    \\  help, -h, --help               show this help
    \\
    \\Exit codes: 0 success, 1 error, 2 usage
    \\
;

/// Run a parsed headless command against `root` (the repo directory).
pub fn run(alloc: Allocator, io: Io, cmd: Command, env: Env, root: Io.Dir) u8 {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    var err_w = std.Io.File.stderr().writer(io, &err_buf);
    defer {
        out_w.interface.flush() catch {};
        err_w.interface.flush() catch {};
    }
    switch (cmd) {
        .help => return cmdHelp(io),
        .status => return cmdStatus(alloc, io, root, &out_w.interface, &err_w.interface),
        .approved => return cmdApproved(alloc, io, root, &out_w.interface, &err_w.interface),
        .unapprove => |tok| return cmdUnapprove(alloc, io, root, tok, &out_w.interface, &err_w.interface),
        .list => return cmdList(alloc, io, root),
        .show => |id| return cmdShow(alloc, io, root, id),
        .resolve => |ids| return cmdResolve(alloc, io, root, ids),
        .@"export" => |opts| return cmdExport(alloc, io, root, opts),
        .install_skill => |opts| return install_skill.run(alloc, io, opts, env.home, env.skill_dir, .{
            .out = &out_w.interface,
            .err = &err_w.interface,
        }),
    }
}

fn cmdHelp(io: Io) u8 {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    out.writeAll(usage_text) catch return writeFail();
    out.flush() catch return writeFail();
    return exit_success;
}

/// Local diff plus live approved hunks/files (`collectApproved`). No prune/save.
const LiveApproved = struct {
    d: diff.Diff,
    approved: approve.Approved,
    items: []approve.Hidden,

    fn deinit(self: *LiveApproved, alloc: Allocator) void {
        alloc.free(self.items);
        self.approved.deinit();
        self.d.deinit();
        self.* = undefined;
    }
};

const LiveLoadError = git.Error || approve.LoadError;

fn loadLiveApproved(alloc: Allocator, io: Io, root: Io.Dir) LiveLoadError!LiveApproved {
    var d = try git.loadDefaultDiffCwd(alloc, io, .{ .dir = root });
    errdefer d.deinit();
    var approved = try approve.load(alloc, io, root);
    errdefer approved.deinit();
    const items = try approve.collectApproved(alloc, io, root, &d, &approved);
    return .{ .d = d, .approved = approved, .items = items };
}

fn cmdFail(err_w: *std.Io.Writer, msg: []const u8) u8 {
    err_w.print("rv: {s}\n", .{msg}) catch return writeFail();
    err_w.flush() catch return writeFail();
    return exit_operational;
}

fn liveLoadFail(err_w: *std.Io.Writer, err: LiveLoadError) u8 {
    const msg: []const u8 = switch (err) {
        error.NotARepository => git.errorMessage(error.NotARepository),
        error.GitNotFound => git.errorMessage(error.GitNotFound),
        error.GitFailed => git.errorMessage(error.GitFailed),
        error.BadHunkHeader => git.errorMessage(error.BadHunkHeader),
        error.InvalidJson, error.InvalidHash => "invalid .rv approved JSON",
        error.OutOfMemory => "out of memory",
        else => "failed to load .rv approved store",
    };
    return cmdFail(err_w, msg);
}

fn cmdStatus(alloc: Allocator, io: Io, root: Io.Dir, out: *std.Io.Writer, err_w: *std.Io.Writer) u8 {
    var review = loadReview(alloc, io, root) catch |err| return loadFail(err);
    defer review.deinit();

    // Live matches only; missing approved file is count 0. Do not prune or save.
    var live = loadLiveApproved(alloc, io, root) catch |err| return liveLoadFail(err_w, err);
    defer live.deinit(alloc);

    const rel = store.reviewRelPath(alloc, review.id) catch {
        std.debug.print("rv: out of memory\n", .{});
        return exit_operational;
    };
    defer alloc.free(rel);

    out.print(
        \\review: {s}
        \\store: {s}
        \\comments: {d}
        \\approved: {d}
        \\approved store: {s}
        \\
    , .{ review.id, rel, review.comments.items.len, live.items.len, approve.rel_path }) catch {
        return writeFail();
    };
    out.flush() catch return writeFail();
    return exit_success;
}

/// `n` is 1-based. Path, group, and preview match the TUI approved overlay
/// (newlines in preview become spaces).
fn writeApprovedLine(out: *std.Io.Writer, n: usize, item: approve.Hidden) !void {
    try out.print("{d}  {s}  {s}  ", .{ n, item.path, item.groupLabel() });
    try writeBodyOneLine(out, item.previewText());
    try out.writeAll("\n");
}

fn cmdApproved(alloc: Allocator, io: Io, root: Io.Dir, out: *std.Io.Writer, err_w: *std.Io.Writer) u8 {
    var live = loadLiveApproved(alloc, io, root) catch |err| return liveLoadFail(err_w, err);
    defer live.deinit(alloc);
    for (live.items, 0..) |item, i| {
        writeApprovedLine(out, i + 1, item) catch return writeFail();
    }
    out.flush() catch return writeFail();
    return exit_success;
}

fn cmdUnapprove(
    alloc: Allocator,
    io: Io,
    root: Io.Dir,
    token: []const u8,
    out: *std.Io.Writer,
    err_w: *std.Io.Writer,
) u8 {
    const n = std.fmt.parseInt(usize, token, 10) catch {
        err_w.print("rv: not a number: {s}\n", .{token}) catch return writeFail();
        err_w.flush() catch return writeFail();
        return exit_operational;
    };
    if (n == 0) return cmdFail(err_w, "index out of range");

    var live = loadLiveApproved(alloc, io, root) catch |err| return liveLoadFail(err_w, err);
    defer live.deinit(alloc);
    if (n > live.items.len) return cmdFail(err_w, "index out of range");

    const item = live.items[n - 1];
    live.approved.unapprove(item.path, item.hash) catch return cmdFail(err_w, "index out of range");

    // Same prune+save as TUI Enter on the approved list.
    const identities = approve.collectLive(alloc, io, root, &live.d) catch {
        return cmdFail(err_w, "out of memory");
    };
    defer alloc.free(identities);
    live.approved.prune(alloc, identities) catch return cmdFail(err_w, "out of memory");
    approve.save(&live.approved, alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return cmdFail(err_w, "out of memory"),
        else => return cmdFail(err_w, "failed to save .rv approved store"),
    };

    out.print("{d} unapproved\n", .{n}) catch return writeFail();
    out.flush() catch return writeFail();
    return exit_success;
}

fn cmdList(alloc: Allocator, io: Io, root: Io.Dir) u8 {
    var review = loadReview(alloc, io, root) catch |err| return loadFail(err);
    defer review.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var anchor_buf: [256]u8 = undefined;
    for (review.comments.items) |c| {
        const anchor = formatAnchor(&anchor_buf, c);
        // One line: id source anchor body (newlines in body → spaces).
        out.print("{s}  {s}  {s}  ", .{ c.id, if (c.source) |s| s.label() else "-", anchor }) catch {
            std.debug.print("rv: write failed\n", .{});
            return exit_operational;
        };
        writeBodyOneLine(out, c.body) catch {
            std.debug.print("rv: write failed\n", .{});
            return exit_operational;
        };
        out.writeAll("\n") catch {
            std.debug.print("rv: write failed\n", .{});
            return exit_operational;
        };
    }
    out.flush() catch {
        std.debug.print("rv: write failed\n", .{});
        return exit_operational;
    };
    return exit_success;
}

fn cmdShow(alloc: Allocator, io: Io, root: Io.Dir, id: []const u8) u8 {
    var review = loadReview(alloc, io, root) catch |err| return loadFail(err);
    defer review.deinit();

    const c = review.find(id) orelse {
        std.debug.print("rv: comment not found: {s}\n", .{id});
        return exit_operational;
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    out.print("id: {s}\n", .{c.id}) catch return writeFail();
    out.print("source: {s}\n", .{if (c.source) |s| s.label() else "-"}) catch return writeFail();
    out.print("path: {s}\n", .{c.path}) catch return writeFail();
    if (c.old_line) |n| {
        out.print("old_line: {d}\n", .{n}) catch return writeFail();
    } else {
        out.writeAll("old_line:\n") catch return writeFail();
    }
    if (c.new_line) |n| {
        out.print("new_line: {d}\n", .{n}) catch return writeFail();
    } else {
        out.writeAll("new_line:\n") catch return writeFail();
    }
    if (c.side) |s| {
        out.print("side: {s}\n", .{@tagName(s)}) catch return writeFail();
    } else {
        out.writeAll("side:\n") catch return writeFail();
    }
    out.writeAll("body:\n") catch return writeFail();
    out.writeAll(c.body) catch return writeFail();
    if (c.body.len == 0 or c.body[c.body.len - 1] != '\n') {
        out.writeAll("\n") catch return writeFail();
    }
    out.flush() catch return writeFail();
    return exit_success;
}

/// Load → remove (all-or-nothing) → save → one confirmation line per id.
fn cmdResolve(alloc: Allocator, io: Io, root: Io.Dir, ids: []const []const u8) u8 {
    var review = loadReview(alloc, io, root) catch |err| return loadFail(err);
    defer review.deinit();

    review.remove(ids) catch {
        for (ids) |id| {
            if (review.find(id) == null) {
                std.debug.print("rv: comment not found: {s}\n", .{id});
            }
        }
        return exit_operational;
    };

    store.save(&review, alloc, io, root) catch {
        std.debug.print("rv: failed to save .rv comment store\n", .{});
        return exit_operational;
    };

    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    for (ids) |id| {
        out.print("{s} deleted\n", .{id}) catch return writeFail();
    }
    out.flush() catch return writeFail();
    return exit_success;
}

fn cmdExport(alloc: Allocator, io: Io, root: Io.Dir, opts: ExportOpts) u8 {
    var review = loadReview(alloc, io, root) catch |err| return loadFail(err);
    defer review.deinit();

    const bytes = switch (opts.format) {
        .md => formatMarkdown(alloc, &review),
        .json => formatJson(alloc, &review),
    } catch {
        std.debug.print("rv: out of memory\n", .{});
        return exit_operational;
    };
    defer alloc.free(bytes);

    if (opts.out_path) |path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch {
            std.debug.print("rv: failed to write {s}\n", .{path});
            return exit_operational;
        };
        return exit_success;
    }

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    out.writeAll(bytes) catch return writeFail();
    out.flush() catch return writeFail();
    return exit_success;
}

/// Paste-ready markdown: header + one section per comment.
fn formatMarkdown(alloc: Allocator, review: *const store.Review) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    w.print("# rv export — review `{s}`\n\n", .{review.id}) catch return error.OutOfMemory;

    var any = false;
    var anchor_buf: [256]u8 = undefined;
    for (review.comments.items) |c| {
        any = true;
        const anchor = formatAnchor(&anchor_buf, c);
        w.print("## [{s}] — {s}", .{ c.id, anchor }) catch return error.OutOfMemory;
        if (c.side) |s| w.print(" ({s})", .{@tagName(s)}) catch return error.OutOfMemory;
        w.print(" · {s}", .{if (c.source) |s| s.label() else "-"}) catch return error.OutOfMemory;
        w.writeAll("\n\n") catch return error.OutOfMemory;
        w.writeAll(c.body) catch return error.OutOfMemory;
        if (c.body.len == 0 or c.body[c.body.len - 1] != '\n') w.writeAll("\n") catch return error.OutOfMemory;
        w.writeAll("\n") catch return error.OutOfMemory;
    }
    if (!any) w.writeAll("_No comments._\n") catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

const ExportComment = struct {
    id: []const u8,
    path: []const u8,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    side: ?[]const u8 = null,
    body: []const u8,
    source: ?store.Source = null,
};

const ExportEnvelope = struct {
    version: u32,
    review_id: []const u8,
    comments: []const ExportComment,
};

/// Export envelope (not a raw store dump): version, review_id, comments[].
fn formatJson(alloc: Allocator, review: *const store.Review) Allocator.Error![]u8 {
    var wire: std.ArrayList(ExportComment) = .empty;
    defer wire.deinit(alloc);
    for (review.comments.items) |c| {
        try wire.append(alloc, .{
            .id = c.id,
            .path = c.path,
            .old_line = c.old_line,
            .new_line = c.new_line,
            .side = if (c.side) |s| @tagName(s) else null,
            .body = c.body,
            .source = c.source,
        });
    }
    const envelope: ExportEnvelope = .{
        .version = store.schema_version,
        .review_id = review.id,
        .comments = wire.items,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(envelope, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn loadReview(alloc: Allocator, io: Io, root: Io.Dir) store.LoadError!store.Review {
    return store.load(alloc, io, root, store.default_review_id);
}

fn loadFail(err: store.LoadError) u8 {
    const msg: []const u8 = switch (err) {
        error.InvalidJson => "invalid .rv review JSON",
        error.InvalidState => "invalid comment state in .rv store",
        error.InvalidSide => "invalid comment side in .rv store",
        error.OutOfMemory => "out of memory",
        else => "failed to load .rv comment store",
    };
    std.debug.print("rv: {s}\n", .{msg});
    return exit_operational;
}

fn writeFail() u8 {
    std.debug.print("rv: write failed\n", .{});
    return exit_operational;
}

fn writeBodyOneLine(out: anytype, body: []const u8) !void {
    for (body) |b| {
        try out.writeByte(if (b == '\n' or b == '\r') ' ' else b);
    }
}

/// Compact anchor for list lines: `path`, `path:+N`, `path:-M`, or `path:-M,+N`.
fn formatAnchor(buf: []u8, c: store.Comment) []const u8 {
    if (c.old_line == null and c.new_line == null) {
        return truncCopy(buf, c.path);
    }
    if (c.old_line) |o| {
        if (c.new_line) |n| {
            return bufPrintTrunc(buf, "{s}:-{d},+{d}", .{ c.path, o, n });
        }
        return bufPrintTrunc(buf, "{s}:-{d}", .{ c.path, o });
    }
    return bufPrintTrunc(buf, "{s}:+{d}", .{ c.path, c.new_line.? });
}

fn truncCopy(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

fn bufPrintTrunc(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch {
        const msg = "...";
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        return buf[0..n];
    };
}

const testing = std.testing;
const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

test "parse help status approved unapprove list show resolve export install-skill" {
    try testing.expectEqual(Command.help, try parse(&.{"help"}));
    try testing.expectEqual(Command.help, try parse(&.{"--help"}));
    try testing.expectEqual(Command.help, try parse(&.{"-h"}));
    try testing.expectEqual(Command.status, try parse(&.{"status"}));
    try testing.expectEqual(Command.approved, try parse(&.{"approved"}));
    try testing.expectEqualStrings("3", (try parse(&.{ "unapprove", "3" })).unapprove);
    try testing.expectEqual(Command.list, try parse(&.{"list"}));

    const show = try parse(&.{ "show", "3" });
    try testing.expectEqualStrings("3", show.show);

    const resolve_one = try parse(&.{ "resolve", "1" });
    try testing.expectEqual(1, resolve_one.resolve.len);
    try testing.expectEqualStrings("1", resolve_one.resolve[0]);

    const resolve_multi = try parse(&.{ "resolve", "1", "2", "3" });
    try testing.expectEqual(3, resolve_multi.resolve.len);
    try testing.expectEqualStrings("2", resolve_multi.resolve[1]);

    const exp_default = (try parse(&.{"export"})).@"export";
    try testing.expectEqual(ExportFormat.md, exp_default.format);
    try testing.expect(exp_default.out_path == null);

    const exp_json = (try parse(&.{ "export", "--format", "json", "-o", "out.json" })).@"export";
    try testing.expectEqual(ExportFormat.json, exp_json.format);
    try testing.expectEqualStrings("out.json", exp_json.out_path.?);

    const exp_order = (try parse(&.{ "export", "-o", "/tmp/r.md", "--format", "md" })).@"export";
    try testing.expectEqual(ExportFormat.md, exp_order.format);
    try testing.expectEqualStrings("/tmp/r.md", exp_order.out_path.?);

    const inst = (try parse(&.{"install-skill"})).install_skill;
    try testing.expect(!inst.list and !inst.uninstall and inst.agent == null);
    const inst_list = (try parse(&.{ "install-skill", "--list" })).install_skill;
    try testing.expect(inst_list.list);
    const inst_agent = (try parse(&.{ "install-skill", "--agent", "grok", "--uninstall" })).install_skill;
    try testing.expect(inst_agent.uninstall);
    try testing.expectEqualStrings("grok", inst_agent.agent.?);
}

test "parse usage errors" {
    try testing.expectError(error.Usage, parse(&.{}));
    try testing.expectError(error.Usage, parse(&.{"nope"}));
    try testing.expectError(error.Usage, parse(&.{ "status", "x" }));
    try testing.expectError(error.Usage, parse(&.{ "approved", "x" }));
    try testing.expectError(error.Usage, parse(&.{"unapprove"}));
    try testing.expectError(error.Usage, parse(&.{ "unapprove", "1", "2" }));
    try testing.expectError(error.Usage, parse(&.{"show"}));
    try testing.expectError(error.Usage, parse(&.{ "show", "1", "2" }));
    try testing.expectError(error.Usage, parse(&.{ "list", "--open" }));
    try testing.expectError(error.Usage, parse(&.{ "list", "--all" }));
    try testing.expectError(error.Usage, parse(&.{ "list", "--resolved" }));
    try testing.expectError(error.Usage, parse(&.{ "list", "--bogus" }));
    try testing.expectError(error.Usage, parse(&.{ "help", "extra" }));
    try testing.expectError(error.Usage, parse(&.{"resolve"}));
    try testing.expectError(error.Usage, parse(&.{"reopen"}));
    try testing.expectError(error.Usage, parse(&.{ "reopen", "7" }));
    try testing.expectError(error.Usage, parse(&.{ "export", "--open" }));
    try testing.expectError(error.Usage, parse(&.{ "export", "--all" }));
    try testing.expectError(error.Usage, parse(&.{ "export", "--resolved" }));
    try testing.expectError(error.Usage, parse(&.{ "export", "--format" }));
    try testing.expectError(error.Usage, parse(&.{ "export", "--format", "xml" }));
    try testing.expectError(error.Usage, parse(&.{ "export", "-o" }));
    try testing.expectError(error.Usage, parse(&.{ "export", "-o", "a", "-o", "b" }));
    try testing.expectError(error.Usage, parse(&.{ "export", "--bogus" }));
    try testing.expectError(error.Usage, parse(&.{ "install-skill", "--list", "--uninstall" }));
    try testing.expectError(error.Usage, parse(&.{ "install-skill", "--agent" }));
    try testing.expectError(error.Usage, parse(&.{ "install-skill", "--bogus" }));
}

test "classify tui vs command" {
    switch (try classify(&.{})) {
        .tui => |src| try testing.expectEqual(Source.local, src),
        .command => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{"main...HEAD"})) {
        .tui => |src| try testing.expectEqualStrings("main...HEAD", src.range),
        .command => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{"HEAD"})) {
        .tui => |src| try testing.expectEqualStrings("HEAD", src.commit),
        .command => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{"HEAD~1"})) {
        .tui => |src| try testing.expectEqualStrings("HEAD~1", src.commit),
        .command => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{"main..HEAD"})) {
        .tui => |src| try testing.expectEqualStrings("main..HEAD", src.range),
        .command => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{"@{upstream}...HEAD"})) {
        .tui => |src| try testing.expectEqualStrings("@{upstream}...HEAD", src.range),
        .command => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{"status"})) {
        .command => |cmd| try testing.expectEqual(Command.status, cmd),
        .tui => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{"approved"})) {
        .command => |cmd| try testing.expectEqual(Command.approved, cmd),
        .tui => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{ "unapprove", "1" })) {
        .command => |cmd| try testing.expectEqualStrings("1", cmd.unapprove),
        .tui => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{ "export", "--format", "json" })) {
        .command => |cmd| try testing.expectEqual(ExportFormat.json, cmd.@"export".format),
        .tui => return error.TestUnexpectedResult,
    }
    switch (try classify(&.{"--help"})) {
        .command => |cmd| try testing.expectEqual(Command.help, cmd),
        .tui => return error.TestUnexpectedResult,
    }
    try testing.expectError(error.Usage, classify(&.{"--bogus"}));
    try testing.expectError(error.Usage, classify(&.{ "main...HEAD", "extra" }));
    try testing.expectError(error.Usage, classify(&.{""}));
}

test "usage_text names approved commands and status approved lines" {
    try testing.expect(std.mem.indexOf(u8, usage_text, "approved") != null);
    try testing.expect(std.mem.indexOf(u8, usage_text, "unapprove <n>") != null);
    try testing.expect(std.mem.indexOf(u8, usage_text, "approved count") != null);
    try testing.expect(std.mem.indexOf(u8, usage_text, "store paths") != null);
}

test "sourceLabel local range commit" {
    try testing.expectEqualStrings("HEAD", sourceLabel(.local, false));
    try testing.expectEqualStrings("HEAD · empty", sourceLabel(.local, true));
    try testing.expectEqualStrings("main...HEAD", sourceLabel(.{ .range = "main...HEAD" }, false));
    try testing.expectEqualStrings("main...HEAD", sourceLabel(.{ .range = "main...HEAD" }, true));
    try testing.expectEqualStrings("abc123", sourceLabel(.{ .commit = "abc123" }, false));
    try testing.expectEqualStrings("abc123", sourceLabel(.{ .commit = "abc123" }, true));
}

test "formatMarkdown and formatJson envelope" {
    var review = try store.initEmpty(testing.allocator, "current");
    defer review.deinit();
    _ = try review.addOpen("a.zig", null, 10, .new, "fix me", .local);
    _ = try review.addOpen("b.zig", 2, null, .old, "also", .local);
    _ = try review.addOpen("c.zig", null, 3, .new, "on commit", .{ .commit = "abc123" });

    const md = try formatMarkdown(testing.allocator, &review);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "# rv export — review `current`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## [1] — a.zig:+10 (new) · local") != null);
    try testing.expect(std.mem.indexOf(u8, md, "fix me") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## [2] — b.zig:-2 (old) · local") != null);
    try testing.expect(std.mem.indexOf(u8, md, "also") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## [3] — c.zig:+3 (new) · abc123") != null);

    const js = try formatJson(testing.allocator, &review);
    defer testing.allocator.free(js);
    var parsed = try std.json.parseFromSlice(ExportEnvelope, testing.allocator, js, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testing.expectEqual(1, parsed.value.version);
    try testing.expectEqualStrings("current", parsed.value.review_id);
    try testing.expectEqual(3, parsed.value.comments.len);
    try testing.expectEqualStrings("1", parsed.value.comments[0].id);
    try testing.expectEqualStrings("a.zig", parsed.value.comments[0].path);
    try testing.expectEqual(10, parsed.value.comments[0].new_line.?);
    try testing.expectEqualStrings("new", parsed.value.comments[0].side.?);
    try testing.expectEqualStrings("fix me", parsed.value.comments[0].body);
    try testing.expectEqual(store.Source.local, parsed.value.comments[0].source.?);
    try testing.expectEqualStrings("abc123", parsed.value.comments[2].source.?.commit);
}

test "formatAnchor" {
    var buf: [64]u8 = undefined;
    const path_only = formatAnchor(&buf, .{
        .id = "1",
        .path = "a.zig",
        .body = "",
    });
    try testing.expectEqualStrings("a.zig", path_only);

    const new_only = formatAnchor(&buf, .{
        .id = "1",
        .path = "a.zig",
        .new_line = 10,
        .body = "",
    });
    try testing.expectEqualStrings("a.zig:+10", new_only);

    const old_only = formatAnchor(&buf, .{
        .id = "1",
        .path = "a.zig",
        .old_line = 3,
        .body = "",
    });
    try testing.expectEqualStrings("a.zig:-3", old_only);

    const both = formatAnchor(&buf, .{
        .id = "1",
        .path = "a.zig",
        .old_line = 3,
        .new_line = 4,
        .body = "",
    });
    try testing.expectEqualStrings("a.zig:-3,+4", both);
}

fn expectGitOk(io: Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.TestUnexpectedResult;
    defer child.kill(io);
    const term = child.wait(io) catch return error.TestUnexpectedResult;
    switch (term) {
        .exited => |code| if (code != 0) return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    }
}

fn initTestRepo(io: Io, cwd: std.process.Child.Cwd) !void {
    try expectGitOk(io, cwd, &.{ "git", "init", "-b", "main" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.email", "rv@test" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.name", "rv test" });
}

fn captureCmd(
    alloc: Allocator,
    io: Io,
    root: Io.Dir,
    cmd: fn (Allocator, Io, Io.Dir, *std.Io.Writer, *std.Io.Writer) u8,
) !struct { rc: u8, text: []u8, err: []u8 } {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(alloc);
    errdefer err_out.deinit();
    const rc = cmd(alloc, io, root, &out.writer, &err_out.writer);
    const text = try out.toOwnedSlice();
    errdefer alloc.free(text);
    return .{ .rc = rc, .text = text, .err = try err_out.toOwnedSlice() };
}

fn makeDirtyRepo(io: Io, tmp: IsolatedTmp) !void {
    const cwd = tmp.cwd();
    try initTestRepo(io, cwd);
    try tmp.write(io, "a.txt", "one\n");
    try expectGitOk(io, cwd, &.{ "git", "add", "a.txt" });
    try expectGitOk(io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "a.txt", "one\ntwo\n");
}

fn saveFirstHunks(alloc: Allocator, io: Io, tmp: IsolatedTmp) !void {
    var d = try git.loadDefaultDiffCwd(alloc, io, tmp.cwd());
    defer d.deinit();
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    for (d.files) |f| {
        if (f.hunks.len == 0) continue;
        try approved.append(f.displayPath(), approve.fingerprintHunk(f.hunks[0]));
    }
    try approve.save(&approved, alloc, io, tmp.dir);
}

fn captureUnapprove(
    alloc: Allocator,
    io: Io,
    root: Io.Dir,
    token: []const u8,
) !struct { rc: u8, text: []u8, err: []u8 } {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(alloc);
    errdefer err_out.deinit();
    const rc = cmdUnapprove(alloc, io, root, token, &out.writer, &err_out.writer);
    const text = try out.toOwnedSlice();
    errdefer alloc.free(text);
    return .{ .rc = rc, .text = text, .err = try err_out.toOwnedSlice() };
}

test "status missing approved file is zero" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try makeDirtyRepo(io, tmp);

    const got = try captureCmd(alloc, io, tmp.dir, cmdStatus);
    defer alloc.free(got.text);
    defer alloc.free(got.err);
    try testing.expectEqual(exit_success, got.rc);
    try testing.expectEqualStrings("", got.err);
    try testing.expect(std.mem.indexOf(u8, got.text, "comments: 0") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "approved: 0") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "approved store: .rv/approved.json") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "store: .rv/reviews/current.json") != null);
}

test "status live approved count matches collectApproved not raw store" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try makeDirtyRepo(io, tmp);

    var d = try git.loadDefaultDiffCwd(alloc, io, tmp.cwd());
    defer d.deinit();
    const path = d.files[0].displayPath();
    const hash = approve.fingerprintHunk(d.files[0].hunks[0]);
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, hash);
    try approved.append("gone.txt", approve.fingerprintFile("stale"));
    try approve.save(&approved, alloc, io, tmp.dir);

    const got = try captureCmd(alloc, io, tmp.dir, cmdStatus);
    defer alloc.free(got.text);
    defer alloc.free(got.err);
    try testing.expectEqual(exit_success, got.rc);
    try testing.expectEqualStrings("", got.err);
    try testing.expect(std.mem.indexOf(u8, got.text, "approved: 1") != null);
}

test "status not a git repository is operational failure" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    const got = try captureCmd(alloc, io, tmp.dir, cmdStatus);
    defer alloc.free(got.text);
    defer alloc.free(got.err);
    try testing.expectEqual(exit_operational, got.rc);
    try testing.expectEqualStrings("rv: not a git repository (run from a work tree)\n", got.err);
}

fn hiddenLine(path: []const u8, group: ?diff.Group, kind: approve.Hidden.Kind, preview: []const u8) approve.Hidden {
    return .{
        .path = path,
        .hash = @splat(0),
        .group = group,
        .kind = kind,
        .preview = preview,
    };
}

test "writeApprovedLine path group preview and placeholders" {
    const alloc = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try writeApprovedLine(w, 1, hiddenLine("a.zig", .unstaged, .hunk, "hello"));
    try writeApprovedLine(w, 2, hiddenLine("bin.dat", .staged, .binary, ""));
    try writeApprovedLine(w, 3, hiddenLine("keep.bin", .untracked, .file, ""));
    try writeApprovedLine(w, 4, hiddenLine("c.zig", .unstaged, .hunk, ""));
    try writeApprovedLine(w, 5, hiddenLine("d.zig", .unstaged, .hunk, "hello\nworld"));
    try writeApprovedLine(w, 6, hiddenLine("e.zig", null, .hunk, "x"));
    try w.flush();
    try testing.expectEqualStrings(
        \\1  a.zig  Unstaged  hello
        \\2  bin.dat  Staged  binary
        \\3  keep.bin  Untracked  file
        \\4  c.zig  Unstaged  hunk
        \\5  d.zig  Unstaged  hello world
        \\6  e.zig  -  x
        \\
    , w.buffered());
}

test "approved empty store prints nothing" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try makeDirtyRepo(io, tmp);

    const got = try captureCmd(alloc, io, tmp.dir, cmdApproved);
    defer alloc.free(got.text);
    defer alloc.free(got.err);
    try testing.expectEqual(exit_success, got.rc);
    try testing.expectEqualStrings("", got.err);
    try testing.expectEqualStrings("", got.text);
}

test "approved lists live hunks and files in flatten order" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try makeDirtyRepo(io, tmp);
    try tmp.write(io, "extra.txt", "hi\n");

    var d = try git.loadDefaultDiffCwd(alloc, io, tmp.cwd());
    defer d.deinit();
    try testing.expectEqual(2, d.files.len);
    try testing.expect(d.files[0].hunks.len > 0);
    try testing.expect(d.files[1].hunks.len > 0);
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(d.files[0].displayPath(), approve.fingerprintHunk(d.files[0].hunks[0]));
    try approved.append(d.files[1].displayPath(), approve.fingerprintHunk(d.files[1].hunks[0]));
    try approved.append("gone.txt", approve.fingerprintFile("stale"));
    try approve.save(&approved, alloc, io, tmp.dir);

    const got = try captureCmd(alloc, io, tmp.dir, cmdApproved);
    defer alloc.free(got.text);
    defer alloc.free(got.err);
    try testing.expectEqual(exit_success, got.rc);
    try testing.expectEqualStrings("", got.err);
    try testing.expect(std.mem.startsWith(u8, got.text, "1  a.txt  Unstaged  "));
    try testing.expect(std.mem.indexOf(u8, got.text, "\n2  extra.txt  Untracked  ") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "gone.txt") == null);
}

test "approved not a git repository is operational failure" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    const got = try captureCmd(alloc, io, tmp.dir, cmdApproved);
    defer alloc.free(got.text);
    defer alloc.free(got.err);
    try testing.expectEqual(exit_operational, got.rc);
    try testing.expectEqualStrings("rv: not a git repository (run from a work tree)\n", got.err);
}

test "unapprove not a number or zero is operational failure" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    const bad = try captureUnapprove(alloc, io, tmp.dir, "abc");
    defer alloc.free(bad.text);
    defer alloc.free(bad.err);
    try testing.expectEqual(exit_operational, bad.rc);
    try testing.expectEqualStrings("rv: not a number: abc\n", bad.err);

    const zero = try captureUnapprove(alloc, io, tmp.dir, "0");
    defer alloc.free(zero.text);
    defer alloc.free(zero.err);
    try testing.expectEqual(exit_operational, zero.rc);
    try testing.expectEqualStrings("rv: index out of range\n", zero.err);
}

test "unapprove empty list or too-large index is operational failure" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try makeDirtyRepo(io, tmp);

    const empty = try captureUnapprove(alloc, io, tmp.dir, "1");
    defer alloc.free(empty.text);
    defer alloc.free(empty.err);
    try testing.expectEqual(exit_operational, empty.rc);
    try testing.expectEqualStrings("rv: index out of range\n", empty.err);

    try saveFirstHunks(alloc, io, tmp);
    const high = try captureUnapprove(alloc, io, tmp.dir, "2");
    defer alloc.free(high.text);
    defer alloc.free(high.err);
    try testing.expectEqual(exit_operational, high.rc);
    try testing.expectEqualStrings("rv: index out of range\n", high.err);
}

test "unapprove drops the nth live row and later indexes shift" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try makeDirtyRepo(io, tmp);
    try tmp.write(io, "extra.txt", "hi\n");
    try saveFirstHunks(alloc, io, tmp);

    const first = try captureUnapprove(alloc, io, tmp.dir, "1");
    defer alloc.free(first.text);
    defer alloc.free(first.err);
    try testing.expectEqual(exit_success, first.rc);
    try testing.expectEqualStrings("1 unapproved\n", first.text);
    try testing.expectEqualStrings("", first.err);

    const listed = try captureCmd(alloc, io, tmp.dir, cmdApproved);
    defer alloc.free(listed.text);
    defer alloc.free(listed.err);
    try testing.expectEqual(exit_success, listed.rc);
    try testing.expect(std.mem.startsWith(u8, listed.text, "1  extra.txt  Untracked  "));
    try testing.expect(std.mem.indexOf(u8, listed.text, "\n2  ") == null);

    const second = try captureUnapprove(alloc, io, tmp.dir, "1");
    defer alloc.free(second.text);
    defer alloc.free(second.err);
    try testing.expectEqual(exit_success, second.rc);
    try testing.expectEqualStrings("1 unapproved\n", second.text);

    const status = try captureCmd(alloc, io, tmp.dir, cmdStatus);
    defer alloc.free(status.text);
    defer alloc.free(status.err);
    try testing.expectEqual(exit_success, status.rc);
    try testing.expect(std.mem.indexOf(u8, status.text, "approved: 0") != null);
}

test "unapprove not a git repository is operational failure" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    const got = try captureUnapprove(alloc, io, tmp.dir, "1");
    defer alloc.free(got.text);
    defer alloc.free(got.err);
    try testing.expectEqual(exit_operational, got.rc);
    try testing.expectEqualStrings("rv: not a git repository (run from a work tree)\n", got.err);
}
