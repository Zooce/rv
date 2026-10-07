//! Intra-line spans from a git hunk's lines.
//!
//! Git decides files and hunks. This module colors inside a hunk: tokenize
//! each zip-paired delete/add line, take the LCS, and store changed-token
//! byte ranges on `Line.spans`. No git word-diff. No correction passes.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;

/// Byte range in a line. Same type the diff row paints.
pub const Span = diff.Span;

const Token = struct {
    start: usize,
    end: usize,
};

/// Changed-token ranges on a paired old line and new line.
pub const PairedSpans = struct {
    old: []Span,
    new: []Span,

    pub fn deinit(self: PairedSpans, alloc: Allocator) void {
        alloc.free(self.old);
        alloc.free(self.new);
    }
};

/// Skip LCS when a line has more tokens than this. That line stays solid fill.
const max_tokens: usize = 512;

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

fn tokenize(alloc: Allocator, text: []const u8) Allocator.Error![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        if (isSpace(text[i])) {
            i += 1;
            while (i < text.len and isSpace(text[i])) i += 1;
        } else if (isWord(text[i])) {
            i += 1;
            while (i < text.len and isWord(text[i])) i += 1;
        } else {
            i += 1;
        }
        try out.append(alloc, .{ .start = start, .end = i });
    }
    return try out.toOwnedSlice(alloc);
}

fn tokenEq(a_text: []const u8, a: Token, b_text: []const u8, b: Token) bool {
    return std.mem.eql(u8, a_text[a.start..a.end], b_text[b.start..b.end]);
}

fn spansOfUnkept(alloc: Allocator, tokens: []const Token, keep: []const bool) Allocator.Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < tokens.len) {
        if (keep[i]) {
            i += 1;
            continue;
        }
        const start = tokens[i].start;
        var end = tokens[i].end;
        i += 1;
        while (i < tokens.len and !keep[i]) : (i += 1) end = tokens[i].end;
        try out.append(alloc, .{ .start = start, .end = end });
    }
    return try out.toOwnedSlice(alloc);
}

/// LCS of tokens on two paired lines. `null` when a line has too many tokens.
/// Spans cover consecutive tokens that are only on that line.
pub fn pairSpans(alloc: Allocator, old_text: []const u8, new_text: []const u8) Allocator.Error!?PairedSpans {
    const old_tok = try tokenize(alloc, old_text);
    defer alloc.free(old_tok);
    const new_tok = try tokenize(alloc, new_text);
    defer alloc.free(new_tok);
    if (old_tok.len > max_tokens or new_tok.len > max_tokens) return null;

    const cols = new_tok.len + 1;
    const dp = try alloc.alloc(u32, (old_tok.len + 1) * cols);
    defer alloc.free(dp);
    @memset(dp, 0);
    var i: usize = 0;
    while (i < old_tok.len) : (i += 1) {
        var j: usize = 0;
        while (j < new_tok.len) : (j += 1) {
            const at = (i + 1) * cols + (j + 1);
            if (tokenEq(old_text, old_tok[i], new_text, new_tok[j])) {
                dp[at] = dp[i * cols + j] + 1;
            } else {
                const drop_old = dp[i * cols + (j + 1)];
                const drop_new = dp[(i + 1) * cols + j];
                dp[at] = @max(drop_old, drop_new);
            }
        }
    }

    const old_keep = try alloc.alloc(bool, old_tok.len);
    defer alloc.free(old_keep);
    const new_keep = try alloc.alloc(bool, new_tok.len);
    defer alloc.free(new_keep);
    @memset(old_keep, false);
    @memset(new_keep, false);
    i = old_tok.len;
    var j: usize = new_tok.len;
    while (i > 0 and j > 0) {
        if (tokenEq(old_text, old_tok[i - 1], new_text, new_tok[j - 1])) {
            old_keep[i - 1] = true;
            new_keep[j - 1] = true;
            i -= 1;
            j -= 1;
        } else if (dp[(i - 1) * cols + j] >= dp[i * cols + (j - 1)]) {
            i -= 1;
        } else {
            j -= 1;
        }
    }

    const old_spans = try spansOfUnkept(alloc, old_tok, old_keep);
    errdefer alloc.free(old_spans);
    return .{
        .old = old_spans,
        .new = try spansOfUnkept(alloc, new_tok, new_keep),
    };
}

