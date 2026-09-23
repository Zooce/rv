//! Git word-diff spans for one file's porcelain output.
//!
//! `git diff --word-diff=porcelain` common runs are bytes from the new side
//! (whitespace between words is not itself a change). `~` is a newline.
//! Delete runs are exact old-side bytes. `gitSpans` walks those runs onto
//! the old and new text and returns the changed byte ranges.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The porcelain runs do not walk `old_text` and `new_text`.
    AlignFailed,
    OutOfMemory,
};

/// Byte range `[start, end)` in one side's text. Newlines are not inside a span.
pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Side = enum { old, new };

pub const Which = enum { our_only, git_only };

/// One run of bytes that only one side marked as changed.
/// `text` borrows from the side text passed to `compareMarks`.
pub const Mismatch = struct {
    path: []const u8,
    hunk: usize,
    side: Side,
    /// 0-based line within that side's text.
    line: usize,
    /// Byte offset of `text` within that line.
    column: usize,
    kind: Which,
    text: []const u8,
};

/// Changed ranges from porcelain, as offsets into the caller's old and new text.
pub const GitSpans = struct {
    old: []Span,
    new: []Span,

    pub fn deinit(self: GitSpans, alloc: Allocator) void {
        alloc.free(self.old);
        alloc.free(self.new);
    }
};

/// Old and new text of one side, with git's spans and ours.
pub const SideMarks = struct {
    text: []const u8,
    git: []const Span,
    our: []const Span,
};

/// Our spans for one hunk. An empty `mismatches` `our` slice means no spans yet.
pub const HunkMarks = struct {
    old: []const Span,
    new: []const Span,
};

