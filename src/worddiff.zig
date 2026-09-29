//! Git word-diff spans for one file's porcelain output.
//!
//! `git diff --word-diff=porcelain` common runs are bytes from the new side
//! (whitespace between words is not itself a change). `~` is a newline.
//! A `~` that extends only the new side is an inserted newline: a blank
//! added line. A `~` after a common or added run that the new side does not
//! take is a deleted blank line. Delete runs are exact old-side bytes.
//! `gitSpans` walks those runs onto the old and new text and returns the
//! changed byte ranges.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The porcelain runs do not walk `old_text` and `new_text`.
    AlignFailed,
    OutOfMemory,
};

/// Byte range in a line or a joined side. Same type the diff row paints.
pub const Span = diff.Span;

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
            // Git does not mark a newline as a word. One that exists only on the
            // new side is still a change: the blank added line. One that follows
            // a common or added run, and that the new side does not take, is a
            // deleted blank line. The newline that closes a deleted word is not:
            // that line already has its own span.
            const extend_new = if (prev) |p| p == .common or p == .add else false;
            const extend_old = oi < old_text.len and old_text[oi] == '\n';
            const take_new = extend_new and
                new_buf.items.len < new_text.len and
                new_text[new_buf.items.len] == '\n';
            if (take_new and !extend_old) {
                const at = new_buf.items.len;
                try new_spans.append(alloc, .{ .start = at, .end = at + 1 });
            }
            if (extend_old and extend_new and !take_new) {
                try old_spans.append(alloc, .{ .start = oi, .end = oi + 1 });
            }
            if (take_new) try new_buf.append(alloc, '\n');
            if (extend_old) oi += 1;
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
                // A space or tab before a deleted word is often only on the old side.
                // Git does not emit it. One newline is the same gap when a joined
                // line deletes the next line's prefix, including that line's indent.
                // Skip the gap only when the delete matches after it.
                // A blank line stays a `~`.
                if (!isWordGap(text[0])) {
                    if (oi < old_text.len and (old_text[oi] == ' ' or old_text[oi] == '\t')) {
                        while (oi < old_text.len and (old_text[oi] == ' ' or old_text[oi] == '\t')) oi += 1;
                    }
                    if (oi < old_text.len and old_text[oi] == '\n') {
                        var j = oi + 1;
                        while (j < old_text.len and (old_text[j] == ' ' or old_text[j] == '\t')) j += 1;
                        if (std.mem.startsWith(u8, old_text[j..], text)) oi = j;
                    }
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
    // A file with no trailing newline still ends with `~`. That extra byte is
    // not in `new_text`, and it is not an inserted blank line.
    const phantom = rebuilt.len == new_text.len + 1 and rebuilt[rebuilt.len - 1] == '\n' and
        std.mem.eql(u8, rebuilt[0..new_text.len], new_text);
    if (!std.mem.eql(u8, rebuilt, new_text) and !phantom) return error.AlignFailed;
    if (phantom and new_spans.items.len > 0) {
        const last = new_spans.items[new_spans.items.len - 1];
        if (last.start == new_text.len and last.end == new_text.len + 1) _ = new_spans.pop();
    }

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
/// A newline stays for `~`, unless this common run continues past it (a line
/// join, where the break became a space).
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
            while (oi < old.len and old[oi] != '\n' and isWordGap(old[oi])) oi += 1;
            if (ci < chunk.len) {
                while (oi < old.len and old[oi] == '\n') oi += 1;
            }
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
    /// The byte at `start + len` is this line's newline.
    newline: bool,
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
    try parts.append(alloc, .{ .index = index, .start = start, .len = text.len, .newline = newline });
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
/// A blank added or deleted line has one span on the newline just past `text`.
///
/// Git can mark a repeated token as the change when a phrase moved onto the
/// next line. The token is then highlighted on both of the paired lines even
/// though those bytes still match, and the old line does not show the phrase
/// that left. That delete/add run is replaced with a word diff of each pair.
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
    try retieMovedWords(alloc, lines, &items);
    return .{ .items = try items.toOwnedSlice(alloc) };
}

