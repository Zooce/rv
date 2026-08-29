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

    switch (layout) {
        .unified => {
            var screen_y: u16 = content_top;

            // Sticky file path under the title bar (hunk headers scroll with body).
            if (sticky.file_idx) |fi| {
                if (screen_y < content_bottom) {
                    const text = formatRow(&line_buf, rows[fi], false);
                    const st = if (fi == cur) pal.file_cur else pal.file;
                    fillRow(scr, screen_y, st);
                    putRowHint(scr, screen_y, text, indexHintForRow(fi, hint_file, hint_hunk, hint_section, hint_group), st);
                    screen_y += 1;
                }
            }

            var i: usize = viewport.scroll;
            while (i < rows.len and screen_y < content_bottom) : (i += 1) {
                const is_cur = i == cur;
                const marked = rowMarked(rows[i], review);
                const text = formatRow(&line_buf, rows[i], marked);
                const st = pal.rowStyle(rows[i], is_cur);
                if (rows[i] == .section_header) {
                    scr.fillRect(.{ .x = 0, .y = screen_y, .w = scr.cols, .h = 1 }, '─', st);
                } else {
                    fillRow(scr, screen_y, st);
                }
                const hint = indexHintForRow(i, hint_file, hint_hunk, hint_section, hint_group);
                if (hint.len > 0) {
                    putRowHint(scr, screen_y, text, hint, st);
                } else {
                    const pan = pan_span.containsBody(i);
                    const visible = if (pan) text[tui.screen.byteAtCol(text, cs)..] else text;
                    scr.putStr(0, screen_y, visible, st, null);
                }
                screen_y += 1;
            }
        },
        .side_by_side => {
            const panes = view.layout.sbsPaneWidths(size.cols);
            var screen_y: u16 = content_top;

            if (sticky.file_idx) |fi| {
                if (screen_y < content_bottom) {
                    const text = formatRow(&line_buf, rows[fi], false);
                    const st = if (fi == cur) pal.file_cur else pal.file;
                    fillRow(scr, screen_y, st);
                    putRowHint(scr, screen_y, text, indexHintForRow(fi, hint_file, hint_hunk, hint_section, hint_group), st);
                    screen_y += 1;
                }
            }

            var si: usize = viewport.scroll;
            while (si < sbs_slots.len and screen_y < content_bottom) : (si += 1) {
                switch (sbs_slots[si]) {
                    .header => |ri| {
                        const is_cur = ri == cur;
                        const text = formatRow(&line_buf, rows[ri], false);
                        const st = pal.rowStyle(rows[ri], is_cur);
                        if (rows[ri] == .section_header) {
                            scr.fillRect(.{ .x = 0, .y = screen_y, .w = scr.cols, .h = 1 }, '─', st);
                        } else {
                            fillRow(scr, screen_y, st);
                        }
                        putRowHint(scr, screen_y, text, indexHintForRow(ri, hint_file, hint_hunk, hint_section, hint_group), st);
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
                            const marked = rowMarked(rows[ri], review);
                            const text = formatRow(&line_buf, rows[ri], marked);
                            const pan = pan_span.containsBody(ri);
                            const visible = if (pan) text[tui.screen.byteAtCol(text, cs)..] else text;
                            putPaneStr(scr, 0, screen_y, panes.left_w, visible, left_st);
                        }
                        if (p.right) |ri| {
                            const marked = rowMarked(rows[ri], review);
                            const text = formatRow(&line_buf, rows[ri], marked);
                            const pan = pan_span.containsBody(ri);
                            const visible = if (pan) text[tui.screen.byteAtCol(text, cs)..] else text;
                            putPaneStr(scr, right_x, screen_y, panes.right_w, visible, right_st);
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
                const footer_text = formatFooter(&line_buf, st, review.openCount(), viewport.layout_pref, size.cols, source);
                scr.putStr(1, footer_y, footer_text, pal.footer, null);
            }
            scr.hideCursor();
        }
    } else {
        scr.hideCursor();
    }
}

/// Widest formatted **line** in the hunk body (headers excluded). 0 if empty.
pub fn hunkMaxLineWidth(rows: []const view.row.Row, span: view.viewport.HunkSpan) usize {
    var max_w: usize = 0;
    var line_buf: [512]u8 = undefined;
    var i = span.body_start;
    while (i < span.body_end) : (i += 1) {
        const text = formatRow(&line_buf, rows[i], false);
        max_w = @max(max_w, tui.screen.displayWidth(text));
    }
    return max_w;
}

fn rowMarked(row: view.row.Row, review: *const store.Review) bool {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .meta => false,
            else => review.firstAt(ln.path, ln.old_no, ln.new_no) != null,
        },
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
) []const u8 {
    const src = cli.sourceLabel(source, st.row_n == 0);
    const mode = layoutFooterLabel(layout_pref, cols);
    if (st.row_n == 0) return src;
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
/// pad/`\` for meta). Add/delete use background color, not `+/-` markers.
pub fn formatRow(buf: []u8, row: view.row.Row, marked: bool) []const u8 {
    return switch (row) {
        .section_header => |g| bufPrintTrunc(buf, "── {s} ", .{switch (g) {
            .unstaged => "Unstaged",
            .untracked => "Untracked",
            .staged => "Staged",
        }}),
        .file_header => |fh| if (fh.is_binary)
            bufPrintTrunc(buf, " {s}  (binary)", .{fh.path})
        else
            bufPrintTrunc(buf, " {s}", .{fh.path}),
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
