//! Soft-wrapped multi-line comment footer layout (goal #53).
//!
//! Display model (per visual line):
//!   [left gutter 1][prefix 2][draft text …][right pad 2]
//!
//! Prefix is `"> "` on the first line and `"  "` on continuations so body text
//! lines up. Right pad is always reserved so a scrollbar appearing after
//! `max_rows` does not change wrap width or reflow text. Scrollbar paints in
//! the rightmost reserved column.
//!
//! Soft-wrap prefers word boundaries (whitespace and common punctuation).
//! Long tokens with no break still hard-split at `text_w`.
//!
//! Enter still means save (no hard newlines). Pure layout math — no Screen/TTY.

const std = @import("std");
const testing = std.testing;

/// First-line prompt (width = `prefix_w`).
pub const prefix_first: []const u8 = "> ";
/// Continuation-line hang indent (same width as `prefix_first`).
pub const prefix_cont: []const u8 = "  ";

pub const left_gutter: u16 = 1;
pub const prefix_w: u16 = 2;
pub const right_pad: u16 = 2;

/// Maximum visible rows of the comment input box.
pub const max_rows: usize = 4;

/// Layout snapshot for one paint (or key handling) step.
pub const Metrics = struct {
    /// Columns available for draft text on each line (excludes gutter/prefix/pad).
    text_w: u16,
    /// Total soft-wrapped visual lines (at least 1 when commenting).
    line_count: usize,
    /// Visible footer rows: `min(cap, line_count)`.
    height: u16,
    /// True when `line_count > height` (scrollbar in the right pad column).
    show_scrollbar: bool,
};

/// Half-open byte range into the draft for one visual line's text (no prefix).
pub const LineRange = struct {
    start: usize,
    end: usize,
};

/// Draft-text column budget for a terminal of `cols` columns.
/// Always reserves left gutter, prefix, and right pad — independent of scrollbar.
pub fn textWidth(cols: u16) u16 {
    const fixed: u16 = left_gutter + prefix_w + right_pad;
    if (cols <= fixed) return 1;
    return cols - fixed;
}

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

fn skipSpaces(draft: []const u8, i: usize) usize {
    var j = i;
    while (j < draft.len and isSpace(draft[j])) : (j += 1) {}
    return j;
}

/// Exclusive end index for a line starting at `start` with max `text_w` columns.
/// Prefers the rightmost word boundary in the window; hard-splits if none.
fn wrapEnd(draft: []const u8, start: usize, text_w: usize) usize {
    if (start >= draft.len) return start;
    if (text_w == 0) return start;
    const rest = draft.len - start;
    if (rest <= text_w) return draft.len;

    // Window [start, start+text_w). Prefer last break opportunity.
    var last_break: ?usize = null; // exclusive end into draft
    var i: usize = 0;
    while (i < text_w) : (i += 1) {
        const c = draft[start + i];
        if (isSpace(c)) {
            // Break before the space (drop trailing spaces from this line).
            if (i > 0) last_break = start + i;
        } else if (isBreakAfter(c)) {
            last_break = start + i + 1;
        }
    }
    if (last_break) |b| {
        if (b > start) return b;
    }
    // No usable boundary (long token): hard split at text_w.
    return start + text_w;
}

/// Advance past a finished line ending at `end` to the next line's start.
fn nextLineStart(draft: []const u8, end: usize) usize {
    if (end >= draft.len) return draft.len;
    if (isSpace(draft[end])) return skipSpaces(draft, end);
    return end;
}