/// Replace a delete/add run when git marked the same bytes on both lines of a pair.
fn retieMovedWords(alloc: Allocator, lines: []const diff.Line, items: *std.ArrayList(LineChange)) Error!void {
    var i: usize = 0;
    while (i < lines.len) {
        if (lines[i].kind != .delete) {
            i += 1;
            continue;
        }
        const d0 = i;
        while (i < lines.len and lines[i].kind == .delete) i += 1;
        const d1 = i;
        if (i >= lines.len or lines[i].kind != .add) continue;
        const a0 = i;
        while (i < lines.len and lines[i].kind == .add) i += 1;
        const a1 = i;
        const n = @min(d1 - d0, a1 - a0);
        var moved = false;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const old_line = lines[d0 + j];
            const new_line = lines[a0 + j];
            if (sameBytesMarked(old_line.text, spansAt(items.items, d0 + j), new_line.text, spansAt(items.items, a0 + j)))
                moved = true;
            if (sameBytesMarked(new_line.text, spansAt(items.items, a0 + j), old_line.text, spansAt(items.items, d0 + j)))
                moved = true;
        }
        if (!moved) continue;
        j = 0;
        while (j < n) : (j += 1) {
            const oi = d0 + j;
            const ai = a0 + j;
            const old_spans = spansAt(items.items, oi);
            const new_spans = spansAt(items.items, ai);
            if (newlineSpan(lines[oi].text, old_spans) or newlineSpan(lines[ai].text, new_spans)) continue;
            const paired = try pairedWordSpans(alloc, lines[oi].text, lines[ai].text) orelse continue;
            {
                var old_owned: ?[]Span = paired.old;
                var new_owned: ?[]Span = paired.new;
                errdefer if (old_owned) |s| alloc.free(s);
                errdefer if (new_owned) |s| alloc.free(s);
                try putLineSpans(alloc, items, oi, old_owned.?);
                old_owned = null;
                try putLineSpans(alloc, items, ai, new_owned.?);
                new_owned = null;
            }
        }
    }
}

fn spansAt(items: []const LineChange, index: usize) []const Span {
    for (items) |item| if (item.index == index) return item.spans;
    return &.{};
}

/// True when `a_spans` marks a range that is the same bytes at the same place in `b`,
/// and `b_spans` marks that range too.
fn sameBytesMarked(a: []const u8, a_spans: []const Span, b: []const u8, b_spans: []const Span) bool {
    for (a_spans) |sp| {
        if (sp.start >= sp.end or sp.end > a.len or sp.end > b.len) continue;
        if (!std.mem.eql(u8, a[sp.start..sp.end], b[sp.start..sp.end])) continue;
        for (b_spans) |other| {
            if (other.start <= sp.start and other.end >= sp.end) return true;
        }
    }
    return false;
}

fn newlineSpan(text: []const u8, spans: []const Span) bool {
    for (spans) |sp| if (sp.start >= text.len and sp.end > sp.start) return true;
    return false;
}

const PairedSpans = struct { old: []Span, new: []Span };

/// Word diff of two paired lines. `null` when a line has too many words to compare here.
/// Spans cover consecutive words that are only on that line, including the spaces between them.
fn pairedWordSpans(alloc: Allocator, old_text: []const u8, new_text: []const u8) Error!?PairedSpans {
    const old_words = try wordOffsets(alloc, old_text);
    defer alloc.free(old_words);
    const new_words = try wordOffsets(alloc, new_text);
    defer alloc.free(new_words);
    if (old_words.len > 512 or new_words.len > 512) return null;

    const cols = new_words.len + 1;
    const dp = try alloc.alloc(u32, (old_words.len + 1) * cols);
    defer alloc.free(dp);
    @memset(dp, 0);
    var i: usize = 0;
    while (i < old_words.len) : (i += 1) {
        var j: usize = 0;
        while (j < new_words.len) : (j += 1) {
            const at = (i + 1) * cols + (j + 1);
            if (std.mem.eql(u8, old_text[old_words[i].start..old_words[i].end], new_text[new_words[j].start..new_words[j].end])) {
                dp[at] = dp[i * cols + j] + 1;
            } else {
                const drop_old = dp[i * cols + (j + 1)];
                const drop_new = dp[(i + 1) * cols + j];
                dp[at] = @max(drop_old, drop_new);
            }
        }
    }

    const old_keep = try alloc.alloc(bool, old_words.len);
    defer alloc.free(old_keep);
    const new_keep = try alloc.alloc(bool, new_words.len);
    defer alloc.free(new_keep);
    @memset(old_keep, false);
    @memset(new_keep, false);
    i = old_words.len;
    var j: usize = new_words.len;
    while (i > 0 and j > 0) {
        const ow = old_words[i - 1];
        const nw = new_words[j - 1];
        if (std.mem.eql(u8, old_text[ow.start..ow.end], new_text[nw.start..nw.end])) {
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

    const old_spans = try spansOfUnkept(alloc, old_words, old_keep);
    errdefer alloc.free(old_spans);
    return .{
        .old = old_spans,
        .new = try spansOfUnkept(alloc, new_words, new_keep),
    };
}

fn wordOffsets(alloc: Allocator, text: []const u8) Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and isWordGap(text[i])) i += 1;
        if (i >= text.len) break;
        const start = i;
        while (i < text.len and !isWordGap(text[i])) i += 1;
        try out.append(alloc, .{ .start = start, .end = i });
    }
    if (out.items.len == 0) {
        out.deinit(alloc);
        return try alloc.alloc(Span, 0);
    }
    return try out.toOwnedSlice(alloc);
}

