//! `rv` entry point — CLI dispatch + full-screen diff review (MVP-1 / MVP-2.2).
//!
//! With no args: load smart-default git diff → flatten rows → load `.rv`
//! comments → TUI (`j`/`k`, `[`/`]` hunk, `{`/`}` file header, `i`/`c`/`a`/`Enter` comment, `q` quit).
//! Empty/error paths never enter raw / alt-screen mode.
//!
//! With a subcommand: headless CLI (`status`, `list`, `show`, `resolve`,
//! `reopen`, `export`, `install-skill`, help) — no git load and no raw TTY modes.
//!
//! Comment UX (v1): single-line footer prompt (not an inline box). Esc cancels;
//! Enter saves. Open-comment marker: `*` in the gutter. Add/delete lines use
//! green/red backgrounds (no `+/-`). Reload on next `rv` via
//! `.rv/reviews/current.json`.

const std = @import("std");
const git = @import("git");
const tui = @import("tui");
const view = @import("view");
const store = @import("store");
const cli = @import("cli");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len > 1) {
        const env: cli.Env = .{
            .home = init.environ_map.get("HOME"),
            .skill_dir = init.environ_map.get("RV_SKILL_DIR"),
        };
        return cli.run(alloc, io, argv[1..], env);
    }
    return try runTui(alloc, io);
}

