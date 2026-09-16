//! Install / uninstall the bundled `rv` agent skill.
//! Copy `SKILL.md` to `$HOME/.agents/skills/rv/`. Agent skill roots that
//! already exist (`~/.grok/skills`, …) get `rv` → that directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const skill_file = "SKILL.md";
const skill_bytes = @import("skill_bytes").bytes;
const canonical_rel = ".agents/skills/rv";

const agents = [_]struct { name: []const u8, rel: []const u8 }{
    .{ .name = "grok", .rel = ".grok/skills/rv" },
    .{ .name = "claude", .rel = ".claude/skills/rv" },
    .{ .name = "codex", .rel = ".codex/skills/rv" },
    .{ .name = "cursor", .rel = ".cursor/skills/rv" },
};

pub const Opts = struct {
    uninstall: bool = false,
};

pub fn run(
    alloc: Allocator,
    io: Io,
    opts: Opts,
    home: ?[]const u8,
    out: *std.Io.Writer,
    err_w: *std.Io.Writer,
) u8 {
    const h = home orelse return fail(err_w, "HOME is not set");
    if (h.len == 0) return fail(err_w, "HOME is empty");
    if (opts.uninstall) return cmdUninstall(alloc, io, h, out, err_w);
    return cmdInstall(alloc, io, h, out, err_w);
}

fn fail(err_w: *std.Io.Writer, msg: []const u8) u8 {
    err_w.print("rv: {s}\n", .{msg}) catch {};
    return 1;
}

fn cmdInstall(alloc: Allocator, io: Io, home: []const u8, out: *std.Io.Writer, err_w: *std.Io.Writer) u8 {
    const canonical = std.fs.path.join(alloc, &.{ home, canonical_rel }) catch return fail(err_w, "out of memory");
    defer alloc.free(canonical);
    putDirFile(io, canonical, skill_bytes) catch |e| switch (e) {
        error.NotADirectory => return fail(err_w, "canonical path exists and is not a directory; remove it and retry"),
        else => return fail(err_w, "failed to install canonical skill"),
    };
    out.print("canonical: {s}\n", .{canonical}) catch return fail(err_w, "write failed");

    for (agents) |a| {
        const link = std.fs.path.join(alloc, &.{ home, a.rel }) catch return fail(err_w, "out of memory");
        defer alloc.free(link);
        const linked = putLink(io, link, canonical) catch |e| switch (e) {
            error.NotASymlink => return fail(err_w, "agent link exists and is not a symlink; remove it and retry"),
            else => return fail(err_w, "failed to link agent skill"),
        };
        if (linked) {
            out.print("agent {s}: {s} -> {s}\n", .{ a.name, link, canonical }) catch return fail(err_w, "write failed");
        }
    }
    return 0;
}

fn cmdUninstall(alloc: Allocator, io: Io, home: []const u8, out: *std.Io.Writer, err_w: *std.Io.Writer) u8 {
    var failed: u8 = 0;
    for (agents) |a| {
        const link = std.fs.path.join(alloc, &.{ home, a.rel }) catch return fail(err_w, "out of memory");
        defer alloc.free(link);
        const rc = dropLink(io, link, out, err_w);
        if (rc != 0) failed = rc;
    }
    const canonical = std.fs.path.join(alloc, &.{ home, canonical_rel }) catch return fail(err_w, "out of memory");
    defer alloc.free(canonical);
    const rc = dropCanonical(io, canonical, out, err_w);
    return if (rc != 0) rc else failed;
}

/// Write `SKILL.md` into `dir_path`, replacing an old directory symlink.
fn putDirFile(io: Io, dir_path: []const u8, contents: []const u8) !void {
    const parent = std.fs.path.dirname(dir_path) orelse return error.NotADirectory;
    Io.Dir.accessAbsolute(io, parent, .{}) catch {
        try Io.Dir.cwd().createDirPath(io, parent);
    };

    const st = Io.Dir.cwd().statFile(io, dir_path, .{ .follow_symlinks = false }) catch null;
    if (st) |s| switch (s.kind) {
        .sym_link => {
            try Io.Dir.deleteFileAbsolute(io, dir_path);
            try Io.Dir.createDirAbsolute(io, dir_path, .default_dir);
        },
        .directory => {},
        else => return error.NotADirectory,
    } else {
        try Io.Dir.createDirAbsolute(io, dir_path, .default_dir);
    }

    var d = try Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = skill_file, .data = contents });
}

