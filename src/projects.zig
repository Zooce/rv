//! Saved work trees in the user config directory.
//!
//! The file is `projects` next to the display config
//! (`$XDG_CONFIG_HOME/rv/projects`, or `~/.config/rv/projects`).
//! One absolute path per line, in the order projects were added.
//! `#` starts a comment. Blank lines are skipped. An optional
//! `current <absolute path>` line names the last live project. It does
//! not move that path. A `current` path that is not in the list is ignored.
//! A missing file is an empty list. Load does not write the file.
//!
//! `completePath` lists the directories a typed prefix can cycle through.
//! `directoryArg` is the `rv <path>` check: an existing directory, or null.

const std = @import("std");
const git = @import("git");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Paths in add order, plus the index of `current` when that path is listed.
pub const List = struct {
    paths: std.ArrayList([]u8) = .empty,
    current: ?usize = null,

    pub fn deinit(self: *List, alloc: Allocator) void {
        for (self.paths.items) |p| alloc.free(p);
        self.paths.deinit(alloc);
        self.* = undefined;
    }

    pub fn indexOf(self: *const List, path: []const u8) ?usize {
        for (self.paths.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, path)) return i;
        }
        return null;
    }

    /// Append `path` when it is not already listed. Does not change `current`.
    /// False means the path was already present.
    pub fn append(self: *List, alloc: Allocator, path: []const u8) Allocator.Error!bool {
        if (self.indexOf(path) != null) return false;
        const owned = try alloc.dupe(u8, path);
        errdefer alloc.free(owned);
        try self.paths.append(alloc, owned);
        return true;
    }

    /// Drop `index`. Later paths stay in order. `current` stays on the same
    /// path, or clears when that path was the one removed.
    pub fn remove(self: *List, alloc: Allocator, index: usize) void {
        if (index >= self.paths.items.len) return;
        const path = self.paths.orderedRemove(index);
        alloc.free(path);
        if (self.current) |cur| {
            if (cur == index) self.current = null else if (cur > index) self.current = cur - 1;
        }
    }

    /// Point `current` at `index`. False when `index` is out of range or
    /// `current` was already there. Does not reorder `paths`.
    pub fn setCurrent(self: *List, index: usize) bool {
        if (index >= self.paths.items.len) return false;
        if (self.current == index) return false;
        self.current = index;
        return true;
    }
};

/// Which saved path a local launch opens. `cwd` means the process directory
/// is a work tree (`null` index: it is not in the list). `saved` is an index
/// into `paths`. `none` means there is no work tree to open.
pub const Launch = union(enum) {
    cwd: ?usize,
    saved: usize,
    none,
};

/// `cwd_is_repo` is the process directory. `is_repo` is parallel to
/// `list.paths` (true when that saved path is a work tree). Does not
/// reorder or rewrite `list`.
pub fn launchChoice(list: *const List, cwd_is_repo: bool, cwd_path: []const u8, is_repo: []const bool) Launch {
    if (cwd_is_repo) return .{ .cwd = list.indexOf(cwd_path) };
    if (list.current) |idx| {
        if (idx < is_repo.len and is_repo[idx]) return .{ .saved = idx };
    }
    for (is_repo, 0..) |ok, i| {
        if (ok and i < list.paths.items.len) return .{ .saved = i };
    }
    return .none;
}

/// `$XDG_CONFIG_HOME/rv/projects`, or `$HOME/.config/rv/projects`.
/// Empty strings count as unset. Null when neither directory is known.
pub fn userPath(alloc: Allocator, xdg: ?[]const u8, home: ?[]const u8) Allocator.Error!?[]u8 {
    if (xdg) |dir| if (dir.len > 0) {
        return try std.fs.path.join(alloc, &.{ dir, "rv", "projects" });
    };
    if (home) |dir| if (dir.len > 0) {
        return try std.fs.path.join(alloc, &.{ dir, ".config", "rv", "projects" });
    };
    return null;
}

const max_file_bytes: usize = 256 * 1024;

pub fn load(alloc: Allocator, io: Io, path: []const u8) !List {
    const text = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(text);
    return try parse(alloc, text);
}