/// Mismatch list for one file. `path` and each `text` live in `arena`.
pub const MismatchReport = struct {
    arena: std.heap.ArenaAllocator,
    items: []Mismatch,

    pub fn deinit(self: *MismatchReport) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const RunKind = enum { common, add, delete };

/// `old_text` / `new_text` are the bytes this porcelain walks, in order.
/// For a diff whose hunks cover the whole file, that is the file.
pub fn gitSpans(
    alloc: Allocator,
    porcelain: []const u8,
    old_text: []const u8,
    new_text: []const u8,
) Error!GitSpans {
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);
    var old_spans: std.ArrayList(Span) = .empty;
    errdefer old_spans.deinit(alloc);
    var new_spans: std.ArrayList(Span) = .empty;
    errdefer new_spans.deinit(alloc);

    var in_hunk = false;
    var oi: usize = 0;
    var prev: ?RunKind = null;
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    while (lines.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (!in_hunk) {
            if (std.mem.startsWith(u8, line, "@@")) in_hunk = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            in_hunk = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@") or line.len == 0 or line[0] == '\\') continue;

        if (std.mem.eql(u8, line, "~")) {
            // Newline in the run that preceded it. Context lines use the same `~`.
            if (prev) |p| {
                if (p == .common or p == .add) try new_buf.append(alloc, '\n');
            }
            if (oi < old_text.len and old_text[oi] == '\n') oi += 1;
            continue;
        }

        const kind: RunKind = switch (line[0]) {
            ' ' => .common,
            '+' => .add,
            '-' => .delete,
            else => continue,
        };
        const text = line[1..];
        switch (kind) {
            .common => {
                oi = consumeCommon(old_text, oi, text) orelse return error.AlignFailed;
                try new_buf.appendSlice(alloc, text);
            },
            .delete => {
                if (text.len == 0) {
                    prev = kind;
                    continue;
                }
                if (!std.mem.startsWith(u8, old_text[oi..], text)) return error.AlignFailed;
                try old_spans.append(alloc, .{ .start = oi, .end = oi + text.len });
                oi += text.len;
            },
            .add => {
                if (text.len == 0) {
                    prev = kind;
                    continue;
                }
                const start = new_buf.items.len;
                try new_buf.appendSlice(alloc, text);
                try new_spans.append(alloc, .{ .start = start, .end = start + text.len });
            },
        }
        prev = kind;
    }

    if (oi != old_text.len) return error.AlignFailed;
    const rebuilt = new_buf.items;
    const new_ok = std.mem.eql(u8, rebuilt, new_text) or
        (rebuilt.len == new_text.len + 1 and rebuilt[rebuilt.len - 1] == '\n' and
            std.mem.eql(u8, rebuilt[0..new_text.len], new_text));
    if (!new_ok) return error.AlignFailed;

    const old_owned = try old_spans.toOwnedSlice(alloc);
    errdefer alloc.free(old_owned);
    return .{
        .old = old_owned,
        .new = try new_spans.toOwnedSlice(alloc),
    };
}

/// Bytes git marked and we did not (`git_only`), and the reverse (`our_only`).
/// Runs stop at a newline. `path` and the side texts are borrowed by the result.
pub fn compareMarks(
    alloc: Allocator,
    path: []const u8,
    hunk: usize,
    old: SideMarks,
    new: SideMarks,
) Error![]Mismatch {
    var out: std.ArrayList(Mismatch) = .empty;
    errdefer out.deinit(alloc);
    try appendSide(alloc, &out, path, hunk, .old, old);
    try appendSide(alloc, &out, path, hunk, .new, new);
    return try out.toOwnedSlice(alloc);
}

fn appendSide(
    alloc: Allocator,
    out: *std.ArrayList(Mismatch),
    path: []const u8,
    hunk: usize,
    side: Side,
    marks: SideMarks,
) Error!void {
    const git_on = try alloc.alloc(bool, marks.text.len);
    defer alloc.free(git_on);
    const our_on = try alloc.alloc(bool, marks.text.len);
    defer alloc.free(our_on);
    @memset(git_on, false);
    @memset(our_on, false);
    try paint(marks.text, git_on, marks.git);
    try paint(marks.text, our_on, marks.our);

    var i: usize = 0;
    while (i < marks.text.len) {
        if (marks.text[i] == '\n' or git_on[i] == our_on[i]) {
            i += 1;
            continue;
        }
        const g = git_on[i];
        const o = our_on[i];
        const kind: Which = if (o) .our_only else .git_only;
        const start = i;
        i += 1;
        while (i < marks.text.len and marks.text[i] != '\n' and git_on[i] == g and our_on[i] == o) {
            i += 1;
        }
        const at = lineColumn(marks.text, start);
        try out.append(alloc, .{
            .path = path,
            .hunk = hunk,
            .side = side,
            .line = at.line,
            .column = at.column,
            .kind = kind,
            .text = marks.text[start..i],
        });
    }
}

fn paint(text: []const u8, on: []bool, spans: []const Span) Error!void {
    for (spans) |span| {
        if (span.start > span.end or span.end > text.len) return error.AlignFailed;
        @memset(on[span.start..span.end], true);
    }
}

fn lineColumn(text: []const u8, offset: usize) struct { line: usize, column: usize } {
    var line: usize = 0;
    var column: usize = 0;
    for (text[0..offset]) |c| {
        if (c == '\n') {
            line += 1;
            column = 0;
        } else column += 1;
    }
    return .{ .line = line, .column = column };
}

/// Advance `oi0` over `chunk`. Common porcelain text is the new side, so a
/// whitespace run may exist on only one side. Words themselves must match.
fn consumeCommon(old: []const u8, oi0: usize, chunk: []const u8) ?usize {
    var oi = oi0;
    var ci: usize = 0;
    while (ci < chunk.len) {
        if (oi < old.len and old[oi] == chunk[ci]) {
            oi += 1;
            ci += 1;
            continue;
        }
        if (isWordGap(chunk[ci])) {
            while (ci < chunk.len and isWordGap(chunk[ci])) ci += 1;
            while (oi < old.len and isWordGap(old[oi])) oi += 1;
            continue;
        }
        if (oi < old.len and isWordGap(old[oi])) {
            while (oi < old.len and isWordGap(old[oi])) oi += 1;
            continue;
        }
        return null;
    }
    return oi;
}

fn isWordGap(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

const Part = struct {
    /// Index into the hunk `lines` this slice came from.
    index: usize,
    /// Offset of `lines[index].text` inside the joined side text.
    start: usize,
    len: usize,
};

const SideBuild = struct {
    text: []u8,
    parts: []Part,

    fn deinit(self: SideBuild, alloc: Allocator) void {
        alloc.free(self.text);
        alloc.free(self.parts);
    }
};

/// Joined bytes of one side, plus where each included line sits in that buffer.
/// A meta line means the previous body line has no trailing newline.
fn buildSide(alloc: Allocator, lines: []const diff.Line, side: Side) Error!SideBuild {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var parts: std.ArrayList(Part) = .empty;
    errdefer parts.deinit(alloc);

    const Pending = struct { index: usize, text: []const u8 };
    var pending: ?Pending = null;
    for (lines, 0..) |line, i| {
        switch (line.kind) {
            .meta => if (pending) |p| {
                try appendPart(alloc, &buf, &parts, p.index, p.text, false);
                pending = null;
            },
            .context, .add, .delete => {
                if (pending) |p| {
                    try appendPart(alloc, &buf, &parts, p.index, p.text, true);
                    pending = null;
                }
                const include = switch (line.kind) {
                    .context => true,
                    .delete => side == .old,
                    .add => side == .new,
                    .meta => false,
                };
                if (include) pending = .{ .index = i, .text = line.text };
            },
        }
    }
    if (pending) |p| try appendPart(alloc, &buf, &parts, p.index, p.text, true);

    const text = try buf.toOwnedSlice(alloc);
    errdefer alloc.free(text);
    return .{
        .text = text,
        .parts = try parts.toOwnedSlice(alloc),
    };
}

fn appendPart(
    alloc: Allocator,
    buf: *std.ArrayList(u8),
    parts: *std.ArrayList(Part),
    index: usize,
    text: []const u8,
    newline: bool,
) Error!void {
    const start = buf.items.len;
    try buf.appendSlice(alloc, text);
    try parts.append(alloc, .{ .index = index, .start = start, .len = text.len });
    if (newline) try buf.append(alloc, '\n');
}

/// Changed bytes on one hunk line. Offsets are into `lines[index].text`.
pub const LineChange = struct {
    index: usize,
    spans: []Span,
};

/// Per-line spans for one hunk. Free with `LineChangeList.deinit`.
pub const LineChangeList = struct {
    items: []LineChange,

    pub fn deinit(self: LineChangeList, alloc: Allocator) void {
        for (self.items) |item| alloc.free(item.spans);
        alloc.free(self.items);
    }
};

/// Git's changed ranges on each add/delete line of this hunk.
/// `porcelain` is the file's word-diff output (one hunk, or a whole diff of one hunk).
/// Context lines and whitespace-only edits are omitted: git marks no words there.
/// A line git marks in full (a pure insert or delete) has one span over all of `text`.
pub fn lineChanges(alloc: Allocator, lines: []const diff.Line, porcelain: []const u8) Error!LineChangeList {
    const old = try buildSide(alloc, lines, .old);
    defer old.deinit(alloc);
    const new = try buildSide(alloc, lines, .new);
    defer new.deinit(alloc);
    const spans = try gitSpans(alloc, porcelain, old.text, new.text);
    defer spans.deinit(alloc);

    var items: std.ArrayList(LineChange) = .empty;
    errdefer {
        for (items.items) |item| alloc.free(item.spans);
        items.deinit(alloc);
    }
    for (lines, 0..) |_, i| {
        const from_old = try clipParts(alloc, spans.old, old.parts, i);
        defer alloc.free(from_old);
        const from_new = try clipParts(alloc, spans.new, new.parts, i);
        defer alloc.free(from_new);
        const chosen = if (from_old.len > 0) from_old else from_new;
        if (chosen.len == 0) continue;
        try items.append(alloc, .{ .index = i, .spans = try alloc.dupe(Span, chosen) });
    }
    return .{ .items = try items.toOwnedSlice(alloc) };
}

fn clipParts(alloc: Allocator, spans: []const Span, parts: []const Part, index: usize) Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(alloc);
    for (parts) |part| {
        if (part.index != index) continue;
        const end = part.start + part.len;
        for (spans) |span| {
            const lo = @max(span.start, part.start);
            const hi = @min(span.end, end);
            if (lo < hi) try out.append(alloc, .{ .start = lo - part.start, .end = hi - part.start });
        }
    }
    return try out.toOwnedSlice(alloc);
}

const Region = struct { start: usize, end: usize };

fn hunkRegion(porcelain: []const u8, from: usize) ?Region {
    const start = indexOfLine(porcelain, from, "@@") orelse return null;
    const next = indexOfLine(porcelain, start + 2, "@@");
    return .{ .start = start, .end = next orelse porcelain.len };
}

fn indexOfLine(text: []const u8, from: usize, prefix: []const u8) ?usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        const at_line = i == 0 or text[i - 1] == '\n';
        if (at_line and std.mem.startsWith(u8, text[i..], prefix)) return i;
    }
    return null;
}

