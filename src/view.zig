//! Flatten a parsed `Diff` into navigable display rows and keep a cursor
//! inside a scroll viewport. Pure data — no TTY.

const std = @import("std");
const diff = @import("diff");
const Allocator = std.mem.Allocator;

/// One renderable row in the review list. String slices borrow from the
/// parent `Diff` arena (or are static); free only the row slice itself.
pub const Row = union(enum) {
    /// Group divider. Local load only.
    section_header: diff.Group,
    file_header: struct {
        path: []const u8,
        is_binary: bool,
        group: ?diff.Group = null,
    },
    hunk_header: struct {
        old_start: u32,
        old_count: ?u32,
        new_start: u32,
        new_count: ?u32,
        section: []const u8,
        group: ?diff.Group = null,
    },
    line: struct {
        kind: diff.LineKind,
        text: []const u8,
        /// Display path of the owning file (borrowed from `Diff`).
        path: []const u8,
        /// 1-based old-file line when this line exists on the old side.
        old_no: ?u32 = null,
        /// 1-based new-file line when this line exists on the new side.
        new_no: ?u32 = null,
    },
};

/// Line-comment target at the cursor (path + line numbers). `null` on headers
/// and meta lines (not commentable in MVP-1).
pub const Anchor = struct {
    path: []const u8,
    old_line: ?u32,
    new_line: ?u32,
};

/// Build an owned list of rows from `d`. Caller's `alloc` owns the slice;
/// free with `alloc.free(rows)`. Nested string data is borrowed from `d`.
pub fn flatten(alloc: Allocator, d: *const diff.Diff) Allocator.Error![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(alloc);

    var prev_group: ?diff.Group = null;
    for (d.files) |f| {
        if (f.group) |g| {
            if (prev_group == null or prev_group.? != g) {
                try rows.append(alloc, .{ .section_header = g });
                prev_group = g;
            }
        }
        try rows.append(alloc, .{ .file_header = .{
            .path = f.displayPath(),
            .is_binary = f.is_binary,
            .group = f.group,
        } });
        for (f.hunks) |h| {
            try rows.append(alloc, .{ .hunk_header = .{
                .old_start = h.old_start,
                .old_count = h.old_count,
                .new_start = h.new_start,
                .new_count = h.new_count,
                .section = h.section,
                .group = f.group,
            } });
            for (h.lines) |ln| {
                try rows.append(alloc, .{ .line = .{
                    .kind = ln.kind,
                    .text = ln.text,
                    .path = f.displayPath(),
                    .old_no = ln.old_no,
                    .new_no = ln.new_no,
                } });
            }
        }
    }
    return try rows.toOwnedSlice(alloc);
}

/// Clamp `cursor` into `[0, len)` (or `0` when the list is empty).
pub fn clampCursor(cursor: usize, len: usize) usize {
    if (len == 0) return 0;
    if (cursor >= len) return len - 1;
    return cursor;
}

/// Move `scroll` so `cursor` is visible in a viewport of `height` rows.
/// Also clamps scroll so the last page is not overscrolled when possible.
pub fn ensureVisible(scroll: usize, cursor: usize, height: usize, row_count: usize) usize {
    if (height == 0 or row_count == 0) return 0;
    var s = scroll;
    if (cursor < s) s = cursor;
    if (cursor >= s + height) s = cursor + 1 - height;
    const max_scroll = if (row_count > height) row_count - height else 0;
    if (s > max_scroll) s = max_scroll;
    return s;
}

// --- horizontal scroll -------------------------------------------------

/// Largest first-visible display column for content of `content_w` columns
/// in a viewport of `viewport_w` columns. Zero when everything fits.
pub fn maxColScroll(content_w: usize, viewport_w: usize) usize {
    if (viewport_w == 0 or content_w <= viewport_w) return 0;
    return content_w - viewport_w;
}

/// Clamp `col_scroll` into a valid range for the given content and viewport.
pub fn clampColScroll(col_scroll: usize, content_w: usize, viewport_w: usize) usize {
    return @min(col_scroll, maxColScroll(content_w, viewport_w));
}

/// First-visible column so the end of a `content_w`-wide row is on screen
/// (or 0 when the row fits). Same as `maxColScroll`.
pub fn colScrollToEnd(content_w: usize, viewport_w: usize) usize {
    return maxColScroll(content_w, viewport_w);
}

/// Body of the hunk that owns `cursor` (half-open `[body_start, body_end)`).
/// File/hunk headers are never in the body. Empty when not inside a hunk
/// (e.g. cursor on a file header before any `@@` in that file).
pub const HunkSpan = struct {
    /// Index of the owning `.hunk_header`, or `null` when not in a hunk.
    header: ?usize = null,
    /// First `.line` row after the header (equals `body_end` if the hunk is empty).
    body_start: usize = 0,
    /// Exclusive end: next file/hunk header, or `rows.len`.
    body_end: usize = 0,

    pub fn containsBody(self: HunkSpan, i: usize) bool {
        return i >= self.body_start and i < self.body_end;
    }
};

/// Hunk body span for horizontal pan: only lines in this range should scroll.
/// Uses `currentHunkInFile` so a file header does not inherit the previous file's hunk.
pub fn hunkSpanAt(rows: []const Row, cursor: usize) HunkSpan {
    const header = currentHunkInFile(rows, cursor) orelse return .{};
    var end = header + 1;
    while (end < rows.len) : (end += 1) {
        switch (rows[end]) {
            .line => {},
            .hunk_header, .file_header, .section_header => break,
        }
    }
    return .{
        .header = header,
        .body_start = header + 1,
        .body_end = end,
    };
}

// --- layout mode (side-by-side vs unified) -----------------------------

/// User layout preference for the session (not the forced narrow fallback).
///
/// - `side_by_side` (default): use two panes when the terminal is wide enough;
///   auto-fall back to unified when narrow; restore side-by-side on widen.
/// - `unified`: user explicitly chose unified; stay unified even when wide.
pub const LayoutPref = enum {
    side_by_side,
    unified,
};

/// What paint actually uses after applying preference + terminal width.
pub const EffectiveLayout = enum {
    side_by_side,
    unified,
};

/// Minimum usable content columns per side-by-side pane (text + gutter).
pub const min_pane_cols: usize = 24;

/// Center separator between the two panes (one column).
pub const sbs_gutter_cols: usize = 1;

/// Terminal content width below which side-by-side is not usable.
/// `2 * min_pane_cols + sbs_gutter_cols` (currently 49).
pub const min_side_by_side_cols: usize = min_pane_cols * 2 + sbs_gutter_cols;

/// Resolve paint layout from session preference and terminal column count.
///
/// `term_cols` is the full terminal width (same as `Size.cols`). When the
/// user prefers side-by-side but columns are below `min_side_by_side_cols`,
/// returns unified. Explicit unified preference always returns unified.
pub fn effectiveLayout(pref: LayoutPref, term_cols: usize) EffectiveLayout {
    return switch (pref) {
        .unified => .unified,
        .side_by_side => if (term_cols >= min_side_by_side_cols)
            .side_by_side
        else
            .unified,
    };
}

/// Flip session preference (side-by-side ↔ unified). Does not consider width;
/// call `effectiveLayout` after to see what paint will use.
pub fn toggleLayoutPref(pref: LayoutPref) LayoutPref {
    return switch (pref) {
        .side_by_side => .unified,
        .unified => .side_by_side,
    };
}

/// Left/right pane widths for a terminal of `cols` columns (1-cell gutter).
pub const SbsPanes = struct {
    left_w: u16,
    right_w: u16,
    /// Column index of the center gutter cell.
    gutter_x: u16,
};

/// Split `cols` into left | gutter | right. When `cols <= 1`, left takes all
/// columns and right/gutter are zero (not a usable side-by-side layout).
pub fn sbsPaneWidths(cols: u16) SbsPanes {
    if (cols <= 1) {
        return .{ .left_w = cols, .right_w = 0, .gutter_x = 0 };
    }
    const inner: u16 = cols - 1;
    const left: u16 = inner / 2;
    return .{
        .left_w = left,
        .right_w = inner - left,
        .gutter_x = left,
    };
}

// --- side-by-side pairing -----------------------------------------------

/// One screen row in side-by-side layout. Indices refer into the unified
/// `rows` from `flatten` (same lifetime; slots do not own string data).
pub const SbsSlot = union(enum) {
    /// Full-width file, hunk, or section header.
    header: usize,
    /// Body: left pane (old) and/or right pane (new). Context uses the same
    /// index on both sides. An empty pane is `null`.
    pair: struct {
        left: ?usize = null,
        right: ?usize = null,
    },

    /// True when this slot references unified row `row_idx`.
    pub fn containsRow(self: SbsSlot, row_idx: usize) bool {
        return switch (self) {
            .header => |h| h == row_idx,
            .pair => |p| (if (p.left) |L| L == row_idx else false) or
                (if (p.right) |R| R == row_idx else false),
        };
    }
};

/// Primary unified row for cursor mapping: header index, else left, else right.
/// Pair slots always have at least one side set.
pub fn sbsPrimaryRow(slot: SbsSlot) usize {
    return switch (slot) {
        .header => |h| h,
        .pair => |p| p.left orelse p.right.?,
    };
}

/// Index of the first slot that contains unified row `row_idx`, or `null`.
pub fn sbsSlotForRow(slots: []const SbsSlot, row_idx: usize) ?usize {
    for (slots, 0..) |s, i| {
        if (s.containsRow(row_idx)) return i;
    }
    return null;
}

