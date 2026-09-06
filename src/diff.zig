//! Unified diff model and parser for `rv`.
//!
//! ## Shape
//!
//! ```text
//! Diff → File* → Hunk* → Line*
//! ```
//!
//! Pure library: no git subprocess, no TUI. Later slices feed this from
//! `git diff` and render the navigable structure.
//!
//! ## Ownership
//!
//! `parse` returns a `Diff` that owns an **arena**. All paths, line text, and
//! nested slices live in that arena. Call `Diff.deinit` exactly once to free
//! everything. Do not free individual fields.
//!
//! ## Line text
//!
//! Body lines store text **without** the leading ` ` / `+` / `-` marker.
//! Meta lines (currently `\ No newline at end of file`) store the message
//! after the leading `\ ` (backslash + space), or the full remainder if the
//! space is missing.
//!
//! ## Binary / noise
//!
//! File sections that only contain binary indicators (or no hunks) produce a
//! `File` with `is_binary = true` and zero hunks. Unknown header lines are
//! ignored. The parser does not error on noise; only allocator failure and
//! hard-broken hunk headers return errors.
//!
//! ## Path precedence
//!
//! Within one file section, later headers win: `---` / `+++` / `rename from|to`
//! overwrite paths first set from `diff --git a/… b/…`. That matches git's
//! usual order and keeps `/dev/null` (add/delete) authoritative.
//!
//! ## Groups
//!
//! `File.group` is the local-load bucket (unstaged / untracked / staged).
//! `parse` leaves it `null`. `parsePieces` sets it per piece. Range diffs
//! stay untagged.
//!
//! ## Expand
//!
//! `Diff.expandHunk` widens one hunk by `expand_amount` context lines on each
//! side, using caller-supplied file text for the surviving side (new path
//! when present, else old). Neighbors in that file that the new window meets
//! or overlaps merge into one hunk. Expansion lives in the in-memory `Diff`
//! until the caller reloads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// Kind of a single line inside a hunk body.
pub const LineKind = enum {
    /// Leading ` ` in the raw diff.
    context,
    /// Leading `+`.
    add,
    /// Leading `-`.
    delete,
    /// Non-body markers such as `\ No newline at end of file`.
    meta,
};

/// One line of a hunk.
pub const Line = struct {
    kind: LineKind,
    /// See module docs: marker stripped for context/add/delete.
    text: []const u8,
    /// 1-based old-file line number when this line exists in the old side.
    old_no: ?u32 = null,
    /// 1-based new-file line number when this line exists in the new side.
    new_no: ?u32 = null,
};

/// One `@@ ... @@` hunk.
pub const Hunk = struct {
    /// 1-based start line in the old file (`0` for pure adds against empty).
    old_start: u32,
    /// Line count in the old side; `null` if the header omitted the count
    /// (unified form treats omitted count as 1 for display elsewhere).
    old_count: ?u32,
    /// 1-based start line in the new file (`0` for pure deletes).
    new_start: u32,
    /// Line count in the new side; `null` if omitted (same as old).
    new_count: ?u32,
    /// Text after the closing `@@` on the header line (may be empty).
    section: []const u8 = "",
    lines: []const Line = &.{},
    /// Stable 0-based index among **all** hunks in the parent `Diff`
    /// (navigation later: next/prev hunk).
    index: usize = 0,
    /// False after expand has reached both file bounds (the `e` hint hides).
    can_grow: bool = true,
};

/// Local default-load bucket. `null` on raw `parse` and range diffs.
pub const Group = enum {
    unstaged,
    untracked,
    staged,
};

/// One file change within a diff.
pub const File = struct {
    /// Path from `---` / `rename from` / `diff --git` old side.
    /// `null` when the file is new (`/dev/null` old side).
    old_path: ?[]const u8 = null,
    /// Path from `+++` / `rename to` / `diff --git` new side.
    /// `null` when the file was deleted (`/dev/null` new side).
    new_path: ?[]const u8 = null,
    hunks: []Hunk = &.{},
    /// True when the section looked binary. Still listed so callers can show
    /// a placeholder even when there are no textual hunks.
    is_binary: bool = false,
    /// Local-load bucket. `null` when untagged (raw `parse`, range diffs).
    group: ?Group = null,

    /// Best path for display: new path, else old path, else `"?"`.
    pub fn displayPath(self: File) []const u8 {
        if (self.new_path) |p| return p;
        if (self.old_path) |p| return p;
        return "?";
    }
};

