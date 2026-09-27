//! Review frame: title bar, diff body, status footer, and one-shot footer note.

const Frame = @This();

const std = @import("std");
const tui = @import("tui");
const view = @import("view");
const store = @import("store");
const cli = @import("cli");
const diff = @import("diff");
const root = @import("root");
const DiffView = root.DiffView;
const Viewport = root.Viewport;
const Focus = root.Focus;

/// One-shot footer message owned by `Frame`. Bytes always live in `buf`;
/// `len == 0` means none. Avoids optional slices that sometimes point at
/// static strings and sometimes at a separate buffer.
pub const StatusNote = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    pub fn clear(self: *StatusNote) void {
        self.len = 0;
    }

    pub fn slice(self: *const StatusNote) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *StatusNote, msg: []const u8) void {
        const n = @min(msg.len, self.buf.len);
        @memcpy(self.buf[0..n], msg[0..n]);
        self.len = n;
    }

    pub fn setFmt(self: *StatusNote, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            self.set("Pattern not found");
            return;
        };
        self.len = written.len;
    }
};

note: StatusNote = .{},

/// Diff line palette (truecolor). Sticky file headers and body paints
/// share one table. Hierarchy:
///   body          — near-black bg, neutral fg
///   section header — body bg, box-drawing rule (`─ Unstaged ─`)
///   file header   — full-row dark grey bar, bold light path
///   hunk header   — full-row deeper grey bar, light `@@`
///   add / delete  — green/red fills when the line has no word spans
///   change        — dim grey for a line that has word spans; spans use add/delete
///   *@_cur        — lighter lift of the same kind (keeps identity)
///   meta / meta@cur — dim / reverse gray only
/// No color → bg may not show; structure still relies on bold/dim when set.
const Palette = struct {
    body: tui.Style,
    section: tui.Style,
    section_cur: tui.Style,
    title: tui.Style,
    footer: tui.Style,
    file: tui.Style,
    file_cur: tui.Style,
    hunk: tui.Style,
    hunk_cur: tui.Style,
    add: tui.Style,
    del: tui.Style,
    /// Grey behind a changed line that still has unchanged bytes.
    change: tui.Style,
    change_cur: tui.Style,
    add_cur: tui.Style,
    del_cur: tui.Style,
    ctx_cur: tui.Style,
    meta: tui.Style,
    cur: tui.Style,
    gutter: tui.Style,

    /// Cursor keeps row kind: add/delete/context and section/file/hunk
    /// headers use a lighter lift of their bar; meta uses reverse gray.
    fn rowStyle(self: Palette, row: view.row.Row, is_cur: bool) tui.Style {
        if (is_cur) {
            return switch (row) {
                .line => |ln| lineStyle(self, ln.kind, ln.text, ln.spans, true),
                .section_header => self.section_cur,
                .file_header => self.file_cur,
                .hunk_header => self.hunk_cur,
            };
        }
        return switch (row) {
            .section_header => self.section,
            .file_header => self.file,
            .hunk_header => self.hunk,
            .line => |ln| lineStyle(self, ln.kind, ln.text, ln.spans, false),
        };
    }
};

fn lineStyle(pal: Palette, kind: diff.LineKind, text: []const u8, spans: ?[]const diff.Span, is_cur: bool) tui.Style {
    // `null` spans were not computed, so the line keeps its solid add/delete fill.
    // An empty list means word-diff found no changed bytes on this side: the row
    // is the same dim grey as the other side, with no red or green.
    // Grey also when some byte sits outside the spans. A full cover stays solid.
    if (kind == .add or kind == .delete) {
        if (spans) |sp| {
            if (sp.len == 0 or !spansCover(text, sp)) return if (is_cur) pal.change_cur else pal.change;
        }
    }
    if (is_cur) {
        return switch (kind) {
            .add => pal.add_cur,
            .delete => pal.del_cur,
            .context => pal.ctx_cur,
            .meta => pal.cur,
        };
    }
    return switch (kind) {
        .add => pal.add,
        .delete => pal.del,
        .meta => pal.meta,
        .context => pal.body,
    };
}

/// True when every non-whitespace byte of `text` sits inside some span.
/// Indent git counted as common does not by itself keep the line intra-line.
fn spansCover(text: []const u8, spans: []const diff.Span) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == ' ' or text[i] == '\t') {
            i += 1;
            continue;
        }
        var end = i;
        for (spans) |sp| {
            if (sp.start <= i and sp.end > end) end = sp.end;
        }
        if (end == i) return false;
        i = end;
    }
    return true;
}

fn spanStyle(kind: diff.LineKind, is_cur: bool) tui.Style {
    return switch (kind) {
        .add => if (is_cur) palette.add_cur else palette.add,
        .delete => if (is_cur) palette.del_cur else palette.del,
        .context, .meta => if (is_cur) palette.change_cur else palette.change,
    };
}

const palette: Palette = blk: {
    const bg = tui.Color{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } };
    const fg = tui.Color{ .rgb = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 } };
    break :blk .{
        .body = .{ .fg = fg, .bg = bg },
        .section = .{
            .fg = .{ .rgb = .{ .r = 0x6a, .g = 0x6a, .b = 0x76 } },
            .bg = bg,
        },
        .section_cur = .{
            .fg = .{ .rgb = .{ .r = 0x7e, .g = 0x7e, .b = 0x8b } },
            .bg = bg,
            .bold = true,
        },
        .title = .{
            .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
            .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x3f, .b = 0x5f } },
            .bold = true,
        },
        .footer = .{
            .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
            .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x3f, .b = 0x5f } },
        },
        // File header: dark grey bar + light bold path (clear vs body; not green/red).
        .file = .{
            .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xf0 } },
            .bg = .{ .rgb = .{ .r = 0x48, .g = 0x48, .b = 0x4c } },
            .bold = true,
        },
        .file_cur = .{
            .fg = .{ .rgb = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
            .bg = .{ .rgb = .{ .r = 0x60, .g = 0x60, .b = 0x64 } },
            .bold = true,
        },
        // Hunk header: deeper grey bar (dimmer than file; light `@@`).
        .hunk = .{
            .fg = .{ .rgb = .{ .r = 0xc8, .g = 0xc8, .b = 0xcc } },
            .bg = .{ .rgb = .{ .r = 0x30, .g = 0x30, .b = 0x34 } },
        },
        .hunk_cur = .{
            .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xf0 } },
            .bg = .{ .rgb = .{ .r = 0x44, .g = 0x44, .b = 0x48 } },
            .bold = true,
        },
        // Small step above the body background (0x121214).
        .change = .{
            .fg = fg,
            .bg = .{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1e } },
        },
        .change_cur = .{
            .fg = fg,
            .bg = .{ .rgb = .{ .r = 0x26, .g = 0x26, .b = 0x2c } },
            .bold = true,
        },
        .add = .{
            .fg = .{ .rgb = .{ .r = 0xb8, .g = 0xe0, .b = 0xb8 } },
            .bg = .{ .rgb = .{ .r = 0x1a, .g = 0x2e, .b = 0x1f } },
        },
        .del = .{
            .fg = .{ .rgb = .{ .r = 0xe8, .g = 0xc0, .b = 0xc4 } },
            .bg = .{ .rgb = .{ .r = 0x3a, .g = 0x1c, .b = 0x20 } },
        },
        .add_cur = .{
            .fg = .{ .rgb = .{ .r = 0xe8, .g = 0xff, .b = 0xe8 } },
            .bg = .{ .rgb = .{ .r = 0x24, .g = 0x52, .b = 0x30 } },
            .bold = true,
        },
        .del_cur = .{
            .fg = .{ .rgb = .{ .r = 0xff, .g = 0xe8, .b = 0xea } },
            .bg = .{ .rgb = .{ .r = 0x6b, .g = 0x2a, .b = 0x32 } },
            .bold = true,
        },
        // Context cursor: lighter lift of body bg (same idea as add/delete cursor).
        .ctx_cur = .{
            .fg = fg,
            .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x30 } },
            .bold = true,
        },
        .meta = .{
            .fg = .{ .rgb = .{ .r = 0x80, .g = 0x80, .b = 0x80 } },
            .bg = bg,
            .dim = true,
        },
        // Meta cursor only (headers use file_cur / hunk_cur).
        .cur = .{
            .fg = .{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } },
            .bg = .{ .rgb = .{ .r = 0xc8, .g = 0xc8, .b = 0xc8 } },
            .bold = true,
        },
        .gutter = .{
            .fg = .{ .rgb = .{ .r = 0x50, .g = 0x50, .b = 0x58 } },
            .bg = bg,
        },
    };
};