fn runTui(alloc: std.mem.Allocator, io: std.Io) !u8 {
    // Load before any TTY setup so error/empty paths never touch the terminal.
    var d = git.loadDefaultDiff(alloc, io) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NotARepository => "not a git repository (run from a work tree)",
            error.GitNotFound => "git executable not found in PATH",
            error.GitFailed => "git command failed",
            error.OutOfMemory => "out of memory",
            error.BadHunkHeader => "failed to parse unified diff (bad hunk header)",
        };
        std.debug.print("rv: {s}\n", .{msg});
        return 1;
    };
    defer d.deinit();

    if (d.files.len == 0) {
        std.debug.print("rv: no changes to review\n", .{});
        return 0;
    }

    const rows = try view.flatten(alloc, &d);
    defer alloc.free(rows);

    var review = store.load(alloc, io, .cwd(), store.default_review_id) catch |err| {
        const msg: []const u8 = switch (err) {
            error.InvalidJson => "invalid .rv review JSON",
            error.InvalidState => "invalid comment state in .rv store",
            error.InvalidSide => "invalid comment side in .rv store",
            error.OutOfMemory => "out of memory",
            else => "failed to load .rv comment store",
        };
        std.debug.print("rv: {s}\n", .{msg});
        return 1;
    };
    defer review.deinit();

    // TTY/screen setup after load: map failures to short messages (same as load
    // errors). `Tty.open` restores on partial failure; `defer deinit` covers
    // success-then-later-setup-fail so raw/alt-screen never sticks.
    var term = tui.Tty.open() catch |err| {
        const msg: []const u8 = switch (err) {
            error.NotATty => "no controlling terminal (need an interactive TTY)",
            error.AccessDenied => "cannot open terminal: access denied",
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "cannot open terminal: too many open files",
            error.SystemResources => "cannot open terminal: system resources exhausted",
            error.BrokenPipe, error.InputOutput => "failed to initialize terminal (I/O error)",
            else => "failed to open terminal",
        };
        std.debug.print("rv: {s}\n", .{msg});
        return 1;
    };
    defer term.deinit();

    var size = term.getSize() catch {
        std.debug.print("rv: failed to read terminal size\n", .{});
        return 1;
    };
    var scr = tui.Screen.init(alloc, size) catch {
        // `Screen.init` only allocates; failure is OOM.
        std.debug.print("rv: out of memory\n", .{});
        return 1;
    };
    defer scr.deinit();

    var cursor: usize = 0;
    var scroll: usize = 0;
    var running = true;
    var commenting = false;
    var draft: std.ArrayList(u8) = .empty;
    defer draft.deinit(alloc);
    // Anchor captured when entering comment mode (cursor does not move then).
    var draft_anchor: view.Anchor = undefined;

    paint(&scr, size, rows, cursor, &scroll, &review, commenting, draft.items);
    try scr.present(&term);

    while (running) {
        const ev = try tui.event.next(&term);
        switch (ev) {
            .quit => running = false,
            .resize => |new_size| {
                size = new_size;
                try scr.resize(size);
            },
            .key => |key| {
                if (commenting) {
                    switch (key) {
                        .esc => {
                            commenting = false;
                            draft.clearRetainingCapacity();
                        },
                        .enter => {
                            if (draft.items.len > 0) {
                                const side = sideForAnchor(draft_anchor);
                                _ = try review.addOpen(
                                    draft_anchor.path,
                                    draft_anchor.old_line,
                                    draft_anchor.new_line,
                                    side,
                                    draft.items,
                                );
                                store.save(&review, alloc, io, .cwd()) catch {
                                    // Stay in review; next save can retry. Marker is in-memory.
                                };
                            }
                            commenting = false;
                            draft.clearRetainingCapacity();
                        },
                        .backspace => {
                            if (draft.items.len > 0) _ = draft.pop();
                        },
                        .char => |c| {
                            if (c >= 0x20 and c < 0x7f) {
                                try draft.append(alloc, @intCast(c));
                            }
                        },
                        .ctrl_c => running = false,
                        else => {},
                    }
                } else switch (key) {
                    .char => |c| {
                        if (c == 'q' or c == 'Q') {
                            running = false;
                        } else if (c == 'j') {
                            if (cursor + 1 < rows.len) cursor += 1;
                        } else if (c == 'k') {
                            if (cursor > 0) cursor -= 1;
                        } else if (c == 'J') {
                            cursor = view.nextChange(rows, cursor);
                        } else if (c == 'K') {
                            cursor = view.prevChange(rows, cursor);
                        } else if (c == ']') {
                            cursor = view.nextHunkHeader(rows, cursor);
                        } else if (c == '[') {
                            cursor = view.prevHunkHeader(rows, cursor);
                        } else if (c == '}') {
                            cursor = view.nextFileHeader(rows, cursor);
                        } else if (c == '{') {
                            cursor = view.prevFileHeader(rows, cursor);
                        } else if (c == 'i' or c == 'c' or c == 'a') {
                            if (view.anchorAt(rows, cursor)) |a| {
                                draft_anchor = a;
                                draft.clearRetainingCapacity();
                                commenting = true;
                            }
                        }
                    },
                    .enter => {
                        if (view.anchorAt(rows, cursor)) |a| {
                            draft_anchor = a;
                            draft.clearRetainingCapacity();
                            commenting = true;
                        }
                    },
                    .down => {
                        if (cursor + 1 < rows.len) cursor += 1;
                    },
                    .up => {
                        if (cursor > 0) cursor -= 1;
                    },
                    .ctrl_c => running = false,
                    else => {},
                }
            },
        }
        if (running) {
            paint(&scr, size, rows, cursor, &scroll, &review, commenting, draft.items);
            try scr.present(&term);
        }
    }
    return 0;
}

fn sideForAnchor(a: view.Anchor) store.Side {
    if (a.old_line != null and a.new_line != null) return .context;
    if (a.new_line != null) return .new;
    return .old;
}