/// Parsed unified diff. Owns all nested data via an arena.
pub const Diff = struct {
    arena: ArenaAllocator,
    files: []File = &.{},
    /// Total number of hunks across all files (same as max `Hunk.index` + 1).
    hunk_count: usize = 0,

    /// Free the arena (all files/hunks/lines/strings). Invalidates `self`.
    pub fn deinit(self: *Diff) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Grow hunk `hunk_i` of `file_i` by `expand_amount` context lines above
    /// and below. `file_text` is the surviving side and is copied into the
    /// arena; the slice is not retained. Repeatable. No-op on a binary file,
    /// a missing hunk, or when the hunk already sits at both file bounds.
    pub fn expandHunk(
        self: *Diff,
        file_i: usize,
        hunk_i: usize,
        file_text: []const u8,
    ) Allocator.Error!ExpandResult {
        // No file, no textual hunk, or a binary placeholder: nothing to grow.
        if (file_i >= self.files.len) return .noop;
        const file = &self.files[file_i];
        if (file.is_binary or hunk_i >= file.hunks.len) return .noop;

        // Surviving side is the new file when it exists, else the old file.
        const alloc = self.arena.allocator();
        const file_lines = try splitLines(alloc, file_text);
        const file_n: u32 = std.math.cast(u32, file_lines.len) orelse std.math.maxInt(u32);
        const side: ExpandSide = if (file.new_path != null) .new else .old;

        const cur = file.hunks[hunk_i];
        const start = hunkSideStart(cur, side);
        const end = hunkSideEnd(cur, side);
        const other_start = hunkSideStart(cur, if (side == .new) .old else .new);

        // Grow by `expand_amount` on each side, clamped to the file and so
        // the other side's line numbers stay at least 1 when that side exists.
        const room = growSides(start, end, other_start, file_n);
        if (room.up == 0 and room.down == 0) {
            file.hunks[hunk_i].can_grow = false;
            return .noop;
        }
        const up = room.up;
        const down = room.down;

        const want_start = start - up;
        const want_end = end + down;

        // Neighbors in this file whose range meets or overlaps that window.
        var first = hunk_i;
        var last = hunk_i;
        for (file.hunks, 0..) |h, i| {
            const hs = hunkSideStart(h, side);
            const he = hunkSideEnd(h, side);
            if (he == 0 and hs == 0) continue;
            if (want_start <= he +| 1 and hs <= want_end +| 1) {
                first = @min(first, i);
                last = @max(last, i);
            }
        }

        // Result span is the window unioned with every included hunk.
        const lo = file.hunks[first];
        const hi = file.hunks[last];
        const result_start = @min(want_start, hunkSideStart(lo, side));
        const result_end = @max(want_end, hunkSideEnd(hi, side));

        // Prefix context, each included hunk (gap-filled), then suffix context.
        var lines: std.ArrayList(Line) = .empty;
        const lo_start = hunkSideStart(lo, side);
        if (result_start > 0 and result_start < lo_start) {
            try appendContextLines(
                alloc,
                &lines,
                file_lines,
                result_start,
                lo_start - 1,
                side,
                lo.old_start,
                lo.new_start,
            );
        }
        try lines.appendSlice(alloc, lo.lines);
        var prev = lo;
        var i = first + 1;
        while (i <= last) : (i += 1) {
            const h = file.hunks[i];
            const gap_from = hunkSideEnd(prev, side) +| 1;
            const gap_to = hunkSideStart(h, side);
            if (gap_to > 0 and gap_from > 0 and gap_from < gap_to) {
                try appendContextLines(
                    alloc,
                    &lines,
                    file_lines,
                    gap_from,
                    gap_to - 1,
                    side,
                    hunkSideEnd(prev, .old),
                    hunkSideEnd(prev, .new),
                );
            }
            try lines.appendSlice(alloc, h.lines);
            prev = h;
        }
        const prev_end = hunkSideEnd(prev, side);
        if (prev_end > 0 and result_end > prev_end) {
            try appendContextLines(
                alloc,
                &lines,
                file_lines,
                prev_end + 1,
                result_end,
                side,
                hunkSideEnd(prev, .old),
                hunkSideEnd(prev, .new),
            );
        }

        // @@ starts follow the result span; counts are retallied from the lines.
        const counts = lineCounts(lines.items);
        const old_start: u32 = switch (side) {
            .old => result_start,
            .new => pairLine(result_start, lo.new_start, lo.old_start) orelse lo.old_start,
        };
        const new_start: u32 = switch (side) {
            .new => result_start,
            .old => pairLine(result_start, lo.old_start, lo.new_start) orelse lo.new_start,
        };
        const other_after = if (side == .new) old_start else new_start;
        const after = growSides(result_start, result_end, other_after, file_n);
        const merged: Hunk = .{
            .old_start = old_start,
            .old_count = counts.old,
            .new_start = new_start,
            .new_count = counts.new,
            .section = lo.section,
            .lines = try lines.toOwnedSlice(alloc),
            .index = lo.index,
            .can_grow = after.up > 0 or after.down > 0,
        };

        // Replace the included hunks with the one merged hunk; reindex globally.
        const new_len = file.hunks.len - (last - first);
        const new_hunks = try alloc.alloc(Hunk, new_len);
        var out_i: usize = 0;
        for (file.hunks, 0..) |h, hi_i| {
            if (hi_i < first or hi_i > last) {
                new_hunks[out_i] = h;
                out_i += 1;
            } else if (hi_i == first) {
                new_hunks[out_i] = merged;
                out_i += 1;
            }
        }
        file.hunks = new_hunks;
        self.reindex();
        return .expanded;
    }

    fn reindex(self: *Diff) void {
        var n: usize = 0;
        for (self.files) |*f| {
            for (f.hunks) |*h| {
                h.index = n;
                n += 1;
            }
        }
        self.hunk_count = n;
    }
};

/// How many context lines `Diff.expandHunk` adds on each side per call.
pub const expand_amount: u32 = 8;

pub const ExpandResult = enum { expanded, noop };

const ExpandSide = enum { old, new };

fn growSides(start: u32, end: u32, other_start: u32, file_n: u32) struct { up: u32, down: u32 } {
    var up: u32 = 0;
    if (start > 1) {
        up = @min(expand_amount, start - 1);
        if (other_start > 1) {
            up = @min(up, other_start - 1);
        } else if (other_start != 0) {
            up = 0;
        }
    }
    var down: u32 = 0;
    if (end > 0 and end < file_n) {
        down = @min(expand_amount, file_n - end);
    }
    return .{ .up = up, .down = down };
}

fn hunkSideStart(h: Hunk, side: ExpandSide) u32 {
    return switch (side) {
        .old => h.old_start,
        .new => h.new_start,
    };
}

fn hunkSideCount(h: Hunk, side: ExpandSide) u32 {
    const c = switch (side) {
        .old => h.old_count,
        .new => h.new_count,
    };
    return c orelse 1;
}

fn hunkSideEnd(h: Hunk, side: ExpandSide) u32 {
    const count = hunkSideCount(h, side);
    if (count == 0) return 0;
    return hunkSideStart(h, side) + count - 1;
}