/// Move cursor to the primary unified row of the next side-by-side slot.
/// Unchanged when already on the last slot (or slots/rows empty).
pub fn nextSbsCursor(slots: []const SbsSlot, rows: []const Row, cursor: usize) usize {
    if (slots.len == 0 or rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    const si = sbsSlotForRow(slots, cur) orelse return cur;
    if (si + 1 >= slots.len) return cur;
    return sbsPrimaryRow(slots[si + 1]);
}

/// Move cursor to the primary unified row of the previous side-by-side slot.
/// Unchanged when already on the first slot (or slots/rows empty).
pub fn prevSbsCursor(slots: []const SbsSlot, rows: []const Row, cursor: usize) usize {
    if (slots.len == 0 or rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    const si = sbsSlotForRow(slots, cur) orelse return cur;
    if (si == 0) return cur;
    return sbsPrimaryRow(slots[si - 1]);
}

fn isDeleteLine(row: Row) bool {
    return switch (row) {
        .line => |ln| ln.kind == .delete,
        else => false,
    };
}

fn isAddLine(row: Row) bool {
    return switch (row) {
        .line => |ln| ln.kind == .add,
        else => false,
    };
}

/// Build side-by-side display slots from unified `rows`.
///
/// Pairing within a change run (git-style `-` then `+` block):
/// consecutive deletes followed by consecutive adds are zip-paired;
/// leftover deletes or adds alone get an empty opposite pane. Context
/// lines occupy both panes (same source row). Meta lines sit on the left
/// pane only (v1). File/hunk headers are full-width slots.
///
/// Caller owns the returned slice (`alloc.free`). Nested indices borrow `rows`.
pub fn pairSideBySide(alloc: Allocator, rows: []const Row) Allocator.Error![]SbsSlot {
    var out: std.ArrayList(SbsSlot) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < rows.len) {
        switch (rows[i]) {
            .file_header, .hunk_header, .section_header => {
                try out.append(alloc, .{ .header = i });
                i += 1;
            },
            .line => |ln| switch (ln.kind) {
                .context => {
                    try out.append(alloc, .{ .pair = .{ .left = i, .right = i } });
                    i += 1;
                },
                .meta => {
                    try out.append(alloc, .{ .pair = .{ .left = i, .right = null } });
                    i += 1;
                },
                .delete => {
                    const d0 = i;
                    while (i < rows.len and isDeleteLine(rows[i])) : (i += 1) {}
                    const d1 = i;
                    const a0 = i;
                    while (i < rows.len and isAddLine(rows[i])) : (i += 1) {}
                    const a1 = i;
                    const nd = d1 - d0;
                    const na = a1 - a0;
                    const n = @max(nd, na);
                    var j: usize = 0;
                    while (j < n) : (j += 1) {
                        try out.append(alloc, .{ .pair = .{
                            .left = if (j < nd) d0 + j else null,
                            .right = if (j < na) a0 + j else null,
                        } });
                    }
                },
                .add => {
                    // Pure inserts (no preceding deletes in this run).
                    const a0 = i;
                    while (i < rows.len and isAddLine(rows[i])) : (i += 1) {}
                    var j = a0;
                    while (j < i) : (j += 1) {
                        try out.append(alloc, .{ .pair = .{ .left = null, .right = j } });
                    }
                },
            },
        }
    }
    return try out.toOwnedSlice(alloc);
}

// --- sticky file headers -----------------------------------------------

/// Display-row index to pin above the scrollable content area.
/// `file_idx` is `null` when nothing is sticky. Hunk headers are never sticky
/// (they scroll with the body so transitions stay one row at a time).
pub const Sticky = struct {
    file_idx: ?usize = null,

    /// How many screen rows sticky headers need (0–1).
    pub fn reserved(self: Sticky) usize {
        return if (self.file_idx != null) 1 else 0;
    }
};

/// Row index of the last `.file_header` at or before `cursor`, or `null`.
pub fn currentFileStart(rows: []const Row, cursor: usize) ?usize {
    if (rows.len == 0) return null;
    var i = clampCursor(cursor, rows.len);
    while (true) {
        if (rows[i] == .file_header) return i;
        if (i == 0) return null;
        i -= 1;
    }
}

/// Hunk header that owns `cursor` within the same file, or `null`.
/// Unlike `currentHunkStart`, stops at a file header so a later file's
/// header/body does not inherit the previous file's last hunk.
pub fn currentHunkInFile(rows: []const Row, cursor: usize) ?usize {
    if (rows.len == 0) return null;
    var i = clampCursor(cursor, rows.len);
    while (true) {
        switch (rows[i]) {
            .hunk_header => return i,
            .file_header, .section_header => return null,
            .line => {},
        }
        if (i == 0) return null;
        i -= 1;
    }
}

/// Drop the file pin when the terminal is too short for sticky + a body row.
fn clampStickyToHeight(sticky: Sticky, content_height: usize) Sticky {
    if (content_height == 0) return .{};
    if (sticky.reserved() >= content_height) return .{};
    return sticky;
}

/// Which file header pins above the body for the scroll window.
///
/// Pins the **last** file header that has scrolled **strictly above** the
/// window (`idx < scroll`). The next file header (at `scroll` or below) stays
/// a normal body row until it too scrolls above. Hunk headers are never
/// sticky — they scroll in the body one row at a time.
/// `content_height` caps pins so the cursor can still occupy a body row.
pub fn stickyHeaders(
    rows: []const Row,
    scroll: usize,
    content_height: usize,
) Sticky {
    if (rows.len == 0 or content_height == 0 or scroll == 0) return .{};
    var s: Sticky = .{};
    var i: usize = 0;
    while (i < scroll) : (i += 1) {
        if (rows[i] == .file_header) s.file_idx = i;
    }
    return clampStickyToHeight(s, content_height);
}

/// Scroll + sticky set so `cursor` stays visible below reserved sticky rows.
/// Iterates because sticky depends on scroll and reserved height depends on sticky.
pub fn ensureVisibleSticky(
    scroll: usize,
    cursor: usize,
    content_height: usize,
    rows: []const Row,
) struct { scroll: usize, sticky: Sticky } {
    if (content_height == 0 or rows.len == 0) {
        return .{ .scroll = 0, .sticky = .{} };
    }
    const cur = clampCursor(cursor, rows.len);
    var s = scroll;
    var sticky: Sticky = .{};
    // Sticky ↔ height feedback is small (at most two rows); a few passes settle.
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        sticky = stickyHeaders(rows, s, content_height);
        const h = content_height - sticky.reserved();
        const next = ensureVisible(s, cur, h, rows.len);
        if (next == s) break;
        s = next;
    }
    sticky = stickyHeaders(rows, s, content_height);
    return .{ .scroll = s, .sticky = sticky };
}

/// Sticky file header for side-by-side scroll (slot index space).
/// Pins the last file-header **slot** strictly above `scroll`; `file_idx` is
/// still the unified row index (for formatting).
pub fn stickyHeadersSbs(
    slots: []const SbsSlot,
    rows: []const Row,
    scroll: usize,
    content_height: usize,
) Sticky {
    if (slots.len == 0 or content_height == 0 or scroll == 0) return .{};
    var s: Sticky = .{};
    var i: usize = 0;
    while (i < scroll and i < slots.len) : (i += 1) {
        switch (slots[i]) {
            .header => |ri| if (ri < rows.len and rows[ri] == .file_header) {
                s.file_idx = ri;
            },
            .pair => {},
        }
    }
    return clampStickyToHeight(s, content_height);
}

/// Like `ensureVisibleSticky`, but scroll/cursor visibility use side-by-side
/// **slot** indices. `cursor_row` is still a unified row index.
pub fn ensureVisibleStickySbs(
    scroll: usize,
    cursor_row: usize,
    content_height: usize,
    slots: []const SbsSlot,
    rows: []const Row,
) struct { scroll: usize, sticky: Sticky } {
    if (content_height == 0 or slots.len == 0) {
        return .{ .scroll = 0, .sticky = .{} };
    }
    const cur_row = clampCursor(cursor_row, rows.len);
    const slot_cur = sbsSlotForRow(slots, cur_row) orelse 0;
    var s = scroll;
    var sticky: Sticky = .{};
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        sticky = stickyHeadersSbs(slots, rows, s, content_height);
        const h = content_height - sticky.reserved();
        const next = ensureVisible(s, slot_cur, h, slots.len);
        if (next == s) break;
        s = next;
    }
    sticky = stickyHeadersSbs(slots, rows, s, content_height);
    return .{ .scroll = s, .sticky = sticky };
}

// --- hunk jump + status (MVP-0.4) ----------------------------------------

/// Location context for the status footer. Slices borrow from `rows`.
pub const Status = struct {
    /// Display path of the file containing the cursor (`""` if none).
    path: []const u8,
    /// 1-based index of the current hunk among all hunks; `0` when not in a hunk.
    hunk_i: usize,
    /// Total number of hunk headers in `rows`.
    hunk_n: usize,
    /// 1-based cursor row among all display rows; `0` when empty.
    row_i: usize,
    /// Total display rows.
    row_n: usize,
};

/// Row index of the last `.hunk_header` at or before `cursor`, or `null`.
pub fn currentHunkStart(rows: []const Row, cursor: usize) ?usize {
    if (rows.len == 0) return null;
    var i = clampCursor(cursor, rows.len);
    while (true) {
        if (rows[i] == .hunk_header) return i;
        if (i == 0) return null;
        i -= 1;
    }
}

/// Land on the first add/delete line of the hunk starting at `hunk_start`,
/// or on the hunk header itself when the hunk has no changed lines.
pub fn landOnHunk(rows: []const Row, hunk_start: usize) usize {
    if (hunk_start >= rows.len or rows[hunk_start] != .hunk_header) {
        return clampCursor(hunk_start, rows.len);
    }
    var i = hunk_start + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .line => |ln| switch (ln.kind) {
                .add, .delete => return i,
                .context, .meta => {},
            },
            .hunk_header, .file_header, .section_header => break,
        }
    }
    return hunk_start;
}

/// Jump to the next hunk after the one containing `cursor` (or the first hunk
/// if none). Lands on the first add/delete line. Unchanged when there is no
/// later hunk.
pub fn nextHunk(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const search_from: usize = if (currentHunkStart(rows, cursor)) |s| s + 1 else 0;
    var i = search_from;
    while (i < rows.len) : (i += 1) {
        if (rows[i] == .hunk_header) return landOnHunk(rows, i);
    }
    return clampCursor(cursor, rows.len);
}

/// Jump to the previous hunk before the one containing `cursor`. Lands on the
/// first add/delete line. Unchanged when already on the first hunk (or before
/// any hunk).
pub fn prevHunk(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = currentHunkStart(rows, cursor) orelse return clampCursor(cursor, rows.len);
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (rows[i] == .hunk_header) return landOnHunk(rows, i);
    }
    return clampCursor(cursor, rows.len);
}

/// Jump to the next `.hunk_header` row after `cursor`. Lands on the header
/// itself (not the first add/delete). Unchanged when none follows.
pub fn nextHunkHeader(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur + 1;
    while (i < rows.len) : (i += 1) {
        if (rows[i] == .hunk_header) return i;
    }
    return cur;
}

/// Jump to the previous `.hunk_header` row before `cursor`. Lands on the
/// header itself. From a hunk body this is the current hunk's `@@` row.
/// Unchanged when none precedes.
pub fn prevHunkHeader(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (rows[i] == .hunk_header) return i;
    }
    return cur;
}

/// Jump to the next `.file_header` row after `cursor`. Lands on the file
/// header itself. Unchanged when none follows.
pub fn nextFileHeader(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur + 1;
    while (i < rows.len) : (i += 1) {
        if (rows[i] == .file_header) return i;
    }
    return cur;
}

/// Jump to the previous `.file_header` row before `cursor`. Lands on the
/// file header itself. From a file body this is the current file's header.
/// Unchanged when none precedes.
pub fn prevFileHeader(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (rows[i] == .file_header) return i;
    }
    return cur;
}

/// True when `row` is an add or delete body line (not context/meta/headers).
fn isChangedLine(row: Row) bool {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .add, .delete => true,
            .context, .meta => false,
        },
        .file_header, .hunk_header, .section_header => false,
    };
}

/// First row of the contiguous add/delete run containing `idx`, or `null`
/// when `rows[idx]` is not a changed line. A group is maximal: broken only by
/// context, meta, or headers (same-hunk groups with context between count
/// as separate groups).
fn changeGroupStart(rows: []const Row, idx: usize) ?usize {
    if (idx >= rows.len or !isChangedLine(rows[idx])) return null;
    var i = idx;
    while (i > 0 and isChangedLine(rows[i - 1])) : (i -= 1) {}
    return i;
}

/// Jump to the first line of the next change *group* after `cursor`. A group
/// is a contiguous run of add/delete rows; consecutive changed lines are one
/// group (unlike one-row `j`). Skips context, meta, and headers. Unchanged
/// when no later group exists.
pub fn nextChange(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    var i = cur + 1;
    // Leave the rest of the current group so J ≠ j on multi-line edits.
    if (isChangedLine(rows[cur])) {
        while (i < rows.len and isChangedLine(rows[i])) : (i += 1) {}
    }
    while (i < rows.len) : (i += 1) {
        if (isChangedLine(rows[i])) return i;
    }
    return cur;
}

/// Jump to the first line of the previous change group (or the start of the
/// current group when mid-group). Unchanged when none precedes.
pub fn prevChange(rows: []const Row, cursor: usize) usize {
    if (rows.len == 0) return 0;
    const cur = clampCursor(cursor, rows.len);
    if (changeGroupStart(rows, cur)) |start| {
        if (start < cur) return start;
        // On the first line of this group: step to the previous group.
        var i = start;
        while (i > 0) {
            i -= 1;
            if (isChangedLine(rows[i])) return changeGroupStart(rows, i).?;
        }
        return cur;
    }
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (isChangedLine(rows[i])) return changeGroupStart(rows, i).?;
    }
    return cur;
}

