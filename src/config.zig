//! Display defaults from `key = value` lines.
//!
//! `layout` is `side-by-side`, `sbs`, `unified`, or `uni`. `line_numbers` and
//! `wrap` are `true` or `false`. A `#` starts a comment. `apply` overlays the
//! keys it finds onto `config`. A missing key leaves the field alone, so a
//! later call overrides one key at a time. An unknown key or value fails the
//! whole text and leaves `config` unchanged.
//!
//! `load` reads the user file, then `.rv/config` in `root`. The user
//! file is `$XDG_CONFIG_HOME/rv/config`, or `$HOME/.config/rv/config`
//! when that variable is unset or empty. A missing file is skipped. A file
//! that is present but unreadable or invalid fails the load.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Layout = enum {
    side_by_side,
    unified,
};

pub const Config = struct {
    layout: Layout = .side_by_side,
    line_numbers: bool = true,
    wrap: bool = false,
};

/// Why `apply` rejected a text. `reason` is a static string. `line` is 1-based.
pub const Diagnostic = struct {
    line: usize,
    reason: []const u8,
};

/// Overlay keys from `text` onto `config`. Null means the text was applied.
/// A diagnostic means `config` was left as it was.
pub fn apply(config: *Config, text: []const u8) ?Diagnostic {
    // Parse into a copy so a bad line does not change `config`.
    var next = config.*;
    var line_no: usize = 1;
    var begin: usize = 0;
    while (begin < text.len) {
        var end = begin;
        while (end < text.len and text[end] != '\n') end += 1;
        var line = text[begin..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (readLine(&next, line)) |reason| return .{ .line = line_no, .reason = reason };
        if (end == text.len) break;
        line_no += 1;
        begin = end + 1;
    }
    config.* = next;
    return null;
}

fn readLine(config: *Config, line: []const u8) ?[]const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
    const body = std.mem.trim(u8, line[0..hash], " \t");
    if (body.len == 0) return null;
    return readAssign(config, body);
}

fn readAssign(config: *Config, line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return "expected key = value";
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const raw = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (raw.len == 0 or !isIdent(key)) return "expected key = value";
    if (std.mem.indexOfAny(u8, raw, " \t") != null) return "trailing characters";

    if (std.mem.eql(u8, key, "layout")) {
        config.layout = readLayout(raw) orelse return "unknown value";
        return null;
    }

    const field: *bool = if (std.mem.eql(u8, key, "line_numbers"))
        &config.line_numbers
    else if (std.mem.eql(u8, key, "wrap"))
        &config.wrap
    else
        return "unknown key";
    return readBool(raw, field);
}

fn readLayout(raw: []const u8) ?Layout {
    if (std.mem.eql(u8, raw, "side-by-side") or std.mem.eql(u8, raw, "sbs")) return .side_by_side;
    if (std.mem.eql(u8, raw, "unified") or std.mem.eql(u8, raw, "uni")) return .unified;
    return null;
}

