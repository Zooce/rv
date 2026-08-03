//! Headless CLI for the comment store (MVP-2.2 / 2.3).
//!
//! Subcommands: `status`, `list`, `show`, `resolve`, `reopen`, help. No git
//! load and no raw TTY modes. Bare `rv` (no args) still launches the review
//! TUI from `main`.

const std = @import("std");
const store = @import("store");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const exit_success: u8 = 0;
pub const exit_operational: u8 = 1;
pub const exit_usage: u8 = 2;

pub const ListFilter = enum { open, resolved, all };

pub const Command = union(enum) {
    help,
    status,
    list: ListFilter,
    show: []const u8,
    resolve: []const []const u8,
    reopen: []const []const u8,
};

/// Parse argv after the program name.
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
        return .{ .list = try parseListFilter(args[1..]) };
    }
    if (std.mem.eql(u8, cmd, "show")) {
        if (args.len != 2) return error.Usage;
        return .{ .show = args[1] };
    }
    if (std.mem.eql(u8, cmd, "resolve")) {
        if (args.len < 2) return error.Usage;
        return .{ .resolve = args[1..] };
    }
    if (std.mem.eql(u8, cmd, "reopen")) {
        if (args.len < 2) return error.Usage;
        return .{ .reopen = args[1..] };
    }
    return error.Usage;
}

fn isHelp(s: []const u8) bool {
    return std.mem.eql(u8, s, "help") or
        std.mem.eql(u8, s, "--help") or
        std.mem.eql(u8, s, "-h");
}

fn parseListFilter(args: []const []const u8) error{Usage}!ListFilter {
    if (args.len == 0) return .open;
    if (args.len != 1) return error.Usage;
    if (std.mem.eql(u8, args[0], "--open")) return .open;
    if (std.mem.eql(u8, args[0], "--all")) return .all;
    if (std.mem.eql(u8, args[0], "--resolved")) return .resolved;
    return error.Usage;
}

const usage_text =
    \\usage: rv [<command>] [args]
    \\
    \\With no command, opens the full-screen review TUI.
    \\
    \\Commands:
    \\  status                         open/resolved counts for the current review
    \\  list [--open|--all|--resolved] list comments (default: open only)
    \\  show <id>                      print one comment
    \\  resolve <id> [id…]             mark comments resolved
    \\  reopen <id> [id…]              mark comments open again
    \\  help, -h, --help               show this help
    \\
    \\Exit codes: 0 success, 1 error, 2 usage
    \\
;

/// Run a CLI command. `args` is argv after the program name.
pub fn run(alloc: Allocator, io: Io, args: []const []const u8) u8 {
    const cmd = parse(args) catch {
        std.debug.print("{s}", .{usage_text});
        return exit_usage;
    };
    switch (cmd) {
        .help => return cmdHelp(io),
        .status => return cmdStatus(alloc, io),
        .list => |filter| return cmdList(alloc, io, filter),
        .show => |id| return cmdShow(alloc, io, id),
        .resolve => |ids| return cmdSetState(alloc, io, ids, .resolved, "resolved"),
        .reopen => |ids| return cmdSetState(alloc, io, ids, .open, "reopened"),
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

    var open_n: usize = 0;
    var resolved_n: usize = 0;
    for (review.comments.items) |c| {
        switch (c.state) {
            .open => open_n += 1,
            .resolved => resolved_n += 1,
        }
    }
    const total = review.comments.items.len;
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
        \\open: {d}
        \\resolved: {d}
        \\total: {d}
        \\
    , .{ review.id, rel, open_n, resolved_n, total }) catch {
        std.debug.print("rv: write failed\n", .{});
        return exit_operational;
    };
    out.flush() catch {
        std.debug.print("rv: write failed\n", .{});
        return exit_operational;
    };
    return exit_success;
}

fn cmdList(alloc: Allocator, io: Io, filter: ListFilter) u8 {
    var review = loadReview(alloc, io) catch |err| return loadFail(err);
    defer review.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var anchor_buf: [256]u8 = undefined;
    for (review.comments.items) |c| {
        if (!matchesFilter(c.state, filter)) continue;
        const anchor = formatAnchor(&anchor_buf, c);
        // One line: id state anchor body (newlines in body → spaces).
        out.print("{s}  {s}  {s}  ", .{ c.id, @tagName(c.state), anchor }) catch {
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
    out.print("state: {s}\n", .{@tagName(c.state)}) catch return writeFail();
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

/// Load → setState (all-or-nothing) → save → one confirmation line per id.
fn cmdSetState(
    alloc: Allocator,
    io: Io,
    ids: []const []const u8,
    state: store.State,
    verb: []const u8,
) u8 {
    var review = loadReview(alloc, io) catch |err| return loadFail(err);
    defer review.deinit();

    review.setState(ids, state) catch {
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
        out.print("{s} {s}\n", .{ id, verb }) catch return writeFail();
    }
    out.flush() catch return writeFail();
    return exit_success;
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

fn matchesFilter(state: store.State, filter: ListFilter) bool {
    return switch (filter) {
        .all => true,
        .open => state == .open,
        .resolved => state == .resolved,
    };
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

test "parse help status list show resolve reopen" {
    try testing.expectEqual(Command.help, try parse(&.{"help"}));
    try testing.expectEqual(Command.help, try parse(&.{"--help"}));
    try testing.expectEqual(Command.help, try parse(&.{"-h"}));
    try testing.expectEqual(Command.status, try parse(&.{"status"}));

    try testing.expectEqual(ListFilter.open, (try parse(&.{"list"})).list);
    try testing.expectEqual(ListFilter.open, (try parse(&.{ "list", "--open" })).list);
    try testing.expectEqual(ListFilter.all, (try parse(&.{ "list", "--all" })).list);
    try testing.expectEqual(ListFilter.resolved, (try parse(&.{ "list", "--resolved" })).list);

    const show = try parse(&.{ "show", "3" });
    try testing.expectEqualStrings("3", show.show);

    const resolve_one = try parse(&.{ "resolve", "1" });
    try testing.expectEqual(1, resolve_one.resolve.len);
    try testing.expectEqualStrings("1", resolve_one.resolve[0]);

    const resolve_multi = try parse(&.{ "resolve", "1", "2", "3" });
    try testing.expectEqual(3, resolve_multi.resolve.len);
    try testing.expectEqualStrings("2", resolve_multi.resolve[1]);

    const reopen_one = try parse(&.{ "reopen", "7" });
    try testing.expectEqual(1, reopen_one.reopen.len);
    try testing.expectEqualStrings("7", reopen_one.reopen[0]);

    const reopen_multi = try parse(&.{ "reopen", "a", "b" });
    try testing.expectEqual(2, reopen_multi.reopen.len);
    try testing.expectEqualStrings("b", reopen_multi.reopen[1]);
}

test "parse usage errors" {
    try testing.expectError(error.Usage, parse(&.{}));
    try testing.expectError(error.Usage, parse(&.{"nope"}));
    try testing.expectError(error.Usage, parse(&.{ "status", "x" }));
    try testing.expectError(error.Usage, parse(&.{"show"}));
    try testing.expectError(error.Usage, parse(&.{ "show", "1", "2" }));
    try testing.expectError(error.Usage, parse(&.{ "list", "--all", "--open" }));
    try testing.expectError(error.Usage, parse(&.{ "list", "--bogus" }));
    try testing.expectError(error.Usage, parse(&.{ "help", "extra" }));
    try testing.expectError(error.Usage, parse(&.{"resolve"}));
    try testing.expectError(error.Usage, parse(&.{"reopen"}));
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