fn pairLine(n: u32, n_ref: u32, other_ref: u32) ?u32 {
    if (n == 0 or n_ref == 0 or other_ref == 0) return null;
    if (n >= n_ref) return other_ref + (n - n_ref);
    const back = n_ref - n;
    if (other_ref <= back) return null;
    return other_ref - back;
}

fn lineCounts(lines: []const Line) struct { old: u32, new: u32 } {
    var old: u32 = 0;
    var new: u32 = 0;
    for (lines) |ln| {
        switch (ln.kind) {
            .context => {
                if (ln.old_no != null) old += 1;
                if (ln.new_no != null) new += 1;
            },
            .delete => old += 1,
            .add => new += 1,
            .meta => {},
        }
    }
    return .{ .old = old, .new = new };
}

fn splitLines(alloc: Allocator, text: []const u8) Allocator.Error![][]const u8 {
    if (text.len == 0) {
        const empty: [][]const u8 = &.{};
        return empty;
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        try lines.append(alloc, stripCr(raw));
    }
    if (lines.items.len > 0 and text[text.len - 1] == '\n') {
        _ = lines.pop();
    }
    return try lines.toOwnedSlice(alloc);
}

fn appendContextLines(
    alloc: Allocator,
    out: *std.ArrayList(Line),
    file_lines: []const []const u8,
    from: u32,
    to: u32,
    side: ExpandSide,
    old_ref: u32,
    new_ref: u32,
) Allocator.Error!void {
    if (from == 0 or to == 0 or from > to) return;
    var n = from;
    while (n <= to) : (n += 1) {
        if (n - 1 >= file_lines.len) break;
        try out.append(alloc, .{
            .kind = .context,
            .text = try alloc.dupe(u8, file_lines[n - 1]),
            .old_no = switch (side) {
                .old => n,
                .new => pairLine(n, new_ref, old_ref),
            },
            .new_no = switch (side) {
                .new => n,
                .old => pairLine(n, old_ref, new_ref),
            },
        });
    }
}

pub const ParseError = error{
    /// Hunk header started with `@@` but could not be parsed.
    BadHunkHeader,
} || Allocator.Error;

/// One blob of unified diff and the group to stamp on every file it yields.
pub const ParsePiece = struct {
    text: []const u8,
    group: ?Group = null,
};

/// Parse a unified diff string into an owned `Diff`.
///
/// `alloc` is the backing allocator for the arena. Empty input yields a Diff
/// with zero files (not an error). Files are untagged (`group == null`).
pub fn parse(alloc: Allocator, input: []const u8) ParseError!Diff {
    const pieces = [_]ParsePiece{.{ .text = input }};
    return parsePieces(alloc, &pieces);
}

/// Parse one or more unified-diff blobs into a single `Diff` (one arena).
/// Empty pieces add no files. Hunk indexes continue across pieces.
pub fn parsePieces(alloc: Allocator, pieces: []const ParsePiece) ParseError!Diff {
    var arena = ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    var files: std.ArrayList(File) = .empty;
    defer files.deinit(arena.allocator());

    var hunk_index: usize = 0;
    for (pieces) |piece| {
        try parseAppend(arena.allocator(), piece.text, &files, &hunk_index, piece.group);
    }

    const owned = try files.toOwnedSlice(arena.allocator());
    return .{
        .arena = arena,
        .files = owned,
        .hunk_count = hunk_index,
    };
}