fn paint(
    scr: *tui.Screen,
    size: tui.Size,
    rows: []const view.Row,
    cursor: usize,
    scroll: *usize,
    review: *const store.Review,
    commenting: bool,
    draft: []const u8,
) void {
    // Diff line palette (truecolor). Documented together so sticky file
    // headers (#36) and body paints share one table. Hierarchy:
    //   body          — near-black bg, neutral fg
    //   file header   — full-row dark grey bar, bold light path
    //   hunk header   — full-row deeper grey bar, light `@@`
    //   add / delete  — green/red fills (#35); markers are not restored
    //   *@_cur        — lighter lift of the same kind (keeps identity)
    //   meta / meta@cur — dim / reverse gray only
    // No color → bg may not show; structure still relies on bold/dim when set.
    const bg = tui.Color{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } };
    const fg = tui.Color{ .rgb = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 } };
    const body = tui.Style{ .fg = fg, .bg = bg };
    const title_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
        .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x3f, .b = 0x5f } },
        .bold = true,
    };
    const footer_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
        .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x3f, .b = 0x5f } },
    };
    // File header: dark grey bar + light bold path (clear vs body; not green/red).
    const file_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xf0 } },
        .bg = .{ .rgb = .{ .r = 0x48, .g = 0x48, .b = 0x4c } },
        .bold = true,
    };
    const file_cur_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .bg = .{ .rgb = .{ .r = 0x60, .g = 0x60, .b = 0x64 } },
        .bold = true,
    };
    // Hunk header: deeper grey bar (dimmer than file; light `@@`).
    const hunk_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xc8, .g = 0xc8, .b = 0xcc } },
        .bg = .{ .rgb = .{ .r = 0x30, .g = 0x30, .b = 0x34 } },
    };
    const hunk_cur_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xf0 } },
        .bg = .{ .rgb = .{ .r = 0x44, .g = 0x44, .b = 0x48 } },
        .bold = true,
    };
    const add_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xb8, .g = 0xe0, .b = 0xb8 } },
        .bg = .{ .rgb = .{ .r = 0x1a, .g = 0x2e, .b = 0x1f } },
    };
    const del_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xe8, .g = 0xc0, .b = 0xc4 } },
        .bg = .{ .rgb = .{ .r = 0x3a, .g = 0x1c, .b = 0x20 } },
    };
    const add_cur_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xe8, .g = 0xff, .b = 0xe8 } },
        .bg = .{ .rgb = .{ .r = 0x24, .g = 0x52, .b = 0x30 } },
        .bold = true,
    };
    const del_cur_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xff, .g = 0xe8, .b = 0xea } },
        .bg = .{ .rgb = .{ .r = 0x6b, .g = 0x2a, .b = 0x32 } },
        .bold = true,
    };
    // Context cursor: lighter lift of body bg (same idea as add/delete cursor).
    const ctx_cur_style = tui.Style{
        .fg = fg,
        .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x30 } },
        .bold = true,
    };
    const meta_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x80, .g = 0x80, .b = 0x80 } },
        .bg = bg,
        .dim = true,
    };
    // Meta cursor only (headers use file_cur / hunk_cur).
    const cur_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } },
        .bg = .{ .rgb = .{ .r = 0xc8, .g = 0xc8, .b = 0xc8 } },
        .bold = true,
    };

    scr.clearStyle(body);

    if (size.rows > 0) {
        fillRow(scr, 0, title_style);
        const help = if (commenting)
            "rv  comment  Enter save  Esc cancel"
        else
            "rv  j/k line  J/K change  [/] hunk  {/} file  i comment  q quit";
        scr.putStr(1, 0, help, title_style);
    }

    const has_footer = size.rows >= 2;
    const footer_y: u16 = if (has_footer) size.rows - 1 else 0;
    const content_top: u16 = 1;
    const content_bottom: u16 = if (has_footer) footer_y else size.rows;
    const content_rows: usize = if (content_bottom > content_top)
        content_bottom - content_top
    else
        0;

    const cur = view.clampCursor(cursor, rows.len);
    const settled = view.ensureVisibleSticky(scroll.*, cur, content_rows, rows);
    scroll.* = settled.scroll;
    const sticky = settled.sticky;

    var line_buf: [512]u8 = undefined;
    var screen_y: u16 = content_top;

    // Sticky file path under the title bar (hunk headers scroll with the body).
    // Last file header strictly above scroll stays pinned; the next file header
    // enters as a normal body row. Cursor lift if cursor is on that source row.
    if (sticky.file_idx) |fi| {
        if (screen_y < content_bottom) {
            const text = formatRow(&line_buf, rows[fi], false);
            const st = if (fi == cur) file_cur_style else file_style;
            fillRow(scr, screen_y, st);
            scr.putStr(0, screen_y, text, st);
            screen_y += 1;
        }
    }

    var i: usize = scroll.*;
    while (i < rows.len and screen_y < content_bottom) : (i += 1) {
        const is_cur = i == cur;
        const marked = rowMarked(rows[i], review);
        const text = formatRow(&line_buf, rows[i], marked);
        const st = rowStyle(
            rows[i],
            is_cur,
            body,
            file_style,
            file_cur_style,
            hunk_style,
            hunk_cur_style,
            add_style,
            del_style,
            add_cur_style,
            del_cur_style,
            ctx_cur_style,
            meta_style,
            cur_style,
        );
        fillRow(scr, screen_y, st);
        scr.putStr(0, screen_y, text, st);
        screen_y += 1;
    }

    if (has_footer) {
        fillRow(scr, footer_y, footer_style);
        const footer_text = if (commenting)
            bufPrintTrunc(&line_buf, "> {s}", .{draft})
        else blk: {
            const st = view.statusAt(rows, cur);
            break :blk formatFooter(&line_buf, st, review.openCount());
        };
        scr.putStr(1, footer_y, footer_text, footer_style);
    }

    scr.hideCursor();
}