/// Anchor for a line comment at `cursor`, or `null` if the row is not a
/// normal diff body line (file/hunk header or meta).
pub fn anchorAt(rows: []const Row, cursor: usize) ?Anchor {
    if (rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    return switch (rows[cur]) {
        .line => |ln| switch (ln.kind) {
            .meta => null,
            .context, .add, .delete => .{
                .path = ln.path,
                .old_line = ln.old_no,
                .new_line = ln.new_no,
            },
        },
        .file_header, .hunk_header, .section_header => null,
    };
}

pub const CommentSide = enum { old, new };

/// Line-comment target for `want` at `cursor`, or null if that side is missing.
/// Unified: current row only. Side-by-side: current slot left (`old`) / right (`new`).
/// Returned Anchor carries only the chosen side’s line number.
pub fn commentAnchor(
    rows: []const Row,
    slots: []const SbsSlot,
    layout: EffectiveLayout,
    cursor: usize,
    want: CommentSide,
) ?Anchor {
    if (rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    const src: usize = switch (layout) {
        .unified => cur,
        .side_by_side => blk: {
            const si = sbsSlotForRow(slots, cur) orelse return null;
            switch (slots[si]) {
                .header => return null,
                .pair => |p| {
                    const pane: ?usize = switch (want) {
                        .old => p.left,
                        .new => p.right,
                    };
                    break :blk pane orelse return null;
                },
            }
        },
    };
    const a = anchorAt(rows, src) orelse return null;
    return switch (want) {
        .old => if (a.old_line) |n| .{
            .path = a.path,
            .old_line = n,
            .new_line = null,
        } else null,
        .new => if (a.new_line) |n| .{
            .path = a.path,
            .old_line = null,
            .new_line = n,
        } else null,
    };
}

/// Path + side + line of a live comment. `line` is that side's 1-based number.
pub const CommentLoc = struct {
    path: []const u8,
    side: CommentSide,
    line: u32,
};

/// Unified row that holds `loc`, or null if that path/side/line is not in `rows`.
pub fn rowForComment(rows: []const Row, loc: CommentLoc) ?usize {
    for (rows, 0..) |row, i| {
        switch (row) {
            .line => |ln| {
                if (!std.mem.eql(u8, ln.path, loc.path)) continue;
                const no = switch (loc.side) {
                    .old => ln.old_no,
                    .new => ln.new_no,
                };
                if (no == loc.line) return i;
            },
            .file_header, .hunk_header, .section_header => {},
        }
    }
    return null;
}

/// Enough of a cursor to restore after a reload. `path` (and line numbers)
/// borrow from the `rows` passed to `cursorMarkAt`.
pub const CursorMark = struct {
    path: []const u8,
    side: ?CommentSide = null,
    line: ?u32 = null,
};

/// Snapshot of `cursor` for `restoreCursor`. `null` when `rows` is empty.
pub fn cursorMarkAt(rows: []const Row, cursor: usize) ?CursorMark {
    if (rows.len == 0) return null;
    const i = clampCursor(cursor, rows.len);
    switch (rows[i]) {
        .file_header => |fh| return .{ .path = fh.path },
        .section_header => return null,
        .hunk_header => {
            const fi = currentFileStart(rows, i) orelse return null;
            return switch (rows[fi]) {
                .file_header => |fh| .{ .path = fh.path },
                else => null,
            };
        },
        .line => |ln| {
            if (ln.new_no) |n| return .{ .path = ln.path, .side = .new, .line = n };
            if (ln.old_no) |n| return .{ .path = ln.path, .side = .old, .line = n };
            return .{ .path = ln.path };
        },
    }
}

/// Best-effort cursor after reload: same path + side + line, else that file's
/// header, else row 0.
pub fn restoreCursor(rows: []const Row, mark: CursorMark) usize {
    if (rows.len == 0) return 0;
    if (mark.side) |side| {
        if (mark.line) |line| {
            if (rowForComment(rows, .{ .path = mark.path, .side = side, .line = line })) |idx|
                return idx;
        }
    }
    for (rows, 0..) |row, i| {
        switch (row) {
            .file_header => |fh| if (std.mem.eql(u8, fh.path, mark.path)) return i,
            else => {},
        }
    }
    return 0;
}

/// File or hunk to stage/unstage at `cursor`. `path` borrows from `rows`.
/// `whole_file` selects the containing file (`Space S` / `Space x` from a hunk). On a file
/// header, the target is always the file. `null` on empty lists, section
/// headers, and untagged (range) rows.
pub const IndexTarget = struct {
    path: []const u8,
    group: diff.Group,
    /// 0-based hunk in this file; `null` means the whole file.
    hunk_i: ?usize,
    first: usize,
    last: usize,
};

pub fn indexTargetAt(rows: []const Row, cursor: usize, whole_file: bool) ?IndexTarget {
    if (rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    if (rows[cur] == .section_header) return null;
    const fi = currentFileStart(rows, cur) orelse return null;
    const fh = rows[fi].file_header;
    const group = fh.group orelse return null;
    const in_hunk = currentHunkInFile(rows, cur);
    if (whole_file or in_hunk == null) {
        return .{
            .path = fh.path,
            .group = group,
            .hunk_i = null,
            .first = fi,
            .last = rowSpanLast(rows, fi, true),
        };
    }
    const hi = in_hunk.?;
    return .{
        .path = fh.path,
        .group = group,
        .hunk_i = hunkIndexInFile(rows, fi, hi),
        .first = hi,
        .last = rowSpanLast(rows, hi, false),
    };
}

/// Remaining change to land on after the target is removed from this load.
/// `path` borrows from `rows`. `hunk_i` is the index in that file *after*
/// removing a same-file hunk target (unchanged for a different file).
pub const NeighborMark = struct {
    path: []const u8,
    group: diff.Group,
    hunk_i: ?usize,
};

/// Prefer the next file/hunk header after `target.last`; else the previous
/// header before `target.first`. `null` when the target is the only change.
pub fn neighborMark(rows: []const Row, target: IndexTarget) ?NeighborMark {
    if (headerAfter(rows, target.last)) |idx| {
        return markAtHeader(rows, idx, target);
    }
    if (target.first > 0) {
        if (headerBefore(rows, target.first)) |idx| {
            return markAtHeader(rows, idx, target);
        }
    }
    return null;
}

/// Section under the cursor and the last row of its last file. `null` when
/// `cursor` is not a section header.
pub const GroupSpan = struct {
    group: diff.Group,
    first: usize,
    last: usize,
};

pub fn groupSpanAt(rows: []const Row, cursor: usize) ?GroupSpan {
    if (rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    const group = switch (rows[cur]) {
        .section_header => |g| g,
        else => return null,
    };
    var i = cur + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .section_header => return .{ .group = group, .first = cur, .last = i - 1 },
            else => {},
        }
    }
    return .{ .group = group, .first = cur, .last = rows.len - 1 };
}

/// Remaining section or file after a whole-group mutation. `path` borrows
/// from `rows`.
pub const GroupNeighborMark = union(enum) {
    section: diff.Group,
    file: struct { path: []const u8, group: diff.Group },
};

/// Prefer the following section or file after `span.last`; else the previous
/// section or file before `span.first`. `null` when this group is the only
/// change.
pub fn groupNeighborMark(rows: []const Row, span: GroupSpan) ?GroupNeighborMark {
    var i = span.last + 1;
    while (i < rows.len) : (i += 1) {
        if (sectionOrFileMark(rows, i)) |m| return m;
    }
    i = span.first;
    while (i > 0) {
        i -= 1;
        if (sectionOrFileMark(rows, i)) |m| return m;
    }
    return null;
}

/// Land on `mark`'s section or file after reload. Missing mark → row 0.
pub fn restoreGroupNeighbor(rows: []const Row, mark: GroupNeighborMark) usize {
    if (rows.len == 0) return 0;
    switch (mark) {
        .section => |g| {
            for (rows, 0..) |row, i| {
                switch (row) {
                    .section_header => |sg| if (sg == g) return i,
                    else => {},
                }
            }
        },
        .file => |f| {
            for (rows, 0..) |row, i| {
                switch (row) {
                    .file_header => |fh| {
                        const g = fh.group orelse continue;
                        if (g == f.group and std.mem.eql(u8, fh.path, f.path)) return i;
                    },
                    else => {},
                }
            }
        },
    }
    return 0;
}

fn sectionOrFileMark(rows: []const Row, idx: usize) ?GroupNeighborMark {
    switch (rows[idx]) {
        .section_header => |g| return .{ .section = g },
        .file_header => |fh| {
            const g = fh.group orelse return null;
            return .{ .file = .{ .path = fh.path, .group = g } };
        },
        .hunk_header, .line => return null,
    }
}

/// Land on `mark`'s file (and hunk, if set) after reload. Missing hunk → that
/// file's header. Missing file → row 0.
pub fn restoreNeighbor(rows: []const Row, mark: NeighborMark) usize {
    if (rows.len == 0) return 0;
    for (rows, 0..) |row, i| {
        switch (row) {
            .file_header => |fh| {
                const g = fh.group orelse continue;
                if (g != mark.group or !std.mem.eql(u8, fh.path, mark.path)) continue;
                const want = mark.hunk_i orelse return i;
                var n: usize = 0;
                var j = i + 1;
                while (j < rows.len) : (j += 1) {
                    switch (rows[j]) {
                        .hunk_header => {
                            if (n == want) return j;
                            n += 1;
                        },
                        .file_header, .section_header => break,
                        .line => {},
                    }
                }
                return i;
            },
            else => {},
        }
    }
    return 0;
}

fn rowSpanLast(rows: []const Row, start: usize, whole_file: bool) usize {
    var i = start + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .file_header, .section_header => return i - 1,
            .hunk_header => if (!whole_file) return i - 1,
            .line => {},
        }
    }
    return rows.len - 1;
}

fn hunkIndexInFile(rows: []const Row, file_start: usize, hunk_row: usize) usize {
    var n: usize = 0;
    var i = file_start;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .hunk_header => {
                if (i == hunk_row) return n;
                n += 1;
            },
            .file_header => if (i != file_start) return n,
            .section_header => return n,
            .line => {},
        }
    }
    return n;
}

fn headerAfter(rows: []const Row, last: usize) ?usize {
    var i = last + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .file_header, .hunk_header => return i,
            .section_header, .line => {},
        }
    }
    return null;
}

fn headerBefore(rows: []const Row, first: usize) ?usize {
    var i = first;
    while (i > 0) {
        i -= 1;
        switch (rows[i]) {
            .file_header, .hunk_header => return i,
            .section_header, .line => {},
        }
    }
    return null;
}

fn markAtHeader(rows: []const Row, idx: usize, target: IndexTarget) ?NeighborMark {
    const fi = currentFileStart(rows, idx) orelse return null;
    const fh = rows[fi].file_header;
    const group = fh.group orelse return null;
    var hunk_i: ?usize = null;
    if (rows[idx] == .hunk_header) {
        hunk_i = hunkIndexInFile(rows, fi, idx);
        if (target.hunk_i) |t| {
            if (std.mem.eql(u8, fh.path, target.path) and group == target.group) {
                if (hunk_i.? > t) hunk_i = hunk_i.? - 1;
            }
        }
    }
    return .{ .path = fh.path, .group = group, .hunk_i = hunk_i };
}