/// Rows between the title bar and the footer. The caller clamps the viewport
/// to `rows` before paint; paint only reads that scroll.
pub const ContentArea = struct {
    top: u16,
    bottom: u16,
    rows: usize,

    /// `footer_h` is the rows reserved under the body (0 when the terminal
    /// has no room for a footer).
    pub fn init(size: tui.Size, footer_h: u16) ContentArea {
        const top: u16 = 1;
        const bottom: u16 = if (size.rows >= 2) size.rows - footer_h else size.rows;
        return .{
            .top = top,
            .bottom = bottom,
            .rows = if (bottom > top) bottom - top else 0,
        };
    }
};

/// Rows reserved for the footer. A comment box uses `comment_h`; every other
/// mode uses one status row. Zero when the terminal is a single row or less.
pub fn footerRows(size: tui.Size, focus: Focus, comment_h: u16) u16 {
    if (size.rows < 2) return 0;
    if (focus == .commenting) return comment_h;
    return 1;
}

/// Title-bar text. `comment` and `confirm` are the open draft and confirm
/// dialog; other modes use a fixed label.
pub fn title(focus: Focus, comment: []const u8, confirm: []const u8) []const u8 {
    return switch (focus) {
        .commenting => comment,
        .searching => "rv  search  Enter jump  Esc cancel",
        .listing => "rv  comments  j/k  Enter jump  i edit  d dismiss  Esc close  q quit",
        .files => "rv  files  j/k  Enter jump  a/A approve  Esc close  q quit",
        .approved => "rv  approved  j/k move  Enter unapprove  Esc close  q quit",
        .helping => "rv  help  j/k  Esc/? close  q quit",
        .git_error => "rv  git error  Enter/Esc close  q quit",
        .discard_confirm => confirm,
        .normal => "rv  j/k  /  i/I  ? help  q quit",
    };
}

pub fn paint(
    self: *const Frame,
    scr: *tui.Screen,
    size: tui.Size,
    diff_view: *const DiffView,
    viewport: *const Viewport,
    review: *const store.Review,
    source: cli.Source,
    focus: Focus,
    title_text: []const u8,
    area: ContentArea,
) void {
    const rows = diff_view.rows;
    const sbs_slots = diff_view.sbs_slots;
    const status_note = self.note.slice();
    const pal = palette;

    scr.clearStyle(pal.body);

    if (size.rows > 0) {
        fillRow(scr, 0, pal.title);
        scr.putStr(1, 0, title_text, pal.title, 0, null);
    }

    const cur = view.row.clampCursor(viewport.cursor, rows.len);
    const layout = view.layout.effectiveLayout(viewport.layout_pref, size.cols);
    const num_w = if (viewport.show_line_numbers) lineNumberWidth(rows) else 0;

    var line_buf: [512]u8 = undefined;
    // Only lines in the cursor's hunk pan; file/hunk headers never pan.
    const pan_span = view.viewport.hunkSpanAt(rows, cur);
    const sticky = switch (layout) {
        .unified => view.viewport.stickyHeaders(rows, viewport.scroll, area.rows),
        .side_by_side => view.viewport.stickyHeadersSbs(sbs_slots, rows, viewport.scroll, area.rows),
    };
    const cs = viewport.col_scroll;
    const hints = rowHints(rows, cur, source, focus);
    var hint_buf: [160]u8 = undefined;
    const full_pane = BodyPane{
        .scr = scr,
        .x = 0,
        .pane_w = size.cols,
        .num_w = num_w,
        .numbers = .unified,
        .col_scroll = cs,
    };

    switch (layout) {
        .unified => {
            var screen_y: u16 = area.top;

            // Sticky file path under the title bar (hunk headers scroll with body).
            if (sticky.file_idx) |fi| {
                if (screen_y < area.bottom) {
                    const text = formatRow(&line_buf, rows[fi], rowMarked(rows[fi], review));
                    const st = if (fi == cur) pal.file_cur else pal.file;
                    fillRow(scr, screen_y, st);
                    putRowHint(scr, screen_y, text, hints.text(&hint_buf, fi), st);
                    screen_y += 1;
                }
            }

            var i: usize = viewport.scroll;
            while (i < rows.len and screen_y < area.bottom) : (i += 1) {
                const is_cur = i == cur;
                const marked = rowMarked(rows[i], review);
                const st = pal.rowStyle(rows[i], is_cur);
                switch (rows[i]) {
                    .line => screen_y = full_pane.putRow(
                        screen_y,
                        area.bottom,
                        rows[i],
                        marked,
                        viewport.wrap,
                        pan_span.containsBody(i),
                        st,
                        is_cur,
                    ),
                    .section_header => {
                        scr.fillRect(.{ .x = 0, .y = screen_y, .w = scr.cols, .h = 1 }, '─', st);
                        const text = formatRow(&line_buf, rows[i], marked);
                        putRowHint(scr, screen_y, text, hints.text(&hint_buf, i), st);
                        screen_y += 1;
                    },
                    else => {
                        fillRow(scr, screen_y, st);
                        const text = formatRow(&line_buf, rows[i], marked);
                        putRowHint(scr, screen_y, text, hints.text(&hint_buf, i), st);
                        screen_y += 1;
                    },
                }
            }
        },
        .side_by_side => {
            const panes = view.layout.sbsPaneWidths(size.cols);
            const right_x: u16 = panes.gutter_x + 1;
            const left_pane = BodyPane{
                .scr = scr,
                .x = 0,
                .pane_w = panes.left_w,
                .num_w = num_w,
                .numbers = .old,
                .col_scroll = cs,
            };
            const right_pane = BodyPane{
                .scr = scr,
                .x = right_x,
                .pane_w = panes.right_w,
                .num_w = num_w,
                .numbers = .new,
                .col_scroll = cs,
            };
            var screen_y: u16 = area.top;

            if (sticky.file_idx) |fi| {
                if (screen_y < area.bottom) {
                    const text = formatRow(&line_buf, rows[fi], rowMarked(rows[fi], review));
                    const st = if (fi == cur) pal.file_cur else pal.file;
                    fillRow(scr, screen_y, st);
                    putRowHint(scr, screen_y, text, hints.text(&hint_buf, fi), st);
                    screen_y += 1;
                }
            }

            var si: usize = viewport.scroll;
            while (si < sbs_slots.len and screen_y < area.bottom) : (si += 1) {
                switch (sbs_slots[si]) {
                    .header => |ri| {
                        const is_cur = ri == cur;
                        const text = formatRow(&line_buf, rows[ri], rowMarked(rows[ri], review));
                        const st = pal.rowStyle(rows[ri], is_cur);
                        if (rows[ri] == .section_header) {
                            scr.fillRect(.{ .x = 0, .y = screen_y, .w = scr.cols, .h = 1 }, '─', st);
                        } else {
                            fillRow(scr, screen_y, st);
                        }
                        putRowHint(scr, screen_y, text, hints.text(&hint_buf, ri), st);
                        screen_y += 1;
                    },
                    .body => |ri| {
                        const marked = rowMarked(rows[ri], review);
                        const st = pal.rowStyle(rows[ri], ri == cur);
                        screen_y = full_pane.putRow(
                            screen_y,
                            area.bottom,
                            rows[ri],
                            marked,
                            viewport.wrap,
                            pan_span.containsBody(ri),
                            st,
                            ri == cur,
                        );
                    },
                    .pair => |p| {
                        // Whole slot is current when the cursor sits on either pane
                        // (paired del|add highlight together as one split row).
                        const slot_cur = sbs_slots[si].containsRow(cur);
                        const left_st = if (p.left) |ri|
                            pal.rowStyle(rows[ri], slot_cur)
                        else if (slot_cur) pal.ctx_cur else pal.body;
                        const right_st = if (p.right) |ri|
                            pal.rowStyle(rows[ri], slot_cur)
                        else if (slot_cur) pal.ctx_cur else pal.body;
                        const n = view.viewport.slotScreenHeight(
                            sbs_slots[si],
                            rows,
                            bodyTextCols(panes.left_w, num_w, .side_by_side),
                            bodyTextCols(panes.right_w, num_w, .side_by_side),
                            bodyTextCols(size.cols, num_w, .unified),
                            viewport.wrap,
                        );
                        var vis: usize = 0;
                        while (vis < n and screen_y < area.bottom) : (vis += 1) {
                            fillSpan(scr, 0, panes.gutter_x, screen_y, left_st);
                            putSbsCenter(scr, panes, screen_y, size.cols, pal.gutter);
                            fillSpan(scr, right_x, size.cols, screen_y, right_st);
                            if (p.left) |ri| {
                                const marked = rowMarked(rows[ri], review);
                                const pan = pan_span.containsBody(ri);
                                if (viewport.wrap) {
                                    left_pane.putSegment(screen_y, rows[ri], marked, vis, left_st, slot_cur);
                                } else {
                                    left_pane.putPanned(screen_y, rows[ri], marked, pan, left_st, slot_cur);
                                }
                            }
                            if (p.right) |ri| {
                                const marked = rowMarked(rows[ri], review);
                                const pan = pan_span.containsBody(ri);
                                if (viewport.wrap) {
                                    right_pane.putSegment(screen_y, rows[ri], marked, vis, right_st, slot_cur);
                                } else {
                                    right_pane.putPanned(screen_y, rows[ri], marked, pan, right_st, slot_cur);
                                }
                            }
                            screen_y += 1;
                        }
                    },
                }
            }
        },
    }

    if (size.rows >= 2) {
        if (focus != .searching and focus != .commenting) {
            const footer_y = area.bottom;
            fillRow(scr, footer_y, pal.footer);
            if (status_note.len > 0) {
                scr.putStr(1, footer_y, status_note, pal.footer, 0, null);
            } else {
                const st = view.nav.statusAt(rows, cur);
                const footer_text = formatFooter(
                    &line_buf,
                    st,
                    review.openCount(),
                    viewport.layout_pref,
                    size.cols,
                    source,
                    diff_view.approved_n,
                    viewport.wrap,
                );
                scr.putStr(1, footer_y, footer_text, pal.footer, 0, null);
            }
            scr.hideCursor();
        }
    } else {
        scr.hideCursor();
    }
}

