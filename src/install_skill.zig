//! Install / list / uninstall the bundled `rv` agent skill (MVP-2.5).
//! Canonical: `$HOME/.agents/skills/rv` → skill source.
//! Agent roots (`~/.grok/skills`, …) get `rv` → canonical when present.
//!
//! All output goes through injectable `Streams` (stdout/stderr) so tests can
//! capture with fixed writers (same pattern as goal's `TestEnv`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const skill_md = "SKILL.md";

pub const Opts = struct {
    list: bool = false,
    uninstall: bool = false,
    agent: ?[]const u8 = null,
};

/// stdout = status / list data; stderr = errors and usage.
pub const Streams = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};

const Agent = struct { name: []const u8, skills_rel: []const u8 };
const known = [_]Agent{
    .{ .name = "grok", .skills_rel = ".grok/skills" },
    .{ .name = "claude", .skills_rel = ".claude/skills" },
    .{ .name = "codex", .skills_rel = ".codex/skills" },
    .{ .name = "cursor", .skills_rel = ".cursor/skills" },
};

pub fn run(
    alloc: Allocator,
    io: Io,
    opts: Opts,
    home: ?[]const u8,
    skill_override: ?[]const u8,
    streams: Streams,
) u8 {
    const h = home orelse return fail(streams, "HOME is not set");
    if (h.len == 0) return fail(streams, "HOME is empty");
    if (opts.list and opts.uninstall) return usage(streams, "use only one of --list or --uninstall");
    if (opts.agent) |n| {
        if (findAgent(n) == null) return usage(streams, "unknown agent (try: grok, claude, codex, cursor)");
    }
    if (opts.list) return cmdList(alloc, io, h, skill_override, opts.agent, streams);
    if (opts.uninstall) return cmdUninstall(alloc, io, h, opts.agent, streams);
    return cmdInstall(alloc, io, h, skill_override, opts.agent, streams);
}

fn findAgent(name: []const u8) ?Agent {
    for (known) |a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

fn homeJoin(alloc: Allocator, home: []const u8, rel: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(alloc, &.{ home, rel });
}

fn canonicalPath(alloc: Allocator, home: []const u8) Allocator.Error![]u8 {
    return homeJoin(alloc, home, ".agents/skills/rv");
}

fn agentSkills(alloc: Allocator, home: []const u8, a: Agent) Allocator.Error![]u8 {
    return homeJoin(alloc, home, a.skills_rel);
}

fn agentLink(alloc: Allocator, home: []const u8, a: Agent) Allocator.Error![]u8 {
    return std.fs.path.join(alloc, &.{ home, a.skills_rel, "rv" });
}

pub fn resolveSource(alloc: Allocator, io: Io, skill_override: ?[]const u8) Allocator.Error!?[]u8 {
    if (skill_override) |p| {
        if (p.len > 0) {
            const abs = try absPath(alloc, io, p);
            if (hasSkillMd(io, abs)) return abs;
            alloc.free(abs);
        }
    }
    if (std.process.executablePathAlloc(io, alloc)) |exe| {
        defer alloc.free(exe);
        if (std.fs.path.dirname(exe)) |bindir| {
            if (std.fs.path.dirname(bindir)) |prefix| {
                const cand = try std.fs.path.join(alloc, &.{ prefix, "share/rv/skills/rv" });
                if (hasSkillMd(io, cand)) return cand;
                alloc.free(cand);
            }
            const rel = try std.fs.path.join(alloc, &.{ bindir, "../../skills/rv" });
            const abs = try absPath(alloc, io, rel);
            alloc.free(rel);
            if (hasSkillMd(io, abs)) return abs;
            alloc.free(abs);
        }
    } else |_| {}
    const cwd_cand = try absPath(alloc, io, "skills/rv");
    if (hasSkillMd(io, cwd_cand)) return cwd_cand;
    alloc.free(cwd_cand);
    return null;
}

fn hasSkillMd(io: Io, dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, skill_md }) catch return false;
    Io.Dir.accessAbsolute(io, p, .{}) catch return false;
    return true;
}