fn parseAppend(
    alloc: Allocator,
    input: []const u8,
    files: *std.ArrayList(File),
    hunk_index: *usize,
    group: ?Group,
) ParseError!void {
    // File section currently being assembled (null until the first header).
    var file_builder: ?FileBuilder = null;
    defer if (file_builder) |*fb| fb.deinit(alloc);

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = stripCr(raw_line);

        // --- file boundary markers ---
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (file_builder) |*fb| {
                try files.append(alloc, try fb.finish(alloc, hunk_index, group));
            }
            file_builder = FileBuilder{};
            try file_builder.?.applyGitHeader(alloc, line);
            continue;
        }

        if (std.mem.startsWith(u8, line, "--- ")) {
            if (file_builder == null) file_builder = FileBuilder{};
            const path = parseFileHeaderPath(line[4..]);
            if (std.mem.eql(u8, path, "/dev/null")) {
                file_builder.?.old_path = null;
            } else {
                file_builder.?.old_path = try alloc.dupe(u8, path);
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "+++ ")) {
            if (file_builder == null) file_builder = FileBuilder{};
            const path = parseFileHeaderPath(line[4..]);
            if (std.mem.eql(u8, path, "/dev/null")) {
                file_builder.?.new_path = null;
            } else {
                file_builder.?.new_path = try alloc.dupe(u8, path);
            }
            continue;
        }

        // rename / copy hints (git)
        if (std.mem.startsWith(u8, line, "rename from ")) {
            if (file_builder == null) file_builder = FileBuilder{};
            file_builder.?.old_path = try alloc.dupe(u8, line["rename from ".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "copy from ")) {
            if (file_builder == null) file_builder = FileBuilder{};
            file_builder.?.old_path = try alloc.dupe(u8, line["copy from ".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "rename to ")) {
            if (file_builder == null) file_builder = FileBuilder{};
            file_builder.?.new_path = try alloc.dupe(u8, line["rename to ".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "copy to ")) {
            if (file_builder == null) file_builder = FileBuilder{};
            file_builder.?.new_path = try alloc.dupe(u8, line["copy to ".len..]);
            continue;
        }

        // binary markers
        if (isBinaryMarker(line)) {
            if (file_builder == null) file_builder = FileBuilder{};
            file_builder.?.is_binary = true;
            continue;
        }

        // hunk header
        if (std.mem.startsWith(u8, line, "@@")) {
            if (file_builder == null) file_builder = FileBuilder{};
            const hdr = try parseHunkHeader(line);
            try file_builder.?.beginHunk(alloc, hdr, hunk_index);
            continue;
        }

        // no-newline marker (applies to previous body line; we record as meta)
        if (std.mem.startsWith(u8, line, "\\")) {
            if (file_builder) |*fb| {
                if (fb.open != null) {
                    const text = if (std.mem.startsWith(u8, line, "\\ "))
                        line[2..]
                    else
                        line[1..];
                    try fb.pushLine(alloc, .{
                        .kind = .meta,
                        .text = try alloc.dupe(u8, text),
                    });
                }
            }
            continue;
        }

        // Hunk body: must start with ` `, `+`, or `-`. A completely blank line
        // is not body text (empty context is a line that is just `" "`). Trailing
        // newlines at EOF must not invent phantom context lines.
        if (file_builder) |*fb| {
            if (fb.open != null and line.len > 0) {
                const marker = line[0];
                if (marker == ' ' or marker == '+' or marker == '-') {
                    const kind: LineKind = switch (marker) {
                        ' ' => .context,
                        '+' => .add,
                        '-' => .delete,
                        else => unreachable,
                    };
                    try fb.pushLine(alloc, .{
                        .kind = kind,
                        .text = try alloc.dupe(u8, line[1..]),
                    });
                    continue;
                }
            }
        }

        // Otherwise: index lines, mode lines, empty separators — ignore.
    }

    if (file_builder) |*fb| {
        try files.append(alloc, try fb.finish(alloc, hunk_index, group));
        file_builder = null;
    }
}

// --- internals -----------------------------------------------------------

const HunkHeader = struct {
    old_start: u32,
    old_count: ?u32,
    new_start: u32,
    new_count: ?u32,
    section: []const u8,
};

/// Header + running line numbers for the hunk currently being filled.
/// Present only while a `@@` body is open (`null` = between hunks / headers).
const OpenHunk = struct {
    old_start: u32,
    old_count: ?u32,
    new_start: u32,
    new_count: ?u32,
    section: []const u8,
    /// Next 1-based line number to assign on the old side (`0` = none).
    next_old: u32,
    /// Next 1-based line number to assign on the new side (`0` = none).
    next_new: u32,
};

const FileBuilder = struct {
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    is_binary: bool = false,
    hunks: std.ArrayList(Hunk) = .empty,
    /// Lines of the open hunk (only meaningful when `open != null`).
    body: std.ArrayList(Line) = .empty,
    /// Non-null while collecting body lines for the current `@@` hunk.
    open: ?OpenHunk = null,

    fn deinit(self: *FileBuilder, a: Allocator) void {
        self.body.deinit(a);
        self.hunks.deinit(a);
    }

    /// Seed paths from `diff --git a/foo b/bar`. Later `---` / `+++` / rename
    /// lines overwrite these (see module "Path precedence").
    fn applyGitHeader(self: *FileBuilder, a: Allocator, line: []const u8) !void {
        const rest = line["diff --git ".len..];
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const p1 = it.next() orelse return;
        const p2 = it.next() orelse return;
        // Always set: this runs on a fresh builder. Later headers may replace.
        self.old_path = try a.dupe(u8, stripGitPrefix(p1));
        self.new_path = try a.dupe(u8, stripGitPrefix(p2));
    }

    fn beginHunk(self: *FileBuilder, a: Allocator, hdr: HunkHeader, hunk_index: *usize) !void {
        try self.closeHunk(a, hunk_index);
        self.open = .{
            .old_start = hdr.old_start,
            .old_count = hdr.old_count,
            .new_start = hdr.new_start,
            .new_count = hdr.new_count,
            .section = try a.dupe(u8, hdr.section),
            .next_old = hdr.old_start,
            .next_new = hdr.new_start,
        };
        self.body.clearRetainingCapacity();
    }

    /// Stamp `old_no` / `new_no` from the open hunk's counters, then advance
    /// those counters the way unified diffs walk both sides:
    /// - context: old and new both advance
    /// - delete: old only
    /// - add: new only
    /// - meta: neither (e.g. "\ No newline at end of file")
    ///
    /// Start `0` means that side is empty (new/deleted file); those lines get
    /// `null` numbers and the counter stays at 0.
    fn pushLine(self: *FileBuilder, a: Allocator, line_in: Line) !void {
        var line = line_in;
        const open = &self.open.?;
        switch (line.kind) {
            .context => {
                line.old_no = if (open.next_old > 0) open.next_old else null;
                line.new_no = if (open.next_new > 0) open.next_new else null;
                if (open.next_old > 0) open.next_old += 1;
                if (open.next_new > 0) open.next_new += 1;
            },
            .delete => {
                line.old_no = if (open.next_old > 0) open.next_old else null;
                line.new_no = null;
                if (open.next_old > 0) open.next_old += 1;
            },
            .add => {
                line.old_no = null;
                line.new_no = if (open.next_new > 0) open.next_new else null;
                if (open.next_new > 0) open.next_new += 1;
            },
            .meta => {},
        }
        try self.body.append(a, line);
    }

    fn closeHunk(self: *FileBuilder, a: Allocator, hunk_index: *usize) !void {
        const open = self.open orelse return;
        const lines = try self.body.toOwnedSlice(a);
        self.body = .empty;
        self.open = null;

        const index = hunk_index.*;
        hunk_index.* += 1;

        try self.hunks.append(a, .{
            .old_start = open.old_start,
            .old_count = open.old_count,
            .new_start = open.new_start,
            .new_count = open.new_count,
            .section = open.section,
            .lines = lines,
            .index = index,
        });
    }

    fn finish(self: *FileBuilder, a: Allocator, hunk_index: *usize, group: ?Group) !File {
        try self.closeHunk(a, hunk_index);
        const hunks = try self.hunks.toOwnedSlice(a);
        self.hunks = .empty;
        return .{
            .old_path = self.old_path,
            .new_path = self.new_path,
            .hunks = hunks,
            .is_binary = self.is_binary,
            .group = group,
        };
    }
};

fn stripCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn isBinaryMarker(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "Binary files ")) return true;
    if (std.mem.startsWith(u8, line, "GIT binary patch")) return true;
    if (std.mem.eql(u8, line, "Binary file differs")) return true;
    return false;
}