fn isIdent(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

/// `true` or `false`. Null means `value` was set.
fn readBool(raw: []const u8, value: *bool) ?[]const u8 {
    if (std.mem.eql(u8, raw, "true")) {
        value.* = true;
        return null;
    }
    if (std.mem.eql(u8, raw, "false")) {
        value.* = false;
        return null;
    }
    return "expected true or false";
}

/// Repo file, relative to the directory passed to `load` (the process cwd
/// for the TUI, same as `.rv/reviews/` and `.rv/approved.json`).
pub const repo_rel_path = ".rv/config";

/// A display file is a few lines. Larger than this is rejected.
const max_file_bytes: usize = 64 * 1024;

/// A file `load` rejected. `path` is owned. `reason` is a static string.
/// `line` is set when a parsed line was rejected.
pub const LoadFailure = struct {
    path: []u8,
    line: ?usize = null,
    reason: []const u8,

    pub fn deinit(self: LoadFailure, alloc: Allocator) void {
        alloc.free(self.path);
    }
};

pub const LoadResult = union(enum) {
    config: Config,
    failure: LoadFailure,
};

const Overlay = union(enum) {
    applied,
    missing,
    failure: LoadFailure,
};

/// Compiled defaults, then the user file, then the repo file. `xdg` is
/// `$XDG_CONFIG_HOME` and `home` is `$HOME`. Empty strings count as unset.
/// A null `root` skips the repo file (no live project).
pub fn load(
    alloc: Allocator,
    io: Io,
    root: ?Io.Dir,
    xdg: ?[]const u8,
    home: ?[]const u8,
) Allocator.Error!LoadResult {
    var config: Config = .{};
    // User file, when a home directory is known. Absolute paths open from cwd.
    if (try userConfigPath(alloc, xdg, home)) |path| {
        defer alloc.free(path);
        switch (try overlayFile(alloc, io, .cwd(), &config, path)) {
            .applied, .missing => {},
            .failure => |fail| return .{ .failure = fail },
        }
    }
    if (root) |dir| {
        switch (try overlayFile(alloc, io, dir, &config, repo_rel_path)) {
            .applied, .missing => {},
            .failure => |fail| return .{ .failure = fail },
        }
    }
    return .{ .config = config };
}

fn userConfigPath(alloc: Allocator, xdg: ?[]const u8, home: ?[]const u8) Allocator.Error!?[]u8 {
    if (xdg) |dir| if (dir.len > 0) {
        return try std.fs.path.join(alloc, &.{ dir, "rv", "config" });
    };
    if (home) |dir| if (dir.len > 0) {
        return try std.fs.path.join(alloc, &.{ dir, ".config", "rv", "config" });
    };
    return null;
}

fn overlayFile(
    alloc: Allocator,
    io: Io,
    dir: Io.Dir,
    config: *Config,
    path: []const u8,
) Allocator.Error!Overlay {
    const text = dir.readFileAlloc(io, path, alloc, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return ownedFailure(alloc, path, null, "config file is too large"),
        else => return ownedFailure(alloc, path, null, "cannot read config"),
    };
    defer alloc.free(text);
    if (apply(config, text)) |diag| return ownedFailure(alloc, path, diag.line, diag.reason);
    return .applied;
}

fn ownedFailure(
    alloc: Allocator,
    path: []const u8,
    line: ?usize,
    reason: []const u8,
) Allocator.Error!Overlay {
    return .{ .failure = .{
        .path = try alloc.dupe(u8, path),
        .line = line,
        .reason = reason,
    } };
}

const testing = std.testing;

fn expectEqualConfig(config: Config, want: Config) !void {
    try testing.expectEqual(want.layout, config.layout);
    try testing.expectEqual(want.line_numbers, config.line_numbers);
    try testing.expectEqual(want.wrap, config.wrap);
}

fn expectOk(start: Config, text: []const u8, want: Config) !void {
    var config = start;
    try testing.expect(apply(&config, text) == null);
    try expectEqualConfig(config, want);
}

fn expectFail(start: Config, text: []const u8, line: usize, reason: []const u8) !void {
    var config = start;
    const diag = apply(&config, text) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(line, diag.line);
    try testing.expectEqualStrings(reason, diag.reason);
    try expectEqualConfig(config, start);
}

test "empty and comment-only text keeps the config" {
    const start: Config = .{ .layout = .unified, .line_numbers = false, .wrap = true };
    try expectOk(start, "", start);
    try expectOk(start, "\n# just a comment\n\n", start);
}

test "layout accepts side-by-side, sbs, unified, and uni" {
    try expectOk(.{ .layout = .unified }, "layout = side-by-side\n", .{});
    try expectOk(.{ .layout = .unified }, "layout = sbs\n", .{});
    try expectOk(.{}, "layout = unified\n", .{ .layout = .unified });
    try expectOk(.{}, "layout = uni\n", .{ .layout = .unified });
}

test "keys set layout, line numbers, and wrap" {
    try expectOk(.{},
        \\layout = unified
        \\line_numbers = false
        \\wrap = true
    , .{ .layout = .unified, .line_numbers = false, .wrap = true });
}

test "a later key overrides only that field" {
    try expectOk(.{},
        \\layout = sbs
        \\layout = uni
        \\line_numbers = true
        \\line_numbers = false
        \\wrap = true
    , .{ .layout = .unified, .line_numbers = false, .wrap = true });

    var config: Config = .{};
    try testing.expect(apply(&config,
        \\layout = side-by-side
        \\line_numbers = false
        \\wrap = true
    ) == null);
    try testing.expect(apply(&config, "line_numbers = true\n") == null);
    try expectEqualConfig(config, .{
        .line_numbers = true,
        .wrap = true,
    });
}

test "comments, blank lines, and surrounding space are ignored" {
    try expectOk(.{}, "  layout\t=\tuni  # keep\n\n  wrap = true\r\n", .{
        .layout = .unified,
        .wrap = true,
    });
}

test "bools replace the previous value" {
    const on: Config = .{ .line_numbers = true, .wrap = true };
    const off: Config = .{ .line_numbers = false, .wrap = false };
    try expectOk(on, "line_numbers = false\nwrap = false\n", off);
    try expectOk(off, "line_numbers = true\nwrap = true\n", on);
}

test "a bad line leaves the config unchanged" {
    const start: Config = .{ .layout = .unified, .wrap = true };
    try expectFail(start, "line_numbers = false\nwrap = nope\n", 2, "expected true or false");
    try expectFail(start, "theme = dark\n", 1, "unknown key");
    try expectFail(start, "Layout = unified\n", 1, "unknown key");
    try expectFail(start, "[display]\n", 1, "expected key = value");
    try expectFail(start, "layout = side_by_side\n", 1, "unknown value");
    try expectFail(start, "layout = \"unified\"\n", 1, "unknown value");
    try expectFail(start, "layout = true\n", 1, "unknown value");
    try expectFail(start, "layout = unified extra\n", 1, "trailing characters");
    try expectFail(start, "wrap = \"true\"\n", 1, "expected true or false");
    try expectFail(start, "wrap =\n", 1, "expected key = value");
    try expectFail(start, "= true\n", 1, "expected key = value");
    try expectFail(start, "line-numbers = false\n", 1, "expected key = value");
    try expectFail(start, "# ok\n\ntheme = 1\n", 3, "unknown key");
}

const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

fn expectLoad(root: Io.Dir, xdg: ?[]const u8, home: ?[]const u8, want: Config) !void {
    const loaded = try load(testing.allocator, testing.io, root, xdg, home);
    switch (loaded) {
        .failure => |fail| {
            fail.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        },
        .config => |cfg| try expectEqualConfig(cfg, want),
    }
}

fn expectLoadFail(
    root: Io.Dir,
    xdg: ?[]const u8,
    home: ?[]const u8,
    path: []const u8,
    line: ?usize,
    reason: []const u8,
) !void {
    const loaded = try load(testing.allocator, testing.io, root, xdg, home);
    switch (loaded) {
        .config => return error.TestUnexpectedResult,
        .failure => |fail| {
            defer fail.deinit(testing.allocator);
            try testing.expectEqualStrings(path, fail.path);
            try testing.expectEqualStrings(reason, fail.reason);
            if (line) |n| {
                try testing.expectEqual(n, fail.line.?);
            } else {
                try testing.expect(fail.line == null);
            }
        },
    }
}

test "missing files keep the compiled defaults" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    try expectLoad(tmp.dir, null, null, .{});
    try expectLoad(tmp.dir, "", "", .{});
    try expectLoad(tmp.dir, tmp.path, null, .{});
}