fn spansOfUnkept(alloc: Allocator, words: []const Span, keep: []const bool) Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < words.len) {
        if (keep[i]) {
            i += 1;
            continue;
        }
        const start = words[i].start;
        var end = words[i].end;
        i += 1;
        while (i < words.len and !keep[i]) : (i += 1) end = words[i].end;
        try out.append(alloc, .{ .start = start, .end = end });
    }
    if (out.items.len == 0) {
        out.deinit(alloc);
        return try alloc.alloc(Span, 0);
    }
    return try out.toOwnedSlice(alloc);
}

fn putLineSpans(alloc: Allocator, items: *std.ArrayList(LineChange), index: usize, spans: []Span) Error!void {
    for (items.items) |*item| {
        if (item.index != index) continue;
        const prev = item.spans;
        item.spans = spans;
        alloc.free(prev);
        return;
    }
    try items.append(alloc, .{ .index = index, .spans = spans });
}

/// Write git's changed ranges onto add/delete lines of files in `group`.
/// `group == null` selects untagged files (a range or commit load).
/// Spans are copied into the diff arena. Rows borrow them.
/// A hunk that does not line up is left untouched. Other hunks are still filled.
pub fn attachSpans(
    alloc: Allocator,
    d: *diff.Diff,
    porcelain: []const u8,
    group: ?diff.Group,
) Error!void {
    // One slot per selected hunk. `null` means this hunk did not line up, so its
    // lines stay `null` and keep the solid fill. Later hunks are still recorded.
    var slots: std.ArrayList(?LineChangeList) = .empty;
    defer {
        for (slots.items) |slot| if (slot) |list| list.deinit(alloc);
        slots.deinit(alloc);
    }

    var from: usize = 0;
    var stopped = false;
    for (d.files) |file| {
        if (file.group != group) continue;
        for (file.hunks) |hunk| {
            if (stopped) {
                try slots.append(alloc, null);
                continue;
            }
            const region = hunkRegion(porcelain, from) orelse {
                stopped = true;
                try slots.append(alloc, null);
                continue;
            };
            from = region.end;
            const changes = lineChanges(alloc, hunk.lines, porcelain[region.start..region.end]) catch {
                try slots.append(alloc, null);
                continue;
            };
            slots.append(alloc, changes) catch |err| {
                changes.deinit(alloc);
                return err;
            };
        }
    }

    // Copy into the diff arena. Each add/delete line in a matched hunk is
    // recorded: a real span list, or an empty one when this side has no
    // changed bytes. Context lines stay `null`.
    const arena = d.arena.allocator();
    const none: []const Span = &.{};
    var n: usize = 0;
    for (d.files) |*file| {
        if (file.group != group) continue;
        for (file.hunks) |*hunk| {
            const changes = slots.items[n] orelse {
                n += 1;
                continue;
            };
            n += 1;
            const lines = try arena.alloc(diff.Line, hunk.lines.len);
            for (hunk.lines, 0..) |ln, i| {
                lines[i] = ln;
                if (ln.kind == .add or ln.kind == .delete) lines[i].spans = none;
            }
            for (changes.items) |ch| {
                lines[ch.index].spans = try arena.dupe(Span, ch.spans);
            }
            hunk.lines = lines;
        }
    }
}