/// Widest **line text** in the hunk body (gutter excluded). 0 if empty.
pub fn hunkMaxLineWidth(rows: []const view.row.Row, span: view.viewport.HunkSpan) usize {
    var max_w: usize = 0;
    var i = span.body_start;
    while (i < span.body_end) : (i += 1) {
        switch (rows[i]) {
            .line => |ln| max_w = @max(max_w, tui.screen.displayWidth(ln.text)),
            else => {},
        }
    }
    return max_w;
}

/// Digit columns for old/new numbers: width of the largest `old_no` / `new_no`
/// in `rows`. At least 1 so blank fields still line up when nothing is numbered.
pub fn lineNumberWidth(rows: []const view.row.Row) usize {
    var max: u32 = 0;
    for (rows) |row| {
        switch (row) {
            .line => |ln| {
                if (ln.old_no) |n| max = @max(max, n);
                if (ln.new_no) |n| max = @max(max, n);
            },
            else => {},
        }
    }
    return decimalDigits(max);
}

const LineNumbers = enum { unified, old, new };

/// Display columns for the sticky body gutter (mark, kind, numbers, trailing space).
/// `num_w == 0` is numbers off: the original 2-char mark/kind gutter.
pub fn lineGutterCols(num_w: usize, layout: view.layout.EffectiveLayout) usize {
    if (num_w == 0) return 2;
    const numbers: LineNumbers = switch (layout) {
        .unified => .unified,
        .side_by_side => .old,
    };
    return 2 + numberFieldCols(num_w, numbers) + 1;
}

fn numberFieldCols(num_w: usize, numbers: LineNumbers) usize {
    return switch (numbers) {
        .unified => num_w + 1 + num_w,
        .old, .new => num_w,
    };
}

fn decimalDigits(n: u32) usize {
    var w: usize = 1;
    var x = n;
    while (x >= 10) {
        x /= 10;
        w += 1;
    }
    return w;
}

fn writePadded(dest: []u8, n: ?u32) void {
    @memset(dest, ' ');
    const v = n orelse return;
    var tmp: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
    if (s.len > dest.len) {
        @memcpy(dest, s[s.len - dest.len ..]);
        return;
    }
    @memcpy(dest[dest.len - s.len ..], s);
}

fn formatBodyGutter(
    buf: []u8,
    row: view.row.Row,
    marked: bool,
    num_w: usize,
    numbers: LineNumbers,
    show_nums: bool,
) []const u8 {
    const ln = switch (row) {
        .line => |l| l,
        else => return buf[0..0],
    };
    const total: usize = if (num_w == 0) 2 else 2 + numberFieldCols(num_w, numbers) + 1;
    if (buf.len < total) return buf[0..0];
    @memset(buf[0..total], ' ');
    buf[0] = if (marked) '*' else ' ';
    buf[1] = switch (ln.kind) {
        .meta => '\\',
        .context, .add, .delete => ' ',
    };
    if (num_w == 0 or !show_nums) return buf[0..total];
    var pos: usize = 2;
    switch (numbers) {
        .unified => {
            writePadded(buf[pos .. pos + num_w], ln.old_no);
            pos += num_w;
            buf[pos] = ' ';
            pos += 1;
            writePadded(buf[pos .. pos + num_w], ln.new_no);
        },
        .old => writePadded(buf[pos .. pos + num_w], ln.old_no),
        .new => writePadded(buf[pos .. pos + num_w], ln.new_no),
    }
    return buf[0..total];
}

/// Columns of `pane_w` left for body text after the sticky gutter.
pub fn bodyTextCols(pane_w: u16, num_w: usize, layout: view.layout.EffectiveLayout) usize {
    const gw = lineGutterCols(num_w, layout);
    const gw_u16: u16 = std.math.cast(u16, gw) orelse pane_w;
    return pane_w -| gw_u16;
}

/// Where one body pane draws: origin, width, which line numbers, and the
/// column pan. The row, mark, and style change per line.
const BodyPane = struct {
    scr: *tui.Screen,
    x: u16,
    pane_w: u16,
    num_w: usize,
    numbers: LineNumbers,
    col_scroll: usize,

    fn textLayout(self: BodyPane) view.layout.EffectiveLayout {
        return switch (self.numbers) {
            .unified => .unified,
            .old, .new => .side_by_side,
        };
    }

    /// Gutter at `x`, then `text`. `skip` hides that many columns of `text`.
    /// Tab stops still start at column 0 of `text`.
    fn putText(
        self: BodyPane,
        y: u16,
        row: view.row.Row,
        marked: bool,
        show_nums: bool,
        text: []const u8,
        style: tui.Style,
        skip: usize,
        spans: []const diff.Span,
        is_cur: bool,
    ) void {
        var gbuf: [32]u8 = undefined;
        const gutter = formatBodyGutter(&gbuf, row, marked, self.num_w, self.numbers, show_nums);
        const gw_usize = tui.screen.displayWidth(gutter);
        const gw: u16 = std.math.cast(u16, gw_usize) orelse self.pane_w;
        if (self.pane_w > 0) putPaneStr(self.scr, self.x, y, @min(gw, self.pane_w), gutter, style);
        if (self.pane_w > gw) {
            const x_text = self.x +| gw;
            const text_w = self.pane_w - gw;
            const clip = tui.Rect{ .x = x_text, .y = y, .w = text_w, .h = 1 };
            self.scr.putStr(x_text, y, text, style, skip, clip);
            if (spans.len > 0) {
                const kind = switch (row) {
                    .line => |l| l.kind,
                    else => diff.LineKind.context,
                };
                const hi = spanStyle(kind, is_cur);
                for (spans) |sp| {
                    if (sp.start >= sp.end or sp.start >= text.len) continue;
                    const end = @min(sp.end, text.len);
                    self.scr.putStrRange(x_text, y, text, sp.start, end, hi, skip, clip);
                }
            }
        }
    }

    /// Gutter, then `ln.text`. `pan` skips `col_scroll` columns of that text.
    fn putPanned(
        self: BodyPane,
        y: u16,
        row: view.row.Row,
        marked: bool,
        pan: bool,
        style: tui.Style,
        is_cur: bool,
    ) void {
        const ln = switch (row) {
            .line => |l| l,
            else => return,
        };
        const skip: usize = if (pan) self.col_scroll else 0;
        self.putText(y, row, marked, true, ln.text, style, skip, ln.spans orelse &.{}, is_cur);
    }

    /// One wrapped visual segment at `vis`, or nothing if that segment does
    /// not exist (shorter pane of a pair).
    fn putSegment(
        self: BodyPane,
        y: u16,
        row: view.row.Row,
        marked: bool,
        vis: usize,
        style: tui.Style,
        is_cur: bool,
    ) void {
        const ln = switch (row) {
            .line => |l| l,
            else => return,
        };
        const width = bodyTextCols(self.pane_w, self.num_w, self.textLayout());
        const seg = view.wrap.segmentAt(ln.text, width, vis) orelse return;
        var buf: [16]diff.Span = undefined;
        const spans = shiftSpans(ln.spans orelse &.{}, seg.start, seg.end, &buf);
        self.putText(y, row, marked, vis == 0, ln.text[seg.start..seg.end], style, 0, spans, is_cur);
    }

    /// Fill the pane and draw one body row. Wrap uses several screen rows.
    /// Returns the next `y`.
    fn putRow(
        self: BodyPane,
        y: u16,
        y_end: u16,
        row: view.row.Row,
        marked: bool,
        wrap: bool,
        pan: bool,
        style: tui.Style,
        is_cur: bool,
    ) u16 {
        if (wrap) return self.putWrapped(y, y_end, row, marked, style, is_cur);
        if (y >= y_end) return y;
        fillSpan(self.scr, self.x, self.x +| self.pane_w, y, style);
        self.putPanned(y, row, marked, pan, style, is_cur);
        return y + 1;
    }

    fn putWrapped(
        self: BodyPane,
        y: u16,
        y_end: u16,
        row: view.row.Row,
        marked: bool,
        style: tui.Style,
        is_cur: bool,
    ) u16 {
        const ln = switch (row) {
            .line => |l| l,
            else => return y,
        };
        const width = bodyTextCols(self.pane_w, self.num_w, self.textLayout());
        const n = view.wrap.lineCount(ln.text, width);
        var vis: usize = 0;
        var yy = y;
        while (vis < n and yy < y_end) : (vis += 1) {
            fillSpan(self.scr, self.x, self.x +| self.pane_w, yy, style);
            self.putSegment(yy, row, marked, vis, style, is_cur);
            yy += 1;
        }
        return yy;
    }
};