/// Byte range of draft text on visual line `line` (0-based), or null if past end.
/// Empty draft yields one empty line at index 0.
pub fn lineRange(draft: []const u8, text_w: u16, line: usize) ?LineRange {
    const tw: usize = if (text_w == 0) 1 else text_w;
    if (draft.len == 0) {
        return if (line == 0) .{ .start = 0, .end = 0 } else null;
    }

    var start: usize = 0;
    var idx: usize = 0;
    while (start < draft.len) {
        const end_raw = wrapEnd(draft, start, tw);
        // Guarantee progress even if wrapEnd is stuck.
        const end = if (end_raw > start) end_raw else @min(start + 1, draft.len);
        if (idx == line) return .{ .start = start, .end = end };

        var next = nextLineStart(draft, end);
        if (next <= start) next = end; // force forward (hard split / edge)
        if (next >= draft.len) return null;
        start = next;
        idx += 1;
    }
    return null;
}

/// Number of soft-wrapped visual lines for `draft` at `text_w` (at least 1).
pub fn lineCount(draft: []const u8, text_w: u16) usize {
    if (draft.len == 0) return 1;
    var n: usize = 0;
    while (lineRange(draft, text_w, n)) |_| : (n += 1) {}
    return if (n == 0) 1 else n;
}

/// Footer height and text width. Cap visible rows at `max_rows`.
pub fn metrics(cols: u16, draft: []const u8) Metrics {
    return metricsLimited(cols, draft, max_rows);
}

/// Like `metrics`, but visible height is capped at `max_visible` (at least 1).
/// Right pad is always reserved — wrap width does not change when the scrollbar
/// appears.
pub fn metricsLimited(cols: u16, draft: []const u8, max_visible: usize) Metrics {
    const cap: usize = if (max_visible == 0) 1 else max_visible;
    const tw = textWidth(cols);
    const lines = lineCount(draft, tw);
    const height: u16 = @intCast(@min(cap, @max(@as(usize, 1), lines)));
    return .{
        .text_w = tw,
        .line_count = lines,
        .height = height,
        .show_scrollbar = lines > height,
    };
}

/// Maximum scroll offset (first visible visual line index).
pub fn maxScroll(line_count: usize, height: u16) usize {
    const h: usize = height;
    if (line_count <= h) return 0;
    return line_count - h;
}

pub fn clampScroll(scroll: usize, line_count: usize, height: u16) usize {
    return @min(scroll, maxScroll(line_count, height));
}

pub fn scrollToEnd(line_count: usize, height: u16) usize {
    return maxScroll(line_count, height);
}

/// Write `prefix + draft-slice` for visual line `line` into `buf`.
pub fn writeVisualLine(buf: []u8, draft: []const u8, text_w: u16, line: usize) []const u8 {
    if (buf.len == 0) return buf[0..0];
    const range = lineRange(draft, text_w, line) orelse return buf[0..0];
    const pref: []const u8 = if (line == 0) prefix_first else prefix_cont;
    const text = draft[range.start..range.end];
    const need = pref.len + text.len;
    if (need > buf.len) {
        // Truncate to buf (should not happen when buf ≥ prefix_w + text_w).
        const n = @min(pref.len, buf.len);
        @memcpy(buf[0..n], pref[0..n]);
        if (n < buf.len) {
            const tn = @min(text.len, buf.len - n);
            @memcpy(buf[n .. n + tn], text[0..tn]);
            return buf[0 .. n + tn];
        }
        return buf[0..n];
    }
    @memcpy(buf[0..pref.len], pref);
    @memcpy(buf[pref.len .. pref.len + text.len], text);
    return buf[0..need];
}