fn hunkOneSided(lines: []const diff.Line) bool {
    var add = false;
    var delete = false;
    for (lines) |ln| {
        switch (ln.kind) {
            .add => add = true,
            .delete => delete = true,
            .context, .meta => {},
        }
        if (add and delete) return false;
    }
    return add or delete;
}

fn copySpans(arena: Allocator, src: []const Span) Allocator.Error![]const Span {
    if (src.len == 0) return &.{};
    return try arena.dupe(Span, src);
}

fn putPair(arena: Allocator, alloc: Allocator, old: *diff.Line, new: *diff.Line) Allocator.Error!void {
    if (old.text.len == 0) {
        // Blank delete stays solid. A non-empty add against empty is a whole-line add.
        if (new.text.len == 0) return;
        new.spans = try arena.dupe(Span, &.{.{ .start = 0, .end = new.text.len }});
        return;
    }
    if (new.text.len == 0) {
        old.spans = try arena.dupe(Span, &.{.{ .start = 0, .end = old.text.len }});
        return;
    }
    const paired = try pairSpans(alloc, old.text, new.text) orelse return;
    defer paired.deinit(alloc);
    old.spans = try copySpans(arena, paired.old);
    new.spans = try copySpans(arena, paired.new);
}

fn attachHunk(arena: Allocator, alloc: Allocator, hunk: *diff.Hunk) Allocator.Error!void {
    if (hunkOneSided(hunk.lines)) return;

    const lines = try arena.alloc(diff.Line, hunk.lines.len);
    for (hunk.lines, lines) |ln, *out| out.* = ln;
    hunk.lines = lines;

    var i: usize = 0;
    while (i < lines.len) {
        switch (lines[i].kind) {
            .context, .meta => i += 1,
            .delete => {
                const d0 = i;
                while (i < lines.len and lines[i].kind == .delete) i += 1;
                const d1 = i;
                const a0 = i;
                while (i < lines.len and lines[i].kind == .add) i += 1;
                const a1 = i;
                const n = @min(d1 - d0, a1 - a0);
                var j: usize = 0;
                while (j < n) : (j += 1) {
                    try putPair(arena, alloc, &lines[d0 + j], &lines[a0 + j]);
                }
            },
            .add => {
                // Pure inserts in this run: solid fill.
                while (i < lines.len and lines[i].kind == .add) i += 1;
            },
        }
    }
}

/// Write intra-line spans onto add/delete lines. One-sided files, one-sided
/// hunks, blank unpaired lines, and over-long lines keep `null` spans (solid fill).
pub fn attachSpans(alloc: Allocator, d: *diff.Diff) Allocator.Error!void {
    const arena = d.arena.allocator();
    for (d.files) |*file| {
        if (file.old_path == null or file.new_path == null) continue;
        for (file.hunks) |*hunk| {
            try attachHunk(arena, alloc, hunk);
        }
    }
}

const testing = std.testing;

fn expectTokens(text: []const u8, want: []const []const u8) !void {
    const tok = try tokenize(testing.allocator, text);
    defer testing.allocator.free(tok);
    try testing.expectEqual(want.len, tok.len);
    for (want, tok) |w, t| {
        try testing.expectEqualStrings(w, text[t.start..t.end]);
    }
}

fn expectPair(
    old_text: []const u8,
    new_text: []const u8,
    old_want: []const Span,
    new_want: []const Span,
) !void {
    const paired = try pairSpans(testing.allocator, old_text, new_text) orelse
        return error.TestUnexpectedResult;
    defer paired.deinit(testing.allocator);
    try testing.expectEqual(old_want.len, paired.old.len);
    try testing.expectEqual(new_want.len, paired.new.len);
    for (old_want, paired.old) |w, g| {
        try testing.expectEqual(w.start, g.start);
        try testing.expectEqual(w.end, g.end);
    }
    for (new_want, paired.new) |w, g| {
        try testing.expectEqual(w.start, g.start);
        try testing.expectEqual(w.end, g.end);
    }
}