/// Spans overlapping `[lo, hi)`, shifted so 0 is `lo`. `buf` caps the count.
fn shiftSpans(spans: []const diff.Span, lo: usize, hi: usize, buf: []diff.Span) []const diff.Span {
    var n: usize = 0;
    for (spans) |s| {
        if (n >= buf.len) break;
        const a = @max(s.start, lo);
        const b = @min(s.end, hi);
        if (a >= b) continue;
        buf[n] = .{ .start = a - lo, .end = b - lo };
        n += 1;
    }
    return buf[0..n];
}

fn rowMarked(row: view.row.Row, review: *const store.Review) bool {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .meta => false,
            else => review.firstAt(ln.path, ln.old_no, ln.new_no, .line) != null,
        },
        .file_header => |fh| review.firstAt(fh.path, null, null, .file) != null,
        .hunk_header => |hh| review.firstAt(hh.path, hh.old_start, hh.new_start, .hunk) != null,
        .section_header => false,
    };
}

/// Short layout label for the status footer.
fn layoutFooterLabel(pref: view.layout.LayoutPref, cols: u16) []const u8 {
    return switch (view.layout.effectiveLayout(pref, cols)) {
        .side_by_side => "sbs",
        .unified => switch (pref) {
            .unified => "uni",
            // Prefer SBS but terminal too narrow for two panes.
            .side_by_side => "uni~",
        },
    };
}

fn formatFooter(
    buf: []u8,
    st: view.nav.Status,
    open_n: usize,
    layout_pref: view.layout.LayoutPref,
    cols: u16,
    source: cli.Source,
    approved_n: usize,
    wrap: bool,
) []const u8 {
    if (st.row_n == 0) {
        if (source == .local and approved_n > 0) {
            return bufPrintTrunc(buf, "HEAD · {d} approved", .{approved_n});
        }
        return cli.sourceLabel(source, true);
    }
    const src = cli.sourceLabel(source, false);
    const mode = layoutFooterLabel(layout_pref, cols);
    const wrap_tag: []const u8 = if (wrap) "  wrap" else "";
    if (st.hunk_n == 0) {
        return bufPrintTrunc(buf, "{s}  {s}  {d}/{d}  {d} open  {s}{s}", .{
            src,
            if (st.path.len > 0) st.path else "?",
            st.row_i,
            st.row_n,
            open_n,
            mode,
            wrap_tag,
        });
    }
    return bufPrintTrunc(buf, "{s}  {s}  hunk {d}/{d}  {d}/{d}  {d} open  {s}{s}", .{
        src,
        if (st.path.len > 0) st.path else "?",
        st.hunk_i,
        st.hunk_n,
        st.row_i,
        st.row_n,
        open_n,
        mode,
        wrap_tag,
    });
}

/// Format one row. Line rows: 2-char gutter (`*` if marked else space, then
/// pad/`\` for meta). File and hunk headers: the same 2-char gutter (`*` or
/// space, then space) so the rest of the row does not shift when marked.
/// Add/delete use background color, not `+/-` markers.
pub fn formatRow(buf: []u8, row: view.row.Row, marked: bool) []const u8 {
    return switch (row) {
        .section_header => |g| bufPrintTrunc(buf, "── {s} ", .{switch (g) {
            .unstaged => "Unstaged",
            .untracked => "Untracked",
            .staged => "Staged",
        }}),
        .file_header => |fh| blk: {
            const prefix: []const u8 = if (marked) "* " else "  ";
            var path_buf: [512]u8 = undefined;
            const path = view.row.fileHeaderPathLabel(fh, &path_buf);
            if (fh.is_binary)
                break :blk bufPrintTrunc(buf, "{s}{s}  (binary)", .{ prefix, path });
            break :blk bufPrintTrunc(buf, "{s}{s}", .{ prefix, path });
        },
        .hunk_header => |hh| blk: {
            const prefix: []const u8 = if (marked) "* " else "  ";
            const oc = hh.old_count orelse 1;
            const nc = hh.new_count orelse 1;
            if (hh.section.len > 0) {
                break :blk bufPrintTrunc(buf, "{s}@@ -{d},{d} +{d},{d} @@ {s}", .{
                    prefix, hh.old_start, oc, hh.new_start, nc, hh.section,
                });
            }
            break :blk bufPrintTrunc(buf, "{s}@@ -{d},{d} +{d},{d} @@", .{
                prefix, hh.old_start, oc, hh.new_start, nc,
            });
        },
        .line => |ln| blk: {
            if (buf.len < 2) break :blk buf[0..0];
            buf[0] = if (marked) '*' else ' ';
            buf[1] = switch (ln.kind) {
                .meta => '\\',
                .context, .add, .delete => ' ',
            };
            const n = @min(ln.text.len, buf.len - 2);
            @memcpy(buf[2..][0..n], ln.text[0..n]);
            break :blk buf[0 .. n + 2];
        },
    };
}

pub fn bufPrintTrunc(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch {
        const msg = "...";
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        return buf[0..n];
    };
}