/// Visual line index and column within that line's draft text.
pub const VisualPos = struct {
    line: usize,
    col: usize,

    /// Map a caret byte index into `draft` to a visual line and column-in-text.
    /// `caret` is clamped to `[0, draft.len]`. Skipped wrap spaces (between a
    /// line's `end` and the next line's `start`) map to the end of the preceding
    /// visual line.
    pub fn init(draft: []const u8, text_w: u16, caret: usize) VisualPos {
        const c = @min(caret, draft.len);
        if (draft.len == 0) return .{ .line = 0, .col = 0 };

        var line: usize = 0;
        while (lineRange(draft, text_w, line)) |range| : (line += 1) {
            if (c <= range.end) {
                return .{ .line = line, .col = c - range.start };
            }
            // Past this line's text: either in skipped spaces before the next
            // line, or on a later line. Peek at next start without allocating.
            const next_start = blk: {
                if (range.end >= draft.len) break :blk draft.len;
                var n = nextLineStart(draft, range.end);
                if (n <= range.start) n = range.end;
                break :blk n;
            };
            if (c < next_start or next_start >= draft.len) {
                // Skipped spaces, or caret past last line content → end of this line.
                return .{ .line = line, .col = range.end - range.start };
            }
            // else: c >= next_start → continue to next visual line
        }
        // Should not reach: empty handled above; last line always covers draft.len.
        return .{ .line = 0, .col = 0 };
    }
};

/// Footer screen position for the hardware caret.
pub const CursorPos = struct {
    x: u16,
    y_off: u16,
};

/// Byte index in `draft` for visual `line` and column-in-text `col`.
/// `col` is clamped to the line's text length (end-of-line). Past-last line → `draft.len`.
pub fn byteAtVisual(draft: []const u8, text_w: u16, line: usize, col: usize) usize {
    const range = lineRange(draft, text_w, line) orelse return draft.len;
    const len = range.end - range.start;
    return range.start + @min(col, len);
}

/// Screen column and footer row offset for a caret byte index.
/// If the caret's visual line is above `scroll`, `y_off` is 0; if below the
/// window, `y_off` is `height - 1`. Callers should scroll with `ensureVisible`
/// first so the caret is on-screen.
pub fn cursorAt(
    draft: []const u8,
    text_w: u16,
    scroll: usize,
    height: u16,
    caret: usize,
) CursorPos {
    const pos = VisualPos.init(draft, text_w, caret);
    const y_off_usize: usize = if (pos.line < scroll) 0 else pos.line - scroll;
    const h: usize = height;
    const y_off: u16 = @intCast(@min(y_off_usize, h -| 1));
    const col: u16 = @intCast(pos.col);
    const x: u16 = left_gutter + prefix_w + col;
    return .{ .x = x, .y_off = y_off };
}

/// End-of-draft caret (append position).
pub fn cursorAtEnd(
    draft: []const u8,
    text_w: u16,
    scroll: usize,
    height: u16,
) CursorPos {
    return cursorAt(draft, text_w, scroll, height, draft.len);
}

/// Move `scroll` so visual line `caret_line` is visible in a window of `height`.
pub fn ensureVisible(scroll: usize, caret_line: usize, height: u16, line_count: usize) usize {
    if (height == 0 or line_count == 0) return 0;
    const h: usize = height;
    var s = scroll;
    if (caret_line < s) s = caret_line;
    if (caret_line >= s + h) s = caret_line + 1 - h;
    return clampScroll(s, line_count, height);
}

/// Vertical scrollbar thumb in a track of `track` rows.
/// Returns half-open `[start, start+len)` of track rows for the thumb.
pub fn scrollbarThumb(total: usize, visible: usize, scroll: usize, track: usize) struct { start: usize, len: usize } {
    if (track == 0 or total <= visible) return .{ .start = 0, .len = 0 };

    var thumb_len = (visible * track) / total;
    if (thumb_len == 0) thumb_len = 1;
    if (thumb_len > track) thumb_len = track;

    const max_s = total - visible;
    const s = @min(scroll, max_s);
    const travel = track - thumb_len;
    const start = if (max_s == 0) 0 else (s * travel) / max_s;
    return .{ .start = start, .len = thumb_len };
}

// --- tests -----------------------------------------------------------------

test "textWidth reserves gutter prefix and right pad" {
    // cols=20 → 20 - 1 - 2 - 2 = 15
    try testing.expectEqual(@as(u16, 15), textWidth(20));
    try testing.expectEqual(@as(u16, 1), textWidth(3)); // degenerate
}