/// Symlink `link` → `target` when the parent exists. False = parent missing.
fn putLink(io: Io, link: []const u8, target: []const u8) !bool {
    const parent = std.fs.path.dirname(link) orelse return error.NotASymlink;
    Io.Dir.accessAbsolute(io, parent, .{}) catch return false;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (Io.Dir.readLinkAbsolute(io, link, &buf)) |n| {
        if (std.mem.eql(u8, buf[0..n], target)) return true;
        try Io.Dir.deleteFileAbsolute(io, link);
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return error.NotASymlink,
    }
    try Io.Dir.symLinkAbsolute(io, target, link, .{ .is_directory = true });
    return true;
}

fn dropLink(io: Io, link: []const u8, out: *std.Io.Writer, err_w: *std.Io.Writer) u8 {
    const st = Io.Dir.cwd().statFile(io, link, .{ .follow_symlinks = false }) catch return 0;
    if (st.kind != .sym_link) {
        err_w.print("rv: left {s} (not a symlink)\n", .{link}) catch {};
        return 1;
    }
    Io.Dir.deleteFileAbsolute(io, link) catch return fail(err_w, "failed to remove skill link");
    out.print("removed: {s}\n", .{link}) catch return fail(err_w, "write failed");
    return 0;
}

fn dropCanonical(io: Io, dir_path: []const u8, out: *std.Io.Writer, err_w: *std.Io.Writer) u8 {
    const st = Io.Dir.cwd().statFile(io, dir_path, .{ .follow_symlinks = false }) catch return 0;
    if (st.kind == .sym_link) {
        Io.Dir.deleteFileAbsolute(io, dir_path) catch return fail(err_w, "failed to remove skill link");
        out.print("removed: {s}\n", .{dir_path}) catch return fail(err_w, "write failed");
        return 0;
    }
    if (st.kind != .directory) {
        err_w.print("rv: left {s} (not a directory)\n", .{dir_path}) catch {};
        return 1;
    }
    {
        var d = Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return fail(err_w, "failed to remove skill");
        defer d.close(io);
        d.deleteFile(io, skill_file) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return fail(err_w, "failed to remove skill"),
        };
    }
    Io.Dir.deleteDirAbsolute(io, dir_path) catch |e| switch (e) {
        error.DirNotEmpty => {},
        else => return fail(err_w, "failed to remove skill"),
    };
    out.print("removed: {s}\n", .{dir_path}) catch return fail(err_w, "write failed");
    return 0;
}

const testing = std.testing;
const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

const t = if (builtin.is_test) struct {
    fn writers(out_buf: *[4096]u8, err_buf: *[1024]u8) struct { out: std.Io.Writer, err_w: std.Io.Writer } {
        return .{ .out = .fixed(out_buf), .err_w = .fixed(err_buf) };
    }

    fn entryKind(io: Io, p: []const u8) ?Io.File.Kind {
        const st = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return null;
        return st.kind;
    }

    fn readSkill(alloc: Allocator, io: Io, dir_path: []const u8) ![]u8 {
        var d = try Io.Dir.openDirAbsolute(io, dir_path, .{});
        defer d.close(io);
        return d.readFileAlloc(io, skill_file, alloc, .limited(1 << 20));
    }
} else void;