/// Git spans for each hunk in `porcelain`, compared with `our` (empty means
/// no spans). Hunk counts must match. One file's porcelain, header included.
pub fn mismatches(
    alloc: Allocator,
    path: []const u8,
    hunks: []const diff.Hunk,
    porcelain: []const u8,
    our: []const HunkMarks,
) Error!MismatchReport {
    if (our.len != 0 and our.len != hunks.len) return error.AlignFailed;

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path_owned = try a.dupe(u8, path);
    var items: std.ArrayList(Mismatch) = .empty;

    var from: usize = 0;
    for (hunks, 0..) |hunk, hi| {
        const region = hunkRegion(porcelain, from) orelse return error.AlignFailed;
        from = region.end;

        const old_side = try buildSide(alloc, hunk.lines, .old);
        defer old_side.deinit(alloc);
        const new_side = try buildSide(alloc, hunk.lines, .new);
        defer new_side.deinit(alloc);
        const spans = try gitSpans(alloc, porcelain[region.start..region.end], old_side.text, new_side.text);
        defer spans.deinit(alloc);

        const none: []const Span = &.{};
        const part = try compareMarks(alloc, path_owned, hi, .{
            .text = old_side.text,
            .git = spans.old,
            .our = if (our.len == 0) none else our[hi].old,
        }, .{
            .text = new_side.text,
            .git = spans.new,
            .our = if (our.len == 0) none else our[hi].new,
        });
        defer alloc.free(part);
        for (part) |m| {
            try items.append(a, .{
                .path = path_owned,
                .hunk = m.hunk,
                .side = m.side,
                .line = m.line,
                .column = m.column,
                .kind = m.kind,
                .text = try a.dupe(u8, m.text),
            });
        }
    }
    if (hunkRegion(porcelain, from) != null) return error.AlignFailed;

    return .{
        .arena = arena,
        .items = try items.toOwnedSlice(a),
    };
}