/// Which header rows show git, approve, and expand labels for this cursor.
/// Empty fields mean that label is off (range load, or the cursor is not on
/// a grouped file).
pub const RowHints = struct {
    file: ?usize = null,
    hunk: ?usize = null,
    section: ?usize = null,
    group: ?diff.Group = null,
    expand_hunk: ?usize = null,
    expand_ok: bool = false,

    /// Git label for row `ri`. File row says File, including the sticky file
    /// header while the cursor is in a hunk. Hunk row says Hunk. Verb follows
    /// the file's group. Empty on other rows, section rows, and range loads.
    pub fn indexAt(self: RowHints, ri: usize) []const u8 {
        const g = self.group orelse return "";
        const stage = switch (g) {
            .unstaged, .untracked => true,
            .staged => false,
        };
        if (self.section) |si| {
            if (ri == si) return "";
        }
        if (self.file) |fi| {
            if (ri == fi) {
                return if (stage)
                    "Stage File (gS)  Discard File (gD)"
                else
                    "Unstage File (gU)";
            }
        }
        if (self.hunk) |hi| {
            if (ri == hi) {
                return if (stage)
                    "Stage Hunk (gs)  Discard Hunk (gd)"
                else
                    "Unstage Hunk (gu)";
            }
        }
        return "";
    }

    /// Approve label for row `ri`. File row says `A`, including the sticky
    /// file header. Empty on other rows, section rows, and range loads.
    pub fn approveAt(self: RowHints, ri: usize) []const u8 {
        if (self.group == null) return "";
        if (self.section) |si| {
            if (ri == si) return "";
        }
        if (self.file) |fi| {
            if (ri == fi) return "Approve File (A)";
        }
        if (self.hunk) |hi| {
            if (ri == hi) return "Approve Hunk (a)";
        }
        return "";
    }

    /// Expand label for row `ri` when that hunk can still grow.
    pub fn expandAt(self: RowHints, ri: usize) []const u8 {
        const hi = self.expand_hunk orelse return "";
        if (ri != hi or !self.expand_ok) return "";
        return "Expand (e)";
    }

    fn text(self: RowHints, buf: []u8, ri: usize) []const u8 {
        const git = self.indexAt(ri);
        const approve = self.approveAt(ri);
        const expand = self.expandAt(ri);
        var n: usize = 0;
        var parts: [3][]const u8 = undefined;
        if (git.len > 0) {
            parts[n] = git;
            n += 1;
        }
        if (approve.len > 0) {
            parts[n] = approve;
            n += 1;
        }
        if (expand.len > 0) {
            parts[n] = expand;
            n += 1;
        }
        if (n == 0) return "";
        if (n == 1) return parts[0];
        if (n == 2) {
            return std.fmt.bufPrint(buf, "{s}  {s}", .{ parts[0], parts[1] }) catch parts[0];
        }
        return std.fmt.bufPrint(buf, "{s}  {s}  {s}", .{ parts[0], parts[1], parts[2] }) catch parts[0];
    }
};

fn rowHints(
    rows: []const view.row.Row,
    cur: usize,
    source: cli.Source,
    focus: Focus,
) RowHints {
    const hints_ok = source == .local and focus == .normal and rows.len > 0;
    const section: ?usize = if (hints_ok and rows[cur] == .section_header) cur else null;
    const file: ?usize = blk: {
        if (!hints_ok or section != null) break :blk null;
        const fi = view.nav.currentFileStart(rows, cur) orelse break :blk null;
        const grouped = switch (rows[fi]) {
            .file_header => |fh| fh.group != null,
            else => false,
        };
        break :blk if (grouped) fi else null;
    };
    const hunk: ?usize = if (file != null)
        view.nav.currentHunkInFile(rows, cur)
    else
        null;
    const group: ?diff.Group = if (file) |fi|
        rows[fi].file_header.group
    else if (section) |si|
        rows[si].section_header
    else
        null;
    const expand_hunk: ?usize = if (focus == .normal and rows.len > 0)
        view.nav.currentHunkInFile(rows, cur)
    else
        null;
    const expand_ok = if (expand_hunk) |hi| switch (rows[hi]) {
        .hunk_header => |hh| hh.can_grow,
        else => false,
    } else false;
    return .{
        .file = file,
        .hunk = hunk,
        .section = section,
        .group = group,
        .expand_hunk = expand_hunk,
        .expand_ok = expand_ok,
    };
}

/// Path/header on the left; `hint` right-aligned with a one-column gap.
/// Skips the hint when it would not leave that gap. Hint is dim on `style`.
fn putRowHint(scr: *tui.Screen, y: u16, text: []const u8, hint: []const u8, style: tui.Style) void {
    if (hint.len == 0) {
        scr.putStr(0, y, text, style, 0, null);
        return;
    }
    const cols = scr.cols;
    const hint_w: u16 = std.math.cast(u16, tui.screen.displayWidth(hint)) orelse {
        scr.putStr(0, y, text, style, 0, null);
        return;
    };
    if (hint_w == 0 or hint_w + 1 >= cols) {
        scr.putStr(0, y, text, style, 0, null);
        return;
    }
    const text_budget: usize = cols - hint_w - 1;
    const end = tui.screen.byteAtCol(text, text_budget);
    scr.putStr(0, y, text[0..end], style, 0, null);
    var hint_st = style;
    hint_st.dim = true;
    hint_st.bold = false;
    scr.putStr(cols - hint_w, y, hint, hint_st, 0, null);
}

pub fn fillRow(scr: *tui.Screen, y: u16, style: tui.Style) void {
    fillSpan(scr, 0, scr.cols, y, style);
}

/// Fill columns `[x0, x1)` on row `y` (clamped to the screen).
pub fn fillSpan(scr: *tui.Screen, x0: u16, x1: u16, y: u16, style: tui.Style) void {
    var x = x0;
    while (x < x1 and x < scr.cols) : (x += 1) {
        scr.setCell(x, y, .{ .char = ' ', .width = 1, .style = style });
    }
}

/// Center `│` between side-by-side panes on row `y`.
fn putSbsCenter(scr: *tui.Screen, panes: view.layout.SbsPanes, y: u16, cols: u16, style: tui.Style) void {
    if (panes.right_w > 0 or panes.gutter_x < cols) {
        fillSpan(scr, panes.gutter_x, panes.gutter_x + 1, y, style);
        if (panes.gutter_x < cols) {
            scr.setCell(panes.gutter_x, y, .{
                .char = '│',
                .width = 1,
                .style = style,
            });
        }
    }
}

/// Write `text` into a pane starting at `x`, at most `pane_w` display columns.
fn putPaneStr(scr: *tui.Screen, x: u16, y: u16, pane_w: u16, text: []const u8, style: tui.Style) void {
    if (pane_w == 0) return;
    const end = tui.screen.byteAtCol(text, pane_w);
    scr.putStr(x, y, text[0..end], style, 0, null);
}

const testing = std.testing;

test "formatRow file header marked" {
    var buf: [64]u8 = undefined;
    const row: view.row.Row = .{ .file_header = .{ .path = "a.zig", .is_binary = false } };
    try testing.expectEqualStrings("  a.zig", formatRow(&buf, row, false));
    try testing.expectEqualStrings("* a.zig", formatRow(&buf, row, true));
    const bin: view.row.Row = .{ .file_header = .{ .path = "pic.png", .is_binary = true } };
    try testing.expectEqualStrings("  pic.png  (binary)", formatRow(&buf, bin, false));
    try testing.expectEqualStrings("* pic.png  (binary)", formatRow(&buf, bin, true));
}

test "formatRow file header rename" {
    var buf: [64]u8 = undefined;
    const renamed: view.row.Row = .{ .file_header = .{
        .path = "new_name.txt",
        .is_binary = false,
        .old_path = "old_name.txt",
        .new_path = "new_name.txt",
    } };
    try testing.expectEqualStrings("  old_name.txt -> new_name.txt", formatRow(&buf, renamed, false));
    try testing.expectEqualStrings("* old_name.txt -> new_name.txt", formatRow(&buf, renamed, true));
    const bin_renamed: view.row.Row = .{ .file_header = .{
        .path = "new.png",
        .is_binary = true,
        .old_path = "old.png",
        .new_path = "new.png",
    } };
    try testing.expectEqualStrings("  old.png -> new.png  (binary)", formatRow(&buf, bin_renamed, false));
    const added: view.row.Row = .{ .file_header = .{
        .path = "new.txt",
        .is_binary = false,
        .new_path = "new.txt",
    } };
    try testing.expectEqualStrings("  new.txt", formatRow(&buf, added, false));
    const deleted: view.row.Row = .{ .file_header = .{
        .path = "gone.txt",
        .is_binary = false,
        .old_path = "gone.txt",
    } };
    try testing.expectEqualStrings("  gone.txt", formatRow(&buf, deleted, false));
}

test "rowMarked file header is not a line" {
    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, null, null, "file", .local);
    _ = try review.addOpen("f", null, 1, .new, "line", .local);

    const fh: view.row.Row = .{ .file_header = .{ .path = "f", .is_binary = false } };
    const other: view.row.Row = .{ .file_header = .{ .path = "g", .is_binary = false } };
    const line: view.row.Row = .{ .line = .{ .kind = .add, .text = "x", .path = "f", .new_no = 1 } };
    try testing.expect(rowMarked(fh, &review));
    try testing.expect(rowMarked(line, &review));
    try testing.expect(!rowMarked(other, &review));
    try testing.expect(!rowMarked(.{ .section_header = .unstaged }, &review));

    var lines_only = try store.initEmpty(testing.allocator, "t");
    defer lines_only.deinit();
    _ = try lines_only.addOpen("f", null, 1, .new, "line", .local);
    try testing.expect(!rowMarked(fh, &lines_only));
    try testing.expect(rowMarked(line, &lines_only));
}