fn clipParts(alloc: Allocator, spans: []const Span, parts: []const Part, index: usize) Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(alloc);
    for (parts) |part| {
        if (part.index != index) continue;
        const text_end = part.start + part.len;
        const before = out.items.len;
        for (spans) |span| {
            const lo = @max(span.start, part.start);
            const hi = @min(span.end, text_end);
            if (lo < hi) try out.append(alloc, .{ .start = lo - part.start, .end = hi - part.start });
        }
        // The newline is not a byte of `text`. Record it only when the line
        // has no word span, so a blank added or deleted line is not an empty span list.
        if (out.items.len != before or !part.newline) continue;
        const nl = text_end;
        for (spans) |span| {
            if (span.start <= nl and span.end > nl) {
                try out.append(alloc, .{ .start = part.len, .end = part.len + 1 });
                break;
            }
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
        &.{ .{ .start = 6, .end = 10 }, .{ .start = 16, .end = 24 }, .{ .start = 24, .end = 25 }, .{ .start = 33, .end = 36 } },
    );
    // Whitespace between words is not a word-diff change.
    try expectGitSpans("foo  bar\n", "foo bar\n", &.{}, &.{});
    try expectGitSpans("hello world", "hello there", &.{.{ .start = 6, .end = 11 }}, &.{.{ .start = 6, .end = 11 }});
    // The blank line is an inserted newline, at the byte between the two lines.
    try expectGitSpans("a\nb\n", "a\n\nb\n", &.{}, &.{.{ .start = 2, .end = 3 }});
    // A deleted blank line is that newline on the old side only.
    try expectGitSpans("keep\n\ngone\n", "keep\ngone\n", &.{.{ .start = 5, .end = 6 }}, &.{});
    try expectGitSpans("keep\n\n", "keep\n", &.{.{ .start = 5, .end = 6 }}, &.{});
}

test "gitSpans does not skip a blank line to reach a deleted word" {
    // Two newlines sit in front of the delete. Skipping both would eat the
    // blank line and still rebuild the new side. One newline must not.
    const porcelain =
        \\@@ -1 +1 @@
        \\ keep
        \\-///
        \\ and each id.
        \\~
        \\
    ;
    try testing.expectError(
        error.AlignFailed,
        gitSpans(testing.allocator, porcelain, "keep\n\n/// and each id.\n", "keep and each id.\n"),
    );
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

    try attachSpans(alloc, &d, por, null);
    const spanned = d.files[0].hunks[0].lines;
    const deleted = spanned[try findLine(spanned, .delete, "hello world")].spans.?;
    try testing.expectEqual(1, deleted.len);
    try testing.expectEqual(6, deleted[0].start);
    try testing.expectEqual(11, deleted[0].end);
    const added = spanned[try findLine(spanned, .add, "hello there")].spans.?;
    try testing.expectEqual(1, added.len);
    try testing.expectEqual(6, added[0].start);
    try testing.expectEqual(11, added[0].end);
    const inserted = spanned[try findLine(spanned, .add, "added")].spans.?;
    try testing.expectEqual(1, inserted.len);
    try testing.expectEqual(0, inserted[0].start);
    try testing.expectEqual(5, inserted[0].end);
    const kept = spanned[try findLine(spanned, .context, "keep me")];
    try testing.expect(kept.spans == null);
}

test "an inserted blank line spans the newline past the text" {
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
    try tmp.write(io, "a.txt", "keep\n");
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
        alloc.free(out);
    }
    // A blank line before the added text, and another after it.
    try tmp.write(io, "a.txt", "keep\n\nhello\n\n");

    const uni = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--", "a.txt" });
    defer alloc.free(uni);
    const por = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(por);

    var d = try diff.parse(alloc, uni);
    defer d.deinit();
    try attachSpans(alloc, &d, por, null);
    const lines = d.files[0].hunks[0].lines;

    var blanks: usize = 0;
    for (lines) |ln| {
        if (ln.kind != .add or ln.text.len != 0) continue;
        const sp = ln.spans orelse return error.TestExpectedEqual;
        try testing.expectEqual(1, sp.len);
        try testing.expectEqual(0, sp[0].start);
        try testing.expectEqual(1, sp[0].end);
        blanks += 1;
    }
    try testing.expectEqual(2, blanks);

    const hello = lines[try findLine(lines, .add, "hello")].spans.?;
    try testing.expectEqual(1, hello.len);
    try testing.expectEqual(0, hello[0].start);
    try testing.expectEqual(5, hello[0].end);
    try testing.expect(lines[try findLine(lines, .context, "keep")].spans == null);
}