test "lineCount empty" {
    try testing.expectEqual(@as(usize, 1), lineCount("", 10));
}

test "word wrap breaks on spaces" {
    // text_w=10: "hello world" → "hello" / "world"
    const d = "hello world";
    try testing.expectEqual(@as(usize, 2), lineCount(d, 10));
    const a = lineRange(d, 10, 0).?;
    const b = lineRange(d, 10, 1).?;
    try testing.expectEqualStrings("hello", d[a.start..a.end]);
    try testing.expectEqualStrings("world", d[b.start..b.end]);
}

test "word wrap breaks after hyphen and comma" {
    // text_w=8 forces boundaries: "pre-" | "flight," | "okay"
    const d = "pre-flight,okay";
    try testing.expectEqualStrings("pre-", d[lineRange(d, 8, 0).?.start..lineRange(d, 8, 0).?.end]);
    try testing.expectEqualStrings("flight,", d[lineRange(d, 8, 1).?.start..lineRange(d, 8, 1).?.end]);
    try testing.expectEqualStrings("okay", d[lineRange(d, 8, 2).?.start..lineRange(d, 8, 2).?.end]);
}

test "hard split long token" {
    const d = "abcdefghijXYZ"; // 13 chars, text_w=10 → abcd...ij / XYZ
    try testing.expectEqual(@as(usize, 2), lineCount(d, 10));
    try testing.expectEqualStrings("abcdefghij", d[lineRange(d, 10, 0).?.start..lineRange(d, 10, 0).?.end]);
    try testing.expectEqualStrings("XYZ", d[lineRange(d, 10, 1).?.start..lineRange(d, 10, 1).?.end]);
}

test "writeVisualLine hanging indent" {
    const d = "hello world";
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("> hello", writeVisualLine(&buf, d, 10, 0));
    try testing.expectEqualStrings("  world", writeVisualLine(&buf, d, 10, 1));
}

test "metrics text_w stable with scrollbar" {
    // Narrow cols so one word per line; five words → scrollbar, text_w unchanged.
    // cols=10 → text_w=5; words longer than 5 still hard-split, short words wrap.
    const d = "alpha bravo charlie delta echo foxtrot";
    const m = metrics(12, d); // text_w = 7
    try testing.expectEqual(textWidth(12), m.text_w);
    try testing.expect(m.line_count > max_rows);
    try testing.expect(m.show_scrollbar);
    try testing.expectEqual(@as(u16, 4), m.height);
    // Same text_w without needing scroll (short draft).
    const m1 = metrics(12, "hi");
    try testing.expectEqual(m.text_w, m1.text_w);
    try testing.expect(!m1.show_scrollbar);
}

test "metricsLimited short terminal" {
    const d = "alpha bravo charlie delta";
    const m = metricsLimited(12, d, 2);
    try testing.expectEqual(@as(u16, 2), m.height);
    try testing.expect(m.show_scrollbar);
    try testing.expectEqual(textWidth(12), m.text_w);
}

test "clampScroll and scrollToEnd" {
    try testing.expectEqual(@as(usize, 0), maxScroll(3, 4));
    try testing.expectEqual(@as(usize, 2), maxScroll(6, 4));
    try testing.expectEqual(@as(usize, 2), clampScroll(99, 6, 4));
    try testing.expectEqual(@as(usize, 2), scrollToEnd(6, 4));
    try testing.expectEqual(@as(usize, 0), scrollToEnd(2, 4));
}

test "cursorAtEnd empty and wrapped" {
    const e = cursorAtEnd("", 10, 0, 1);
    try testing.expectEqual(@as(u16, left_gutter + prefix_w), e.x);
    try testing.expectEqual(@as(u16, 0), e.y_off);

    const d = "hello world";
    // 2 lines; caret after "world" on line 1
    const c = cursorAtEnd(d, 10, 0, 2);
    try testing.expectEqual(@as(u16, 1), c.y_off);
    try testing.expectEqual(@as(u16, left_gutter + prefix_w + 5), c.x); // "world"
}