/// Status footer fields for `cursor` within `rows`.
pub fn statusAt(rows: []const Row, cursor: usize) Status {
    if (rows.len == 0) {
        return .{ .path = "", .hunk_i = 0, .hunk_n = 0, .row_i = 0, .row_n = 0 };
    }
    const cur = clampCursor(cursor, rows.len);
    var path: []const u8 = "";
    var hunk_n: usize = 0;
    var hunk_i: usize = 0;
    var i: usize = 0;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .file_header => |fh| {
                if (i <= cur) path = fh.path;
            },
            .hunk_header => {
                hunk_n += 1;
                if (i <= cur) hunk_i = hunk_n;
            },
            .line, .section_header => {},
        }
    }
    return .{
        .path = path,
        .hunk_i = hunk_i,
        .hunk_n = hunk_n,
        .row_i = cur + 1,
        .row_n = rows.len,
    };
}

// --- diff text search (MVP-3a) -------------------------------------------

/// Result of a text search step. `wrapped` is true when the walk crossed
/// the end (or start) of the row list to find the hit.
pub const SearchHit = struct {
    index: usize,
    wrapped: bool,
};

/// Searchable text for one display row, or `null` if `/` does not search it.
///
/// In scope (v1): add / delete / context **body** line text only. File headers,
/// hunk headers, and meta lines are excluded.
pub fn searchText(row: Row) ?[]const u8 {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .add, .delete, .context => ln.text,
            .meta => null,
        },
        .file_header, .hunk_header, .section_header => null,
    };
}

/// Path string for a `.file_header` row, or `null` on non-header rows.
/// Lands on the file header itself (not the first body/change line).
pub fn searchPath(row: Row) ?[]const u8 {
    return switch (row) {
        .file_header => |fh| fh.path,
        .hunk_header, .line, .section_header => null,
    };
}

/// Case-sensitive substring match against `searchText` for this row.
pub fn rowMatches(row: Row, query: []const u8) bool {
    if (query.len == 0) return false;
    const t = searchText(row) orelse return false;
    return std.mem.indexOf(u8, t, query) != null;
}

/// Case-sensitive substring match against `searchPath` for this row.
pub fn rowPathMatches(row: Row, query: []const u8) bool {
    if (query.len == 0) return false;
    const t = searchPath(row) orelse return false;
    return std.mem.indexOf(u8, t, query) != null;
}

/// First match at or after `cursor`, wrapping from the top if needed.
/// Empty query or no hits → `null`. Used when Enter commits a `/` query.
pub fn firstMatch(rows: []const Row, query: []const u8, cursor: usize) ?SearchHit {
    if (query.len == 0 or rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i < rows.len) : (i += 1) {
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = false };
    }
    i = 0;
    while (i < cur) : (i += 1) {
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = true };
    }
    return null;
}

/// Next match strictly after `cursor`, wrapping around to the start.
/// Unchanged semantics for the caller when `null` (no query / no hits).
pub fn nextMatch(rows: []const Row, query: []const u8, cursor: usize) ?SearchHit {
    if (query.len == 0 or rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    var i = cur + 1;
    while (i < rows.len) : (i += 1) {
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = false };
    }
    i = 0;
    while (i <= cur) : (i += 1) {
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = true };
    }
    return null;
}

/// Previous match strictly before `cursor`, wrapping around to the end.
/// A sole match on `cursor` returns that index with `wrapped = true`.
pub fn prevMatch(rows: []const Row, query: []const u8, cursor: usize) ?SearchHit {
    if (query.len == 0 or rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i > 0) {
        i -= 1;
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = false };
    }
    // Wrap: scan from the last row down through `cur` (inclusive).
    i = rows.len;
    while (i > cur) {
        i -= 1;
        if (rowMatches(rows[i], query)) return .{ .index = i, .wrapped = true };
    }
    return null;
}

/// First file-header path match at or after `cursor`, wrapping from the top.
/// Empty query or no hits → `null`. Multi-match: first hit from the cursor
/// (same walk as `firstMatch`).
pub fn firstPathMatch(rows: []const Row, query: []const u8, cursor: usize) ?SearchHit {
    if (query.len == 0 or rows.len == 0) return null;
    const cur = clampCursor(cursor, rows.len);
    var i = cur;
    while (i < rows.len) : (i += 1) {
        if (rowPathMatches(rows[i], query)) return .{ .index = i, .wrapped = false };
    }
    i = 0;
    while (i < cur) : (i += 1) {
        if (rowPathMatches(rows[i], query)) return .{ .index = i, .wrapped = true };
    }
    return null;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "flatten empty diff" {
    var d = try diff.parse(testing.allocator, "");
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    try testing.expectEqual(0, rows.len);
}

test "flatten file hunk and lines" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expectEqual(4, rows.len);
    try testing.expect(rows[0] == .file_header);
    try testing.expectEqualStrings("f", rows[0].file_header.path);
    try testing.expect(rows[0].file_header.group == null);
    try testing.expect(rows[1] == .hunk_header);
    try testing.expect(rows[1].hunk_header.group == null);
    try testing.expect(rows[2] == .line);
    try testing.expectEqual(diff.LineKind.delete, rows[2].line.kind);
    try testing.expectEqualStrings("old", rows[2].line.text);
    try testing.expectEqualStrings("f", rows[2].line.path);
    try testing.expectEqual(1, rows[2].line.old_no.?);
    try testing.expect(rows[2].line.new_no == null);
    try testing.expect(rows[3] == .line);
    try testing.expectEqual(diff.LineKind.add, rows[3].line.kind);
    try testing.expectEqualStrings("new", rows[3].line.text);
    try testing.expectEqual(1, rows[3].line.new_no.?);
    try testing.expect(rows[3].line.old_no == null);

    try testing.expect(anchorAt(rows, 0) == null);
    try testing.expect(anchorAt(rows, 1) == null);
    const a = anchorAt(rows, 2).?;
    try testing.expectEqualStrings("f", a.path);
    try testing.expectEqual(1, a.old_line.?);
    try testing.expect(a.new_line == null);
}

test "flatten copies file group onto headers and hunks" {
    const unstaged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const staged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1,2 @@
        \\ same
        \\+staged
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = unstaged_txt, .group = .unstaged },
        .{ .text = staged_txt, .group = .staged },
    });
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    // Unstaged header + file/hunk/lines, Staged header + file/hunk/lines.
    try testing.expectEqual(10, rows.len);
    try testing.expect(rows[0] == .section_header);
    try testing.expectEqual(diff.Group.unstaged, rows[0].section_header);
    try testing.expect(rows[1] == .file_header);
    try testing.expect(rows[2] == .hunk_header);
    try testing.expect(rows[5] == .section_header);
    try testing.expectEqual(diff.Group.staged, rows[5].section_header);
    try testing.expect(rows[6] == .file_header);
    try testing.expect(rows[7] == .hunk_header);
    try testing.expectEqual(diff.Group.unstaged, rows[1].file_header.group.?);
    try testing.expectEqual(diff.Group.unstaged, rows[2].hunk_header.group.?);
    try testing.expectEqualStrings("a", rows[1].file_header.path);
    try testing.expectEqual(diff.Group.staged, rows[6].file_header.group.?);
    try testing.expectEqual(diff.Group.staged, rows[7].hunk_header.group.?);
    try testing.expectEqualStrings("a", rows[6].file_header.path);
}

fn threeGroupFixture(alloc: Allocator) !struct { d: diff.Diff, rows: []Row } {
    const unstaged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const untracked_txt =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    const staged_txt =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1,2 @@
        \\ same
        \\+staged
    ;
    var d = try diff.parsePieces(alloc, &.{
        .{ .text = unstaged_txt, .group = .unstaged },
        .{ .text = untracked_txt, .group = .untracked },
        .{ .text = staged_txt, .group = .staged },
    });
    errdefer d.deinit();
    const rows = try flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "flatten inserts section headers at group boundaries" {
    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    // Unstaged (1) + file/hunk/del/add (4) + Untracked (1) + file/hunk/add (3)
    // + Staged (1) + file/hunk/ctx/add (4) = 14.
    try testing.expectEqual(14, rows.len);

    try testing.expectEqual(diff.Group.unstaged, rows[0].section_header);
    try testing.expectEqualStrings("a", rows[1].file_header.path);

    try testing.expectEqual(diff.Group.untracked, rows[5].section_header);
    try testing.expectEqualStrings("u", rows[6].file_header.path);

    try testing.expectEqual(diff.Group.staged, rows[9].section_header);
    try testing.expectEqualStrings("a", rows[10].file_header.path);

    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    for ([_]usize{ 0, 5, 9 }) |ri| {
        const si = sbsSlotForRow(slots, ri).?;
        try testing.expect(slots[si] == .header);
        try testing.expectEqual(ri, slots[si].header);
    }

    try testing.expectEqual(1, nextFileHeader(rows, 0));
    try testing.expectEqual(6, nextFileHeader(rows, 1));
    try testing.expectEqual(6, nextFileHeader(rows, 5));
    try testing.expectEqual(10, nextFileHeader(rows, 6));
    try testing.expectEqual(6, prevFileHeader(rows, 9));
    try testing.expectEqual(6, prevFileHeader(rows, 10));
    try testing.expectEqual(1, prevFileHeader(rows, 6));
    try testing.expectEqual(1, prevFileHeader(rows, 5));

    try testing.expectEqualStrings("", statusAt(rows, 0).path);
    try testing.expectEqualStrings("a", statusAt(rows, 5).path);
    try testing.expect(currentHunkInFile(rows, 0) == null);
    try testing.expect(currentHunkInFile(rows, 5) == null);
    try testing.expect(anchorAt(rows, 0) == null);
    try testing.expect(searchText(rows[0]) == null);
    try testing.expect(searchPath(rows[0]) == null);
}

test "flatten untracked-only still emits one section header" {
    const untracked_txt =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = "", .group = .unstaged },
        .{ .text = untracked_txt, .group = .untracked },
        .{ .text = "", .group = .staged },
    });
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expect(rows[0] == .section_header);
    try testing.expectEqual(diff.Group.untracked, rows[0].section_header);
    try testing.expectEqualStrings("u", rows[1].file_header.path);
}

test "flatten binary file has header only" {
    const fixture =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);

    try testing.expectEqual(1, rows.len);
    try testing.expect(rows[0] == .file_header);
    try testing.expect(rows[0].file_header.is_binary);
    try testing.expectEqualStrings("pic.png", rows[0].file_header.path);
}

test "clampCursor" {
    try testing.expectEqual(0, clampCursor(0, 0));
    try testing.expectEqual(0, clampCursor(5, 0));
    try testing.expectEqual(0, clampCursor(0, 3));
    try testing.expectEqual(2, clampCursor(2, 3));
    try testing.expectEqual(2, clampCursor(99, 3));
}

test "ensureVisible scrolls with cursor" {
    // height 3, 10 rows: cursor at 0 → scroll 0
    try testing.expectEqual(0, ensureVisible(0, 0, 3, 10));
    // cursor moves below window → scroll so cursor is last visible
    try testing.expectEqual(1, ensureVisible(0, 3, 3, 10));
    // cursor above scroll → pull scroll up
    try testing.expectEqual(2, ensureVisible(5, 2, 3, 10));
    // near end: do not overscroll past last page
    try testing.expectEqual(7, ensureVisible(0, 9, 3, 10));
    try testing.expectEqual(0, ensureVisible(0, 0, 3, 2));
    try testing.expectEqual(0, ensureVisible(0, 0, 0, 10));
}

test "maxColScroll and clampColScroll" {
    try testing.expectEqual(0, maxColScroll(10, 20));
    try testing.expectEqual(0, maxColScroll(10, 10));
    try testing.expectEqual(5, maxColScroll(15, 10));
    try testing.expectEqual(0, maxColScroll(15, 0));
    try testing.expectEqual(0, clampColScroll(0, 15, 10));
    try testing.expectEqual(3, clampColScroll(3, 15, 10));
    try testing.expectEqual(5, clampColScroll(99, 15, 10));
    try testing.expectEqual(0, clampColScroll(3, 5, 10));
    try testing.expectEqual(5, colScrollToEnd(15, 10));
    try testing.expectEqual(0, colScrollToEnd(5, 10));
}