test "rowMarked hunk is not a line" {
    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("f", 1, 1, null, "hunk", .local);
    _ = try review.addOpen("f", null, 1, .new, "line", .local);

    const hunk: view.row.Row = .{ .hunk_header = .{
        .path = "f",
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = "",
    } };
    const other_hunk: view.row.Row = .{ .hunk_header = .{
        .path = "f",
        .old_start = 10,
        .old_count = 1,
        .new_start = 10,
        .new_count = 1,
        .section = "",
    } };
    const fh: view.row.Row = .{ .file_header = .{ .path = "f", .is_binary = false } };
    const line: view.row.Row = .{ .line = .{ .kind = .add, .text = "x", .path = "f", .new_no = 1 } };
    try testing.expect(rowMarked(hunk, &review));
    try testing.expect(!rowMarked(other_hunk, &review));
    try testing.expect(!rowMarked(fh, &review));
    try testing.expect(rowMarked(line, &review));

    var hunk_only = try store.initEmpty(testing.allocator, "t");
    defer hunk_only.deinit();
    _ = try hunk_only.addOpen("f", 1, 1, null, "hunk", .local);
    try testing.expect(rowMarked(hunk, &hunk_only));
    try testing.expect(!rowMarked(line, &hunk_only));
    try testing.expect(!rowMarked(fh, &hunk_only));
}

test "lineNumberWidth is max digits and at least 1" {
    try testing.expectEqual(1, lineNumberWidth(&.{}));
    const headers: []const view.row.Row = &.{
        .{ .file_header = .{ .path = "f", .is_binary = false } },
    };
    try testing.expectEqual(1, lineNumberWidth(headers));
    const mixed: []const view.row.Row = &.{
        .{ .line = .{ .kind = .context, .text = "a", .path = "f", .old_no = 9, .new_no = 9 } },
        .{ .line = .{ .kind = .add, .text = "b", .path = "f", .new_no = 10 } },
    };
    try testing.expectEqual(2, lineNumberWidth(mixed));
    const wide: []const view.row.Row = &.{
        .{ .line = .{ .kind = .delete, .text = "c", .path = "f", .old_no = 100 } },
    };
    try testing.expectEqual(3, lineNumberWidth(wide));
}

test "lineGutterCols numbers on and off" {
    try testing.expectEqual(8, lineGutterCols(2, .unified));
    try testing.expectEqual(5, lineGutterCols(2, .side_by_side));
    try testing.expectEqual(2, lineGutterCols(0, .unified));
    try testing.expectEqual(2, lineGutterCols(0, .side_by_side));
}

test "formatBodyGutter unified sbs meta and off" {
    var buf: [32]u8 = undefined;
    const ctx: view.row.Row = .{ .line = .{
        .kind = .context,
        .text = "hello",
        .path = "f",
        .old_no = 10,
        .new_no = 11,
    } };
    const del: view.row.Row = .{ .line = .{
        .kind = .delete,
        .text = "gone",
        .path = "f",
        .old_no = 12,
    } };
    const add: view.row.Row = .{ .line = .{
        .kind = .add,
        .text = "new",
        .path = "f",
        .new_no = 13,
    } };
    const meta: view.row.Row = .{ .line = .{
        .kind = .meta,
        .text = "No newline at end of file",
        .path = "f",
    } };
    const hunk: view.row.Row = .{ .hunk_header = .{
        .path = "f",
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = "",
    } };

    try testing.expectEqualStrings("  10 11 ", formatBodyGutter(&buf, ctx, false, 2, .unified, true));
    try testing.expectEqualStrings("* 10 11 ", formatBodyGutter(&buf, ctx, true, 2, .unified, true));
    try testing.expectEqualStrings("  12    ", formatBodyGutter(&buf, del, false, 2, .unified, true));
    try testing.expectEqualStrings("     13 ", formatBodyGutter(&buf, add, false, 2, .unified, true));
    try testing.expectEqualStrings(" \\      ", formatBodyGutter(&buf, meta, false, 2, .unified, true));
    try testing.expectEqualStrings("  12 ", formatBodyGutter(&buf, del, false, 2, .old, true));
    try testing.expectEqualStrings("  13 ", formatBodyGutter(&buf, add, false, 2, .new, true));
    try testing.expectEqualStrings("     ", formatBodyGutter(&buf, add, false, 2, .old, true));
    try testing.expectEqualStrings("  ", formatBodyGutter(&buf, ctx, false, 0, .unified, true));
    try testing.expectEqualStrings("* ", formatBodyGutter(&buf, ctx, true, 0, .unified, true));
    try testing.expectEqualStrings(" \\", formatBodyGutter(&buf, meta, false, 0, .unified, true));
    try testing.expectEqualStrings("", formatBodyGutter(&buf, hunk, false, 2, .unified, true));
    try testing.expectEqualStrings("        ", formatBodyGutter(&buf, ctx, false, 2, .unified, false));
    try testing.expectEqualStrings("*       ", formatBodyGutter(&buf, ctx, true, 2, .unified, false));
    try testing.expectEqualStrings("  hello", formatRow(&buf, ctx, false));
    try testing.expectEqualStrings("  @@ -1,1 +1,1 @@", formatRow(&buf, hunk, false));
    try testing.expectEqualStrings("* @@ -1,1 +1,1 @@", formatRow(&buf, hunk, true));
}

test "hunkMaxLineWidth is text only" {
    const rows: []const view.row.Row = &.{
        .{ .hunk_header = .{
            .path = "f",
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .section = "",
        } },
        .{ .line = .{ .kind = .context, .text = "hello", .path = "f", .old_no = 1, .new_no = 1 } },
    };
    const span = view.viewport.HunkSpan{ .header = 0, .body_start = 1, .body_end = 2 };
    try testing.expectEqual(5, hunkMaxLineWidth(rows, span));
}

test "putPannedBody pans text and leaves gutter" {
    const row: view.row.Row = .{ .line = .{
        .kind = .context,
        .text = "ABCDEFGHIJ",
        .path = "f",
        .old_no = 1,
        .new_no = 2,
    } };
    const st = tui.Style{};
    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 20, .rows = 1 });
    defer scr.deinit();

    const pane = BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 20,
        .num_w = 1,
        .numbers = .unified,
        .col_scroll = 0,
    };
    scr.clear();
    pane.putPanned(0, row, false, false, st, false);
    try testing.expectEqual(' ', scr.getCell(0, 0).char);
    try testing.expectEqual('1', scr.getCell(2, 0).char);
    try testing.expectEqual('2', scr.getCell(4, 0).char);
    try testing.expectEqual('A', scr.getCell(6, 0).char);

    scr.clear();
    var panned = pane;
    panned.col_scroll = 3;
    panned.putPanned(0, row, false, true, st, false);
    try testing.expectEqual(' ', scr.getCell(0, 0).char);
    try testing.expectEqual('1', scr.getCell(2, 0).char);
    try testing.expectEqual('2', scr.getCell(4, 0).char);
    try testing.expectEqual('D', scr.getCell(6, 0).char);
    try testing.expectEqual('E', scr.getCell(7, 0).char);

    scr.clear();
    const marked = BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 20,
        .num_w = 0,
        .numbers = .unified,
        .col_scroll = 2,
    };
    marked.putPanned(0, row, true, true, st, false);
    try testing.expectEqual('*', scr.getCell(0, 0).char);
    try testing.expectEqual(' ', scr.getCell(1, 0).char);
    try testing.expectEqual('C', scr.getCell(2, 0).char);
}

