//! Headless CLI for the comment store (MVP-2.2–2.5).
//!
//! Subcommands: `status`, `list`, `show`, `resolve`, `export`,
//! `install-skill`, help. No git load and no raw TTY modes. Bare `rv` and
//! `rv <range>` launch the review TUI from `main` (`classify`).
//! `resolve` deletes ids. There is no reopen and no list/export filter.

const std = @import("std");
const store = @import("store");
const install_skill = @import("install_skill");
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
    list,
    show: []const u8,
    resolve: []const []const u8,
    @"export": ExportOpts,
    install_skill: install_skill.Opts,
};

/// Where the TUI diff came from. Recorded at launch; paint prints a label
/// and must not re-resolve git.
pub const Source = union(enum) {
    local,
    range: []const u8,
};

/// Status-strip text for `source`. `empty` is a clean worktree (no local
/// changes), not an approved-only hide. Local is `HEAD`; an explicit range
/// stays the user-supplied string even if empty.
pub fn sourceLabel(source: Source, empty: bool) []const u8 {
    return switch (source) {
        .local => if (empty) "HEAD · empty" else "HEAD",
        .range => |r| r,
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
        return .{ .tui = .{ .range = args[0] } };
    }
    return error.Usage;
}

fn isCommand(s: []const u8) bool {
    return isHelp(s) or
        std.mem.eql(u8, s, "status") or
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
    \\usage: rv [<range> | <command>] [args]
    \\
    \\With no args, opens the review TUI on local changes (staged, unstaged,
    \\and untracked). A clean worktree opens empty. A git revision or range
    \\(for example main...HEAD) opens the TUI on `git diff <range>` as written.
    \\
    \\Commands:
    \\  status                         live comment count and store path
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

/// Run a parsed headless command.
pub fn run(alloc: Allocator, io: Io, cmd: Command, env: Env) u8 {
    switch (cmd) {
        .help => return cmdHelp(io),
        .status => return cmdStatus(alloc, io),
        .list => return cmdList(alloc, io),
        .show => |id| return cmdShow(alloc, io, id),
        .resolve => |ids| return cmdResolve(alloc, io, ids),
        .@"export" => |opts| return cmdExport(alloc, io, opts),
        .install_skill => |opts| {
            var out_buf: [4096]u8 = undefined;
            var err_buf: [1024]u8 = undefined;
            var out_w = std.Io.File.stdout().writer(io, &out_buf);
            var err_w = std.Io.File.stderr().writer(io, &err_buf);
            const rc = install_skill.run(alloc, io, opts, env.home, env.skill_dir, .{
                .out = &out_w.interface,
                .err = &err_w.interface,
            });
            out_w.interface.flush() catch {};
            err_w.interface.flush() catch {};
            return rc;
        },
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

fn cmdStatus(alloc: Allocator, io: Io) u8 {
    var review = loadReview(alloc, io) catch |err| return loadFail(err);
    defer review.deinit();

    const rel = store.reviewRelPath(alloc, review.id) catch {
        std.debug.print("rv: out of memory\n", .{});
        return exit_operational;
    };
    defer alloc.free(rel);

    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    out.print(
        \\review: {s}
        \\store: {s}
        \\comments: {d}
        \\
    , .{ review.id, rel, review.comments.items.len }) catch {
        std.debug.print("rv: write failed\n", .{});
        return exit_operational;
    };
    out.flush() catch {
        std.debug.print("rv: write failed\n", .{});
        return exit_operational;
    };
    return exit_success;
}

fn cmdList(alloc: Allocator, io: Io) u8 {
    var review = loadReview(alloc, io) catch |err| return loadFail(err);
    defer review.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var anchor_buf: [256]u8 = undefined;
    for (review.comments.items) |c| {
        const anchor = formatAnchor(&anchor_buf, c);
        // One line: id anchor body (newlines in body → spaces).
        out.print("{s}  {s}  ", .{ c.id, anchor }) catch {
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

fn cmdShow(alloc: Allocator, io: Io, id: []const u8) u8 {
    var review = loadReview(alloc, io) catch |err| return loadFail(err);
    defer review.deinit();

    const c = review.find(id) orelse {
        std.debug.print("rv: comment not found: {s}\n", .{id});
        return exit_operational;
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    out.print("id: {s}\n", .{c.id}) catch return writeFail();
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
fn cmdResolve(alloc: Allocator, io: Io, ids: []const []const u8) u8 {
    var review = loadReview(alloc, io) catch |err| return loadFail(err);
    defer review.deinit();

    review.remove(ids) catch {
        for (ids) |id| {
            if (review.find(id) == null) {
                std.debug.print("rv: comment not found: {s}\n", .{id});
            }
        }
        return exit_operational;
    };

    store.save(&review, alloc, io, .cwd()) catch {
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

fn cmdExport(alloc: Allocator, io: Io, opts: ExportOpts) u8 {
    var review = loadReview(alloc, io) catch |err| return loadFail(err);
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

fn loadReview(alloc: Allocator, io: Io) store.LoadError!store.Review {
    return store.load(alloc, io, .cwd(), store.default_review_id);
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

test "parse help status list show resolve export install-skill" {
    try testing.expectEqual(Command.help, try parse(&.{"help"}));
    try testing.expectEqual(Command.help, try parse(&.{"--help"}));
    try testing.expectEqual(Command.help, try parse(&.{"-h"}));
    try testing.expectEqual(Command.status, try parse(&.{"status"}));
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
        .tui => |src| try testing.expectEqualStrings("HEAD", src.range),
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

test "sourceLabel local and range" {
    try testing.expectEqualStrings("HEAD", sourceLabel(.local, false));
    try testing.expectEqualStrings("HEAD · empty", sourceLabel(.local, true));
    try testing.expectEqualStrings("main...HEAD", sourceLabel(.{ .range = "main...HEAD" }, false));
    try testing.expectEqualStrings("main...HEAD", sourceLabel(.{ .range = "main...HEAD" }, true));
}

test "formatMarkdown and formatJson envelope" {
    var review = try store.initEmpty(testing.allocator, "current");
    defer review.deinit();
    _ = try review.addOpen("a.zig", null, 10, .new, "fix me");
    _ = try review.addOpen("b.zig", 2, null, .old, "also");

    const md = try formatMarkdown(testing.allocator, &review);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "# rv export — review `current`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## [1] — a.zig:+10 (new)") != null);
    try testing.expect(std.mem.indexOf(u8, md, "fix me") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## [2] — b.zig:-2 (old)") != null);
    try testing.expect(std.mem.indexOf(u8, md, "also") != null);

    const js = try formatJson(testing.allocator, &review);
    defer testing.allocator.free(js);
    var parsed = try std.json.parseFromSlice(ExportEnvelope, testing.allocator, js, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testing.expectEqual(1, parsed.value.version);
    try testing.expectEqualStrings("current", parsed.value.review_id);
    try testing.expectEqual(2, parsed.value.comments.len);
    try testing.expectEqualStrings("1", parsed.value.comments[0].id);
    try testing.expectEqualStrings("a.zig", parsed.value.comments[0].path);
    try testing.expectEqual(10, parsed.value.comments[0].new_line.?);
    try testing.expectEqualStrings("new", parsed.value.comments[0].side.?);
    try testing.expectEqualStrings("fix me", parsed.value.comments[0].body);
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