fn absPath(alloc: Allocator, io: Io, p: []const u8) Allocator.Error![]u8 {
    if (std.fs.path.isAbsolute(p)) return try alloc.dupe(u8, p);
    const cwd = std.process.currentPathAlloc(io, alloc) catch return error.OutOfMemory;
    defer alloc.free(cwd);
    return std.fs.path.resolve(alloc, &.{ cwd, p }) catch return error.OutOfMemory;
}

fn exists(io: Io, p: []const u8) bool {
    Io.Dir.accessAbsolute(io, p, .{}) catch return false;
    return true;
}

fn isLink(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

fn ensureDirSymlink(io: Io, link: []const u8, target: []const u8) !void {
    if (isLink(io, link)) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (Io.Dir.readLinkAbsolute(io, link, &buf)) |n| {
            if (std.mem.eql(u8, buf[0..n], target)) return;
        } else |_| {}
        try Io.Dir.deleteFileAbsolute(io, link);
    } else if (exists(io, link)) return error.NotASymlink;
    if (std.fs.path.dirname(link)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.symLinkAbsolute(io, target, link, .{ .is_directory = true });
}

fn fail(s: Streams, msg: []const u8) u8 {
    s.err.print("rv: {s}\n", .{msg}) catch {};
    return 1;
}
fn usage(s: Streams, msg: []const u8) u8 {
    s.err.print("rv: {s}\n", .{msg}) catch {};
    return 2;
}
fn oom(s: Streams) u8 {
    return fail(s, "out of memory");
}
fn writeFail(s: Streams) u8 {
    return fail(s, "write failed");
}

fn cmdInstall(
    alloc: Allocator,
    io: Io,
    home: []const u8,
    skill_override: ?[]const u8,
    agent_filter: ?[]const u8,
    s: Streams,
) u8 {
    const source = (resolveSource(alloc, io, skill_override) catch return oom(s)) orelse
        return fail(s, "skill source not found (set RV_SKILL_DIR or install share/rv/skills/rv)");
    defer alloc.free(source);
    const canonical = canonicalPath(alloc, home) catch return oom(s);
    defer alloc.free(canonical);
    ensureDirSymlink(io, canonical, source) catch |err| {
        if (err == error.NotASymlink)
            return fail(s, "canonical path exists and is not a symlink; remove it and retry");
        return fail(s, "failed to install canonical skill");
    };
    s.out.print("canonical: {s} -> {s}\n", .{ canonical, source }) catch return writeFail(s);
    if (agent_filter) |name|
        return linkAgent(alloc, io, home, findAgent(name).?, canonical, true, s);
    for (known) |a| {
        const skills = agentSkills(alloc, home, a) catch return oom(s);
        defer alloc.free(skills);
        if (!exists(io, skills)) continue;
        const rc = linkAgent(alloc, io, home, a, canonical, false, s);
        if (rc != 0) return rc;
    }
    return 0;
}

fn linkAgent(
    alloc: Allocator,
    io: Io,
    home: []const u8,
    a: Agent,
    canonical: []const u8,
    create_root: bool,
    s: Streams,
) u8 {
    const skills = agentSkills(alloc, home, a) catch return oom(s);
    defer alloc.free(skills);
    if (!exists(io, skills)) {
        if (!create_root) return 0;
        Io.Dir.cwd().createDirPath(io, skills) catch return fail(s, "failed to create agent skills dir");
    }
    const link = agentLink(alloc, home, a) catch return oom(s);
    defer alloc.free(link);
    ensureDirSymlink(io, link, canonical) catch |err| {
        if (err == error.NotASymlink)
            return fail(s, "agent link exists and is not a symlink; remove it and retry");
        return fail(s, "failed to link agent skill");
    };
    s.out.print("agent {s}: {s} -> {s}\n", .{ a.name, link, canonical }) catch return writeFail(s);
    return 0;
}

fn cmdUninstall(alloc: Allocator, io: Io, home: []const u8, agent_filter: ?[]const u8, s: Streams) u8 {
    var failed: u8 = 0;
    if (agent_filter) |name| {
        const link = agentLink(alloc, home, findAgent(name).?) catch return oom(s);
        defer alloc.free(link);
        return dropLink(io, link, s);
    }
    for (known) |a| {
        const link = agentLink(alloc, home, a) catch return oom(s);
        defer alloc.free(link);
        const rc = dropLink(io, link, s);
        if (rc != 0) failed = rc;
    }
    const canonical = canonicalPath(alloc, home) catch return oom(s);
    defer alloc.free(canonical);
    const rc = dropLink(io, canonical, s);
    return if (rc != 0) rc else failed;
}

fn dropLink(io: Io, link: []const u8, s: Streams) u8 {
    if (!isLink(io, link)) {
        if (exists(io, link)) {
            s.err.print("rv: left {s} (not a symlink)\n", .{link}) catch {};
            return 1;
        }
        return 0;
    }
    Io.Dir.deleteFileAbsolute(io, link) catch return fail(s, "failed to remove skill link");
    s.out.print("removed: {s}\n", .{link}) catch return writeFail(s);
    return 0;
}

fn cmdList(
    alloc: Allocator,
    io: Io,
    home: []const u8,
    skill_override: ?[]const u8,
    agent_filter: ?[]const u8,
    s: Streams,
) u8 {
    if (resolveSource(alloc, io, skill_override) catch null) |source| {
        defer alloc.free(source);
        s.out.print("source: {s}\n", .{source}) catch return writeFail(s);
    } else {
        s.out.writeAll("source: (not found)\n") catch return writeFail(s);
    }
    const canonical = canonicalPath(alloc, home) catch return oom(s);
    defer alloc.free(canonical);
    printLink(io, s.out, "canonical", canonical) catch return writeFail(s);
    if (agent_filter) |name| {
        printAgent(alloc, io, home, findAgent(name).?, s.out) catch return writeFail(s);
    } else {
        for (known) |a| printAgent(alloc, io, home, a, s.out) catch return writeFail(s);
    }
    return 0;
}

fn printAgent(alloc: Allocator, io: Io, home: []const u8, a: Agent, out: *std.Io.Writer) !void {
    const skills = try agentSkills(alloc, home, a);
    defer alloc.free(skills);
    if (!exists(io, skills)) {
        try out.print("agent {s}: (skills root not present: {s})\n", .{ a.name, skills });
        return;
    }
    const link = try agentLink(alloc, home, a);
    defer alloc.free(link);
    var lb: [48]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "agent {s}", .{a.name}) catch "agent";
    try printLink(io, out, label, link);
}