test "word spans grey the line and color only the changed columns" {
    const spans = [_]diff.Span{.{ .start = 6, .end = 11 }};
    const row: view.row.Row = .{ .line = .{
        .kind = .add,
        .text = "hello WORLD",
        .path = "f",
        .new_no = 1,
        .spans = &spans,
    } };
    const plain: view.row.Row = .{ .line = .{
        .kind = .add,
        .text = "hello WORLD",
        .path = "f",
        .new_no = 1,
    } };
    try testing.expect(palette.rowStyle(plain, false).bg.eql(palette.add.bg));
    try testing.expect(palette.rowStyle(row, false).bg.eql(palette.change.bg));
    try testing.expect(palette.rowStyle(row, true).bg.eql(palette.change_cur.bg));

    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 20, .rows = 3 });
    defer scr.deinit();
    const pane = BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 20,
        .num_w = 0,
        .numbers = .unified,
        .col_scroll = 0,
    };
    const base = palette.rowStyle(row, false);
    scr.clear();
    pane.putPanned(0, row, false, false, base, false);
    // 2-column gutter, then "hello " on grey and "WORLD" on the add fill.
    try testing.expect(scr.getCell(2, 0).style.bg.eql(palette.change.bg));
    try testing.expectEqual('h', scr.getCell(2, 0).char);
    try testing.expect(scr.getCell(7, 0).style.bg.eql(palette.change.bg));
    try testing.expectEqual(' ', scr.getCell(7, 0).char);
    try testing.expect(scr.getCell(8, 0).style.bg.eql(palette.add.bg));
    try testing.expectEqual('W', scr.getCell(8, 0).char);

    scr.clear();
    var panned = pane;
    panned.col_scroll = 6;
    panned.putPanned(0, row, false, true, base, false);
    try testing.expect(scr.getCell(2, 0).style.bg.eql(palette.add.bg));
    try testing.expectEqual('W', scr.getCell(2, 0).char);

    const del_spans = [_]diff.Span{.{ .start = 6, .end = 11 }};
    const deleted: view.row.Row = .{ .line = .{
        .kind = .delete,
        .text = "hello WORLD",
        .path = "f",
        .old_no = 1,
        .spans = &del_spans,
    } };
    scr.clear();
    pane.putPanned(0, deleted, false, false, palette.rowStyle(deleted, true), true);
    try testing.expect(scr.getCell(2, 0).style.bg.eql(palette.change_cur.bg));
    try testing.expect(scr.getCell(8, 0).style.bg.eql(palette.del_cur.bg));

    // Text width 6 wraps "hello WORLD" into "hello" and "WORLD".
    scr.clear();
    var wrapped = pane;
    wrapped.pane_w = 8;
    _ = wrapped.putWrapped(0, 3, row, false, base, false);
    try testing.expect(scr.getCell(2, 0).style.bg.eql(palette.change.bg));
    try testing.expectEqual('h', scr.getCell(2, 0).char);
    try testing.expect(scr.getCell(2, 1).style.bg.eql(palette.add.bg));
    try testing.expectEqual('W', scr.getCell(2, 1).char);
}

test "a fully covered line keeps the solid add or delete fill" {
    try testing.expect(palette.change.bg.eql(.{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x1e } }));
    const whole = [_]diff.Span{.{ .start = 0, .end = 11 }};
    const row: view.row.Row = .{ .line = .{
        .kind = .add,
        .text = "hello WORLD",
        .path = "f",
        .new_no = 1,
        .spans = &whole,
    } };
    try testing.expect(palette.rowStyle(row, false).bg.eql(palette.add.bg));
    try testing.expect(palette.rowStyle(row, true).bg.eql(palette.add_cur.bg));

    const parts = [_]diff.Span{ .{ .start = 0, .end = 5 }, .{ .start = 5, .end = 11 } };
    const joined: view.row.Row = .{ .line = .{
        .kind = .delete,
        .text = "hello WORLD",
        .path = "f",
        .old_no = 1,
        .spans = &parts,
    } };
    try testing.expect(palette.rowStyle(joined, false).bg.eql(palette.del.bg));

    // The only uncovered byte is the space. Whitespace does not keep intra-line mode.
    const gap = [_]diff.Span{ .{ .start = 0, .end = 5 }, .{ .start = 6, .end = 11 } };
    const split: view.row.Row = .{ .line = .{
        .kind = .add,
        .text = "hello WORLD",
        .path = "f",
        .new_no = 1,
        .spans = &gap,
    } };
    try testing.expect(palette.rowStyle(split, false).bg.eql(palette.add.bg));

    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 20, .rows = 3 });
    defer scr.deinit();
    var pane = BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 20,
        .num_w = 0,
        .numbers = .unified,
        .col_scroll = 0,
    };
    const base = palette.rowStyle(row, false);
    scr.clear();
    _ = pane.putRow(0, 3, row, false, false, false, base, false);
    // Gutter, text, and the rest of the row are the solid add fill.
    try testing.expect(scr.getCell(0, 0).style.bg.eql(palette.add.bg));
    try testing.expect(scr.getCell(2, 0).style.bg.eql(palette.add.bg));
    try testing.expectEqual('h', scr.getCell(2, 0).char);
    try testing.expect(scr.getCell(19, 0).style.bg.eql(palette.add.bg));

    scr.clear();
    pane.pane_w = 8;
    _ = pane.putRow(0, 3, row, false, true, false, base, false);
    try testing.expect(scr.getCell(0, 0).style.bg.eql(palette.add.bg));
    try testing.expect(scr.getCell(7, 0).style.bg.eql(palette.add.bg));
    try testing.expect(scr.getCell(0, 1).style.bg.eql(palette.add.bg));
    try testing.expect(scr.getCell(7, 1).style.bg.eql(palette.add.bg));
}

test "indent outside the spans still uses the solid fill" {
    const spans = [_]diff.Span{.{ .start = 4, .end = 32 }};
    const row: view.row.Row = .{ .line = .{
        .kind = .add,
        .text = "    /// Changed bytes in `text`.",
        .path = "src/diff.zig",
        .new_no = 84,
        .spans = &spans,
    } };
    try testing.expect(palette.rowStyle(row, false).bg.eql(palette.add.bg));
}

test "a side with no changed bytes keeps the dim grey and no red or green" {
    const none: []const diff.Span = &.{};
    const old: view.row.Row = .{ .line = .{
        .kind = .delete,
        .text = "hello WORLD",
        .path = "f",
        .old_no = 1,
        .spans = none,
    } };
    try testing.expect(palette.rowStyle(old, false).bg.eql(palette.change.bg));
    try testing.expect(palette.rowStyle(old, true).bg.eql(palette.change_cur.bg));

    const unknown: view.row.Row = .{ .line = .{
        .kind = .delete,
        .text = "hello WORLD",
        .path = "f",
        .old_no = 1,
    } };
    try testing.expect(palette.rowStyle(unknown, false).bg.eql(palette.del.bg));

    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 20, .rows = 1 });
    defer scr.deinit();
    const pane = BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 20,
        .num_w = 0,
        .numbers = .unified,
        .col_scroll = 0,
    };
    scr.clear();
    _ = pane.putRow(0, 1, old, false, false, false, palette.rowStyle(old, false), false);
    try testing.expect(scr.getCell(0, 0).style.bg.eql(palette.change.bg));
    try testing.expectEqual('h', scr.getCell(2, 0).char);
    try testing.expect(scr.getCell(2, 0).style.bg.eql(palette.change.bg));
    try testing.expect(scr.getCell(19, 0).style.bg.eql(palette.change.bg));
}

test "putPannedBody expands a tab to the next stop" {
    const row: view.row.Row = .{ .line = .{
        .kind = .context,
        .text = "\tX",
        .path = "f",
        .old_no = 1,
        .new_no = 2,
    } };
    const st = tui.Style{};
    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 20, .rows = 1 });
    defer scr.deinit();

    // num_w 0 → 2-column gutter. Tab is a dim arrow plus 3 spaces, then X.
    const pane = BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 20,
        .num_w = 0,
        .numbers = .unified,
        .col_scroll = 0,
    };
    scr.clear();
    pane.putPanned(0, row, false, false, st, false);
    try testing.expectEqual('→', scr.getCell(2, 0).char);
    try testing.expect(scr.getCell(2, 0).style.dim);
    try testing.expectEqual(' ', scr.getCell(3, 0).char);
    try testing.expect(!scr.getCell(3, 0).style.dim);
    try testing.expectEqual('X', scr.getCell(6, 0).char);

    // Skip 3 columns: the arrow is gone, one space remains, then X.
    scr.clear();
    var skipped = pane;
    skipped.col_scroll = 3;
    skipped.putPanned(0, row, false, true, st, false);
    try testing.expectEqual(' ', scr.getCell(2, 0).char);
    try testing.expectEqual('X', scr.getCell(3, 0).char);
}

test "putWrappedPane wraps text and repeats gutter" {
    const row: view.row.Row = .{ .line = .{
        .kind = .context,
        .text = "hello world",
        .path = "f",
        .old_no = 1,
        .new_no = 2,
    } };
    const st = tui.Style{};
    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 12, .rows = 3 });
    defer scr.deinit();
    scr.clear();
    const next = (BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 12,
        .num_w = 0,
        .numbers = .unified,
        .col_scroll = 0,
    }).putWrapped(0, 3, row, false, st, false);
    try testing.expectEqual(2, next);
    try testing.expectEqual(' ', scr.getCell(0, 0).char);
    try testing.expectEqual('h', scr.getCell(2, 0).char);
    try testing.expectEqual('o', scr.getCell(6, 0).char);
    try testing.expectEqual(' ', scr.getCell(0, 1).char);
    try testing.expectEqual('w', scr.getCell(2, 1).char);
    try testing.expectEqual('d', scr.getCell(6, 1).char);
}

