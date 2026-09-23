//! Git word-diff spans for one file's porcelain output.
//!
//! `git diff --word-diff=porcelain` common runs are bytes from the new side
//! (whitespace between words is not itself a change). `~` is a newline.
//! Delete runs are exact old-side bytes. `gitSpans` walks those runs onto
//! the old and new text and returns the changed byte ranges.

const std = @import("std");
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