fn rowMarked(row: view.Row, review: *const store.Review) bool {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .meta => false,
            else => review.hasOpenAt(ln.path, ln.old_no, ln.new_no),
        },
        else => false,
    };
}

fn formatFooter(buf: []u8, st: view.Status, open_n: usize) []const u8 {
    if (st.row_n == 0) return "no changes";
    if (st.hunk_n == 0) {
        return bufPrintTrunc(buf, "{s}  {d}/{d}  {d} open", .{
            if (st.path.len > 0) st.path else "?",
            st.row_i,
            st.row_n,
            open_n,
        });
    }
    return bufPrintTrunc(buf, "{s}  hunk {d}/{d}  {d}/{d}  {d} open", .{
        if (st.path.len > 0) st.path else "?",
        st.hunk_i,
        st.hunk_n,
        st.row_i,
        st.row_n,
        open_n,
    });
}

/// Style for one content row. Cursor keeps row kind: add/delete/context and
/// file/hunk headers use a lighter lift of their bar; meta uses reverse gray.
fn rowStyle(
    row: view.Row,
    is_cur: bool,
    body: tui.Style,
    file_style: tui.Style,
    file_cur_style: tui.Style,
    hunk_style: tui.Style,
    hunk_cur_style: tui.Style,
    add_style: tui.Style,
    del_style: tui.Style,
    add_cur_style: tui.Style,
    del_cur_style: tui.Style,
    ctx_cur_style: tui.Style,
    meta_style: tui.Style,
    cur_style: tui.Style,
) tui.Style {
    if (is_cur) {
        return switch (row) {
            .line => |ln| switch (ln.kind) {
                .add => add_cur_style,
                .delete => del_cur_style,
                .context => ctx_cur_style,
                .meta => cur_style,
            },
            .file_header => file_cur_style,
            .hunk_header => hunk_cur_style,
        };
    }
    return switch (row) {
        .file_header => file_style,
        .hunk_header => hunk_style,
        .line => |ln| switch (ln.kind) {
            .add => add_style,
            .delete => del_style,
            .meta => meta_style,
            .context => body,
        },
    };
}

/// Format one row. Line rows: 2-char gutter (`*` if marked else space, then
/// pad/`\` for meta). Add/delete use background color, not `+/-` markers.
fn formatRow(buf: []u8, row: view.Row, marked: bool) []const u8 {
    return switch (row) {
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

fn bufPrintTrunc(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch {
        const msg = "...";
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        return buf[0..n];
    };
}

fn fillRow(scr: *tui.Screen, y: u16, style: tui.Style) void {
    var x: u16 = 0;
    while (x < scr.cols) : (x += 1) {
        scr.setCell(x, y, .{ .char = ' ', .width = 1, .style = style });
    }
}