fn printLink(io: Io, out: *std.Io.Writer, label: []const u8, path: []const u8) !void {
    if (isLink(io, path)) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (Io.Dir.readLinkAbsolute(io, path, &buf)) |n| {
            try out.print("{s}: {s} -> {s}\n", .{ label, path, buf[0..n] });
            return;
        } else |_| {}
    }
    if (exists(io, path))
        try out.print("{s}: {s} (not a symlink)\n", .{ label, path })
    else
        try out.print("{s}: {s} (missing)\n", .{ label, path });
}

const testing = std.testing;
const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

/// Fixed stdout/stderr buffers for unit tests (goal `TestEnv` pattern).
const Capture = struct {
    out_buf: [4096]u8 = undefined,
    err_buf: [1024]u8 = undefined,
    out: std.Io.Writer = undefined,
    err: std.Io.Writer = undefined,

    fn init(self: *Capture) Streams {
        self.out = .fixed(&self.out_buf);
        self.err = .fixed(&self.err_buf);
        return .{ .out = &self.out, .err = &self.err };
    }
    fn stdout(self: *const Capture) []const u8 {
        return self.out.buffered();
    }
    fn stderr(self: *const Capture) []const u8 {
        return self.err.buffered();
    }
    fn resetOut(self: *Capture) void {
        _ = self.out.consumeAll();
    }
    fn resetErr(self: *Capture) void {
        _ = self.err.consumeAll();
    }
};