test "putWrappedPane omits line numbers on continuation" {
    const row: view.row.Row = .{ .line = .{
        .kind = .context,
        .text = "hello world",
        .path = "f",
        .old_no = 1,
        .new_no = 2,
    } };
    const st = tui.Style{};
    // gutter 2 + num_w 1 + 1 + num_w 1 + 1 = 6; pane 16 → text_w 10
    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 16, .rows = 2 });
    defer scr.deinit();
    scr.clear();
    _ = (BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 16,
        .num_w = 1,
        .numbers = .unified,
        .col_scroll = 0,
    }).putWrapped(0, 2, row, false, st, false);
    try testing.expectEqual('1', scr.getCell(2, 0).char);
    try testing.expectEqual('2', scr.getCell(4, 0).char);
    try testing.expectEqual('h', scr.getCell(6, 0).char);
    try testing.expectEqual(' ', scr.getCell(2, 1).char);
    try testing.expectEqual(' ', scr.getCell(4, 1).char);
    try testing.expectEqual('w', scr.getCell(6, 1).char);
}

test "putWrappedPane keeps mark on continuation" {
    const row: view.row.Row = .{ .line = .{
        .kind = .add,
        .text = "hello world",
        .path = "f",
        .new_no = 1,
    } };
    const st = tui.Style{};
    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 12, .rows = 2 });
    defer scr.deinit();
    scr.clear();
    _ = (BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 12,
        .num_w = 0,
        .numbers = .unified,
        .col_scroll = 0,
    }).putWrapped(0, 2, row, true, st, false);
    try testing.expectEqual('*', scr.getCell(0, 0).char);
    try testing.expectEqual('*', scr.getCell(0, 1).char);
}

test "putWrappedPane clips at y_end" {
    const row: view.row.Row = .{ .line = .{
        .kind = .context,
        .text = "hello world",
        .path = "f",
    } };
    const st = tui.Style{};
    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 12, .rows = 2 });
    defer scr.deinit();
    scr.clear();
    const next = (BodyPane{
        .scr = &scr,
        .x = 0,
        .pane_w = 12,
        .num_w = 0,
        .numbers = .unified,
        .col_scroll = 0,
    }).putWrapped(0, 1, row, false, st, false);
    try testing.expectEqual(1, next);
    try testing.expectEqual('h', scr.getCell(2, 0).char);
    try testing.expectEqual(' ', scr.getCell(2, 1).char);
}

test "putWrappedPane wraps at side-by-side pane width" {
    const row: view.row.Row = .{ .line = .{
        .kind = .delete,
        .text = "hello world",
        .path = "f",
        .old_no = 1,
    } };
    const st = tui.Style{};
    var scr = try tui.Screen.init(testing.allocator, .{ .cols = 24, .rows = 3 });
    defer scr.deinit();
    scr.clear();
    const next = (BodyPane{
        .scr = &scr,
        .x = 10,
        .pane_w = 12,
        .num_w = 0,
        .numbers = .old,
        .col_scroll = 0,
    }).putWrapped(0, 3, row, false, st, false);
    try testing.expectEqual(2, next);
    try testing.expectEqual(' ', scr.getCell(9, 0).char);
    try testing.expectEqual('h', scr.getCell(12, 0).char);
    try testing.expectEqual('w', scr.getCell(12, 1).char);
}

test "headerHint joins git and approve" {
    var buf: [160]u8 = undefined;
    const hints = RowHints{ .file = 1, .group = .unstaged };
    try testing.expectEqualStrings(
        "Stage File (gS)  Discard File (gD)  Approve File (A)",
        hints.text(&buf, 1),
    );
}

test "headerHint expand on hunk that can grow" {
    var buf: [160]u8 = undefined;
    const growing = RowHints{
        .file = 1,
        .hunk = 2,
        .group = .unstaged,
        .expand_hunk = 2,
        .expand_ok = true,
    };
    try testing.expectEqualStrings(
        "Stage Hunk (gs)  Discard Hunk (gd)  Approve Hunk (a)  Expand (e)",
        growing.text(&buf, 2),
    );
    const expand_only = RowHints{ .expand_hunk = 2, .expand_ok = true };
    try testing.expectEqualStrings("Expand (e)", expand_only.text(&buf, 2));
    const held = RowHints{
        .file = 1,
        .hunk = 2,
        .group = .unstaged,
        .expand_hunk = 2,
        .expand_ok = false,
    };
    try testing.expectEqualStrings(
        "Stage Hunk (gs)  Discard Hunk (gd)  Approve Hunk (a)",
        held.text(&buf, 2),
    );
    try testing.expectEqualStrings("", growing.expandAt(1));
    try testing.expectEqualStrings("Expand (e)", growing.expandAt(2));
    try testing.expectEqualStrings("", held.expandAt(2));
}

test "indexHintForRow file hunk and sticky file" {
    const unstaged_file = RowHints{ .file = 1, .group = .unstaged };
    try testing.expectEqualStrings(
        "Stage File (gS)  Discard File (gD)",
        unstaged_file.indexAt(1),
    );
    const unstaged_both = RowHints{ .file = 1, .hunk = 2, .group = .unstaged };
    try testing.expectEqualStrings(
        "Stage File (gS)  Discard File (gD)",
        unstaged_both.indexAt(1),
    );
    const staged_both = RowHints{ .file = 1, .hunk = 2, .group = .staged };
    try testing.expectEqualStrings("Unstage File (gU)", staged_both.indexAt(1));
    try testing.expectEqualStrings(
        "Stage Hunk (gs)  Discard Hunk (gd)",
        unstaged_both.indexAt(2),
    );
    try testing.expectEqualStrings("Unstage Hunk (gu)", staged_both.indexAt(2));
}

test "approveHintForRow file hunk section and sticky file" {
    const section = RowHints{ .section = 0, .group = .unstaged };
    try testing.expectEqualStrings("", section.approveAt(0));
    const staged_file = RowHints{ .file = 1, .group = .staged };
    try testing.expectEqualStrings("Approve File (A)", staged_file.approveAt(1));
    const unstaged_both = RowHints{ .file = 1, .hunk = 2, .group = .unstaged };
    try testing.expectEqualStrings("Approve Hunk (a)", unstaged_both.approveAt(2));
    try testing.expectEqualStrings("Approve File (A)", unstaged_both.approveAt(1));
    const untagged = RowHints{ .section = 0 };
    try testing.expectEqualStrings("", untagged.approveAt(0));
}

test "formatFooter approved-only is not a clean worktree" {
    var buf: [64]u8 = undefined;
    const empty = view.nav.Status{
        .path = "",
        .hunk_i = 0,
        .hunk_n = 0,
        .row_i = 0,
        .row_n = 0,
    };
    try testing.expectEqualStrings(
        "HEAD · empty",
        formatFooter(&buf, empty, 0, .side_by_side, 80, .local, 0, false),
    );
    try testing.expectEqualStrings(
        "HEAD · 2 approved",
        formatFooter(&buf, empty, 0, .side_by_side, 80, .local, 2, false),
    );
    try testing.expectEqualStrings(
        "main...HEAD",
        formatFooter(&buf, empty, 0, .side_by_side, 80, .{ .range = "main...HEAD" }, 3, false),
    );
    try testing.expectEqualStrings(
        "abc123",
        formatFooter(&buf, empty, 0, .side_by_side, 80, .{ .commit = "abc123" }, 3, false),
    );
}

test "formatFooter shows wrap when on" {
    var buf: [96]u8 = undefined;
    const st = view.nav.Status{
        .path = "f",
        .hunk_i = 1,
        .hunk_n = 1,
        .row_i = 1,
        .row_n = 2,
    };
    const off = formatFooter(&buf, st, 0, .unified, 80, .local, 0, false);
    try testing.expect(std.mem.indexOf(u8, off, "wrap") == null);
    var buf2: [96]u8 = undefined;
    const on = formatFooter(&buf2, st, 0, .unified, 80, .local, 0, true);
    try testing.expect(std.mem.indexOf(u8, on, "wrap") != null);
}