/// Strip `a/` or `b/` git prefixes when present; leave other paths alone.
fn stripGitPrefix(path: []const u8) []const u8 {
    if (path.len >= 2 and path[1] == '/' and (path[0] == 'a' or path[0] == 'b')) {
        return path[2..];
    }
    return path;
}

/// `--- a/foo\t` or `+++ b/foo` — drop optional tab+timestamp, strip a/b.
fn parseFileHeaderPath(rest: []const u8) []const u8 {
    var path = rest;
    if (std.mem.indexOfScalar(u8, path, '\t')) |tab| {
        path = path[0..tab];
    }
    // Also tolerate trailing spaces.
    path = std.mem.trimEnd(u8, path, " ");
    if (std.mem.eql(u8, path, "/dev/null")) return path;
    return stripGitPrefix(path);
}

/// Parse a unified hunk header.
///
/// Example inputs:
/// - `@@ -1,3 +1,4 @@`
/// - `@@ -3 +5 @@` (counts omitted)
/// - `@@ -10,2 +11,2 @@ trailing section`
fn parseHunkHeader(line: []const u8) ParseError!HunkHeader {
    // Must start with `@@`.
    // e.g. "@@ -1,3 +1,4 @@ optional"
    if (!std.mem.startsWith(u8, line, "@@")) return error.BadHunkHeader;

    // Cursor into `line` as we walk past each piece of the header.
    var pos: usize = 2;

    // Skip spaces after opening `@@`.
    // "@@ -1…" → pos at '-'
    while (pos < line.len and line[pos] == ' ') : (pos += 1) {}

    // Old range: `-START` or `-START,COUNT`.
    // "@@ -1,3 +1,4 @@" → old = {1, 3}
    if (pos >= line.len or line[pos] != '-') return error.BadHunkHeader;
    pos += 1;
    const old = try parseRange(line, &pos);

    // Skip spaces between ranges.
    while (pos < line.len and line[pos] == ' ') : (pos += 1) {}

    // New range: `+START` or `+START,COUNT`.
    // "@@ -1,3 +1,4 @@" → new = {1, 4}
    if (pos >= line.len or line[pos] != '+') return error.BadHunkHeader;
    pos += 1;
    const new = try parseRange(line, &pos);

    // Skip spaces before closing `@@`.
    while (pos < line.len and line[pos] == ' ') : (pos += 1) {}

    // Consume closing `@@` (tolerate a single trailing `@`).
    if (pos + 1 < line.len and line[pos] == '@' and line[pos + 1] == '@') {
        pos += 2;
    } else if (pos < line.len and line[pos] == '@') {
        pos += 1;
    }

    // Optional section label after the closing `@@`.
    // "@@ -10,2 +11,2 @@ trailing section" → "trailing section"
    while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
    const section = if (pos < line.len) line[pos..] else "";

    return .{
        .old_start = old.start,
        .old_count = old.count,
        .new_start = new.start,
        .new_count = new.count,
        .section = section,
    };
}

const Range = struct { start: u32, count: ?u32 };

/// Read `START` or `START,COUNT` from `line`, advancing `pos`.
///
/// Examples (pos at first digit):
/// - `1,3` → start=1, count=3; pos past `3`
/// - `5`   → start=5, count=null; pos past `5`
fn parseRange(line: []const u8, pos: *usize) ParseError!Range {
    // START digits.
    const start_s = readNumber(line, pos) orelse return error.BadHunkHeader;
    const start = std.fmt.parseInt(u32, start_s, 10) catch return error.BadHunkHeader;

    // Optional `,COUNT`.
    var count: ?u32 = null;
    if (pos.* < line.len and line[pos.*] == ',') {
        pos.* += 1;
        const count_s = readNumber(line, pos) orelse return error.BadHunkHeader;
        count = std.fmt.parseInt(u32, count_s, 10) catch return error.BadHunkHeader;
    }
    return .{ .start = start, .count = count };
}