test "hunkSpanAt body excludes headers and stops at next hunk/file" {
    // twoHunkFixture: 0 file, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add
    var fix = try twoHunkFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    // On file header: not in a hunk.
    const none = hunkSpanAt(rows, 0);
    try testing.expect(none.header == null);
    try testing.expectEqual(0, none.body_start);
    try testing.expectEqual(0, none.body_end);
    try testing.expect(!none.containsBody(2));

    // On first @@ or its lines: body is 2..4
    const h0 = hunkSpanAt(rows, 1);
    try testing.expectEqual(1, h0.header.?);
    try testing.expectEqual(2, h0.body_start);
    try testing.expectEqual(4, h0.body_end);
    try testing.expect(h0.containsBody(2));
    try testing.expect(h0.containsBody(3));
    try testing.expect(!h0.containsBody(1));
    try testing.expect(!h0.containsBody(4));

    const h0_line = hunkSpanAt(rows, 3);
    try testing.expectEqual(1, h0_line.header.?);
    try testing.expectEqual(2, h0_line.body_start);
    try testing.expectEqual(4, h0_line.body_end);

    // Second hunk
    const h1 = hunkSpanAt(rows, 5);
    try testing.expectEqual(4, h1.header.?);
    try testing.expectEqual(5, h1.body_start);
    try testing.expectEqual(7, h1.body_end);
}

/// Two-hunk fixture: file, h0, del, add, h1, del, add → indices 0..6.
/// Caller owns `d` and `rows` (strings borrow from `d`).
fn twoHunkFixture(alloc: Allocator) !struct { d: diff.Diff, rows: []Row } {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old1
        \\+new1
        \\@@ -10 +10 @@ section
        \\-old2
        \\+new2
    ;
    var d = try diff.parse(alloc, fixture);
    errdefer d.deinit();
    const rows = try flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "nextHunk and prevHunk land on first changed line" {
    var fix = try twoHunkFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(7, rows.len);

    // From file header → first hunk's first delete.
    try testing.expectEqual(2, nextHunk(rows, 0));
    // From first hunk body → second hunk's first delete.
    try testing.expectEqual(5, nextHunk(rows, 2));
    try testing.expectEqual(5, nextHunk(rows, 3));
    // No later hunk.
    try testing.expectEqual(5, nextHunk(rows, 5));
    try testing.expectEqual(6, nextHunk(rows, 6));

    // From second hunk → first hunk land.
    try testing.expectEqual(2, prevHunk(rows, 5));
    try testing.expectEqual(2, prevHunk(rows, 6));
    // Already on first hunk: stay.
    try testing.expectEqual(2, prevHunk(rows, 2));
    try testing.expectEqual(0, prevHunk(rows, 0));
}

// twoHunkFixture layout: 0 file, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add.
test "nextHunkHeader and prevHunkHeader land on @@ rows" {
    var fix = try twoHunkFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(7, rows.len);
    try testing.expect(rows[1] == .hunk_header);
    try testing.expect(rows[4] == .hunk_header);

    // From file header / first body → next is first then second header.
    try testing.expectEqual(1, nextHunkHeader(rows, 0));
    try testing.expectEqual(4, nextHunkHeader(rows, 1));
    try testing.expectEqual(4, nextHunkHeader(rows, 2));
    try testing.expectEqual(4, nextHunkHeader(rows, 3));
    // No later header: stay.
    try testing.expectEqual(4, nextHunkHeader(rows, 4));
    try testing.expectEqual(5, nextHunkHeader(rows, 5));
    try testing.expectEqual(6, nextHunkHeader(rows, 6));

    // From body → current hunk header; from header → previous header.
    try testing.expectEqual(4, prevHunkHeader(rows, 5));
    try testing.expectEqual(4, prevHunkHeader(rows, 6));
    try testing.expectEqual(1, prevHunkHeader(rows, 4));
    try testing.expectEqual(1, prevHunkHeader(rows, 2));
    try testing.expectEqual(1, prevHunkHeader(rows, 3));
    // No earlier header: stay.
    try testing.expectEqual(1, prevHunkHeader(rows, 1));
    try testing.expectEqual(0, prevHunkHeader(rows, 0));

    try testing.expectEqual(0, nextHunkHeader(&.{}, 0));
    try testing.expectEqual(0, prevHunkHeader(&.{}, 0));
}

test "statusAt path and hunk index" {
    var fix = try twoHunkFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    const s0 = statusAt(rows, 0);
    try testing.expectEqualStrings("f", s0.path);
    try testing.expectEqual(0, s0.hunk_i);
    try testing.expectEqual(2, s0.hunk_n);
    try testing.expectEqual(1, s0.row_i);
    try testing.expectEqual(7, s0.row_n);

    const s2 = statusAt(rows, 2);
    try testing.expectEqualStrings("f", s2.path);
    try testing.expectEqual(1, s2.hunk_i);
    try testing.expectEqual(2, s2.hunk_n);

    const s5 = statusAt(rows, 5);
    try testing.expectEqual(2, s5.hunk_i);
    try testing.expectEqual(2, s5.hunk_n);

    const empty = statusAt(&.{}, 0);
    try testing.expectEqual(0, empty.hunk_n);
    try testing.expectEqual(0, empty.row_i);
}

/// Two files, two hunks each. Indices:
/// 0 file A, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add,
/// 7 file B, 8 h2, 9 del, 10 add.
fn twoFileFixture(alloc: Allocator) !struct { d: diff.Diff, rows: []Row } {
    const fixture =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-oldA1
        \\+newA1
        \\@@ -10 +10 @@
        \\-oldA2
        \\+newA2
        \\diff --git a/b b/b
        \\--- a/b
        \\+++ b/b
        \\@@ -1 +1 @@
        \\-oldB
        \\+newB
    ;
    var d = try diff.parse(alloc, fixture);
    errdefer d.deinit();
    const rows = try flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "currentFileStart and currentHunkInFile" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(11, rows.len);

    try testing.expectEqual(0, currentFileStart(rows, 0).?);
    try testing.expectEqual(0, currentFileStart(rows, 5).?);
    try testing.expectEqual(7, currentFileStart(rows, 7).?);
    try testing.expectEqual(7, currentFileStart(rows, 10).?);

    try testing.expect(currentHunkInFile(rows, 0) == null);
    try testing.expectEqual(1, currentHunkInFile(rows, 1).?);
    try testing.expectEqual(1, currentHunkInFile(rows, 3).?);
    try testing.expectEqual(4, currentHunkInFile(rows, 5).?);
    // On next file header: no hunk in this file yet.
    try testing.expect(currentHunkInFile(rows, 7) == null);
    try testing.expectEqual(8, currentHunkInFile(rows, 9).?);
}

// twoFileFixture: 0 fileA … 6, 7 fileB, 8 h2, 9 del, 10 add.
test "nextFileHeader and prevFileHeader land on file rows" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(11, rows.len);
    try testing.expect(rows[0] == .file_header);
    try testing.expect(rows[7] == .file_header);

    // Next file after A body / A header.
    try testing.expectEqual(7, nextFileHeader(rows, 0));
    try testing.expectEqual(7, nextFileHeader(rows, 3));
    try testing.expectEqual(7, nextFileHeader(rows, 6));
    // No later file: stay.
    try testing.expectEqual(7, nextFileHeader(rows, 7));
    try testing.expectEqual(9, nextFileHeader(rows, 9));
    try testing.expectEqual(10, nextFileHeader(rows, 10));

    // From B body → B header; from B header → A header.
    try testing.expectEqual(7, prevFileHeader(rows, 9));
    try testing.expectEqual(7, prevFileHeader(rows, 10));
    try testing.expectEqual(0, prevFileHeader(rows, 7));
    try testing.expectEqual(0, prevFileHeader(rows, 3));
    // No earlier file: stay.
    try testing.expectEqual(0, prevFileHeader(rows, 0));

    // Coexists with hunk-header jump (different landings from same cursor).
    try testing.expectEqual(4, nextHunkHeader(rows, 3));
    try testing.expectEqual(7, nextFileHeader(rows, 3));
    try testing.expectEqual(1, prevHunkHeader(rows, 3));
    try testing.expectEqual(0, prevFileHeader(rows, 3));

    try testing.expectEqual(0, nextFileHeader(&.{}, 0));
    try testing.expectEqual(0, prevFileHeader(&.{}, 0));
}

/// Multi-group fixture (groups can share a hunk when context sits between):
/// 0 file, 1 h0, 2 ctx, 3–5 group0 (del,del,add), 6 ctx, 7–8 group1 (del,add),
/// 9 ctx, 10 h1, 11–12 group2 (del,add).
fn changeNavFixture(alloc: Allocator) !struct { d: diff.Diff, rows: []Row } {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,6 +1,6 @@
        \\ keep
        \\-old1a
        \\-old1b
        \\+new1
        \\ mid
        \\-old2
        \\+new2
        \\ tail
        \\@@ -20 +20 @@
        \\-old3
        \\+new3
    ;
    var d = try diff.parse(alloc, fixture);
    errdefer d.deinit();
    const rows = try flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "searchText is body lines only" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@ section
        \\ keep
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // file, hunk, context, delete, add
    try testing.expect(searchText(rows[0]) == null);
    try testing.expect(searchText(rows[1]) == null);
    try testing.expectEqualStrings("keep", searchText(rows[2]).?);
    try testing.expectEqualStrings("old", searchText(rows[3]).?);
    try testing.expectEqualStrings("new", searchText(rows[4]).?);
    try testing.expect(rowMatches(rows[3], "old"));
    try testing.expect(!rowMatches(rows[3], "OLD"));
    try testing.expect(!rowMatches(rows[0], "f"));
}

test "firstMatch nextMatch prevMatch wrap" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,4 +1,4 @@
        \\ alpha
        \\-beta
        \\+beta2
        \\ gamma alpha
        \\ tail
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk, 2 "alpha", 3 "beta", 4 "beta2", 5 "gamma alpha", 6 "tail"

    const first = firstMatch(rows, "alpha", 0).?;
    try testing.expectEqual(2, first.index);
    try testing.expect(!first.wrapped);

    // Inclusive of cursor when already on a match.
    try testing.expectEqual(2, firstMatch(rows, "alpha", 2).?.index);

    // From after first alpha → second (gamma alpha).
    const n1 = nextMatch(rows, "alpha", 2).?;
    try testing.expectEqual(5, n1.index);
    try testing.expect(!n1.wrapped);

    // Wrap from last alpha back to first.
    const n2 = nextMatch(rows, "alpha", 5).?;
    try testing.expectEqual(2, n2.index);
    try testing.expect(n2.wrapped);

    const p1 = prevMatch(rows, "alpha", 5).?;
    try testing.expectEqual(2, p1.index);
    try testing.expect(!p1.wrapped);

    const p2 = prevMatch(rows, "alpha", 2).?;
    try testing.expectEqual(5, p2.index);
    try testing.expect(p2.wrapped);

    try testing.expect(firstMatch(rows, "nope", 0) == null);
    try testing.expect(firstMatch(rows, "", 0) == null);
    // Headers not searchable.
    try testing.expect(firstMatch(rows, "@@", 0) == null);
}