pub const SaveError = error{WriteFailed} || Allocator.Error ||
    Io.Dir.CreateDirPathError || Io.Dir.OpenError || Io.Dir.CreateFileAtomicError ||
    Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

/// Atomic replace. Writes `current` (when set) and then the paths in order.
pub fn save(self: *const List, alloc: Allocator, io: Io, path: []const u8) SaveError!void {
    const bytes = try format(self, alloc);
    defer alloc.free(bytes);
    const parent = std.fs.path.dirname(path) orelse return error.WriteFailed;
    const base = std.fs.path.basename(path);
    try Io.Dir.cwd().createDirPath(io, parent);
    var dir = try Io.Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    var af = try dir.createFileAtomic(io, base, .{ .replace = true });
    defer af.deinit(io);
    af.file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
    try af.replace(io);
}

/// Parse `text`. Non-absolute lines are skipped. The first `current` line
/// wins; a later one is ignored. Duplicate paths keep the first.
pub fn parse(alloc: Allocator, text: []const u8) Allocator.Error!List {
    var list: List = .{};
    errdefer list.deinit(alloc);
    var current_text: ?[]u8 = null;
    errdefer if (current_text) |p| alloc.free(p);

    var begin: usize = 0;
    while (begin < text.len) {
        var end = begin;
        while (end < text.len and text[end] != '\n') end += 1;
        var line = text[begin..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        // Comment and blank lines carry no path.
        const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
        const body = std.mem.trim(u8, line[0..hash], " \t");
        if (body.len > 0) {
            const key = "current";
            const is_current = std.mem.startsWith(u8, body, key) and
                (body.len == key.len or body[key.len] == ' ' or body[key.len] == '\t');
            if (is_current) {
                if (current_text == null) {
                    const rest = std.mem.trim(u8, body[key.len..], " \t");
                    if (rest.len > 0 and std.fs.path.isAbsolute(rest)) {
                        current_text = try alloc.dupe(u8, rest);
                    }
                }
            } else if (std.fs.path.isAbsolute(body)) {
                _ = try list.append(alloc, body);
            }
        }

        if (end == text.len) break;
        begin = end + 1;
    }

    if (current_text) |p| {
        defer alloc.free(p);
        current_text = null;
        if (list.indexOf(p)) |idx| list.current = idx;
    }
    return list;
}

pub fn format(self: *const List, alloc: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (self.current) |idx| {
        if (idx < self.paths.items.len) {
            try out.appendSlice(alloc, "current ");
            try out.appendSlice(alloc, self.paths.items[idx]);
            try out.append(alloc, '\n');
        }
    }
    for (self.paths.items) |p| {
        try out.appendSlice(alloc, p);
        try out.append(alloc, '\n');
    }
    return try out.toOwnedSlice(alloc);
}

pub const ResolveError = error{ Empty, NoHome, NotFound } || Allocator.Error;

/// Expand `~` / `~/…` with `home`, join a relative path onto `cwd`, then
/// realpath. `cwd` is the process directory, not the live project.
pub fn resolve(alloc: Allocator, io: Io, home: ?[]const u8, cwd: []const u8, input: []const u8) ResolveError![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return error.Empty;
    const expanded = try expandHome(alloc, home, trimmed);
    defer alloc.free(expanded);
    const absolute = if (std.fs.path.isAbsolute(expanded))
        try alloc.dupe(u8, expanded)
    else
        try std.fs.path.join(alloc, &.{ cwd, expanded });
    defer alloc.free(absolute);
    if (!std.fs.path.isAbsolute(absolute)) return error.NotFound;
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = Io.Dir.realPathFileAbsolute(io, absolute, &buf) catch return error.NotFound;
    return try alloc.dupe(u8, buf[0..n]);
}

fn expandHome(alloc: Allocator, home: ?[]const u8, input: []const u8) ResolveError![]u8 {
    if (input.len == 0 or input[0] != '~') return try alloc.dupe(u8, input);
    if (input.len > 1 and input[1] != '/') return error.NoHome;
    const dir = home orelse return error.NoHome;
    if (dir.len == 0) return error.NoHome;
    if (input.len == 1) return try alloc.dupe(u8, dir);
    return try std.fs.path.join(alloc, &.{ dir, input[2..] });
}

/// Real path when `input` names an existing directory. Null when it does
/// not: missing, a file, empty, or `~user`. `cwd` is the process directory.
pub fn directoryArg(
    alloc: Allocator,
    io: Io,
    home: ?[]const u8,
    cwd: []const u8,
    input: []const u8,
) Allocator.Error!?[]u8 {
    const path = resolve(alloc, io, home, cwd, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var dir = Io.Dir.openDirAbsolute(io, path, .{}) catch {
        alloc.free(path);
        return null;
    };
    dir.close(io);
    return path;
}

/// Directories matching the text before the caret. `text` is set only for
/// `~`, which becomes `~/`. Otherwise `head` is the typed directory prefix
/// (`sub/`, `~/`, or empty) and `names` are the matching directory names,
/// sorted. Names do not include a trailing slash. An empty `names` leaves
/// the typed text unchanged.
pub const PathMatches = struct {
    text: ?[]u8 = null,
    head: []u8,
    names: [][]u8,

    pub fn deinit(self: *PathMatches, alloc: Allocator) void {
        if (self.text) |text| alloc.free(text);
        alloc.free(self.head);
        freeNames(alloc, self.names);
        self.* = undefined;
    }
};

/// Directory matches for `input` (the text before the caret). The typed
/// `~/` form is kept. Relative heads resolve against `cwd`, the process
/// directory. Names that start with `.` are skipped unless the partial does
/// too. A missing directory, a file, or `~user` yields no names.
pub fn completePath(
    alloc: Allocator,
    io: Io,
    home: ?[]const u8,
    cwd: []const u8,
    input: []const u8,
) Allocator.Error!PathMatches {
    // `~` alone is the home prefix. The next Tab cycles that directory.
    if (std.mem.eql(u8, input, "~")) return bare(alloc, "~/");
    // `~user` is not expanded.
    if (input.len > 1 and input[0] == '~' and input[1] != '/') return bare(alloc, null);

    const slash = std.mem.lastIndexOfScalar(u8, input, '/');
    const head = if (slash) |i| input[0 .. i + 1] else "";
    const partial = if (slash) |i| input[i + 1 ..] else input;

    // Open the directory the typed head names. Keep that head in the result.
    const dir_path = (try directoryToList(alloc, home, cwd, head)) orelse return bare(alloc, null);
    defer alloc.free(dir_path);

    const names = matchingNames(alloc, io, dir_path, partial) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unavailable => return bare(alloc, null),
    };
    errdefer freeNames(alloc, names);
    return .{ .head = try alloc.dupe(u8, head), .names = names };
}

fn bare(alloc: Allocator, text: ?[]const u8) Allocator.Error!PathMatches {
    const owned = if (text) |t| try alloc.dupe(u8, t) else null;
    errdefer if (owned) |t| alloc.free(t);
    const head = try alloc.dupe(u8, "");
    errdefer alloc.free(head);
    return .{ .text = owned, .head = head, .names = try alloc.alloc([]u8, 0) };
}

fn freeNames(alloc: Allocator, names: [][]u8) void {
    for (names) |name| alloc.free(name);
    alloc.free(names);
}

/// Absolute directory named by `head`, or null when it cannot be formed.
/// `head` is empty or ends with `/`. The typed text is not rewritten here.
fn directoryToList(alloc: Allocator, home: ?[]const u8, cwd: []const u8, head: []const u8) Allocator.Error!?[]u8 {
    if (head.len == 0) {
        if (!std.fs.path.isAbsolute(cwd)) return null;
        return try alloc.dupe(u8, cwd);
    }
    const body = if (head.len > 1 and head[head.len - 1] == '/') head[0 .. head.len - 1] else head;
    const owned = if (head[0] == '~') blk: {
        const dir = home orelse return null;
        if (dir.len == 0) return null;
        if (body.len == 1) break :blk try alloc.dupe(u8, dir);
        break :blk try std.fs.path.join(alloc, &.{ dir, body[2..] });
    } else if (std.fs.path.isAbsolute(head)) blk: {
        break :blk try alloc.dupe(u8, if (body.len == 0) "/" else body);
    } else blk: {
        break :blk try std.fs.path.join(alloc, &.{ cwd, body });
    };
    if (!std.fs.path.isAbsolute(owned)) {
        alloc.free(owned);
        return null;
    }
    return owned;
}

const MatchError = Allocator.Error || error{Unavailable};

fn matchingNames(alloc: Allocator, io: Io, dir_path: []const u8, partial: []const u8) MatchError![][]u8 {
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return error.Unavailable;
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    const hide_dot = partial.len == 0 or partial[0] != '.';
    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch return error.Unavailable;
        const item = entry orelse break;
        if (hide_dot and item.name.len > 0 and item.name[0] == '.') continue;
        if (!std.mem.startsWith(u8, item.name, partial)) continue;
        if (!entryIsDir(io, dir, item)) continue;
        const owned = try alloc.dupe(u8, item.name);
        names.append(alloc, owned) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
    // Every directory has `.` and `..`. Iteration may omit them.
    if (partial.len > 0 and partial[0] == '.') {
        const dots = [_][]const u8{ ".", ".." };
        for (dots) |dot| {
            if (!std.mem.startsWith(u8, dot, partial)) continue;
            var seen = false;
            for (names.items) |have| {
                if (std.mem.eql(u8, have, dot)) seen = true;
            }
            if (seen) continue;
            const owned = try alloc.dupe(u8, dot);
            names.append(alloc, owned) catch |err| {
                alloc.free(owned);
                return err;
            };
        }
    }
    std.mem.sort([]u8, names.items, {}, nameBefore);
    return try names.toOwnedSlice(alloc);
}

fn nameBefore(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn entryIsDir(io: Io, parent: Io.Dir, entry: Io.Dir.Entry) bool {
    if (entry.kind == .directory) return true;
    if (entry.kind != .sym_link and entry.kind != .unknown) return false;
    var child = parent.openDir(io, entry.name, .{}) catch return false;
    child.close(io);
    return true;
}

/// True when `path` exists and `git rev-parse --is-inside-work-tree` is true.
/// A missing path is false.
pub fn isWorkTree(alloc: Allocator, io: Io, path: []const u8) Allocator.Error!bool {
    const dir = Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    defer dir.close(io);
    return git.isWorkTree(alloc, io, .{ .dir = dir }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
}

const testing = std.testing;
const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

fn expectPaths(list: *const List, want: []const []const u8) !void {
    try testing.expectEqual(want.len, list.paths.items.len);
    for (want, list.paths.items) |w, got| try testing.expectEqualStrings(w, got);
}

test "parse skips blanks and comments and ignores a current path that is not listed" {
    const alloc = testing.allocator;
    var list = try parse(alloc,
        \\# note
        \\
        \\current /missing
        \\/a
        \\  /b  
        \\/a
        \\relative
        \\
    );
    defer list.deinit(alloc);
    try expectPaths(&list, &.{ "/a", "/b" });
    try testing.expect(list.current == null);
}

test "the first current line wins and does not move the path" {
    const alloc = testing.allocator;
    var list = try parse(alloc,
        \\current /b
        \\/a
        \\/b
        \\current /a
        \\
    );
    defer list.deinit(alloc);
    try expectPaths(&list, &.{ "/a", "/b" });
    try testing.expectEqual(1, list.current.?);
}

test "add appends and dedupes; remove keeps order; current does not reorder" {
    const alloc = testing.allocator;
    var list: List = .{};
    defer list.deinit(alloc);
    try testing.expect(try list.append(alloc, "/a"));
    try testing.expect(try list.append(alloc, "/b"));
    try testing.expect(!try list.append(alloc, "/a"));
    try expectPaths(&list, &.{ "/a", "/b" });

    try testing.expect(list.setCurrent(1));
    try testing.expect(!list.setCurrent(1));
    try expectPaths(&list, &.{ "/a", "/b" });
    try testing.expectEqual(1, list.current.?);

    list.remove(alloc, 0);
    try expectPaths(&list, &.{"/b"});
    try testing.expectEqual(0, list.current.?);

    try testing.expect(try list.append(alloc, "/c"));
    try expectPaths(&list, &.{ "/b", "/c" });
    try testing.expectEqual(0, list.current.?);

    list.remove(alloc, 0);
    try expectPaths(&list, &.{"/c"});
    try testing.expect(list.current == null);
}

test "format writes current then the paths, and save round-trips" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var list: List = .{};
    defer list.deinit(alloc);
    try testing.expect(try list.append(alloc, "/a"));
    try testing.expect(try list.append(alloc, "/b"));
    try testing.expect(list.setCurrent(1));

    const text = try format(&list, alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("current /b\n/a\n/b\n", text);

    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const path = try std.fs.path.join(alloc, &.{ tmp.path, "projects" });
    defer alloc.free(path);
    try save(&list, alloc, io, path);
    var loaded = try load(alloc, io, path);
    defer loaded.deinit(alloc);
    try expectPaths(&loaded, &.{ "/a", "/b" });
    try testing.expectEqual(1, loaded.current.?);

    // A missing file is empty and does not create the file.
    const missing = try std.fs.path.join(alloc, &.{ tmp.path, "nope" });
    defer alloc.free(missing);
    var empty = try load(alloc, io, missing);
    defer empty.deinit(alloc);
    try testing.expectEqual(0, empty.paths.items.len);
    try testing.expect(empty.current == null);
}

test "launch choice does not reorder" {
    const alloc = testing.allocator;
    var list = try parse(alloc, "current /b\n/a\n/b\n/c\n");
    defer list.deinit(alloc);

    switch (launchChoice(&list, true, "/a", &.{ true, true, false })) {
        .cwd => |idx| try testing.expectEqual(0, idx.?),
        else => return error.TestUnexpectedResult,
    }
    switch (launchChoice(&list, false, "/nowhere", &.{ false, true, false })) {
        .saved => |idx| try testing.expectEqual(1, idx),
        else => return error.TestUnexpectedResult,
    }
    switch (launchChoice(&list, false, "/nowhere", &.{ true, false, false })) {
        .saved => |idx| try testing.expectEqual(0, idx),
        else => return error.TestUnexpectedResult,
    }
    switch (launchChoice(&list, false, "/nowhere", &.{ false, false, false })) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
    try expectPaths(&list, &.{ "/a", "/b", "/c" });
    try testing.expectEqual(1, list.current.?);
    try testing.expect(list.setCurrent(0));
    try expectPaths(&list, &.{ "/a", "/b", "/c" });
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

test "resolve expands ~ and a relative path; a plain directory is not a work tree" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    var other = try IsolatedTmp.init(alloc, io);
    defer other.deinit(alloc, io);
    try tmp.dir.createDirPath(io, "sub");

    try testing.expect(!try isWorkTree(alloc, io, tmp.path));

    const rel = try resolve(alloc, io, null, tmp.path, "sub");
    defer alloc.free(rel);
    const tilde = try resolve(alloc, io, tmp.path, other.path, "~/sub");
    defer alloc.free(tilde);
    const abs = try resolve(alloc, io, null, other.path, rel);
    defer alloc.free(abs);
    try testing.expectEqualStrings(rel, tilde);
    try testing.expectEqualStrings(rel, abs);
    try testing.expect(std.mem.startsWith(u8, rel, tmp.path));

    try testing.expectError(error.NotFound, resolve(alloc, io, tmp.path, tmp.path, "missing"));
    try testing.expectError(error.Empty, resolve(alloc, io, tmp.path, tmp.path, "  "));
    try testing.expectError(error.NoHome, resolve(alloc, io, null, tmp.path, "~/sub"));

    try expectGitOk(io, tmp.cwd(), &.{ "git", "init", "-b", "main" });
    try testing.expect(try isWorkTree(alloc, io, tmp.path));
    try testing.expect(!try isWorkTree(alloc, io, other.path));
}

fn expectMatches(got: PathMatches, head: []const u8, names: []const []const u8) !void {
    try testing.expect(got.text == null);
    try testing.expectEqualStrings(head, got.head);
    try testing.expectEqual(names.len, got.names.len);
    for (names, got.names) |want, name| try testing.expectEqualStrings(want, name);
}

fn expectNone(got: PathMatches) !void {
    try testing.expect(got.text == null);
    try testing.expectEqual(0, got.names.len);
}

test "tab completion lists directories and keeps the typed prefix" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try tmp.dir.createDirPath(io, "aaa");
    try tmp.dir.createDirPath(io, "aab");
    try tmp.dir.createDirPath(io, "sub/only");
    try tmp.dir.createDirPath(io, ".hidden");
    try tmp.dir.createDirPath(io, "nested");
    try tmp.write(io, "file.txt", "x");

    var one = try completePath(alloc, io, null, tmp.path, "sub/o");
    defer one.deinit(alloc);
    try expectMatches(one, "sub/", &.{"only"});

    var full = try completePath(alloc, io, null, tmp.path, "sub/only");
    defer full.deinit(alloc);
    try expectMatches(full, "sub/", &.{"only"});

    var shared = try completePath(alloc, io, null, tmp.path, "a");
    defer shared.deinit(alloc);
    try expectMatches(shared, "", &.{ "aaa", "aab" });

    var both = try completePath(alloc, io, null, tmp.path, "aa");
    defer both.deinit(alloc);
    try expectMatches(both, "", &.{ "aaa", "aab" });

    var tilde = try completePath(alloc, io, tmp.path, tmp.path, "~");
    defer tilde.deinit(alloc);
    try testing.expectEqualStrings("~/", tilde.text.?);
    try testing.expectEqual(0, tilde.names.len);

    var home_one = try completePath(alloc, io, tmp.path, "/tmp", "~/sub/o");
    defer home_one.deinit(alloc);
    try expectMatches(home_one, "~/sub/", &.{"only"});

    var file = try completePath(alloc, io, null, tmp.path, "file");
    defer file.deinit(alloc);
    try expectNone(file);

    var missing = try completePath(alloc, io, null, tmp.path, "missing/x");
    defer missing.deinit(alloc);
    try expectNone(missing);

    var user = try completePath(alloc, io, tmp.path, tmp.path, "~zooce");
    defer user.deinit(alloc);
    try expectNone(user);

    var hidden = try completePath(alloc, io, null, tmp.path, ".h");
    defer hidden.deinit(alloc);
    try expectMatches(hidden, "", &.{".hidden"});

    var dotdot = try completePath(alloc, io, null, tmp.path, "..");
    defer dotdot.deinit(alloc);
    try expectMatches(dotdot, "", &.{".."});

    const child = try std.fs.path.join(alloc, &.{ tmp.path, "nested" });
    defer alloc.free(child);
    var parent = try completePath(alloc, io, null, child, "../sub/o");
    defer parent.deinit(alloc);
    try expectMatches(parent, "../sub/", &.{"only"});

    var empty = try completePath(alloc, io, null, tmp.path, "");
    defer empty.deinit(alloc);
    try expectMatches(empty, "", &.{ "aaa", "aab", "nested", "sub" });
}

test "a directory argument is the real path; a file is not" {
    if (builtin.os.tag == .wasi) return;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.createDirPath(io, "nested");
    try tmp.write(io, "file.txt", "x");

    const dir = try directoryArg(alloc, io, null, tmp.path, "sub");
    defer if (dir) |p| alloc.free(p);
    const want = try std.fs.path.join(alloc, &.{ tmp.path, "sub" });
    defer alloc.free(want);
    try testing.expectEqualStrings(want, dir.?);

    const child = try std.fs.path.join(alloc, &.{ tmp.path, "nested" });
    defer alloc.free(child);
    const via = try directoryArg(alloc, io, null, child, "../sub");
    defer if (via) |p| alloc.free(p);
    try testing.expectEqualStrings(want, via.?);

    const home = try directoryArg(alloc, io, tmp.path, child, "~/sub");
    defer if (home) |p| alloc.free(p);
    try testing.expectEqualStrings(want, home.?);

    try testing.expect(try directoryArg(alloc, io, null, tmp.path, "file.txt") == null);
    try testing.expect(try directoryArg(alloc, io, null, tmp.path, "missing") == null);
    try testing.expect(try directoryArg(alloc, io, null, tmp.path, "  ") == null);
    try testing.expect(try directoryArg(alloc, io, null, tmp.path, "~zooce") == null);
}