test "install list uninstall: stdout capture and fs roundtrip" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;

    var home_tmp = try IsolatedTmp.init(alloc, io);
    defer home_tmp.deinit(alloc, io);
    var src_tmp = try IsolatedTmp.init(alloc, io);
    defer src_tmp.deinit(alloc, io);
    try src_tmp.write(io, skill_md, "# rv\n");

    const grok = try homeJoin(alloc, home_tmp.path, ".grok/skills");
    defer alloc.free(grok);
    try Io.Dir.cwd().createDirPath(io, grok);

    const home = home_tmp.path;
    const src = src_tmp.path;
    const canonical = try canonicalPath(alloc, home);
    defer alloc.free(canonical);
    const gl = try agentLink(alloc, home, known[0]);
    defer alloc.free(gl);

    var cap: Capture = .{};
    const streams = cap.init();

    // install
    try testing.expectEqual(0, run(alloc, io, .{}, home, src, streams));
    try testing.expect(isLink(io, canonical));
    try testing.expect(isLink(io, gl));
    const install_out = try std.fmt.allocPrint(alloc, "canonical: {s} -> {s}\nagent grok: {s} -> {s}\n", .{
        canonical, src, gl, canonical,
    });
    defer alloc.free(install_out);
    try testing.expectEqualStrings(install_out, cap.stdout());
    try testing.expectEqualStrings("", cap.stderr());
    cap.resetOut();

    // idempotent re-run
    try testing.expectEqual(0, run(alloc, io, .{}, home, src, streams));
    try testing.expectEqualStrings(install_out, cap.stdout());
    try testing.expectEqualStrings("", cap.stderr());
    cap.resetOut();

    // list
    try testing.expectEqual(0, run(alloc, io, .{ .list = true }, home, src, streams));
    const list_out = try std.fmt.allocPrint(alloc,
        \\source: {s}
        \\canonical: {s} -> {s}
        \\agent grok: {s} -> {s}
        \\agent claude: (skills root not present: {s}/.claude/skills)
        \\agent codex: (skills root not present: {s}/.codex/skills)
        \\agent cursor: (skills root not present: {s}/.cursor/skills)
        \\
    , .{ src, canonical, src, gl, canonical, home, home, home });
    defer alloc.free(list_out);
    try testing.expectEqualStrings(list_out, cap.stdout());
    try testing.expectEqualStrings("", cap.stderr());
    cap.resetOut();

    // uninstall
    try testing.expectEqual(0, run(alloc, io, .{ .uninstall = true }, home, null, streams));
    try testing.expect(!exists(io, canonical));
    try testing.expect(!isLink(io, gl));
    const un_out = try std.fmt.allocPrint(alloc, "removed: {s}\nremoved: {s}\n", .{ gl, canonical });
    defer alloc.free(un_out);
    try testing.expectEqualStrings(un_out, cap.stdout());
    try testing.expectEqualStrings("", cap.stderr());
}

test "unknown agent writes usage to stderr" {
    var cap: Capture = .{};
    const streams = cap.init();
    try testing.expectEqual(2, run(
        testing.allocator,
        testing.io,
        .{ .agent = "nope" },
        "/tmp",
        null,
        streams,
    ));
    try testing.expectEqualStrings("", cap.stdout());
    try testing.expectEqualStrings("rv: unknown agent (try: grok, claude, codex, cursor)\n", cap.stderr());
}