test "searchPath and firstPathMatch are file headers only" {
    const fixture =
        \\diff --git a/src/app/main.zig b/src/app/main.zig
        \\--- a/src/app/main.zig
        \\+++ b/src/app/main.zig
        \\@@ -1 +1 @@
        \\-oldMain
        \\+newMain
        \\diff --git a/src/view.zig b/src/view.zig
        \\--- a/src/view.zig
        \\+++ b/src/view.zig
        \\@@ -1 +1 @@
        \\-oldView
        \\+newView
        \\diff --git a/lib/util.zig b/lib/util.zig
        \\--- a/lib/util.zig
        \\+++ b/lib/util.zig
        \\@@ -1 +1 @@
        \\-oldUtil
        \\+newUtil
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 main hdr, 1 hunk, 2 del, 3 add,
    // 4 view hdr, 5 hunk, 6 del, 7 add,
    // 8 util hdr, 9 hunk, 10 del, 11 add

    try testing.expectEqualStrings("src/app/main.zig", searchPath(rows[0]).?);
    try testing.expectEqualStrings("src/view.zig", searchPath(rows[4]).?);
    try testing.expectEqualStrings("lib/util.zig", searchPath(rows[8]).?);
    try testing.expect(searchPath(rows[1]) == null);
    try testing.expect(searchPath(rows[2]) == null);
    try testing.expect(searchPath(rows[3]) == null);

    try testing.expect(rowPathMatches(rows[0], "app/main"));
    try testing.expect(rowPathMatches(rows[4], "view"));
    try testing.expect(!rowPathMatches(rows[0], "APP"));
    try testing.expect(!rowPathMatches(rows[2], "app/main"));
    try testing.expect(!rowPathMatches(rows[2], "oldMain"));
    try testing.expect(!rowPathMatches(rows[0], ""));

    const unique = firstPathMatch(rows, "util", 0).?;
    try testing.expectEqual(8, unique.index);
    try testing.expect(!unique.wrapped);

    // Inclusive of cursor when already on a matching header.
    try testing.expectEqual(0, firstPathMatch(rows, "src/", 0).?.index);

    // From after first src file → next src file (not wrap).
    const next_src = firstPathMatch(rows, "src/", 1).?;
    try testing.expectEqual(4, next_src.index);
    try testing.expect(!next_src.wrapped);

    // From past the last src file → wrap to the first.
    const wrap = firstPathMatch(rows, "src/", 5).?;
    try testing.expectEqual(0, wrap.index);
    try testing.expect(wrap.wrapped);

    try testing.expect(firstPathMatch(rows, "nope", 0) == null);
    try testing.expect(firstPathMatch(rows, "", 0) == null);
    // Body text is not a path hit.
    try testing.expect(firstPathMatch(rows, "oldMain", 0) == null);
}

test "nextChange and prevChange jump change groups not single lines" {
    var fix = try changeNavFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    try testing.expectEqual(13, rows.len);
    try testing.expect(rows[2] == .line and rows[2].line.kind == .context);
    try testing.expect(rows[3] == .line and rows[3].line.kind == .delete);
    try testing.expect(rows[4] == .line and rows[4].line.kind == .delete);
    try testing.expect(rows[5] == .line and rows[5].line.kind == .add);
    try testing.expect(rows[6] == .line and rows[6].line.kind == .context);
    try testing.expect(rows[7] == .line and rows[7].line.kind == .delete);
    try testing.expect(rows[8] == .line and rows[8].line.kind == .add);
    try testing.expect(rows[9] == .line and rows[9].line.kind == .context);
    try testing.expect(rows[10] == .hunk_header);
    try testing.expect(rows[11] == .line and rows[11].line.kind == .delete);
    try testing.expect(rows[12] == .line and rows[12].line.kind == .add);

    // From file/hunk/context → first group start.
    try testing.expectEqual(3, nextChange(rows, 0));
    try testing.expectEqual(3, nextChange(rows, 1));
    try testing.expectEqual(3, nextChange(rows, 2));
    // Mid multi-line group: J skips the whole run (not j-like line steps).
    try testing.expectEqual(7, nextChange(rows, 3));
    try testing.expectEqual(7, nextChange(rows, 4));
    try testing.expectEqual(7, nextChange(rows, 5));
    // Context between same-hunk groups → next group.
    try testing.expectEqual(7, nextChange(rows, 6));
    // Across hunk header → next group.
    try testing.expectEqual(11, nextChange(rows, 7));
    try testing.expectEqual(11, nextChange(rows, 8));
    try testing.expectEqual(11, nextChange(rows, 9));
    try testing.expectEqual(11, nextChange(rows, 10));
    // No later group: stay (including mid last group).
    try testing.expectEqual(11, nextChange(rows, 11));
    try testing.expectEqual(12, nextChange(rows, 12));

    // Mid group → current group start; on start → previous group start.
    try testing.expectEqual(11, prevChange(rows, 12));
    try testing.expectEqual(7, prevChange(rows, 11));
    try testing.expectEqual(7, prevChange(rows, 10));
    try testing.expectEqual(7, prevChange(rows, 9));
    try testing.expectEqual(7, prevChange(rows, 8));
    try testing.expectEqual(3, prevChange(rows, 7));
    try testing.expectEqual(3, prevChange(rows, 6));
    try testing.expectEqual(3, prevChange(rows, 5));
    try testing.expectEqual(3, prevChange(rows, 4));
    // No earlier group: stay.
    try testing.expectEqual(3, prevChange(rows, 3));
    try testing.expectEqual(2, prevChange(rows, 2));
    try testing.expectEqual(1, prevChange(rows, 1));
    try testing.expectEqual(0, prevChange(rows, 0));

    // Coexists with header jumps (different landings from mid group0).
    try testing.expectEqual(7, nextChange(rows, 4)); // J → next group
    try testing.expectEqual(10, nextHunkHeader(rows, 4)); // ] → next @@
    try testing.expectEqual(3, prevChange(rows, 4)); // K → group start
    try testing.expectEqual(1, prevHunkHeader(rows, 4)); // [ → @@

    try testing.expectEqual(0, nextChange(&.{}, 0));
    try testing.expectEqual(0, prevChange(&.{}, 0));
}

test "stickyHeaders pins last file above scroll only" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    // 0 fileA, 1 h0, 2 del, 3 add, 4 h1, 5 del, 6 add, 7 fileB, 8 h2, 9 del, 10 add
    const tall: usize = 20;

    // scroll 0: nothing above the window.
    try testing.expect(stickyHeaders(rows, 0, tall).file_idx == null);

    // Mid file A: file sticky; hunks never sticky.
    const mid = stickyHeaders(rows, 3, tall);
    try testing.expectEqual(0, mid.file_idx.?);
    try testing.expectEqual(1, mid.reserved());

    // Hunk boundary inside A: still only file sticky.
    const h1_at_top = stickyHeaders(rows, 4, tall);
    try testing.expectEqual(0, h1_at_top.file_idx.?);

    // File B header at body top: keep sticky file A (B enters as body).
    const on_b = stickyHeaders(rows, 7, tall);
    try testing.expectEqual(0, on_b.file_idx.?);

    // Past file B header: sticky file B.
    const past_b = stickyHeaders(rows, 8, tall);
    try testing.expectEqual(7, past_b.file_idx.?);

    // Deep in file B.
    try testing.expectEqual(7, stickyHeaders(rows, 10, tall).file_idx.?);
}

test "stickyHeaders drops pin on short content height" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    // height 1 keeps only a body row → drop file pin.
    try testing.expectEqual(0, stickyHeaders(rows, 3, 1).reserved());
    // height 2 → file pin fits.
    try testing.expectEqual(1, stickyHeaders(rows, 3, 2).reserved());
    try testing.expectEqual(0, stickyHeaders(rows, 3, 2).file_idx.?);
    try testing.expectEqual(0, stickyHeaders(rows, 3, 0).reserved());
}

test "ensureVisibleSticky reserves file row and keeps cursor in body" {
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;

    // Mid first hunk: file sticky; cursor in reduced body window.
    const r = ensureVisibleSticky(3, 3, 5, rows);
    try testing.expectEqual(0, r.sticky.file_idx.?);
    try testing.expectEqual(1, r.sticky.reserved());
    const body_h = 5 - r.sticky.reserved();
    try testing.expect(r.scroll <= 3);
    try testing.expect(3 < r.scroll + body_h);

    // Deep in file A with a short window.
    const deep = ensureVisibleSticky(0, 6, 3, rows);
    try testing.expect(deep.sticky.file_idx != null);
    try testing.expect(deep.scroll <= 6);
    try testing.expect(6 < deep.scroll + (3 - deep.sticky.reserved()));

    // At top of list: no sticky.
    const top = ensureVisibleSticky(0, 0, 5, rows);
    try testing.expectEqual(0, top.scroll);
    try testing.expectEqual(0, top.sticky.reserved());

    const empty = ensureVisibleSticky(0, 0, 5, &.{});
    try testing.expectEqual(0, empty.scroll);
    try testing.expectEqual(0, empty.sticky.reserved());
}

test "min_side_by_side_cols formula" {
    try testing.expectEqual(min_pane_cols * 2 + sbs_gutter_cols, min_side_by_side_cols);
    try testing.expectEqual(49, min_side_by_side_cols);
}

test "sbsPaneWidths splits evenly with gutter" {
    const p = sbsPaneWidths(49);
    try testing.expectEqual(24, p.left_w);
    try testing.expectEqual(24, p.right_w);
    try testing.expectEqual(24, p.gutter_x);
    try testing.expectEqual(49, p.left_w + 1 + p.right_w);

    const odd = sbsPaneWidths(50);
    try testing.expectEqual(24, odd.left_w);
    try testing.expectEqual(25, odd.right_w);
    try testing.expectEqual(50, odd.left_w + 1 + odd.right_w);

    const tiny = sbsPaneWidths(1);
    try testing.expectEqual(1, tiny.left_w);
    try testing.expectEqual(0, tiny.right_w);
}

test "effectiveLayout prefers side-by-side when wide enough" {
    try testing.expectEqual(EffectiveLayout.side_by_side, effectiveLayout(.side_by_side, min_side_by_side_cols));
    try testing.expectEqual(EffectiveLayout.side_by_side, effectiveLayout(.side_by_side, 120));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.side_by_side, min_side_by_side_cols - 1));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.side_by_side, 0));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.side_by_side, 40));
}

test "effectiveLayout respects explicit unified preference" {
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.unified, 200));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.unified, min_side_by_side_cols));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(.unified, 0));
}

test "toggleLayoutPref flips and restore uses side-by-side when wide" {
    try testing.expectEqual(LayoutPref.unified, toggleLayoutPref(.side_by_side));
    try testing.expectEqual(LayoutPref.side_by_side, toggleLayoutPref(.unified));

    // User forced unified → widen still unified.
    var pref = LayoutPref.side_by_side;
    pref = toggleLayoutPref(pref);
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(pref, 120));

    // Toggle back → side-by-side when wide, auto-unified when narrow.
    pref = toggleLayoutPref(pref);
    try testing.expectEqual(EffectiveLayout.side_by_side, effectiveLayout(pref, 120));
    try testing.expectEqual(EffectiveLayout.unified, effectiveLayout(pref, 30));
}

test "pairSideBySide empty" {
    const slots = try pairSideBySide(testing.allocator, &.{});
    defer testing.allocator.free(slots);
    try testing.expectEqual(0, slots.len);
}

test "pairSideBySide zips delete then add" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    // file, hunk, one paired body row (delete|add)
    try testing.expectEqual(3, slots.len);
    try testing.expectEqual(0, slots[0].header);
    try testing.expectEqual(1, slots[1].header);
    try testing.expectEqual(2, slots[2].pair.left.?);
    try testing.expectEqual(3, slots[2].pair.right.?);

    try testing.expectEqual(2, sbsSlotForRow(slots, 2).?);
    try testing.expectEqual(2, sbsSlotForRow(slots, 3).?);
    try testing.expectEqual(2, sbsPrimaryRow(slots[2]));
    try testing.expect(slots[2].containsRow(2));
    try testing.expect(slots[2].containsRow(3));
    try testing.expect(!slots[2].containsRow(0));
}