test "the user file overlays defaults and the repo file overrides one key" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    try tmp.dir.createDirPath(io, "rv");
    try tmp.write(io, "rv/config",
        \\layout = uni
        \\line_numbers = true
        \\
    );
    try tmp.dir.createDirPath(io, ".rv");
    try tmp.write(io, ".rv/config", "line_numbers = false\nwrap = true\n");

    try expectLoad(tmp.dir, tmp.path, null, .{
        .layout = .unified,
        .line_numbers = false,
        .wrap = true,
    });
}

test "an empty XDG_CONFIG_HOME uses HOME" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var home = try IsolatedTmp.init(alloc, io);
    defer home.deinit(alloc, io);
    var root = try IsolatedTmp.init(alloc, io);
    defer root.deinit(alloc, io);

    try home.dir.createDirPath(io, ".config/rv");
    try home.write(io, ".config/rv/config", "wrap = true\n");
    try root.dir.createDirPath(io, "rv");
    try root.write(io, "rv/config", "layout = sbs\n");

    try expectLoad(root.dir, null, home.path, .{ .wrap = true });
    try expectLoad(root.dir, "", home.path, .{ .wrap = true });
    // A set XDG_CONFIG_HOME wins, and its missing keys stay at the defaults.
    // `sbs` is side-by-side, so wrap stays off instead of the home file's true.
    try expectLoad(root.dir, root.path, home.path, .{});
}

test "an invalid file names its path and does not apply" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    try tmp.dir.createDirPath(io, "rv");
    try tmp.write(io, "rv/config", "layout = nope\n");
    try tmp.dir.createDirPath(io, ".rv");
    try tmp.write(io, ".rv/config", "wrap = true\n");

    const user_path = try std.fs.path.join(alloc, &.{ tmp.path, "rv", "config" });
    defer alloc.free(user_path);
    try expectLoadFail(tmp.dir, tmp.path, null, user_path, 1, "unknown value");

    try tmp.write(io, "rv/config", "layout = side-by-side\n");
    try tmp.write(io, ".rv/config", "wrap = nope\n");
    try expectLoadFail(tmp.dir, tmp.path, null, repo_rel_path, 1, "expected true or false");
}

test "a directory or an oversized file cannot be read" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    try tmp.dir.createDirPath(io, ".rv/config");
    try expectLoadFail(tmp.dir, null, null, repo_rel_path, null, "cannot read config");

    try tmp.dir.deleteTree(io, ".rv");
    try tmp.dir.createDirPath(io, ".rv");
    const big = try alloc.alloc(u8, max_file_bytes + 1);
    defer alloc.free(big);
    @memset(big, '\n');
    try tmp.write(io, ".rv/config", big);
    try expectLoadFail(tmp.dir, null, null, repo_rel_path, null, "config file is too large");
}