test "attachSpans writes nothing when porcelain hunks do not match" {
    const fixture =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    try attachSpans(testing.allocator, &d, "", null);
    try testing.expect(d.files[0].hunks[0].lines[0].spans == null);
}

test "a mismatched hunk does not drop spans on the hunks that lined up" {
    const fixture =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\@@ -1 +1 @@
        \\-c
        \\+d
        \\
    ;
    const porcelain =
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\~
        \\@@ -1 +1 @@
        \\-nope
        \\+d
        \\~
        \\
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    try attachSpans(testing.allocator, &d, porcelain, null);
    const hunks = d.files[0].hunks;
    const first = hunks[0].lines[0].spans.?;
    try testing.expectEqual(1, first.len);
    try testing.expectEqual(0, first[0].start);
    try testing.expectEqual(1, first[0].end);
    try testing.expect(hunks[1].lines[0].spans == null);
}

test "an insertion leaves the old line with no changed bytes" {
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
    try tmp.write(io, "a.txt", "hello world\n");
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", "hello ln.text world\n");

    const uni = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--", "a.txt" });
    defer alloc.free(uni);
    const por = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(por);

    var d = try diff.parse(alloc, uni);
    defer d.deinit();
    try attachSpans(alloc, &d, por, null);
    const lines = d.files[0].hunks[0].lines;
    const old = lines[try findLine(lines, .delete, "hello world")].spans.?;
    try testing.expectEqual(0, old.len);
    const new = lines[try findLine(lines, .add, "hello ln.text world")].spans.?;
    try testing.expect(new.len > 0);
}

test "a space before a deleted word still lines up" {
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
    const before = "    if (spans.len > 0 and (kind == .add or kind == .delete)) {\n";
    const after = "    if (kind == .add or kind == .delete) {\n";
    try tmp.write(io, "a.txt", before);
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", after);

    const uni = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--", "a.txt" });
    defer alloc.free(uni);
    const por = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(por);

    var d = try diff.parse(alloc, uni);
    defer d.deinit();
    try attachSpans(alloc, &d, por, null);
    const lines = d.files[0].hunks[0].lines;
    const old = lines[try findLine(lines, .delete, "    if (spans.len > 0 and (kind == .add or kind == .delete)) {")].spans.?;
    try testing.expect(old.len > 0);
    const new = lines[try findLine(lines, .add, "    if (kind == .add or kind == .delete) {")].spans.?;
    try testing.expect(new.len > 0);
    // The leading "    if" is unchanged, so the line is not one solid span.
    try testing.expect(old[0].start > 0);
}

test "a joined line keeps the later word change" {
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
    const before =
        \\/// Old note. Caller frees the list
        \\/// and each id.
        \\    return null;
        \\
    ;
    const after =
        \\/// Old note. Caller frees the list and each id.
        \\    return error.Name;
        \\
    ;
    try tmp.write(io, "a.txt", before);
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", after);

    const uni = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--", "a.txt" });
    defer alloc.free(uni);
    const por = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(por);

    var d = try diff.parse(alloc, uni);
    defer d.deinit();
    try attachSpans(alloc, &d, por, null);
    const lines = d.files[0].hunks[0].lines;

    const moved = lines[try findLine(lines, .delete, "/// Old note. Caller frees the list")];
    try testing.expectEqual(0, moved.spans.?.len);
    const joined = lines[try findLine(lines, .add, "/// Old note. Caller frees the list and each id.")];
    try testing.expectEqual(0, joined.spans.?.len);

    const prefix = lines[try findLine(lines, .delete, "/// and each id.")];
    const prefix_sp = prefix.spans.?;
    try testing.expectEqual(1, prefix_sp.len);
    try testing.expectEqualStrings("///", prefix.text[prefix_sp[0].start..prefix_sp[0].end]);

    const old_ret = lines[try findLine(lines, .delete, "    return null;")];
    const old_sp = old_ret.spans.?;
    try testing.expectEqual(1, old_sp.len);
    try testing.expectEqualStrings("null;", old_ret.text[old_sp[0].start..old_sp[0].end]);

    const new_ret = lines[try findLine(lines, .add, "    return error.Name;")];
    const new_sp = new_ret.spans.?;
    try testing.expectEqual(1, new_sp.len);
    try testing.expectEqualStrings("error.Name;", new_ret.text[new_sp[0].start..new_sp[0].end]);
}