test "pairSideBySide context both panes same row" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    // 0 file, 1 hunk, 2 ctx, 3 del|add, 4 ctx
    try testing.expectEqual(5, slots.len);
    try testing.expectEqual(2, slots[2].pair.left.?);
    try testing.expectEqual(2, slots[2].pair.right.?);
    try testing.expectEqual(3, slots[3].pair.left.?);
    try testing.expectEqual(4, slots[3].pair.right.?);
    try testing.expectEqual(5, slots[4].pair.left.?);
    try testing.expectEqual(5, slots[4].pair.right.?);
}

test "pairSideBySide unequal change runs" {
    // 2 deletes + 1 add → pair then left-only leftover delete
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,2 +1 @@
        \\-a
        \\-b
        \\+c
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    try testing.expectEqual(4, slots.len); // file, hunk, pair, left-only
    try testing.expectEqual(2, slots[2].pair.left.?);
    try testing.expectEqual(4, slots[2].pair.right.?);
    try testing.expectEqual(3, slots[3].pair.left.?);
    try testing.expect(slots[3].pair.right == null);

    // 1 delete + 2 adds → pair then right-only leftover add
    const fixture2 =
        \\diff --git a/g b/g
        \\--- a/g
        \\+++ b/g
        \\@@ -1 +1,2 @@
        \\-x
        \\+y
        \\+z
    ;
    var d2 = try diff.parse(testing.allocator, fixture2);
    defer d2.deinit();
    const rows2 = try flatten(testing.allocator, &d2);
    defer testing.allocator.free(rows2);
    const slots2 = try pairSideBySide(testing.allocator, rows2);
    defer testing.allocator.free(slots2);

    try testing.expectEqual(4, slots2.len);
    try testing.expectEqual(2, slots2[2].pair.left.?);
    try testing.expectEqual(3, slots2[2].pair.right.?);
    try testing.expect(slots2[3].pair.left == null);
    try testing.expectEqual(4, slots2[3].pair.right.?);
}

test "pairSideBySide pure adds and pure deletes" {
    const adds_only =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -0,0 +1,2 @@
        \\+a
        \\+b
    ;
    var d = try diff.parse(testing.allocator, adds_only);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    try testing.expectEqual(4, slots.len);
    try testing.expect(slots[2].pair.left == null);
    try testing.expectEqual(2, slots[2].pair.right.?);
    try testing.expect(slots[3].pair.left == null);
    try testing.expectEqual(3, slots[3].pair.right.?);

    const dels_only =
        \\diff --git a/g b/g
        \\--- a/g
        \\+++ b/g
        \\@@ -1,2 +0,0 @@
        \\-a
        \\-b
    ;
    var d2 = try diff.parse(testing.allocator, dels_only);
    defer d2.deinit();
    const rows2 = try flatten(testing.allocator, &d2);
    defer testing.allocator.free(rows2);
    const slots2 = try pairSideBySide(testing.allocator, rows2);
    defer testing.allocator.free(slots2);

    try testing.expectEqual(4, slots2.len);
    try testing.expectEqual(2, slots2[2].pair.left.?);
    try testing.expect(slots2[2].pair.right == null);
    try testing.expectEqual(3, slots2[3].pair.left.?);
    try testing.expect(slots2[3].pair.right == null);
}

test "pairSideBySide meta left only; slot lookup" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\\ No newline at end of file
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // file, hunk, del, meta, add — meta breaks the delete→add run
    try testing.expect(rows[3] == .line);
    try testing.expectEqual(diff.LineKind.meta, rows[3].line.kind);

    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    // file, hunk, left-only del, left-only meta, right-only add
    try testing.expectEqual(5, slots.len);
    try testing.expectEqual(2, slots[2].pair.left.?);
    try testing.expect(slots[2].pair.right == null);
    try testing.expectEqual(3, slots[3].pair.left.?);
    try testing.expect(slots[3].pair.right == null);
    try testing.expect(slots[4].pair.left == null);
    try testing.expectEqual(4, slots[4].pair.right.?);

    try testing.expectEqual(0, sbsSlotForRow(slots, 0).?);
    try testing.expectEqual(3, sbsSlotForRow(slots, 3).?);
    try testing.expect(sbsSlotForRow(slots, 99) == null);
}

test "nextSbsCursor and prevSbsCursor step by slot" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    // slots: file, hunk, ctx, del|add, ctx  (5 slots; rows 0..5)
    try testing.expectEqual(5, slots.len);

    // From file header → hunk header (primary = that header row).
    try testing.expectEqual(1, nextSbsCursor(slots, rows, 0));
    // From hunk → context row 2.
    try testing.expectEqual(2, nextSbsCursor(slots, rows, 1));
    // From context → paired change (primary = delete row 3, not add row 4).
    try testing.expectEqual(3, nextSbsCursor(slots, rows, 2));
    // From delete (or add in same slot) → tail context row 5 in one step.
    try testing.expectEqual(5, nextSbsCursor(slots, rows, 3));
    try testing.expectEqual(5, nextSbsCursor(slots, rows, 4));
    // Last slot stays put.
    try testing.expectEqual(5, nextSbsCursor(slots, rows, 5));

    try testing.expectEqual(3, prevSbsCursor(slots, rows, 5));
    try testing.expectEqual(2, prevSbsCursor(slots, rows, 3));
    try testing.expectEqual(2, prevSbsCursor(slots, rows, 4));
    try testing.expectEqual(0, prevSbsCursor(slots, rows, 0));
}

test "ensureVisibleStickySbs uses slot indices" {
    // Zip-paired del|add → fewer slots than rows; cursor on add maps to pair slot.
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    try testing.expectEqual(3, slots.len);

    // Cursor on add (row 3) → slot 2; short window should scroll to show it.
    const r = ensureVisibleStickySbs(0, 3, 2, slots, rows);
    try testing.expectEqual(2, sbsSlotForRow(slots, 3).?);
    try testing.expect(r.scroll <= 2);
    try testing.expect(2 < r.scroll + (2 - r.sticky.reserved()));

    // File header sticky when scrolled past it (multi-file).
    var fix = try twoFileFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const slots2 = try pairSideBySide(testing.allocator, fix.rows);
    defer testing.allocator.free(slots2);
    // Scroll past first file's slots; pin file A.
    const deep = ensureVisibleStickySbs(0, fix.rows.len - 1, 3, slots2, fix.rows);
    try testing.expect(deep.sticky.file_idx != null or deep.scroll == 0);
}

test "commentAnchor unified add delete context header" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const empty: []const SbsSlot = &.{};

    try testing.expect(commentAnchor(rows, empty, .unified, 0, .new) == null);
    try testing.expect(commentAnchor(rows, empty, .unified, 0, .old) == null);
    try testing.expect(commentAnchor(rows, empty, .unified, 1, .new) == null);
    try testing.expect(commentAnchor(rows, empty, .unified, 1, .old) == null);

    const ctx_new = commentAnchor(rows, empty, .unified, 2, .new).?;
    try testing.expectEqualStrings("f", ctx_new.path);
    try testing.expectEqual(1, ctx_new.new_line.?);
    try testing.expect(ctx_new.old_line == null);
    const ctx_old = commentAnchor(rows, empty, .unified, 2, .old).?;
    try testing.expectEqual(1, ctx_old.old_line.?);
    try testing.expect(ctx_old.new_line == null);

    try testing.expect(commentAnchor(rows, empty, .unified, 3, .new) == null);
    const del = commentAnchor(rows, empty, .unified, 3, .old).?;
    try testing.expectEqual(2, del.old_line.?);
    try testing.expect(del.new_line == null);

    const add = commentAnchor(rows, empty, .unified, 4, .new).?;
    try testing.expectEqual(2, add.new_line.?);
    try testing.expect(add.old_line == null);
    try testing.expect(commentAnchor(rows, empty, .unified, 4, .old) == null);

    try testing.expect(commentAnchor(&.{}, empty, .unified, 0, .new) == null);
    try testing.expect(commentAnchor(&.{}, empty, .unified, 0, .old) == null);
}

test "commentAnchor side-by-side pair empty pane header" {
    const pair_fix =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, pair_fix);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);

    try testing.expect(commentAnchor(rows, slots, .side_by_side, 0, .new) == null);
    try testing.expect(commentAnchor(rows, slots, .side_by_side, 0, .old) == null);
    try testing.expect(commentAnchor(rows, slots, .side_by_side, 1, .new) == null);
    try testing.expect(commentAnchor(rows, slots, .side_by_side, 1, .old) == null);

    // Cursor on the delete (slot primary) or the add (same slot) → same sides.
    const from_del_new = commentAnchor(rows, slots, .side_by_side, 2, .new).?;
    try testing.expectEqualStrings("f", from_del_new.path);
    try testing.expectEqual(1, from_del_new.new_line.?);
    try testing.expect(from_del_new.old_line == null);
    const from_del_old = commentAnchor(rows, slots, .side_by_side, 2, .old).?;
    try testing.expectEqual(1, from_del_old.old_line.?);
    try testing.expect(from_del_old.new_line == null);
    const from_add_new = commentAnchor(rows, slots, .side_by_side, 3, .new).?;
    try testing.expectEqual(1, from_add_new.new_line.?);
    try testing.expect(from_add_new.old_line == null);
    const from_add_old = commentAnchor(rows, slots, .side_by_side, 3, .old).?;
    try testing.expectEqual(1, from_add_old.old_line.?);
    try testing.expect(from_add_old.new_line == null);

    const leftover =
        \\diff --git a/g b/g
        \\--- a/g
        \\+++ b/g
        \\@@ -1,2 +1 @@
        \\-a
        \\-b
        \\+c
    ;
    var d2 = try diff.parse(testing.allocator, leftover);
    defer d2.deinit();
    const rows2 = try flatten(testing.allocator, &d2);
    defer testing.allocator.free(rows2);
    const slots2 = try pairSideBySide(testing.allocator, rows2);
    defer testing.allocator.free(slots2);
    // leftover delete `b` is left-only (row 3)
    try testing.expect(commentAnchor(rows2, slots2, .side_by_side, 3, .new) == null);
    const left_only = commentAnchor(rows2, slots2, .side_by_side, 3, .old).?;
    try testing.expectEqual(2, left_only.old_line.?);
    try testing.expect(left_only.new_line == null);

    const leftover_add =
        \\diff --git a/h b/h
        \\--- a/h
        \\+++ b/h
        \\@@ -1 +1,2 @@
        \\-x
        \\+y
        \\+z
    ;
    var d3 = try diff.parse(testing.allocator, leftover_add);
    defer d3.deinit();
    const rows3 = try flatten(testing.allocator, &d3);
    defer testing.allocator.free(rows3);
    const slots3 = try pairSideBySide(testing.allocator, rows3);
    defer testing.allocator.free(slots3);
    // leftover add `z` is right-only (row 4)
    const right_only = commentAnchor(rows3, slots3, .side_by_side, 4, .new).?;
    try testing.expectEqual(2, right_only.new_line.?);
    try testing.expect(right_only.old_line == null);
    try testing.expect(commentAnchor(rows3, slots3, .side_by_side, 4, .old) == null);

    try testing.expect(commentAnchor(&.{}, &.{}, .side_by_side, 0, .new) == null);
}