test "VisualPos.init empty mid and end" {
    try testing.expectEqual(0, VisualPos.init("", 10, 0).line);
    try testing.expectEqual(0, VisualPos.init("", 10, 0).col);

    const d = "hello world"; // line0 "hello", line1 "world"
    const p0 = VisualPos.init(d, 10, 0);
    try testing.expectEqual(0, p0.line);
    try testing.expectEqual(0, p0.col);

    const mid = VisualPos.init(d, 10, 2); // 'l' of hello
    try testing.expectEqual(0, mid.line);
    try testing.expectEqual(2, mid.col);

    // After "hello" (byte 5 = space, skipped) → end of line 0
    const after_hello = VisualPos.init(d, 10, 5);
    try testing.expectEqual(0, after_hello.line);
    try testing.expectEqual(5, after_hello.col);

    const world = VisualPos.init(d, 10, 6);
    try testing.expectEqual(1, world.line);
    try testing.expectEqual(0, world.col);

    const end = VisualPos.init(d, 10, d.len);
    try testing.expectEqual(1, end.line);
    try testing.expectEqual(5, end.col);
}

test "byteAtVisual roundtrip and clamp" {
    const d = "hello world";
    try testing.expectEqual(0, byteAtVisual(d, 10, 0, 0));
    try testing.expectEqual(2, byteAtVisual(d, 10, 0, 2));
    try testing.expectEqual(5, byteAtVisual(d, 10, 0, 5)); // end of "hello"
    try testing.expectEqual(5, byteAtVisual(d, 10, 0, 99)); // clamp
    try testing.expectEqual(6, byteAtVisual(d, 10, 1, 0));
    try testing.expectEqual(11, byteAtVisual(d, 10, 1, 5));
    try testing.expectEqual(11, byteAtVisual(d, 10, 9, 0)); // past last

    // Round-trip displayed positions (not the skipped space byte).
    for ([_]usize{ 0, 2, 5, 6, 8, 11 }) |b| {
        const p = VisualPos.init(d, 10, b);
        try testing.expectEqual(b, byteAtVisual(d, 10, p.line, p.col));
    }
}

test "cursorAt mid-line matches VisualPos" {
    const d = "hello world";
    const c = cursorAt(d, 10, 0, 2, 2);
    try testing.expectEqual(0, c.y_off);
    try testing.expectEqual(left_gutter + prefix_w + 2, c.x);

    // End caret matches cursorAtEnd.
    const end = cursorAt(d, 10, 0, 2, d.len);
    const end2 = cursorAtEnd(d, 10, 0, 2);
    try testing.expectEqual(end2.x, end.x);
    try testing.expectEqual(end2.y_off, end.y_off);
}

test "ensureVisible keeps caret line in window" {
    try testing.expectEqual(0, ensureVisible(0, 0, 4, 10));
    try testing.expectEqual(0, ensureVisible(0, 3, 4, 10));
    try testing.expectEqual(2, ensureVisible(0, 5, 4, 10)); // 5 at bottom of [2,6)
    try testing.expectEqual(3, ensureVisible(5, 3, 4, 10)); // pull up
    try testing.expectEqual(6, ensureVisible(0, 9, 4, 10)); // last page
}

test "scrollbarThumb extremes" {
    const top = scrollbarThumb(10, 4, 0, 4);
    try testing.expectEqual(@as(usize, 0), top.start);
    try testing.expect(top.len >= 1);

    const bot = scrollbarThumb(10, 4, 6, 4);
    try testing.expectEqual(bot.start + bot.len, @as(usize, 4));

    const none = scrollbarThumb(3, 4, 0, 4);
    try testing.expectEqual(@as(usize, 0), none.len);
}