/// Consume a run of ASCII digits at `pos`, advancing it. Returns null if none.
fn readNumber(line: []const u8, pos: *usize) ?[]const u8 {
    const begin = pos.*;
    while (pos.* < line.len and line[pos.*] >= '0' and line[pos.*] <= '9') : (pos.* += 1) {}
    if (pos.* == begin) return null;
    return line[begin..pos.*];
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

fn expectLine(line: Line, want: struct {
    kind: LineKind,
    text: []const u8,
    old_no: ?u32,
    new_no: ?u32,
}) !void {
    try testing.expectEqual(want.kind, line.kind);
    try testing.expectEqualStrings(want.text, line.text);
    try testing.expectEqual(want.old_no, line.old_no);
    try testing.expectEqual(want.new_no, line.new_no);
}

fn expectHunkMeta(h: Hunk, want: struct {
    index: usize,
    old_start: u32,
    old_count: ?u32,
    new_start: u32,
    new_count: ?u32,
    section: []const u8,
    line_count: usize,
}) !void {
    try testing.expectEqual(want.index, h.index);
    try testing.expectEqual(want.old_start, h.old_start);
    try testing.expectEqual(want.old_count, h.old_count);
    try testing.expectEqual(want.new_start, h.new_start);
    try testing.expectEqual(want.new_count, h.new_count);
    try testing.expectEqualStrings(want.section, h.section);
    try testing.expectEqual(want.line_count, h.lines.len);
}

test "empty input" {
    var diff = try parse(testing.allocator, "");
    defer diff.deinit();
    try testing.expectEqual(0, diff.files.len);
    try testing.expectEqual(0, diff.hunk_count);
}

test "whitespace-only input" {
    var diff = try parse(testing.allocator, "\n\n  \n");
    defer diff.deinit();
    try testing.expectEqual(0, diff.files.len);
    try testing.expectEqual(0, diff.hunk_count);
}

test "parsePieces tags groups and continues hunk indexes" {
    const unstaged_txt =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const staged_txt =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1,2 @@
        \\ same
        \\+staged
    ;
    var d = try parsePieces(testing.allocator, &.{
        .{ .text = unstaged_txt, .group = .unstaged },
        .{ .text = "", .group = .untracked },
        .{ .text = staged_txt, .group = .staged },
    });
    defer d.deinit();

    try testing.expectEqual(2, d.files.len);
    try testing.expectEqual(2, d.hunk_count);
    try testing.expectEqualStrings("a.txt", d.files[0].displayPath());
    try testing.expectEqual(Group.unstaged, d.files[0].group.?);
    try testing.expectEqual(0, d.files[0].hunks[0].index);
    try testing.expectEqualStrings("a.txt", d.files[1].displayPath());
    try testing.expectEqual(Group.staged, d.files[1].group.?);
    try testing.expectEqual(1, d.files[1].hunks[0].index);
}

test "single file multi-hunk with context add delete" {
    const fixture =
        \\diff --git a/hello.txt b/hello.txt
        \\index 111..222 100644
        \\--- a/hello.txt
        \\+++ b/hello.txt
        \\@@ -1,3 +1,4 @@
        \\ line one
        \\-line two
        \\+line two changed
        \\ line three
        \\+line four
        \\@@ -10,2 +11,2 @@ trailing section
        \\ keep
        \\-old
        \\+new
    ;

    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(1, diff.files.len);
    try testing.expectEqual(2, diff.hunk_count);

    const f = diff.files[0];
    try testing.expectEqualStrings("hello.txt", f.old_path.?);
    try testing.expectEqualStrings("hello.txt", f.new_path.?);
    try testing.expectEqualStrings("hello.txt", f.displayPath());
    try testing.expect(!f.is_binary);
    try testing.expect(f.group == null);
    try testing.expectEqual(2, f.hunks.len);

    const h0 = f.hunks[0];
    try expectHunkMeta(h0, .{
        .index = 0,
        .old_start = 1,
        .old_count = 3,
        .new_start = 1,
        .new_count = 4,
        .section = "",
        .line_count = 5,
    });
    try expectLine(h0.lines[0], .{ .kind = .context, .text = "line one", .old_no = 1, .new_no = 1 });
    try expectLine(h0.lines[1], .{ .kind = .delete, .text = "line two", .old_no = 2, .new_no = null });
    try expectLine(h0.lines[2], .{ .kind = .add, .text = "line two changed", .old_no = null, .new_no = 2 });
    try expectLine(h0.lines[3], .{ .kind = .context, .text = "line three", .old_no = 3, .new_no = 3 });
    try expectLine(h0.lines[4], .{ .kind = .add, .text = "line four", .old_no = null, .new_no = 4 });

    const h1 = f.hunks[1];
    try expectHunkMeta(h1, .{
        .index = 1,
        .old_start = 10,
        .old_count = 2,
        .new_start = 11,
        .new_count = 2,
        .section = "trailing section",
        .line_count = 3,
    });
    try expectLine(h1.lines[0], .{ .kind = .context, .text = "keep", .old_no = 10, .new_no = 11 });
    try expectLine(h1.lines[1], .{ .kind = .delete, .text = "old", .old_no = 11, .new_no = null });
    try expectLine(h1.lines[2], .{ .kind = .add, .text = "new", .old_no = null, .new_no = 12 });
}

test "multi-file diff" {
    const fixture =
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-old a
        \\+new a
        \\diff --git a/b.txt b/b.txt
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -1 +1 @@
        \\-old b
        \\+new b
    ;

    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(2, diff.files.len);
    try testing.expectEqual(2, diff.hunk_count);

    const fa = diff.files[0];
    try testing.expectEqualStrings("a.txt", fa.old_path.?);
    try testing.expectEqualStrings("a.txt", fa.new_path.?);
    try testing.expectEqualStrings("a.txt", fa.displayPath());
    try testing.expect(!fa.is_binary);
    try testing.expectEqual(1, fa.hunks.len);
    try expectHunkMeta(fa.hunks[0], .{
        .index = 0,
        .old_start = 1,
        .old_count = null,
        .new_start = 1,
        .new_count = null,
        .section = "",
        .line_count = 2,
    });
    try expectLine(fa.hunks[0].lines[0], .{ .kind = .delete, .text = "old a", .old_no = 1, .new_no = null });
    try expectLine(fa.hunks[0].lines[1], .{ .kind = .add, .text = "new a", .old_no = null, .new_no = 1 });

    const fb = diff.files[1];
    try testing.expectEqualStrings("b.txt", fb.old_path.?);
    try testing.expectEqualStrings("b.txt", fb.new_path.?);
    try testing.expectEqualStrings("b.txt", fb.displayPath());
    try testing.expect(!fb.is_binary);
    try testing.expectEqual(1, fb.hunks.len);
    try expectHunkMeta(fb.hunks[0], .{
        .index = 1,
        .old_start = 1,
        .old_count = null,
        .new_start = 1,
        .new_count = null,
        .section = "",
        .line_count = 2,
    });
    try expectLine(fb.hunks[0].lines[0], .{ .kind = .delete, .text = "old b", .old_no = 1, .new_no = null });
    try expectLine(fb.hunks[0].lines[1], .{ .kind = .add, .text = "new b", .old_no = null, .new_no = 1 });
}

test "add-only new file" {
    const fixture =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1,2 @@
        \\+alpha
        \\+beta
    ;

    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(1, diff.files.len);
    try testing.expectEqual(1, diff.hunk_count);

    const f = diff.files[0];
    try testing.expect(f.old_path == null);
    try testing.expectEqualStrings("new.txt", f.new_path.?);
    try testing.expectEqualStrings("new.txt", f.displayPath());
    try testing.expect(!f.is_binary);
    try testing.expectEqual(1, f.hunks.len);

    const h = f.hunks[0];
    try expectHunkMeta(h, .{
        .index = 0,
        .old_start = 0,
        .old_count = 0,
        .new_start = 1,
        .new_count = 2,
        .section = "",
        .line_count = 2,
    });
    try expectLine(h.lines[0], .{ .kind = .add, .text = "alpha", .old_no = null, .new_no = 1 });
    try expectLine(h.lines[1], .{ .kind = .add, .text = "beta", .old_no = null, .new_no = 2 });
}

test "delete-only removed file" {
    const fixture =
        \\diff --git a/gone.txt b/gone.txt
        \\deleted file mode 100644
        \\--- a/gone.txt
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-one
        \\-two
    ;

    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(1, diff.files.len);
    try testing.expectEqual(1, diff.hunk_count);

    const f = diff.files[0];
    try testing.expectEqualStrings("gone.txt", f.old_path.?);
    try testing.expect(f.new_path == null);
    try testing.expectEqualStrings("gone.txt", f.displayPath());
    try testing.expect(!f.is_binary);
    try testing.expectEqual(1, f.hunks.len);

    const h = f.hunks[0];
    try expectHunkMeta(h, .{
        .index = 0,
        .old_start = 1,
        .old_count = 2,
        .new_start = 0,
        .new_count = 0,
        .section = "",
        .line_count = 2,
    });
    try expectLine(h.lines[0], .{ .kind = .delete, .text = "one", .old_no = 1, .new_no = null });
    try expectLine(h.lines[1], .{ .kind = .delete, .text = "two", .old_no = 2, .new_no = null });
}

test "no newline at end of file marker" {
    const fixture =
        \\diff --git a/x b/x
        \\--- a/x
        \\+++ b/x
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\\ No newline at end of file
    ;

    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(1, diff.files.len);
    try testing.expectEqual(1, diff.hunk_count);

    const f = diff.files[0];
    try testing.expectEqualStrings("x", f.old_path.?);
    try testing.expectEqualStrings("x", f.new_path.?);
    try testing.expectEqualStrings("x", f.displayPath());
    try testing.expect(!f.is_binary);
    try testing.expectEqual(1, f.hunks.len);

    const h = f.hunks[0];
    try expectHunkMeta(h, .{
        .index = 0,
        .old_start = 1,
        .old_count = null,
        .new_start = 1,
        .new_count = null,
        .section = "",
        .line_count = 3,
    });
    try expectLine(h.lines[0], .{ .kind = .delete, .text = "old", .old_no = 1, .new_no = null });
    try expectLine(h.lines[1], .{ .kind = .add, .text = "new", .old_no = null, .new_no = 1 });
    // Meta does not steal a line number from add/delete.
    try expectLine(h.lines[2], .{ .kind = .meta, .text = "No newline at end of file", .old_no = null, .new_no = null });
}

test "rename paths from git headers" {
    const fixture =
        \\diff --git a/old_name.txt b/new_name.txt
        \\similarity index 95%
        \\rename from old_name.txt
        \\rename to new_name.txt
        \\--- a/old_name.txt
        \\+++ b/new_name.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
    ;

    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(1, diff.files.len);
    try testing.expectEqual(1, diff.hunk_count);

    const f = diff.files[0];
    try testing.expectEqualStrings("old_name.txt", f.old_path.?);
    try testing.expectEqualStrings("new_name.txt", f.new_path.?);
    try testing.expectEqualStrings("new_name.txt", f.displayPath());
    try testing.expect(!f.is_binary);
    try testing.expectEqual(1, f.hunks.len);

    const h = f.hunks[0];
    try expectHunkMeta(h, .{
        .index = 0,
        .old_start = 1,
        .old_count = null,
        .new_start = 1,
        .new_count = null,
        .section = "",
        .line_count = 2,
    });
    try expectLine(h.lines[0], .{ .kind = .delete, .text = "a", .old_no = 1, .new_no = null });
    try expectLine(h.lines[1], .{ .kind = .add, .text = "b", .old_no = null, .new_no = 1 });
}

test "binary file does not crash" {
    const fixture =
        \\diff --git a/pic.png b/pic.png
        \\index 111..222 100644
        \\Binary files a/pic.png and b/pic.png differ
        \\diff --git a/ok.txt b/ok.txt
        \\--- a/ok.txt
        \\+++ b/ok.txt
        \\@@ -1 +1 @@
        \\-x
        \\+y
    ;

    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(2, diff.files.len);
    try testing.expectEqual(1, diff.hunk_count);

    const bin = diff.files[0];
    try testing.expectEqualStrings("pic.png", bin.old_path.?);
    try testing.expectEqualStrings("pic.png", bin.new_path.?);
    try testing.expectEqualStrings("pic.png", bin.displayPath());
    try testing.expect(bin.is_binary);
    try testing.expectEqual(0, bin.hunks.len);

    const ok = diff.files[1];
    try testing.expectEqualStrings("ok.txt", ok.old_path.?);
    try testing.expectEqualStrings("ok.txt", ok.new_path.?);
    try testing.expectEqualStrings("ok.txt", ok.displayPath());
    try testing.expect(!ok.is_binary);
    try testing.expectEqual(1, ok.hunks.len);
    try expectHunkMeta(ok.hunks[0], .{
        .index = 0,
        .old_start = 1,
        .old_count = null,
        .new_start = 1,
        .new_count = null,
        .section = "",
        .line_count = 2,
    });
    try expectLine(ok.hunks[0].lines[0], .{ .kind = .delete, .text = "x", .old_no = 1, .new_no = null });
    try expectLine(ok.hunks[0].lines[1], .{ .kind = .add, .text = "y", .old_no = null, .new_no = 1 });
}

test "hunk header omitted counts" {
    const fixture =
        \\--- a/f
        \\+++ b/f
        \\@@ -3 +5 @@
        \\-x
        \\+y
    ;

    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(1, diff.files.len);
    try testing.expectEqual(1, diff.hunk_count);

    const f = diff.files[0];
    try testing.expectEqualStrings("f", f.old_path.?);
    try testing.expectEqualStrings("f", f.new_path.?);
    try testing.expectEqualStrings("f", f.displayPath());
    try testing.expect(!f.is_binary);
    try testing.expectEqual(1, f.hunks.len);

    const h = f.hunks[0];
    try expectHunkMeta(h, .{
        .index = 0,
        .old_start = 3,
        .old_count = null,
        .new_start = 5,
        .new_count = null,
        .section = "",
        .line_count = 2,
    });
    try expectLine(h.lines[0], .{ .kind = .delete, .text = "x", .old_no = 3, .new_no = null });
    try expectLine(h.lines[1], .{ .kind = .add, .text = "y", .old_no = null, .new_no = 5 });
}

test "CRLF line endings" {
    const fixture = "--- a/f\r\n+++ b/f\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n";
    var diff = try parse(testing.allocator, fixture);
    defer diff.deinit();

    try testing.expectEqual(1, diff.files.len);
    try testing.expectEqual(1, diff.hunk_count);

    const f = diff.files[0];
    try testing.expectEqualStrings("f", f.old_path.?);
    try testing.expectEqualStrings("f", f.new_path.?);
    try testing.expectEqualStrings("f", f.displayPath());
    try testing.expect(!f.is_binary);
    try testing.expectEqual(1, f.hunks.len);

    const h = f.hunks[0];
    try expectHunkMeta(h, .{
        .index = 0,
        .old_start = 1,
        .old_count = null,
        .new_start = 1,
        .new_count = null,
        .section = "",
        .line_count = 2,
    });
    try expectLine(h.lines[0], .{ .kind = .delete, .text = "old", .old_no = 1, .new_no = null });
    try expectLine(h.lines[1], .{ .kind = .add, .text = "new", .old_no = null, .new_no = 1 });
}

test "expandHunk grows context and merges a nearby hunk" {
    // Two git -U3 hunks in a 20-line file. Each @@ is "old start,count + new
    // start,count"; space = context, - = old only, + = new only. Hunk 1 is
    // lines 2–8, hunk 2 is 13–19, four-line gap (9–12). One expand (8/side)
    // fills the gap and merges; add/delete lines stay put.
    const fixture =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -2,7 +2,7 @@
        \\ bravo
        \\ charlie
        \\ delta
        \\-EPSILON_OLD
        \\+EPSILON_NEW
        \\ foxtrot
        \\ golf
        \\ hotel
        \\@@ -13,7 +13,7 @@
        \\ mike
        \\ november
        \\ oscar
        \\-PAPA_OLD
        \\+PAPA_NEW
        \\ quebec
        \\ romeo
        \\ sierra
    ;
    const new_file =
        \\alpha
        \\bravo
        \\charlie
        \\delta
        \\EPSILON_NEW
        \\foxtrot
        \\golf
        \\hotel
        \\india
        \\juliet
        \\kilo
        \\lima
        \\mike
        \\november
        \\oscar
        \\PAPA_NEW
        \\quebec
        \\romeo
        \\sierra
        \\tango
        \\
    ;

    var d = try parse(testing.allocator, fixture);
    defer d.deinit();

    try testing.expectEqual(2, d.hunk_count);
    try testing.expectEqual(.expanded, try d.expandHunk(0, 0, new_file));
    try testing.expectEqual(1, d.hunk_count);
    try testing.expectEqual(1, d.files[0].hunks.len);

    // Merged hunk: line 1 through 19, both edits intact, gap now context.
    const h = d.files[0].hunks[0];
    try expectHunkMeta(h, .{
        .index = 0,
        .old_start = 1,
        .old_count = 19,
        .new_start = 1,
        .new_count = 19,
        .section = "",
        .line_count = 21,
    });
    try expectLine(h.lines[0], .{ .kind = .context, .text = "alpha", .old_no = 1, .new_no = 1 });
    try expectLine(h.lines[4], .{ .kind = .delete, .text = "EPSILON_OLD", .old_no = 5, .new_no = null });
    try expectLine(h.lines[5], .{ .kind = .add, .text = "EPSILON_NEW", .old_no = null, .new_no = 5 });
    try expectLine(h.lines[9], .{ .kind = .context, .text = "india", .old_no = 9, .new_no = 9 });
    try expectLine(h.lines[16], .{ .kind = .delete, .text = "PAPA_OLD", .old_no = 16, .new_no = null });
    try expectLine(h.lines[17], .{ .kind = .add, .text = "PAPA_NEW", .old_no = null, .new_no = 16 });
    try expectLine(h.lines[20], .{ .kind = .context, .text = "sierra", .old_no = 19, .new_no = 19 });
    try testing.expect(h.can_grow);

    // Second expand takes the last file line; a third is already at the edge.
    try testing.expectEqual(.expanded, try d.expandHunk(0, 0, new_file));
    try expectHunkMeta(d.files[0].hunks[0], .{
        .index = 0,
        .old_start = 1,
        .old_count = 20,
        .new_start = 1,
        .new_count = 20,
        .section = "",
        .line_count = 22,
    });
    try expectLine(d.files[0].hunks[0].lines[21], .{
        .kind = .context,
        .text = "tango",
        .old_no = 20,
        .new_no = 20,
    });
    try testing.expect(!d.files[0].hunks[0].can_grow);
    try testing.expectEqual(.noop, try d.expandHunk(0, 0, new_file));
    try testing.expect(!d.files[0].hunks[0].can_grow);
}