test "rowForComment add delete context missing" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk, 2 keep, 3 del, 4 add, 5 tail

    try testing.expectEqual(3, rowForComment(rows, .{ .path = "f", .side = .old, .line = 2 }).?);
    try testing.expectEqual(4, rowForComment(rows, .{ .path = "f", .side = .new, .line = 2 }).?);
    try testing.expectEqual(2, rowForComment(rows, .{ .path = "f", .side = .old, .line = 1 }).?);
    try testing.expectEqual(2, rowForComment(rows, .{ .path = "f", .side = .new, .line = 1 }).?);
    try testing.expect(rowForComment(rows, .{ .path = "f", .side = .new, .line = 99 }) == null);
    try testing.expect(rowForComment(rows, .{ .path = "gone", .side = .old, .line = 2 }) == null);
    try testing.expect(rowForComment(&.{}, .{ .path = "f", .side = .new, .line = 1 }) == null);
}

test "rowForComment new side is not the pair's primary row" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    const slots = try pairSideBySide(testing.allocator, rows);
    defer testing.allocator.free(slots);
    // 0 file, 1 hunk, 2 del, 3 add — one pair slot, primary is the delete.
    const pair_i = sbsSlotForRow(slots, 2).?;
    try testing.expectEqual(2, sbsPrimaryRow(slots[pair_i]));
    try testing.expectEqual(2, rowForComment(rows, .{ .path = "f", .side = .old, .line = 1 }).?);
    try testing.expectEqual(3, rowForComment(rows, .{ .path = "f", .side = .new, .line = 1 }).?);
}

test "cursorMarkAt empty file hunk line" {
    try testing.expect(cursorMarkAt(&.{}, 0) == null);

    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 file, 1 hunk, 2 keep, 3 del, 4 add, 5 tail

    const file = cursorMarkAt(rows, 0).?;
    try testing.expectEqualStrings("f", file.path);
    try testing.expect(file.side == null);
    try testing.expect(file.line == null);

    const hunk = cursorMarkAt(rows, 1).?;
    try testing.expectEqualStrings("f", hunk.path);
    try testing.expect(hunk.side == null);
    try testing.expect(hunk.line == null);

    const ctx = cursorMarkAt(rows, 2).?;
    try testing.expectEqualStrings("f", ctx.path);
    try testing.expectEqual(.new, ctx.side.?);
    try testing.expectEqual(1, ctx.line.?);

    const del = cursorMarkAt(rows, 3).?;
    try testing.expectEqual(.old, del.side.?);
    try testing.expectEqual(2, del.line.?);

    const add = cursorMarkAt(rows, 4).?;
    try testing.expectEqual(.new, add.side.?);
    try testing.expectEqual(2, add.line.?);
}

test "restoreCursor exact file fallback gone" {
    try testing.expectEqual(0, restoreCursor(&.{}, .{ .path = "f" }));

    const before =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
        \\diff --git a/g b/g
        \\--- a/g
        \\+++ b/g
        \\@@ -1 +1 @@
        \\-gone
        \\+here
    ;
    var d0 = try diff.parse(testing.allocator, before);
    defer d0.deinit();
    const old_rows = try flatten(testing.allocator, &d0);
    defer testing.allocator.free(old_rows);
    // f: 0 file, 1 hunk, 2 keep, 3 del, 4 add, 5 tail
    // g: 6 file, 7 hunk, 8 del, 9 add

    const after =
        \\diff --git a/e b/e
        \\--- a/e
        \\+++ b/e
        \\@@ -1 +1 @@
        \\-x
        \\+y
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\ tail
    ;
    var d1 = try diff.parse(testing.allocator, after);
    defer d1.deinit();
    const new_rows = try flatten(testing.allocator, &d1);
    defer testing.allocator.free(new_rows);
    // e: 0 file, 1 hunk, 2 del, 3 add
    // f: 4 file, 5 hunk, 6 keep, 7 del, 8 add, 9 tail

    try testing.expectEqual(8, restoreCursor(new_rows, cursorMarkAt(old_rows, 4).?));
    try testing.expectEqual(4, restoreCursor(new_rows, cursorMarkAt(old_rows, 0).?));
    try testing.expectEqual(4, restoreCursor(new_rows, cursorMarkAt(old_rows, 1).?));
    try testing.expectEqual(0, restoreCursor(new_rows, cursorMarkAt(old_rows, 6).?));
    try testing.expectEqual(0, restoreCursor(new_rows, .{ .path = "gone" }));
}

test "indexTargetAt empty section and untagged" {
    try testing.expect(indexTargetAt(&.{}, 0, false) == null);

    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    try testing.expect(indexTargetAt(rows, 0, false) == null);
    try testing.expect(indexTargetAt(rows, 2, false) == null);

    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    try testing.expect(indexTargetAt(fix.rows, 0, false) == null);
    try testing.expect(indexTargetAt(fix.rows, 5, true) == null);
}

test "indexTargetAt file hunk and file-from-hunk" {
    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const rows = fix.rows;
    // 0 Unstaged, 1 file a, 2 hunk, 3 del, 4 add, 5 Untracked, 6 file u, …
    // 9 Staged, 10 file a, 11 hunk, 12 ctx, 13 add.

    const file = indexTargetAt(rows, 1, false).?;
    try testing.expectEqualStrings("a", file.path);
    try testing.expectEqual(diff.Group.unstaged, file.group);
    try testing.expect(file.hunk_i == null);
    try testing.expectEqual(1, file.first);
    try testing.expectEqual(4, file.last);

    const hunk = indexTargetAt(rows, 3, false).?;
    try testing.expectEqualStrings("a", hunk.path);
    try testing.expectEqual(diff.Group.unstaged, hunk.group);
    try testing.expectEqual(0, hunk.hunk_i.?);
    try testing.expectEqual(2, hunk.first);
    try testing.expectEqual(4, hunk.last);

    const from_hunk = indexTargetAt(rows, 3, true).?;
    try testing.expect(from_hunk.hunk_i == null);
    try testing.expectEqual(1, from_hunk.first);
    try testing.expectEqual(4, from_hunk.last);

    const staged = indexTargetAt(rows, 12, false).?;
    try testing.expectEqualStrings("a", staged.path);
    try testing.expectEqual(diff.Group.staged, staged.group);
    try testing.expectEqual(0, staged.hunk_i.?);
}

test "neighborMark following hunk next file and only change" {
    const two_hunks =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1 @@
        \\-old1
        \\+new1
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = two_hunks, .group = .unstaged },
    });
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 Unstaged, 1 file, 2 h0, 3 del, 4 add, 5 h1, 6 del, 7 add.

    const first = indexTargetAt(rows, 3, false).?;
    const after_first = neighborMark(rows, first).?;
    try testing.expectEqualStrings("a", after_first.path);
    try testing.expectEqual(diff.Group.unstaged, after_first.group);
    try testing.expectEqual(0, after_first.hunk_i.?);

    const second = indexTargetAt(rows, 6, false).?;
    const before_second = neighborMark(rows, second).?;
    try testing.expectEqualStrings("a", before_second.path);
    try testing.expectEqual(0, before_second.hunk_i.?);

    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    const next_file = neighborMark(fix.rows, indexTargetAt(fix.rows, 3, false).?).?;
    try testing.expectEqualStrings("u", next_file.path);
    try testing.expectEqual(diff.Group.untracked, next_file.group);
    try testing.expect(next_file.hunk_i == null);

    const only =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d_only = try diff.parsePieces(testing.allocator, &.{
        .{ .text = only, .group = .untracked },
    });
    defer d_only.deinit();
    const only_rows = try flatten(testing.allocator, &d_only);
    defer testing.allocator.free(only_rows);
    // Whole file is the only change: no following or previous header.
    try testing.expect(neighborMark(only_rows, indexTargetAt(only_rows, 1, false).?) == null);
    // Only hunk: previous header is that file’s row.
    const prev_file = neighborMark(only_rows, indexTargetAt(only_rows, 2, false).?).?;
    try testing.expectEqualStrings("u", prev_file.path);
    try testing.expectEqual(diff.Group.untracked, prev_file.group);
    try testing.expect(prev_file.hunk_i == null);
}

test "restoreNeighbor dest hunk file fallback and gone" {
    try testing.expectEqual(0, restoreNeighbor(&.{}, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = 0,
    }));

    const remaining =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = remaining, .group = .unstaged },
    });
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    // 0 Unstaged, 1 file, 2 hunk, 3 del, 4 add.

    try testing.expectEqual(2, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = 0,
    }));
    try testing.expectEqual(1, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = 4,
    }));
    try testing.expectEqual(1, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = null,
    }));
    try testing.expectEqual(0, restoreNeighbor(rows, .{
        .path = "a",
        .group = .staged,
        .hunk_i = 0,
    }));
    try testing.expectEqual(0, restoreNeighbor(rows, .{
        .path = "gone",
        .group = .unstaged,
        .hunk_i = null,
    }));
}

test "groupSpanAt empty untagged and three groups" {
    try testing.expect(groupSpanAt(&.{}, 0) == null);

    const untagged =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(testing.allocator, untagged);
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    try testing.expect(groupSpanAt(rows, 0) == null);

    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);
    // 0 Unstaged, 1-4 file a, 5 Untracked, 6-8 file u, 9 Staged, 10-13 file a.
    try testing.expect(groupSpanAt(fix.rows, 1) == null);

    const unstaged = groupSpanAt(fix.rows, 0).?;
    try testing.expectEqual(diff.Group.unstaged, unstaged.group);
    try testing.expectEqual(0, unstaged.first);
    try testing.expectEqual(4, unstaged.last);

    const untracked = groupSpanAt(fix.rows, 5).?;
    try testing.expectEqual(diff.Group.untracked, untracked.group);
    try testing.expectEqual(5, untracked.first);
    try testing.expectEqual(8, untracked.last);

    const staged = groupSpanAt(fix.rows, 9).?;
    try testing.expectEqual(diff.Group.staged, staged.group);
    try testing.expectEqual(9, staged.first);
    try testing.expectEqual(13, staged.last);
}

test "groupNeighborMark following section previous file and only group" {
    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);

    const after_unstaged = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 0).?).?;
    try testing.expect(after_unstaged == .section);
    try testing.expectEqual(diff.Group.untracked, after_unstaged.section);

    const after_untracked = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 5).?).?;
    try testing.expect(after_untracked == .section);
    try testing.expectEqual(diff.Group.staged, after_untracked.section);

    const before_staged = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 9).?).?;
    try testing.expect(before_staged == .file);
    try testing.expectEqualStrings("u", before_staged.file.path);
    try testing.expectEqual(diff.Group.untracked, before_staged.file.group);

    const only =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d_only = try diff.parsePieces(testing.allocator, &.{
        .{ .text = only, .group = .untracked },
    });
    defer d_only.deinit();
    const only_rows = try flatten(testing.allocator, &d_only);
    defer testing.allocator.free(only_rows);
    try testing.expect(groupNeighborMark(only_rows, groupSpanAt(only_rows, 0).?) == null);
}

test "restoreGroupNeighbor dest section file fallback and gone" {
    try testing.expectEqual(0, restoreGroupNeighbor(&.{}, .{ .section = .unstaged }));

    var fix = try threeGroupFixture(testing.allocator);
    defer fix.d.deinit();
    defer testing.allocator.free(fix.rows);

    try testing.expectEqual(5, restoreGroupNeighbor(fix.rows, .{ .section = .untracked }));
    try testing.expectEqual(6, restoreGroupNeighbor(fix.rows, .{
        .file = .{ .path = "u", .group = .untracked },
    }));
    try testing.expectEqual(0, restoreGroupNeighbor(fix.rows, .{
        .file = .{ .path = "gone", .group = .unstaged },
    }));

    const remaining =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1 +1,2 @@
        \\ same
        \\+staged
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = remaining, .group = .staged },
    });
    defer d.deinit();
    const rows = try flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    try testing.expectEqual(0, restoreGroupNeighbor(rows, .{ .section = .untracked }));
}