test "a reflowed comment marks the words that moved" {
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
    const before =
        \\    // A blank added line has a span on the newline past `text`. Nothing on the
        \\    // line is an unchanged word, so the row stays the solid fill.
        \\
    ;
    const after =
        \\    // A blank added or deleted line has a span on the newline past `text`.
        \\    // Nothing on the line is an unchanged word, so the row stays the solid fill.
        \\
    ;
    try tmp.write(io, "a.txt", before);
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", after);

    const uni = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--", "a.txt" });
    defer alloc.free(uni);
    const por = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(por);

    var d = try diff.parse(alloc, uni);
    defer d.deinit();
    try attachSpans(alloc, &d, por, null);
    const lines = d.files[0].hunks[0].lines;

    const old_head = "    // A blank added line has a span on the newline past `text`. Nothing on the";
    const removed = lines[try findLine(lines, .delete, old_head)];
    const removed_sp = removed.spans orelse return error.TestExpectedEqual;
    try testing.expectEqual(1, removed_sp.len);
    try testing.expectEqualStrings("Nothing on the", removed.text[removed_sp[0].start..removed_sp[0].end]);

    const new_head = "    // A blank added or deleted line has a span on the newline past `text`.";
    const added = lines[try findLine(lines, .add, new_head)];
    const added_sp = added.spans orelse return error.TestExpectedEqual;
    try testing.expectEqual(1, added_sp.len);
    try testing.expectEqualStrings("or deleted", added.text[added_sp[0].start..added_sp[0].end]);

    const old_tail = "    // line is an unchanged word, so the row stays the solid fill.";
    const old_tail_line = lines[try findLine(lines, .delete, old_tail)];
    const old_tail_sp = old_tail_line.spans orelse return error.TestExpectedEqual;
    try testing.expectEqual(0, old_tail_sp.len);

    const new_tail = "    // Nothing on the line is an unchanged word, so the row stays the solid fill.";
    const moved = lines[try findLine(lines, .add, new_tail)];
    const moved_sp = moved.spans orelse return error.TestExpectedEqual;
    try testing.expectEqual(1, moved_sp.len);
    try testing.expectEqualStrings("Nothing on the", moved.text[moved_sp[0].start..moved_sp[0].end]);
}

test "a deleted blank line is not an empty span list" {
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
    try tmp.write(io, "a.txt", "keep\n\ngone\n");
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "init" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", "keep\ngone\n");

    const uni = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--", "a.txt" });
    defer alloc.free(uni);
    const por = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(por);

    var d = try diff.parse(alloc, uni);
    defer d.deinit();
    try attachSpans(alloc, &d, por, null);
    const blank = d.files[0].hunks[0].lines[try findLine(d.files[0].hunks[0].lines, .delete, "")];
    // An empty span list paints grey. The newline span keeps the solid fill.
    const mid = blank.spans orelse return error.TestExpectedEqual;
    try testing.expectEqual(1, mid.len);
    try testing.expectEqual(0, mid[0].start);
    try testing.expectEqual(1, mid[0].end);

    // A trailing blank line aligns as an extra `~`. It must still be a span.
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "drop middle" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", "keep\ngone\n\n");
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "add", "a.txt" });
        alloc.free(out);
    }
    {
        const out = try gitRun(alloc, io, cwd, &.{ "git", "commit", "-m", "trailing blank" });
        alloc.free(out);
    }
    try tmp.write(io, "a.txt", "keep\ngone\n");

    const uni2 = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--", "a.txt" });
    defer alloc.free(uni2);
    const por2 = try gitRun(alloc, io, cwd, &.{ "git", "diff", "--word-diff=porcelain", "--", "a.txt" });
    defer alloc.free(por2);
    var d2 = try diff.parse(alloc, uni2);
    defer d2.deinit();
    try attachSpans(alloc, &d2, por2, null);
    const end = d2.files[0].hunks[0].lines[try findLine(d2.files[0].hunks[0].lines, .delete, "")];
    const end_sp = end.spans orelse return error.TestExpectedEqual;
    try testing.expectEqual(1, end_sp.len);
    try testing.expectEqual(0, end_sp[0].start);
    try testing.expectEqual(1, end_sp[0].end);
}