test "install copies SKILL.md, links existing agent, uninstalls" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;

    var home_tmp = try IsolatedTmp.init(alloc, io);
    defer home_tmp.deinit(alloc, io);
    const home = home_tmp.path;

    const grok_skills = try std.fs.path.join(alloc, &.{ home, ".grok/skills" });
    defer alloc.free(grok_skills);
    try Io.Dir.cwd().createDirPath(io, grok_skills);

    const canonical = try std.fs.path.join(alloc, &.{ home, canonical_rel });
    defer alloc.free(canonical);
    const gl = try std.fs.path.join(alloc, &.{ home, agents[0].rel });
    defer alloc.free(gl);

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var w = t.writers(&out_buf, &err_buf);

    try testing.expectEqual(0, run(alloc, io, .{}, home, &w.out, &w.err_w));
    try testing.expectEqual(.directory, t.entryKind(io, canonical).?);
    const got = try t.readSkill(alloc, io, canonical);
    defer alloc.free(got);
    try testing.expectEqualStrings(skill_bytes, got);
    try testing.expectEqual(.sym_link, t.entryKind(io, gl).?);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.readLinkAbsolute(io, gl, &buf);
    try testing.expectEqualStrings(canonical, buf[0..n]);
    const claude = try std.fs.path.join(alloc, &.{ home, ".claude/skills/rv" });
    defer alloc.free(claude);
    try testing.expect(t.entryKind(io, claude) == null);

    // idempotent re-run
    w = t.writers(&out_buf, &err_buf);
    try testing.expectEqual(0, run(alloc, io, .{}, home, &w.out, &w.err_w));
    try testing.expectEqual(.directory, t.entryKind(io, canonical).?);
    try testing.expectEqual(.sym_link, t.entryKind(io, gl).?);

    w = t.writers(&out_buf, &err_buf);
    try testing.expectEqual(0, run(alloc, io, .{ .uninstall = true }, home, &w.out, &w.err_w));
    try testing.expect(t.entryKind(io, canonical) == null);
    try testing.expect(t.entryKind(io, gl) == null);
}

test "agent skills dir that is a symlink still receives rv" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;

    var home_tmp = try IsolatedTmp.init(alloc, io);
    defer home_tmp.deinit(alloc, io);
    var skills_tmp = try IsolatedTmp.init(alloc, io);
    defer skills_tmp.deinit(alloc, io);

    const grok_parent = try std.fs.path.join(alloc, &.{ home_tmp.path, ".grok" });
    defer alloc.free(grok_parent);
    try Io.Dir.cwd().createDirPath(io, grok_parent);
    const grok = try std.fs.path.join(alloc, &.{ home_tmp.path, ".grok/skills" });
    defer alloc.free(grok);
    try Io.Dir.symLinkAbsolute(io, skills_tmp.path, grok, .{ .is_directory = true });

    const canonical = try std.fs.path.join(alloc, &.{ home_tmp.path, canonical_rel });
    defer alloc.free(canonical);
    const gl = try std.fs.path.join(alloc, &.{ home_tmp.path, agents[0].rel });
    defer alloc.free(gl);
    const in_target = try std.fs.path.join(alloc, &.{ skills_tmp.path, "rv" });
    defer alloc.free(in_target);

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var w = t.writers(&out_buf, &err_buf);

    try testing.expectEqual(0, run(alloc, io, .{}, home_tmp.path, &w.out, &w.err_w));
    try testing.expectEqual(.sym_link, t.entryKind(io, gl).?);
    try testing.expectEqual(.sym_link, t.entryKind(io, in_target).?);
    try testing.expectEqual(.directory, t.entryKind(io, canonical).?);
}

test "old canonical symlink is replaced by a directory copy" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;

    var home_tmp = try IsolatedTmp.init(alloc, io);
    defer home_tmp.deinit(alloc, io);
    var old_tmp = try IsolatedTmp.init(alloc, io);
    defer old_tmp.deinit(alloc, io);

    const parent = try std.fs.path.join(alloc, &.{ home_tmp.path, ".agents/skills" });
    defer alloc.free(parent);
    try Io.Dir.cwd().createDirPath(io, parent);
    const canonical = try std.fs.path.join(alloc, &.{ home_tmp.path, canonical_rel });
    defer alloc.free(canonical);
    try Io.Dir.symLinkAbsolute(io, old_tmp.path, canonical, .{ .is_directory = true });

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var w = t.writers(&out_buf, &err_buf);

    try testing.expectEqual(0, run(alloc, io, .{}, home_tmp.path, &w.out, &w.err_w));
    try testing.expectEqual(.directory, t.entryKind(io, canonical).?);
    const got = try t.readSkill(alloc, io, canonical);
    defer alloc.free(got);
    try testing.expectEqualStrings(skill_bytes, got);
}

test "HOME unset writes to stderr" {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var w = t.writers(&out_buf, &err_buf);
    try testing.expectEqual(1, run(testing.allocator, testing.io, .{}, null, &w.out, &w.err_w));
    try testing.expectEqualStrings("rv: HOME is not set\n", w.err_w.buffered());
}