const testing = std.testing;
const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

fn gitRun(alloc: Allocator, io: std.Io, cwd: std.process.Child.Cwd, argv: []const []const u8) ![]u8 {
    const result = std.process.run(alloc, io, .{ .argv = argv, .cwd = cwd }) catch return error.TestUnexpectedResult;
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0 and code != 1) {
            alloc.free(result.stdout);
            return error.TestUnexpectedResult;
        },
        else => {
            alloc.free(result.stdout);
            return error.TestUnexpectedResult;
        },
    }
    return result.stdout;
}

fn expectSpans(got: []const Span, want: []const Span) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.start, g.start);
        try testing.expectEqual(w.end, g.end);
    }
}

fn expectGitSpans(old_text: []const u8, new_text: []const u8, old_want: []const Span, new_want: []const Span) !void {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    const setup = [_][]const []const u8{
        &.{ "git", "init", "-b", "main" },
        &.{ "git", "config", "user.email", "rv@test" },
        &.{ "git", "config", "user.name", "rv test" },
    };
    for (setup) |argv| {
        const out = try gitRun(alloc, io, cwd, argv);
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", old_text);
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", new_text);
    const porcelain = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(porcelain);

    const spans = try gitSpans(alloc, porcelain, old_text, new_text);
    defer spans.deinit(alloc);
    try expectSpans(spans.old, old_want);
    try expectSpans(spans.new, new_want);
}

test "gitSpans follows word-diff porcelain" {
    try expectGitSpans(
        "hello world\nkeep\nfoo bar baz\n",
        "hello there\nkeep\nfoo BAR baz\n",
        &.{ .{ .start = 6, .end = 11 }, .{ .start = 21, .end = 24 } },
        &.{ .{ .start = 6, .end = 11 }, .{ .start = 21, .end = 24 } },
    );
    // The changed "bar" is the middle one.
    try expectGitSpans(
        "bar bar bar\n",
        "bar BAR bar\n",
        &.{.{ .start = 4, .end = 7 }},
        &.{.{ .start = 4, .end = 7 }},
    );
    // Line breaks in the word diff are not the unified line breaks.
    try expectGitSpans(
        "alpha beta\ngone line\nkeep\nfoo bar\n",
        "alpha BETA\nkeep\ninserted\nfoo bar baz\n",
        &.{ .{ .start = 6, .end = 10 }, .{ .start = 11, .end = 20 } },
        &.{ .{ .start = 6, .end = 10 }, .{ .start = 16, .end = 24 }, .{ .start = 33, .end = 36 } },
    );
    // Whitespace between words is not a word-diff change.
    try expectGitSpans("foo  bar\n", "foo bar\n", &.{}, &.{});
    try expectGitSpans("hello world", "hello there", &.{.{ .start = 6, .end = 11 }}, &.{.{ .start = 6, .end = 11 }});
    try expectGitSpans("a\nb\n", "a\n\nb\n", &.{}, &.{});
}

test "gitSpans rejects a walk that misses the old text" {
    const porcelain =
        \\@@ -1 +1 @@
        \\ hello
        \\~
        \\
    ;
    try testing.expectError(
        error.AlignFailed,
        gitSpans(testing.allocator, porcelain, "goodbye\n", "hello\n"),
    );
}

test "compareMarks reports our_only and git_only" {
    const alloc = testing.allocator;
    const old = "hello world\n";
    const new = "hello there\n";
    const git_old = [_]Span{.{ .start = 6, .end = 11 }};
    const git_new = [_]Span{.{ .start = 6, .end = 11 }};
    // Whole line, so the shared prefix is ours alone.
    const our_old = [_]Span{.{ .start = 0, .end = 11 }};
    const our_new = [_]Span{.{ .start = 0, .end = 5 }};

    const got = try compareMarks(alloc, "a.txt", 0, .{
        .text = old,
        .git = &git_old,
        .our = &our_old,
    }, .{
        .text = new,
        .git = &git_new,
        .our = &our_new,
    });
    defer alloc.free(got);

    try testing.expectEqual(3, got.len);
    try testing.expectEqual(Which.our_only, got[0].kind);
    try testing.expectEqual(Side.old, got[0].side);
    try testing.expectEqual(0, got[0].line);
    try testing.expectEqual(0, got[0].column);
    try testing.expectEqualStrings("hello ", got[0].text);
    try testing.expectEqualStrings("a.txt", got[0].path);

    try testing.expectEqual(Which.our_only, got[1].kind);
    try testing.expectEqual(Side.new, got[1].side);
    try testing.expectEqual(0, got[1].column);
    try testing.expectEqualStrings("hello", got[1].text);

    try testing.expectEqual(Which.git_only, got[2].kind);
    try testing.expectEqual(Side.new, got[2].side);
    try testing.expectEqual(6, got[2].column);
    try testing.expectEqualStrings("there", got[2].text);
}

test "buildSide drops the newline only when meta follows that line" {
    const lines = [_]diff.Line{
        .{ .kind = .delete, .text = "old" },
        .{ .kind = .add, .text = "new" },
        .{ .kind = .meta, .text = "No newline at end of file" },
    };
    const alloc = testing.allocator;
    const old = try buildSide(alloc, &lines, .old);
    defer old.deinit(alloc);
    const new = try buildSide(alloc, &lines, .new);
    defer new.deinit(alloc);
    try testing.expectEqualStrings("old\n", old.text);
    try testing.expectEqualStrings("new", new.text);
}

test "mismatches rejects a porcelain hunk the diff does not have" {
    const porcelain =
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    ;
    try testing.expectError(
        error.AlignFailed,
        mismatches(testing.allocator, "a.txt", &.{}, porcelain, &.{}),
    );
}

fn findLine(lines: []const diff.Line, kind: diff.LineKind, text: []const u8) !usize {
    for (lines, 0..) |ln, i| {
        if (ln.kind == kind and std.mem.eql(u8, ln.text, text)) return i;
    }
    return error.TestExpectedEqual;
}

fn expectOneSpan(changes: LineChangeList, index: usize, start: usize, end: usize) !void {
    for (changes.items) |item| {
        if (item.index != index) continue;
        try testing.expectEqual(1, item.spans.len);
        try testing.expectEqual(start, item.spans[0].start);
        try testing.expectEqual(end, item.spans[0].end);
        return;
    }
    return error.TestExpectedEqual;
}

test "lineChanges are columns of each hunk line" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    const setup = [_][]const []const u8{
        &.{ "git", "init", "-b", "main" },
        &.{ "git", "config", "user.email", "rv@test" },
        &.{ "git", "config", "user.name", "rv test" },
    };
    for (setup) |argv| {
        const out = try gitRun(alloc, io, cwd, argv);
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", "hello world\nkeep me\n");
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", "hello there\nkeep me\nadded\n");

    const uni = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--", "a.txt" });
    defer alloc.free(uni);
    const por = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(por);

    var d = try diff.parse(alloc, uni);
    defer d.deinit();
    try testing.expectEqual(1, d.files[0].hunks.len);
    const lines = d.files[0].hunks[0].lines;
    const changes = try lineChanges(alloc, lines, por);
    defer changes.deinit(alloc);

    try testing.expectEqual(3, changes.items.len);
    try expectOneSpan(changes, try findLine(lines, .delete, "hello world"), 6, 11);
    try expectOneSpan(changes, try findLine(lines, .add, "hello there"), 6, 11);
    // A pure insert is one span over the whole line.
    try expectOneSpan(changes, try findLine(lines, .add, "added"), 0, 5);
}
