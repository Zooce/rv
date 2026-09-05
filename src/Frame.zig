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
const Draft = root.Draft;
const DiscardConfirm = root.DiscardConfirm;

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
///   add / delete  — green/red fills (#35); markers are not restored
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
                .line => |ln| switch (ln.kind) {
                    .add => self.add_cur,
                    .delete => self.del_cur,
                    .context => self.ctx_cur,
                    .meta => self.cur,
                },
                .section_header => self.section_cur,
                .file_header => self.file_cur,
                .hunk_header => self.hunk_cur,
            };
        }
        return switch (row) {
            .section_header => self.section,
            .file_header => self.file,
            .hunk_header => self.hunk,
            .line => |ln| switch (ln.kind) {
                .add => self.add,
                .delete => self.del,
                .meta => self.meta,
                .context => self.body,
            },
        };
    }
};

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

pub fn paint(
    self: *const Frame,
    scr: *tui.Screen,
    size: tui.Size,
    diff_view: *const DiffView,
    viewport: *Viewport,
    review: *const store.Review,
    source: cli.Source,
    focus: Focus,
    draft: *const Draft,
    discard: DiscardConfirm,
) void {
    const rows = diff_view.rows;
    const sbs_slots = diff_view.sbs_slots;
    const status_note = self.note.slice();
    const pal = palette;

    scr.clearStyle(pal.body);

    if (size.rows > 0) {
        fillRow(scr, 0, pal.title);
        const help = switch (focus) {
            .commenting => draft.titleBar(),
            .searching => "rv  search  Enter jump  Esc cancel",
            .listing => "rv  comments  j/k move  Enter jump  Esc close  q quit",
            .files => "rv  files  j/k move  Enter jump  Esc close  q quit",
            .approved => "rv  approved  j/k move  Enter unapprove  Esc close  q quit",
            .helping => "rv  help  j/k  Esc/? close  q quit",
            .git_error => "rv  git error  Enter/Esc close  q quit",
            .discard_confirm => discard.titleBar(),
            .normal => "rv  j/k  /  i/I  ? help  q quit",
        };
        scr.putStr(1, 0, help, pal.title, null);
    }

    // Footer: 1 status row, search prompt, or soft-wrapped comment box.
    const has_footer = size.rows >= 2;
    const footer_h: u16 = if (!has_footer)
        0
    else if (focus == .commenting)
        draft.metrics(size).height
    else
        1;
    const footer_top: u16 = if (has_footer) size.rows - footer_h else 0;
    const content_top: u16 = 1;
    const content_bottom: u16 = if (has_footer) footer_top else size.rows;
    const content_rows: usize = if (content_bottom > content_top)
        content_bottom - content_top
    else
        0;

    const cur = view.row.clampCursor(viewport.cursor, rows.len);
    const layout = view.layout.effectiveLayout(viewport.layout_pref, size.cols);
    const num_w = if (viewport.show_line_numbers) lineNumberWidth(rows) else 0;

    var line_buf: [512]u8 = undefined;
    // Only lines in the cursor's hunk pan; file/hunk headers never pan.
    const pan_span = view.viewport.hunkSpanAt(rows, cur);
    const sticky = viewport.settle(size.cols, content_rows, rows, sbs_slots);
    const cs = viewport.col_scroll;

    const hints_ok = source == .local and focus == .normal and rows.len > 0;
    const hint_section: ?usize = if (hints_ok and rows[cur] == .section_header) cur else null;
    const hint_file: ?usize = blk: {
        if (!hints_ok or hint_section != null) break :blk null;
        const fi = view.nav.currentFileStart(rows, cur) orelse break :blk null;
        const grouped = switch (rows[fi]) {
            .file_header => |fh| fh.group != null,
            else => false,
        };
        break :blk if (grouped) fi else null;
    };
    const hint_hunk: ?usize = if (hint_file != null)
        view.nav.currentHunkInFile(rows, cur)
    else
        null;
    const hint_group: ?diff.Group = if (hint_file) |fi|
        rows[fi].file_header.group
    else if (hint_section) |si|
        rows[si].section_header
    else
        null;
    const show_fold = focus == .normal and rows.len > 0;
    var hint_buf: [160]u8 = undefined;

    switch (layout) {
        .unified => {
            var screen_y: u16 = content_top;

            // Sticky file path under the title bar (hunk headers scroll with body).
            if (sticky.file_idx) |fi| {
                if (screen_y < content_bottom) {
                    const text = formatRow(&line_buf, rows[fi], rowMarked(rows[fi], review));
                    const st = if (fi == cur) pal.file_cur else pal.file;
                    fillRow(scr, screen_y, st);
                    putRowHint(scr, screen_y, text, headerHint(&hint_buf, diff_view.folds, rows, fi, hint_file, hint_hunk, hint_section, hint_group, show_fold), st);
                    screen_y += 1;
                }
            }

            var i: usize = viewport.scroll;
            while (i < rows.len and screen_y < content_bottom) : (i += 1) {
                const is_cur = i == cur;
                const marked = rowMarked(rows[i], review);
                const st = pal.rowStyle(rows[i], is_cur);
                if (rows[i] == .section_header) {
                    scr.fillRect(.{ .x = 0, .y = screen_y, .w = scr.cols, .h = 1 }, '─', st);
                } else {
                    fillRow(scr, screen_y, st);
                }
                switch (rows[i]) {
                    .line => putPannedBody(
                        scr,
                        0,
                        screen_y,
                        size.cols,
                        rows[i],
                        marked,
                        num_w,
                        .unified,
                        pan_span.containsBody(i),
                        cs,
                        st,
                    ),
                    else => {
                        const text = formatRow(&line_buf, rows[i], marked);
                        putRowHint(scr, screen_y, text, headerHint(&hint_buf, diff_view.folds, rows, i, hint_file, hint_hunk, hint_section, hint_group, show_fold), st);
                    },
                }
                screen_y += 1;
            }
        },
        .side_by_side => {
            const panes = view.layout.sbsPaneWidths(size.cols);
            var screen_y: u16 = content_top;

            if (sticky.file_idx) |fi| {
                if (screen_y < content_bottom) {
                    const text = formatRow(&line_buf, rows[fi], rowMarked(rows[fi], review));
                    const st = if (fi == cur) pal.file_cur else pal.file;
                    fillRow(scr, screen_y, st);
                    putRowHint(scr, screen_y, text, headerHint(&hint_buf, diff_view.folds, rows, fi, hint_file, hint_hunk, hint_section, hint_group, show_fold), st);
                    screen_y += 1;
                }
            }

            var si: usize = viewport.scroll;
            while (si < sbs_slots.len and screen_y < content_bottom) : (si += 1) {
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
                        putRowHint(scr, screen_y, text, headerHint(&hint_buf, diff_view.folds, rows, ri, hint_file, hint_hunk, hint_section, hint_group, show_fold), st);
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

                        fillSpan(scr, 0, panes.gutter_x, screen_y, left_st);
                        if (panes.right_w > 0 or panes.gutter_x < size.cols) {
                            fillSpan(scr, panes.gutter_x, panes.gutter_x + 1, screen_y, pal.gutter);
                            if (panes.gutter_x < size.cols) {
                                scr.setCell(panes.gutter_x, screen_y, .{
                                    .char = '│',
                                    .width = 1,
                                    .style = pal.gutter,
                                });
                            }
                        }
                        const right_x: u16 = panes.gutter_x + 1;
                        fillSpan(scr, right_x, size.cols, screen_y, right_st);

                        if (p.left) |ri| {
                            putPannedBody(
                                scr,
                                0,
                                screen_y,
                                panes.left_w,
                                rows[ri],
                                rowMarked(rows[ri], review),
                                num_w,
                                .old,
                                pan_span.containsBody(ri),
                                cs,
                                left_st,
                            );
                        }
                        if (p.right) |ri| {
                            putPannedBody(
                                scr,
                                right_x,
                                screen_y,
                                panes.right_w,
                                rows[ri],
                                rowMarked(rows[ri], review),
                                num_w,
                                .new,
                                pan_span.containsBody(ri),
                                cs,
                                right_st,
                            );
                        }
                    },
                }
                screen_y += 1;
            }
        },
    }

    if (has_footer) {
        if (focus != .searching and focus != .commenting) {
            const footer_y = footer_top;
            fillRow(scr, footer_y, pal.footer);
            if (status_note.len > 0) {
                scr.putStr(1, footer_y, status_note, pal.footer, null);
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
                );
                scr.putStr(1, footer_y, footer_text, pal.footer, null);
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

fn formatBodyGutter(buf: []u8, row: view.row.Row, marked: bool, num_w: usize, numbers: LineNumbers) []const u8 {
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
    if (num_w == 0) return buf[0..total];
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

/// Gutter (mark + numbers) at `x`; only `ln.text` pans.
fn putPannedBody(
    scr: *tui.Screen,
    x: u16,
    y: u16,
    pane_w: u16,
    row: view.row.Row,
    marked: bool,
    num_w: usize,
    numbers: LineNumbers,
    pan: bool,
    col_scroll: usize,
    style: tui.Style,
) void {
    const ln = switch (row) {
        .line => |l| l,
        else => return,
    };
    var gbuf: [32]u8 = undefined;
    const gutter = formatBodyGutter(&gbuf, row, marked, num_w, numbers);
    const gw_usize = tui.screen.displayWidth(gutter);
    const gw: u16 = std.math.cast(u16, gw_usize) orelse pane_w;
    const text = ln.text;
    const visible = if (pan) text[tui.screen.byteAtCol(text, col_scroll)..] else text;
    if (pane_w > 0) putPaneStr(scr, x, y, @min(gw, pane_w), gutter, style);
    if (pane_w > gw) putPaneStr(scr, x +| gw, y, pane_w - gw, visible, style);
}

fn rowMarked(row: view.row.Row, review: *const store.Review) bool {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .meta => false,
            else => review.firstAt(ln.path, ln.old_no, ln.new_no) != null,
        },
        .file_header => |fh| review.firstAt(fh.path, null, null) != null,
        else => false,
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
) []const u8 {
    if (st.row_n == 0) {
        if (source == .local and approved_n > 0) {
            return bufPrintTrunc(buf, "HEAD · {d} approved", .{approved_n});
        }
        return cli.sourceLabel(source, true);
    }
    const src = cli.sourceLabel(source, false);
    const mode = layoutFooterLabel(layout_pref, cols);
    if (st.hunk_n == 0) {
        return bufPrintTrunc(buf, "{s}  {s}  {d}/{d}  {d} open  {s}", .{
            src,
            if (st.path.len > 0) st.path else "?",
            st.row_i,
            st.row_n,
            open_n,
            mode,
        });
    }
    return bufPrintTrunc(buf, "{s}  {s}  hunk {d}/{d}  {d}/{d}  {d} open  {s}", .{
        src,
        if (st.path.len > 0) st.path else "?",
        st.hunk_i,
        st.hunk_n,
        st.row_i,
        st.row_n,
        open_n,
        mode,
    });
}

/// Format one row. Line rows: 2-char gutter (`*` if marked else space, then
/// pad/`\` for meta). File headers: `*` in the leading gutter when marked.
/// Add/delete use background color, not `+/-` markers.
pub fn formatRow(buf: []u8, row: view.row.Row, marked: bool) []const u8 {
    return switch (row) {
        .section_header => |g| bufPrintTrunc(buf, "── {s} ", .{switch (g) {
            .unstaged => "Unstaged",
            .untracked => "Untracked",
            .staged => "Staged",
        }}),
        .file_header => |fh| blk: {
            const prefix: []const u8 = if (marked) "* " else " ";
            var path_buf: [512]u8 = undefined;
            const path = view.row.fileHeaderPathLabel(fh, &path_buf);
            if (fh.is_binary)
                break :blk bufPrintTrunc(buf, "{s}{s}  (binary)", .{ prefix, path });
            break :blk bufPrintTrunc(buf, "{s}{s}", .{ prefix, path });
        },
        .hunk_header => |hh| blk: {
            const oc = hh.old_count orelse 1;
            const nc = hh.new_count orelse 1;
            if (hh.section.len > 0) {
                break :blk bufPrintTrunc(buf, " @@ -{d},{d} +{d},{d} @@ {s}", .{
                    hh.old_start, oc, hh.new_start, nc, hh.section,
                });
            }
            break :blk bufPrintTrunc(buf, " @@ -{d},{d} +{d},{d} @@", .{
                hh.old_start, oc, hh.new_start, nc,
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

/// Index labels for the current section/file/hunk rows. Empty when `ri` is
/// not one of those rows. Section row says All (`Space Space`). File row
/// always says File (`Space S` / `Space x` while the cursor is in a hunk,
/// otherwise `Space Space` / `Space d`). Hunk row always says Hunk
/// (`Space Space` / `Space d`). Verb follows the file’s (or section’s)
/// group. Discard chords only on unstaged/untracked file and hunk rows.
pub fn indexHintForRow(ri: usize, file_i: ?usize, hunk_i: ?usize, section_i: ?usize, group: ?diff.Group) []const u8 {
    const g = group orelse return "";
    const stage = switch (g) {
        .unstaged, .untracked => true,
        .staged => false,
    };
    if (section_i) |si| {
        if (ri == si) {
            return if (stage)
                "Stage All (Space Space)"
            else
                "Unstage All (Space Space)";
        }
    }
    if (file_i) |fi| {
        if (ri == fi) {
            if (hunk_i != null) {
                return if (stage)
                    "Stage File (Space S)  Discard File (Space x)"
                else
                    "Unstage File (Space S)";
            }
            return if (stage)
                "Stage File (Space Space)  Discard File (Space d)"
            else
                "Unstage File (Space Space)";
        }
    }
    if (hunk_i) |hi| {
        if (ri == hi) {
            return if (stage)
                "Stage Hunk (Space Space)  Discard Hunk (Space d)"
            else
                "Unstage Hunk (Space Space)";
        }
    }
    return "";
}

/// `Space a` labels on the current section, file, or hunk header. Empty on
/// other rows, range loads (`group == null`), and the file header while the
/// cursor is in a hunk (file-from-hunk approve is not bound).
pub fn approveHintForRow(ri: usize, file_i: ?usize, hunk_i: ?usize, section_i: ?usize, group: ?diff.Group) []const u8 {
    if (group == null) return "";
    if (section_i) |si| {
        if (ri == si) return "Approve All (Space a)";
    }
    if (file_i) |fi| {
        if (ri == fi) {
            if (hunk_i != null) return "";
            return "Approve File (Space a)";
        }
    }
    if (hunk_i) |hi| {
        if (ri == hi) return "Approve Hunk (Space a)";
    }
    return "";
}

/// `Fold (za)` / `Unfold (za)` on a foldable file or hunk header. Empty on
/// sections, body lines, and headers that cannot fold.
pub fn foldHintForRow(folds: *const view.fold.Set, rows: []const view.row.Row, ri: usize) []const u8 {
    if (ri >= rows.len) return "";
    switch (rows[ri]) {
        .file_header, .hunk_header => {},
        .line, .section_header => return "",
    }
    const target = folds.targetAt(rows, ri) orelse return "";
    return switch (target) {
        .file => |f| if (folds.containsFile(f.path, f.group)) "Unfold (za)" else "Fold (za)",
        .hunk => |h| if (folds.containsHunk(h.path, h.group, h.old_start, h.new_start))
            "Unfold (za)"
        else
            "Fold (za)",
    };
}

fn headerHint(
    buf: []u8,
    folds: *const view.fold.Set,
    rows: []const view.row.Row,
    ri: usize,
    file_i: ?usize,
    hunk_i: ?usize,
    section_i: ?usize,
    group: ?diff.Group,
    show_fold: bool,
) []const u8 {
    const fold = if (show_fold) foldHintForRow(folds, rows, ri) else "";
    const git = indexHintForRow(ri, file_i, hunk_i, section_i, group);
    const approve = approveHintForRow(ri, file_i, hunk_i, section_i, group);
    return joinHintParts(buf, fold, git, approve);
}

fn joinHintParts(buf: []u8, a: []const u8, b: []const u8, c: []const u8) []const u8 {
    if (a.len == 0) {
        if (b.len == 0) return c;
        if (c.len == 0) return b;
        return std.fmt.bufPrint(buf, "{s}  {s}", .{ b, c }) catch b;
    }
    if (b.len == 0) {
        if (c.len == 0) return a;
        return std.fmt.bufPrint(buf, "{s}  {s}", .{ a, c }) catch a;
    }
    if (c.len == 0) return std.fmt.bufPrint(buf, "{s}  {s}", .{ a, b }) catch a;
    return std.fmt.bufPrint(buf, "{s}  {s}  {s}", .{ a, b, c }) catch a;
}

/// Path/header on the left; `hint` right-aligned with a one-column gap.
/// Skips the hint when it would not leave that gap. Hint is dim on `style`.
fn putRowHint(scr: *tui.Screen, y: u16, text: []const u8, hint: []const u8, style: tui.Style) void {
    if (hint.len == 0) {
        scr.putStr(0, y, text, style, null);
        return;
    }
    const cols = scr.cols;
    const hint_w: u16 = std.math.cast(u16, tui.screen.displayWidth(hint)) orelse {
        scr.putStr(0, y, text, style, null);
        return;
    };
    if (hint_w == 0 or hint_w + 1 >= cols) {
        scr.putStr(0, y, text, style, null);
        return;
    }
    const text_budget: usize = cols - hint_w - 1;
    const end = tui.screen.byteAtCol(text, text_budget);
    scr.putStr(0, y, text[0..end], style, null);
    var hint_st = style;
    hint_st.dim = true;
    hint_st.bold = false;
    scr.putStr(cols - hint_w, y, hint, hint_st, null);
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

/// Write `text` into a pane starting at `x`, at most `pane_w` display columns.
fn putPaneStr(scr: *tui.Screen, x: u16, y: u16, pane_w: u16, text: []const u8, style: tui.Style) void {
    if (pane_w == 0) return;
    const end = tui.screen.byteAtCol(text, pane_w);
    scr.putStr(x, y, text[0..end], style, null);
}

const testing = std.testing;

test "formatRow file header marked" {
    var buf: [64]u8 = undefined;
    const row: view.row.Row = .{ .file_header = .{ .path = "a.zig", .is_binary = false } };
    try testing.expectEqualStrings(" a.zig", formatRow(&buf, row, false));
    try testing.expectEqualStrings("* a.zig", formatRow(&buf, row, true));
    const bin: view.row.Row = .{ .file_header = .{ .path = "pic.png", .is_binary = true } };
    try testing.expectEqualStrings(" pic.png  (binary)", formatRow(&buf, bin, false));
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
    try testing.expectEqualStrings(" old_name.txt -> new_name.txt", formatRow(&buf, renamed, false));
    try testing.expectEqualStrings("* old_name.txt -> new_name.txt", formatRow(&buf, renamed, true));
    const bin_renamed: view.row.Row = .{ .file_header = .{
        .path = "new.png",
        .is_binary = true,
        .old_path = "old.png",
        .new_path = "new.png",
    } };
    try testing.expectEqualStrings(" old.png -> new.png  (binary)", formatRow(&buf, bin_renamed, false));
    const added: view.row.Row = .{ .file_header = .{
        .path = "new.txt",
        .is_binary = false,
        .new_path = "new.txt",
    } };
    try testing.expectEqualStrings(" new.txt", formatRow(&buf, added, false));
    const deleted: view.row.Row = .{ .file_header = .{
        .path = "gone.txt",
        .is_binary = false,
        .old_path = "gone.txt",
    } };
    try testing.expectEqualStrings(" gone.txt", formatRow(&buf, deleted, false));
}

test "rowMarked file header is not a line" {
    var review = try store.initEmpty(testing.allocator, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, null, null, "file");
    _ = try review.addOpen("f", null, 1, .new, "line");

    const fh: view.row.Row = .{ .file_header = .{ .path = "f", .is_binary = false } };
    const other: view.row.Row = .{ .file_header = .{ .path = "g", .is_binary = false } };
    const line: view.row.Row = .{ .line = .{ .kind = .add, .text = "x", .path = "f", .new_no = 1 } };
    try testing.expect(rowMarked(fh, &review));
    try testing.expect(rowMarked(line, &review));
    try testing.expect(!rowMarked(other, &review));
    try testing.expect(!rowMarked(.{ .section_header = .unstaged }, &review));

    var lines_only = try store.initEmpty(testing.allocator, "t");
    defer lines_only.deinit();
    _ = try lines_only.addOpen("f", null, 1, .new, "line");
    try testing.expect(!rowMarked(fh, &lines_only));
    try testing.expect(rowMarked(line, &lines_only));
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
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = "",
    } };

    try testing.expectEqualStrings("  10 11 ", formatBodyGutter(&buf, ctx, false, 2, .unified));
    try testing.expectEqualStrings("* 10 11 ", formatBodyGutter(&buf, ctx, true, 2, .unified));
    try testing.expectEqualStrings("  12    ", formatBodyGutter(&buf, del, false, 2, .unified));
    try testing.expectEqualStrings("     13 ", formatBodyGutter(&buf, add, false, 2, .unified));
    try testing.expectEqualStrings(" \\      ", formatBodyGutter(&buf, meta, false, 2, .unified));
    try testing.expectEqualStrings("  12 ", formatBodyGutter(&buf, del, false, 2, .old));
    try testing.expectEqualStrings("  13 ", formatBodyGutter(&buf, add, false, 2, .new));
    try testing.expectEqualStrings("     ", formatBodyGutter(&buf, add, false, 2, .old));
    try testing.expectEqualStrings("  ", formatBodyGutter(&buf, ctx, false, 0, .unified));
    try testing.expectEqualStrings("* ", formatBodyGutter(&buf, ctx, true, 0, .unified));
    try testing.expectEqualStrings(" \\", formatBodyGutter(&buf, meta, false, 0, .unified));
    try testing.expectEqualStrings("", formatBodyGutter(&buf, hunk, false, 2, .unified));
    try testing.expectEqualStrings("  hello", formatRow(&buf, ctx, false));
    try testing.expectEqualStrings(" @@ -1,1 +1,1 @@", formatRow(&buf, hunk, false));
}

test "hunkMaxLineWidth is text only" {
    const rows: []const view.row.Row = &.{
        .{ .hunk_header = .{
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

    scr.clear();
    putPannedBody(&scr, 0, 0, 20, row, false, 1, .unified, false, 0, st);
    try testing.expectEqual(' ', scr.getCell(0, 0).char);
    try testing.expectEqual('1', scr.getCell(2, 0).char);
    try testing.expectEqual('2', scr.getCell(4, 0).char);
    try testing.expectEqual('A', scr.getCell(6, 0).char);

    scr.clear();
    putPannedBody(&scr, 0, 0, 20, row, false, 1, .unified, true, 3, st);
    try testing.expectEqual(' ', scr.getCell(0, 0).char);
    try testing.expectEqual('1', scr.getCell(2, 0).char);
    try testing.expectEqual('2', scr.getCell(4, 0).char);
    try testing.expectEqual('D', scr.getCell(6, 0).char);
    try testing.expectEqual('E', scr.getCell(7, 0).char);

    scr.clear();
    putPannedBody(&scr, 0, 0, 20, row, true, 0, .unified, true, 2, st);
    try testing.expectEqual('*', scr.getCell(0, 0).char);
    try testing.expectEqual(' ', scr.getCell(1, 0).char);
    try testing.expectEqual('C', scr.getCell(2, 0).char);
}

test "foldHintForRow file and hunk" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    var folds: view.fold.Set = .{};
    defer folds.deinit(testing.allocator);

    try testing.expectEqualStrings("Fold (za)", foldHintForRow(&folds, rows, 0));
    try testing.expectEqualStrings("Fold (za)", foldHintForRow(&folds, rows, 1));
    try testing.expectEqualStrings("", foldHintForRow(&folds, rows, 2));

    try folds.toggle(testing.allocator, folds.targetAt(rows, 1).?);
    const vis_hunk = try view.fold.visibleRows(testing.allocator, rows, &folds);
    defer testing.allocator.free(vis_hunk);
    try testing.expectEqualStrings("Unfold (za)", foldHintForRow(&folds, vis_hunk, 1));
    try testing.expectEqualStrings("Fold (za)", foldHintForRow(&folds, vis_hunk, 0));

    try folds.toggle(testing.allocator, folds.targetAt(vis_hunk, 0).?);
    const vis_file = try view.fold.visibleRows(testing.allocator, rows, &folds);
    defer testing.allocator.free(vis_file);
    try testing.expectEqualStrings("Unfold (za)", foldHintForRow(&folds, vis_file, 0));
}

test "foldHintForRow skips hunk-less file" {
    const fixture =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var d = try diff.parse(testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    var folds: view.fold.Set = .{};
    defer folds.deinit(testing.allocator);
    try testing.expectEqualStrings("", foldHintForRow(&folds, rows, 0));
}

test "headerHint prepends fold to git hint" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = fixture, .group = .unstaged },
    });
    defer d.deinit();
    const rows = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(rows);
    var folds: view.fold.Set = .{};
    defer folds.deinit(testing.allocator);
    var buf: [160]u8 = undefined;
    const file_i: usize = 1;
    try testing.expectEqualStrings(
        "Fold (za)  Stage File (Space Space)  Discard File (Space d)  Approve File (Space a)",
        headerHint(&buf, &folds, rows, file_i, file_i, null, null, .unstaged, true),
    );
    try testing.expectEqualStrings(
        "Stage File (Space Space)  Discard File (Space d)  Approve File (Space a)",
        headerHint(&buf, &folds, rows, file_i, file_i, null, null, .unstaged, false),
    );
}

test "approveHintForRow file hunk section and file-from-hunk" {
    try testing.expectEqualStrings(
        "Approve All (Space a)",
        approveHintForRow(0, null, null, 0, .unstaged),
    );
    try testing.expectEqualStrings(
        "Approve File (Space a)",
        approveHintForRow(1, 1, null, null, .staged),
    );
    try testing.expectEqualStrings(
        "Approve Hunk (Space a)",
        approveHintForRow(2, 1, 2, null, .unstaged),
    );
    try testing.expectEqualStrings("", approveHintForRow(1, 1, 2, null, .unstaged));
    try testing.expectEqualStrings("", approveHintForRow(0, null, null, 0, null));
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
        formatFooter(&buf, empty, 0, .side_by_side, 80, .local, 0),
    );
    try testing.expectEqualStrings(
        "HEAD · 2 approved",
        formatFooter(&buf, empty, 0, .side_by_side, 80, .local, 2),
    );
    try testing.expectEqualStrings(
        "main...HEAD",
        formatFooter(&buf, empty, 0, .side_by_side, 80, .{ .range = "main...HEAD" }, 3),
    );
}
