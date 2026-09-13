//! Soft-wrap of one diff body line into visual segments (goal #135).
//!
//! Given pane text width, split `ln.text` at word boundaries; a token longer
//! than the pane hard-splits. Same break rules as the comment box. Columns
//! are bytes (one byte = one column). Pure data — no TTY.

const std = @import("std");
const testing = std.testing;

/// Half-open byte range into the source line for one visual segment.
pub const Segment = struct {
    start: usize,
    end: usize,
};

/// True if wrapping may break *after* this character (keep it on the current line).
fn isBreakAfter(c: u8) bool {
    return switch (c) {
        // Whitespace: caller treats as break *before* (exclude from line).
        ' ', '\t' => true,
        '-', ',', '.', ';', ':', '!', '?', '/', '\\',
        ')', ']', '}', '>', '"', '\'', '_',
        => true,
        else => false,
    };
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn skipSpaces(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len and isSpace(text[j])) : (j += 1) {}
    return j;
}

/// Exclusive end index for a segment starting at `start` with max `text_w` columns.
/// Prefers the rightmost word boundary in the window; hard-splits if none.
fn wrapEnd(text: []const u8, start: usize, text_w: usize) usize {
    if (start >= text.len) return start;
    if (text_w == 0) return start;
    const rest = text.len - start;
    if (rest <= text_w) return text.len;

    var last_break: ?usize = null;
    var i: usize = 0;
    while (i < text_w) : (i += 1) {
        const c = text[start + i];
        if (isSpace(c)) {
            if (i > 0) last_break = start + i;
        } else if (isBreakAfter(c)) {
            last_break = start + i + 1;
        }
    }
    if (last_break) |b| {
        if (b > start) return b;
    }
    return start + text_w;
}

fn nextStart(text: []const u8, end: usize) usize {
    if (end >= text.len) return text.len;
    if (isSpace(text[end])) return skipSpaces(text, end);
    return end;
}

/// Byte range of visual segment `line` (0-based), or null if past the end.
/// Empty text yields one empty segment at index 0.
pub fn segmentAt(text: []const u8, text_w: usize, line: usize) ?Segment {
    const tw: usize = if (text_w == 0) 1 else text_w;
    if (text.len == 0) {
        return if (line == 0) .{ .start = 0, .end = 0 } else null;
    }

    var start: usize = 0;
    var idx: usize = 0;
    while (start < text.len) {
        const end_raw = wrapEnd(text, start, tw);
        const end = if (end_raw > start) end_raw else @min(start + 1, text.len);
        if (idx == line) return .{ .start = start, .end = end };

        var next = nextStart(text, end);
        if (next <= start) next = end;
        if (next >= text.len) return null;
        start = next;
        idx += 1;
    }
    return null;
}

/// Number of visual segments for `text` at `text_w` (at least 1).
pub fn lineCount(text: []const u8, text_w: usize) usize {
    if (text.len == 0) return 1;
    var n: usize = 0;
    while (segmentAt(text, text_w, n)) |_| : (n += 1) {}
    return if (n == 0) 1 else n;
}

test "empty text is one empty segment" {
    try testing.expectEqual(1, lineCount("", 10));
    const s = segmentAt("", 10, 0).?;
    try testing.expectEqual(0, s.start);
    try testing.expectEqual(0, s.end);
    try testing.expect(segmentAt("", 10, 1) == null);
}

test "short line stays one segment" {
    const t = "hello";
    try testing.expectEqual(1, lineCount(t, 10));
    const a = segmentAt(t, 10, 0).?;
    try testing.expectEqualStrings("hello", t[a.start..a.end]);
    try testing.expect(segmentAt(t, 10, 1) == null);
}

test "word wrap breaks on spaces" {
    const t = "hello world";
    try testing.expectEqual(2, lineCount(t, 10));
    const a = segmentAt(t, 10, 0).?;
    const b = segmentAt(t, 10, 1).?;
    try testing.expectEqualStrings("hello", t[a.start..a.end]);
    try testing.expectEqualStrings("world", t[b.start..b.end]);
}

test "word wrap breaks after hyphen and comma" {
    const t = "pre-flight,okay";
    const a = segmentAt(t, 8, 0).?;
    const b = segmentAt(t, 8, 1).?;
    const c = segmentAt(t, 8, 2).?;
    try testing.expectEqualStrings("pre-", t[a.start..a.end]);
    try testing.expectEqualStrings("flight,", t[b.start..b.end]);
    try testing.expectEqualStrings("okay", t[c.start..c.end]);
}

test "hard split long token" {
    const t = "abcdefghijXYZ";
    try testing.expectEqual(2, lineCount(t, 10));
    const a = segmentAt(t, 10, 0).?;
    const b = segmentAt(t, 10, 1).?;
    try testing.expectEqualStrings("abcdefghij", t[a.start..a.end]);
    try testing.expectEqualStrings("XYZ", t[b.start..b.end]);
}

test "zero width is treated as one column" {
    const t = "ab";
    try testing.expectEqual(2, lineCount(t, 0));
    const a = segmentAt(t, 0, 0).?;
    const b = segmentAt(t, 0, 1).?;
    try testing.expectEqualStrings("a", t[a.start..a.end]);
    try testing.expectEqualStrings("b", t[b.start..b.end]);
}

test "leading indent stays on the first segment" {
    const t = "    foo bar";
    const a = segmentAt(t, 8, 0).?;
    const b = segmentAt(t, 8, 1).?;
    try testing.expectEqualStrings("    foo", t[a.start..a.end]);
    try testing.expectEqualStrings("bar", t[b.start..b.end]);
}