test "tokenize splits words, punctuation, and space runs" {
    try expectTokens("null;", &.{ "null", ";" });
    try expectTokens("foo.bar", &.{ "foo", ".", "bar" });
    try expectTokens("return foo(bar)", &.{ "return", " ", "foo", "(", "bar", ")" });
    try expectTokens("a  b", &.{ "a", "  ", "b" });
}

test "insert a word: only the new word is spanned" {
    try expectPair(
        "let's do something cool",
        "let's do something very cool",
        &.{},
        &.{.{ .start = 18, .end = 23 }},
    );
}

test "delete a phrase in place" {
    try expectPair(
        "cool and all that stuff. I",
        "cool and stuff. I",
        &.{.{ .start = 8, .end = 17 }},
        &.{},
    );
}

test "punctuation change colors the punctuation only" {
    try expectPair("null;", "null", &.{.{ .start = 4, .end = 5 }}, &.{});
}

test "swapped words are spanned" {
    try expectPair(
        "return foo(bar)",
        "return bar(foo)",
        &.{.{ .start = 10, .end = 14 }},
        &.{.{ .start = 7, .end = 11 }},
    );
}

test "space runs that differ are spanned; identical words are not" {
    try expectPair(
        "\"walrus\",     \"otter\"",
        "\"walrus\",  \"otter\"",
        &.{.{ .start = 9, .end = 14 }},
        &.{.{ .start = 9, .end = 11 }},
    );
}

test "stayed-put words stay unspanned when a neighbor changes" {
    try expectPair(
        "we even need some stuff about things",
        "we even need some stuff to talk about",
        &.{.{ .start = 29, .end = 36 }},
        &.{.{ .start = 23, .end = 31 }},
    );
}

fn parseOne(text: []const u8) !diff.Diff {
    return diff.parse(testing.allocator, text);
}

test "attachSpans skips a deleted file" {
    const text =
        \\diff --git a/old.txt b/old.txt
        \\deleted file mode 100644
        \\--- a/old.txt
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-this is old
        \\
    ;
    var d = try parseOne(text);
    defer d.deinit();
    try attachSpans(testing.allocator, &d);
    try testing.expect(d.files[0].hunks[0].lines[0].spans == null);
}

test "attachSpans skips a new file" {
    const text =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1 @@
        \\+this is new
        \\
    ;
    var d = try parseOne(text);
    defer d.deinit();
    try attachSpans(testing.allocator, &d);
    try testing.expect(d.files[0].hunks[0].lines[0].spans == null);
}

test "attachSpans leaves a blank pair solid and spans the next paired edit" {
    const text =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,4 +1,4 @@
        \\ keep
        \\-
        \\+
        \\-old
        \\+new
        \\
    ;
    var d = try parseOne(text);
    defer d.deinit();
    try attachSpans(testing.allocator, &d);
    const lines = d.files[0].hunks[0].lines;
    try testing.expect(lines[1].spans == null);
    try testing.expect(lines[2].spans == null);
    const old_sp = lines[3].spans.?;
    const new_sp = lines[4].spans.?;
    try testing.expectEqual(1, old_sp.len);
    try testing.expectEqual(0, old_sp[0].start);
    try testing.expectEqual(3, old_sp[0].end);
    try testing.expectEqual(1, new_sp.len);
    try testing.expectEqual(0, new_sp[0].start);
    try testing.expectEqual(3, new_sp[0].end);
}

test "attachSpans colors a word that moved to the next line" {
    const text =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,2 +1,2 @@
        \\-alpha pika
        \\-beta
        \\+alpha
        \\+pika beta
        \\
    ;
    var d = try parseOne(text);
    defer d.deinit();
    try attachSpans(testing.allocator, &d);
    const lines = d.files[0].hunks[0].lines;
    const old0 = lines[0].spans.?;
    try testing.expectEqual(1, old0.len);
    try testing.expectEqualStrings(" pika", lines[0].text[old0[0].start..old0[0].end]);
    const new1 = lines[3].spans.?;
    try testing.expectEqual(1, new1.len);
    try testing.expectEqualStrings("pika ", lines[3].text[new1[0].start..new1[0].end]);
}
