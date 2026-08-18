//! `rv` entry point — CLI dispatch + full-screen diff review (MVP-1 / MVP-2.2).
//!
//! With no args: load local-only git diff → flatten rows → load `.rv`
//! comments → TUI (`j`/`k`, `h`/`l` pan, `0`/`$` col home/end, `[`/`]` hunk,
//! `{`/`}` file header, `(`/`)` prev/next comment, `/` text search, `n`/`N`
//! next/prev match, `Space` `f` file-path find, `Space` `l` comment list,
//! `i`/`c`/`a`/`Enter` create or edit new, `I`/`C`/`A` old, `d` dismiss new,
//! `D` dismiss old, `r` reload the loaded diff, `q` quit).
//! Diff layout defaults to side-by-side when the terminal is wide enough;
//! falls back to unified when narrow. `t` toggles session preference
//! (explicit unified stays unified even when wide).
//! Error paths never enter raw / alt-screen mode. An empty model still
//! opens the TUI; the footer shows the load source (`HEAD · empty`).
//!
//! With a git range arg: load `git diff <range>` as written → same TUI.
//! With a subcommand: headless CLI (`status`, `list`, `show`, `resolve`,
//! `export`, `install-skill`, help) — no git load and no raw TTY modes.
//!
//! Comment UX: soft-wrapped multi-line footer prompt (grows up to 4 rows, then
//! scrolls with a right-edge scrollbar). Arrow keys move the caret; insert and
//! backspace edit at the caret. Esc cancels; Enter saves. Open-comment marker:
//! `*` in the gutter. Add/delete lines use green/red backgrounds (no `+/-`).
//! Reload on next `rv` via `.rv/reviews/current.json`.
//!
//! Diff text search (MVP-3a): `/` opens a single-line footer prompt. Enter
//! commits a case-sensitive substring query over add/delete/context body text
//! (not headers/meta); Esc cancels without moving the cursor. `n`/`N` walk
//! those text matches with wrap. No match leaves the cursor put and shows a
//! footer note.
//!
//! File-path find (MVP-3b): `Space` then `f` opens the same footer prompt
//! (prefix `/`, same keys). Enter jumps to the first matching **file header**
//! from the cursor (wrap). Multi-match: that first hit only — `n`/`N` stay
//! text-search. An unmatched `Space` leader is dropped; the next key is
//! handled as normal. Esc cancels without moving the cursor.
//!
//! Comment list: `Space` then `l` opens a centered overlay of live comments
//! (same store as `rv list`). `j`/`k` move; Enter jumps with the same landing
//! as `(`/`)` and closes the overlay. Esc closes without moving the cursor.
//! A row whose path/line is gone from the flatten stays in the list and shows
//! a footer note. `q` still quits.

const std = @import("std");
const git = @import("git");
const diff = @import("diff");
const tui = @import("tui");
const view = @import("view");
const store = @import("store");
const cli = @import("cli");
const comment_input = @import("comment_input");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const launch = cli.classify(if (argv.len > 1) argv[1..] else &.{}) catch {
        std.debug.print("{s}", .{cli.usage_text});
        return 2;
    };
    switch (launch) {
        .tui => |source| return try runTui(alloc, io, source),
        .command => |cmd| {
            const env: cli.Env = .{
                .home = init.environ_map.get("HOME"),
                .skill_dir = init.environ_map.get("RV_SKILL_DIR"),
            };
            return cli.run(alloc, io, cmd, env);
        },
    }
}

fn runTui(alloc: std.mem.Allocator, io: std.Io, source: cli.Source) !u8 {
    // Load before any TTY setup so error paths never touch the terminal.
    var d = switch (source) {
        .local => git.loadDefaultDiff(alloc, io),
        .range => |r| git.loadRangeDiff(alloc, io, .inherit, r),
    } catch |err| {
        std.debug.print("rv: {s}\n", .{gitLoadMsg(err)});
        return 1;
    };
    defer d.deinit();

    var rows = try view.flatten(alloc, &d);
    defer alloc.free(rows);
    var sbs_slots = try view.pairSideBySide(alloc, rows);
    defer alloc.free(sbs_slots);

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
    // First visible display column for lines in the cursor's hunk only.
    var col_scroll: usize = 0;
    // Prefer side-by-side; auto-unified when narrow. `t` flips session preference.
    var layout_pref: view.LayoutPref = .side_by_side;
    var running = true;
    // Exactly one focus; cannot comment, search, and list at once.
    var focus: Focus = .normal;
    // Scope for the open `/` prompt (text vs file path). Ignored otherwise.
    var search_kind: SearchKind = .text;
    // `Space` leader: next key may be `f` (file find) or `l` (comment list).
    // Cleared on that next key.
    var leader_pending: bool = false;
    var draft: Draft = .{};
    defer draft.buf.deinit(alloc);
    // Snapshot of `review.comments` while the list overlay is open.
    var list_items: std.ArrayList(store.Comment) = .empty;
    defer list_items.deinit(alloc);
    var list_cursor: usize = 0;
    var list_scroll: usize = 0;
    // Committed `/` text query for `n`/`N` (empty means no active text search).
    var last_query: std.ArrayList(u8) = .empty;
    defer last_query.deinit(alloc);
    // One-shot footer note (owned bytes; len 0 = none). Cleared on next key.
    var note: StatusNote = .{};

    paint(&scr, size, rows, sbs_slots, layout_pref, cursor, &scroll, &col_scroll, &review, source, focus, search_kind, draft.buf.items, draft.caret, &draft.scroll, draft.anchor, note.slice(), list_items.items, list_cursor, &list_scroll);
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
                // Notes are one-shot; any key clears them (including keys that no-op).
                note.clear();
                switch (focus) {
                    .commenting => switch (key) {
                        .esc => {
                            focus = .normal;
                            draft.clear();
                        },
                        .enter => {
                            if (draft.buf.items.len > 0) {
                                if (draft.edit_id) |id| {
                                    if (review.find(id)) |c| {
                                        const prior = c.body;
                                        if (review.setBody(id, draft.buf.items)) |_| {
                                            store.save(&review, alloc, io, .cwd()) catch {
                                                review.setBody(id, prior) catch {};
                                                note.set("failed to save .rv comment store");
                                            };
                                        } else |err| switch (err) {
                                            error.NotFound => {},
                                            error.OutOfMemory => return error.OutOfMemory,
                                        }
                                    }
                                } else {
                                    const side = sideForAnchor(draft.anchor);
                                    _ = try review.addOpen(
                                        draft.anchor.path,
                                        draft.anchor.old_line,
                                        draft.anchor.new_line,
                                        side,
                                        draft.buf.items,
                                    );
                                    store.save(&review, alloc, io, .cwd()) catch {
                                        // Stay in review; next save can retry. Marker is in-memory.
                                    };
                                }
                            }
                            focus = .normal;
                            draft.clear();
                        },
                        .backspace => {
                            if (draft.caret > 0) {
                                draft.caret -= 1;
                                _ = draft.buf.orderedRemove(draft.caret);
                                ensureDraftCaretVisible(size.cols, size.rows, draft.buf.items, &draft.scroll, draft.caret);
                            }
                        },
                        .char => |c| {
                            if (c >= 0x20 and c < 0x7f) {
                                try draft.buf.insert(alloc, draft.caret, @intCast(c));
                                draft.caret += 1;
                                ensureDraftCaretVisible(size.cols, size.rows, draft.buf.items, &draft.scroll, draft.caret);
                            }
                        },
                        .left => {
                            if (draft.caret > 0) draft.caret -= 1;
                            ensureDraftCaretVisible(size.cols, size.rows, draft.buf.items, &draft.scroll, draft.caret);
                        },
                        .right => {
                            if (draft.caret < draft.buf.items.len) draft.caret += 1;
                            ensureDraftCaretVisible(size.cols, size.rows, draft.buf.items, &draft.scroll, draft.caret);
                        },
                        .up => {
                            const m = commentMetrics(size.cols, size.rows, draft.buf.items);
                            const pos = comment_input.VisualPos.init(draft.buf.items, m.text_w, draft.caret);
                            // On the first visual line, stay put (keep column).
                            if (pos.line > 0) {
                                draft.caret = comment_input.byteAtVisual(draft.buf.items, m.text_w, pos.line - 1, pos.col);
                                ensureDraftCaretVisible(size.cols, size.rows, draft.buf.items, &draft.scroll, draft.caret);
                            }
                        },
                        .down => {
                            const m = commentMetrics(size.cols, size.rows, draft.buf.items);
                            const pos = comment_input.VisualPos.init(draft.buf.items, m.text_w, draft.caret);
                            if (pos.line + 1 < m.line_count) {
                                draft.caret = comment_input.byteAtVisual(draft.buf.items, m.text_w, pos.line + 1, pos.col);
                            }
                            ensureDraftCaretVisible(size.cols, size.rows, draft.buf.items, &draft.scroll, draft.caret);
                        },
                        .ctrl_c => running = false,
                        else => {},
                    },
                    .searching => switch (key) {
                        .esc => {
                            // Cancel: leave cursor where it was; discard draft only.
                            focus = .normal;
                            draft.clear();
                        },
                        .enter => {
                            focus = .normal;
                            if (draft.buf.items.len == 0) {
                                draft.caret = 0;
                            } else if (search_kind == .file) {
                                // Single jump; do not replace the `/` n/N query.
                                if (view.firstPathMatch(rows, draft.buf.items, cursor)) |hit| {
                                    cursor = hit.index;
                                    if (hit.wrapped) note.set("search wrapped");
                                } else {
                                    note.setFmt("Pattern not found: {s}", .{draft.buf.items});
                                }
                                draft.clear();
                            } else {
                                last_query.clearRetainingCapacity();
                                try last_query.appendSlice(alloc, draft.buf.items);
                                draft.clear();
                                if (view.firstMatch(rows, last_query.items, cursor)) |hit| {
                                    cursor = hit.index;
                                    if (hit.wrapped) note.set("search wrapped");
                                } else {
                                    note.setFmt("Pattern not found: {s}", .{last_query.items});
                                }
                            }
                        },
                        .backspace => {
                            if (draft.caret > 0) {
                                draft.caret -= 1;
                                _ = draft.buf.orderedRemove(draft.caret);
                            }
                        },
                        .char => |c| {
                            if (c >= 0x20 and c < 0x7f) {
                                try draft.buf.insert(alloc, draft.caret, @intCast(c));
                                draft.caret += 1;
                            }
                        },
                        .left => {
                            if (draft.caret > 0) draft.caret -= 1;
                        },
                        .right => {
                            if (draft.caret < draft.buf.items.len) draft.caret += 1;
                        },
                        .ctrl_c => running = false,
                        else => {},
                    },
                    .listing => switch (key) {
                        .esc => {
                            focus = .normal;
                        },
                        .enter => {
                            if (list_cursor < list_items.items.len) {
                                if (commentLoc(list_items.items[list_cursor])) |loc| {
                                    if (view.rowForComment(rows, loc)) |idx| {
                                        cursor = idx;
                                        focus = .normal;
                                    } else {
                                        note.set("comment not in this diff");
                                    }
                                } else {
                                    note.set("comment not in this diff");
                                }
                            }
                        },
                        .char => |c| {
                            if (c == 'q' or c == 'Q') {
                                running = false;
                            } else if (c == 'j') {
                                if (list_cursor + 1 < list_items.items.len) list_cursor += 1;
                            } else if (c == 'k') {
                                if (list_cursor > 0) list_cursor -= 1;
                            }
                        },
                        .down => {
                            if (list_cursor + 1 < list_items.items.len) list_cursor += 1;
                        },
                        .up => {
                            if (list_cursor > 0) list_cursor -= 1;
                        },
                        .ctrl_c => running = false,
                        else => {},
                    },
                    .normal => {
                        const after_leader = leader_pending;
                        leader_pending = false;
                        const layout = view.effectiveLayout(layout_pref, size.cols);
                        switch (key) {
                            .char => |c| {
                                if (after_leader and c == 'f') {
                                    focus = .searching;
                                    search_kind = .file;
                                    draft.clear();
                                } else if (after_leader and c == 'l') {
                                    list_items.clearRetainingCapacity();
                                    try list_items.appendSlice(alloc, review.comments.items);
                                    list_cursor = 0;
                                    list_scroll = 0;
                                    focus = .listing;
                                } else if (c == 'q' or c == 'Q') {
                                    running = false;
                                } else if (c == ' ') {
                                    leader_pending = true;
                                } else if (c == '/') {
                                    focus = .searching;
                                    search_kind = .text;
                                    draft.clear();
                                } else if (c == 'n') {
                                    if (last_query.items.len > 0) {
                                        if (view.nextMatch(rows, last_query.items, cursor)) |hit| {
                                            cursor = hit.index;
                                            if (hit.wrapped) note.set("search wrapped");
                                        } else {
                                            note.set("Pattern not found");
                                        }
                                    }
                                } else if (c == 'N') {
                                    if (last_query.items.len > 0) {
                                        if (view.prevMatch(rows, last_query.items, cursor)) |hit| {
                                            cursor = hit.index;
                                            if (hit.wrapped) note.set("search wrapped");
                                        } else {
                                            note.set("Pattern not found");
                                        }
                                    }
                                } else if (c == 'j') {
                                    cursor = moveLineDown(layout_pref, size.cols, rows, sbs_slots, cursor);
                                } else if (c == 'k') {
                                    cursor = moveLineUp(layout_pref, size.cols, rows, sbs_slots, cursor);
                                } else if (c == 'h') {
                                    const step = panStep(panViewportCols(layout_pref, size.cols));
                                    col_scroll = if (col_scroll > step) col_scroll - step else 0;
                                } else if (c == 'l') {
                                    col_scroll +%= panStep(panViewportCols(layout_pref, size.cols));
                                } else if (c == '0') {
                                    col_scroll = 0;
                                } else if (c == '$') {
                                    const span = view.hunkSpanAt(rows, cursor);
                                    const vp = panViewportCols(layout_pref, size.cols);
                                    col_scroll = view.colScrollToEnd(hunkMaxLineWidth(rows, span), vp);
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
                                } else if (c == ')') {
                                    try jumpLiveComment(&review, alloc, rows, &cursor, &note, .next);
                                } else if (c == '(') {
                                    try jumpLiveComment(&review, alloc, rows, &cursor, &note, .prev);
                                } else if (c == 't') {
                                    layout_pref = view.toggleLayoutPref(layout_pref);
                                } else if (c == 'r') {
                                    reloadDiff(alloc, io, source, &d, &rows, &sbs_slots, &cursor, &note);
                                } else if (c == 'i' or c == 'c' or c == 'a') {
                                    if (try beginComment(&review, alloc, rows, sbs_slots, layout, cursor, .new, &draft)) {
                                        focus = .commenting;
                                    }
                                } else if (c == 'I' or c == 'C' or c == 'A') {
                                    if (try beginComment(&review, alloc, rows, sbs_slots, layout, cursor, .old, &draft)) {
                                        focus = .commenting;
                                    }
                                } else if (c == 'd') {
                                    dismissAt(&review, alloc, io, rows, sbs_slots, layout, cursor, .new, &note);
                                } else if (c == 'D') {
                                    dismissAt(&review, alloc, io, rows, sbs_slots, layout, cursor, .old, &note);
                                }
                            },
                            .enter => {
                                if (try beginComment(&review, alloc, rows, sbs_slots, layout, cursor, .new, &draft)) {
                                    focus = .commenting;
                                }
                            },
                            .down => {
                                cursor = moveLineDown(layout_pref, size.cols, rows, sbs_slots, cursor);
                            },
                            .up => {
                                cursor = moveLineUp(layout_pref, size.cols, rows, sbs_slots, cursor);
                            },
                            .left => {
                                const step = panStep(panViewportCols(layout_pref, size.cols));
                                col_scroll = if (col_scroll > step) col_scroll - step else 0;
                            },
                            .right => {
                                col_scroll +%= panStep(panViewportCols(layout_pref, size.cols));
                            },
                            .ctrl_c => running = false,
                            else => {},
                        }
                    },
                }
            },
        }
        if (running) {
            paint(&scr, size, rows, sbs_slots, layout_pref, cursor, &scroll, &col_scroll, &review, source, focus, search_kind, draft.buf.items, draft.caret, &draft.scroll, draft.anchor, note.slice(), list_items.items, list_cursor, &list_scroll);
            try scr.present(&term);
        }
    }
    return 0;
}

fn gitLoadMsg(err: git.Error) []const u8 {
    return switch (err) {
        error.NotARepository => "not a git repository (run from a work tree)",
        error.GitNotFound => "git executable not found in PATH",
        error.GitFailed => "git command failed",
        error.OutOfMemory => "out of memory",
        error.BadHunkHeader => "failed to parse unified diff (bad hunk header)",
    };
}

/// Re-run the startup load. On success, replace `d`/`rows`/`sbs_slots` and
/// restore the cursor. On failure, leave the previous model and set `note`.
/// Does not touch the comment store. `r` is only bound in normal focus.
fn reloadDiff(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
    d: *diff.Diff,
    rows: *[]view.Row,
    sbs_slots: *[]view.SbsSlot,
    cursor: *usize,
    note: *StatusNote,
) void {
    var new_d = switch (source) {
        .local => git.loadDefaultDiff(alloc, io),
        .range => |r| git.loadRangeDiff(alloc, io, .inherit, r),
    } catch |err| {
        note.set(gitLoadMsg(err));
        return;
    };
    const new_rows = view.flatten(alloc, &new_d) catch {
        new_d.deinit();
        note.set("out of memory");
        return;
    };
    const new_sbs = view.pairSideBySide(alloc, new_rows) catch {
        alloc.free(new_rows);
        new_d.deinit();
        note.set("out of memory");
        return;
    };
    // `mark.path` borrows from the old `d` / `rows`. Restore before free.
    const mark = view.cursorMarkAt(rows.*, cursor.*);
    const new_cursor = if (mark) |m| view.restoreCursor(new_rows, m) else 0;
    alloc.free(rows.*);
    alloc.free(sbs_slots.*);
    d.deinit();
    d.* = new_d;
    rows.* = new_rows;
    sbs_slots.* = new_sbs;
    cursor.* = new_cursor;
}

/// Key ownership: normal nav, comment draft, `/` search prompt, or comment list.
const Focus = enum { normal, commenting, searching, listing };

/// Footer box buffer plus comment-mode extras. Search uses `buf` and `caret` only.
const Draft = struct {
    buf: std.ArrayList(u8) = .empty,
    scroll: usize = 0,
    caret: usize = 0,
    anchor: view.Anchor = .{ .path = "", .old_line = null, .new_line = null },
    edit_id: ?[]const u8 = null,

    fn clear(self: *Draft) void {
        self.buf.clearRetainingCapacity();
        self.scroll = 0;
        self.caret = 0;
        self.edit_id = null;
    }
};

/// What the open `/` prompt matches. `n`/`N` always use `.text` (`last_query`).
const SearchKind = enum { text, file };

/// One-shot footer message. Bytes always live in `buf`; `len == 0` means none.
/// Avoids optional slices that sometimes point at static strings and sometimes
/// at a separate buffer.
const StatusNote = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn clear(self: *StatusNote) void {
        self.len = 0;
    }

    fn slice(self: *const StatusNote) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *StatusNote, msg: []const u8) void {
        const n = @min(msg.len, self.buf.len);
        @memcpy(self.buf[0..n], msg[0..n]);
        self.len = n;
    }

    fn setFmt(self: *StatusNote, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            self.set("Pattern not found");
            return;
        };
        self.len = written.len;
    }
};

/// Columns available for horizontal pan: full width (unified) or one pane (SBS).
fn panViewportCols(pref: view.LayoutPref, cols: u16) u16 {
    return switch (view.effectiveLayout(pref, cols)) {
        .unified => cols,
        .side_by_side => view.sbsPaneWidths(cols).left_w,
    };
}

/// One step down: unified row in unified layout; next SBS slot in side-by-side.
fn moveLineDown(
    pref: view.LayoutPref,
    cols: u16,
    rows: []const view.Row,
    slots: []const view.SbsSlot,
    cursor: usize,
) usize {
    return switch (view.effectiveLayout(pref, cols)) {
        .unified => if (cursor + 1 < rows.len) cursor + 1 else cursor,
        .side_by_side => view.nextSbsCursor(slots, rows, cursor),
    };
}

/// One step up: unified row in unified layout; previous SBS slot in side-by-side.
fn moveLineUp(
    pref: view.LayoutPref,
    cols: u16,
    rows: []const view.Row,
    slots: []const view.SbsSlot,
    cursor: usize,
) usize {
    return switch (view.effectiveLayout(pref, cols)) {
        .unified => if (cursor > 0) cursor - 1 else cursor,
        .side_by_side => view.prevSbsCursor(slots, rows, cursor),
    };
}

/// Horizontal pan step: about a quarter of the pan viewport (at least 1).
fn panStep(cols: u16) usize {
    if (cols == 0) return 1;
    return @max(1, cols / 4);
}

/// Widest formatted **line** in the hunk body (headers excluded). 0 if empty.
fn hunkMaxLineWidth(rows: []const view.Row, span: view.HunkSpan) usize {
    var max_w: usize = 0;
    var line_buf: [512]u8 = undefined;
    var i = span.body_start;
    while (i < span.body_end) : (i += 1) {
        const text = formatRow(&line_buf, rows[i], false);
        max_w = @max(max_w, tui.screen.displayWidth(text));
    }
    return max_w;
}

/// Visible comment-box row budget: keep the title row; cap at `max_rows`.
fn commentMaxVisible(term_rows: u16) usize {
    if (term_rows <= 1) return 1;
    return @min(comment_input.max_rows, @as(usize, term_rows - 1));
}

fn commentMetrics(cols: u16, term_rows: u16, draft: []const u8) comment_input.Metrics {
    return comment_input.metricsLimited(cols, draft, commentMaxVisible(term_rows));
}

/// Keep `cursor` inside the overlay window of height `view_h`.
fn ensureListCursorVisible(scroll: *usize, cursor: usize, view_h: usize, n: usize) void {
    if (n == 0 or view_h == 0) {
        scroll.* = 0;
        return;
    }
    if (cursor < scroll.*) {
        scroll.* = cursor;
    } else if (cursor >= scroll.* + view_h) {
        scroll.* = cursor - view_h + 1;
    }
    const max_scroll = if (n > view_h) n - view_h else 0;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
}

/// Keep the visual line under `caret` inside the comment footer window.
/// Typing at the end still end-follows (last line is the caret line).
fn ensureDraftCaretVisible(
    cols: u16,
    term_rows: u16,
    draft: []const u8,
    draft_scroll: *usize,
    caret: usize,
) void {
    const m = commentMetrics(cols, term_rows, draft);
    const pos = comment_input.VisualPos.init(draft, m.text_w, caret);
    draft_scroll.* = comment_input.ensureVisible(draft_scroll.*, pos.line, m.height, m.line_count);
}

fn sideForAnchor(a: view.Anchor) store.Side {
    if (a.old_line != null and a.new_line != null) return .context;
    if (a.new_line != null) return .new;
    return .old;
}

/// Open the comment box on `want` at `cursor`. Missing side: silent no-op.
/// Existing comment: pre-fill the first in store order; caret at end. None: create.
/// Returns true when the box opened.
fn beginComment(
    review: *const store.Review,
    alloc: std.mem.Allocator,
    rows: []const view.Row,
    slots: []const view.SbsSlot,
    layout: view.EffectiveLayout,
    cursor: usize,
    want: view.CommentSide,
    draft: *Draft,
) std.mem.Allocator.Error!bool {
    const a = view.commentAnchor(rows, slots, layout, cursor, want) orelse return false;
    draft.clear();
    draft.anchor = a;
    if (review.firstAt(a.path, a.old_line, a.new_line)) |idx| {
        const c = review.comments.items[idx];
        try draft.buf.appendSlice(alloc, c.body);
        draft.caret = draft.buf.items.len;
        draft.edit_id = c.id;
    }
    return true;
}

/// Live comment as a display target, or null if it has no usable side/line.
fn commentLoc(c: store.Comment) ?view.CommentLoc {
    if (c.state != .open) return null;
    if (c.side) |s| {
        switch (s) {
            .old => if (c.old_line) |n| return .{ .path = c.path, .side = .old, .line = n },
            .new => if (c.new_line) |n| return .{ .path = c.path, .side = .new, .line = n },
            .context => {
                if (c.new_line) |n| return .{ .path = c.path, .side = .new, .line = n };
                if (c.old_line) |n| return .{ .path = c.path, .side = .old, .line = n };
            },
        }
        return null;
    }
    if (c.new_line) |n| return .{ .path = c.path, .side = .new, .line = n };
    if (c.old_line) |n| return .{ .path = c.path, .side = .old, .line = n };
    return null;
}

fn jumpLiveComment(
    review: *const store.Review,
    alloc: std.mem.Allocator,
    rows: []const view.Row,
    cursor: *usize,
    note: *StatusNote,
    comptime toward: enum { next, prev },
) std.mem.Allocator.Error!void {
    var locs: std.ArrayList(view.CommentLoc) = .empty;
    defer locs.deinit(alloc);
    for (review.comments.items) |c| {
        if (commentLoc(c)) |loc| try locs.append(alloc, loc);
    }
    const hit = switch (toward) {
        .next => view.nextComment(rows, locs.items, cursor.*),
        .prev => view.prevComment(rows, locs.items, cursor.*),
    };
    if (hit) |h| {
        cursor.* = h.index;
        if (h.wrapped) note.set("comment wrapped");
    } else {
        note.set("no comments");
    }
}

/// Dismiss the first live comment on `want` at `cursor`. Missing side or no
/// comment: footer note, store unchanged. Save failure puts the comment back.
fn dismissAt(
    review: *store.Review,
    alloc: std.mem.Allocator,
    io: std.Io,
    rows: []const view.Row,
    slots: []const view.SbsSlot,
    layout: view.EffectiveLayout,
    cursor: usize,
    want: view.CommentSide,
    note: *StatusNote,
) void {
    const a = view.commentAnchor(rows, slots, layout, cursor, want) orelse {
        note.set("no comment on this side");
        return;
    };
    const idx = review.firstAt(a.path, a.old_line, a.new_line) orelse {
        note.set("no comment on this side");
        return;
    };
    const saved = review.comments.items[idx];
    const id = saved.id;
    review.remove(&.{id}) catch return;
    store.save(review, alloc, io, .cwd()) catch {
        review.comments.insert(review.arena.allocator(), idx, saved) catch {};
        note.set("failed to save .rv comment store");
        return;
    };
    note.setFmt("deleted {s}", .{id});
}

/// Centered overlay. Width up to 120; height grows with rows, clamped to
/// 25–70% of the terminal. Always leaves at least 2 cells on every side.
fn listOverlayRect(cols: u16, rows: u16, n: usize) tui.Rect {
    const n16: u16 = std.math.cast(u16, n) orelse std.math.maxInt(u16);
    const max_w: u16 = 120;
    const avail_h: u16 = rows -| 4;
    const rows_n: u32 = rows;
    const min_pct: u16 = @intCast(rows_n / 4);
    const max_pct: u16 = @intCast(rows_n * 7 / 10);
    const min_h: u16 = @min(avail_h, @max(3, min_pct));
    const max_h: u16 = @min(avail_h, @max(min_h, max_pct));
    const want_w: u16 = @min(cols -| 4, max_w);
    const content_h: u16 = @max(3, n16 +| 2);
    const want_h: u16 = @min(max_h, @max(min_h, content_h));
    return tui.Rect.centered(cols, rows, want_w, want_h);
}

fn formatCommentLineCol(buf: []u8, c: store.Comment) []const u8 {
    if (c.side) |s| {
        switch (s) {
            .old => if (c.old_line) |ln| return bufPrintTrunc(buf, "-{d}", .{ln}),
            .new => if (c.new_line) |ln| return bufPrintTrunc(buf, "+{d}", .{ln}),
            .context => {
                if (c.new_line) |ln| return bufPrintTrunc(buf, "+{d}", .{ln});
                if (c.old_line) |ln| return bufPrintTrunc(buf, "-{d}", .{ln});
            },
        }
        return "-";
    }
    if (c.new_line) |ln| return bufPrintTrunc(buf, "+{d}", .{ln});
    if (c.old_line) |ln| return bufPrintTrunc(buf, "-{d}", .{ln});
    return "-";
}

fn formatListRow(buf: []u8, c: store.Comment) []const u8 {
    var line_col_buf: [16]u8 = undefined;
    const line_col = formatCommentLineCol(&line_col_buf, c);
    const side: []const u8 = if (c.side) |s| switch (s) {
        .old => "old",
        .new => "new",
        .context => "ctx",
    } else "-";
    const prefix = bufPrintTrunc(buf, "{s}  {s}  {s}  {s}  ", .{ c.id, c.path, side, line_col });
    var i: usize = 0;
    const rest = buf[prefix.len..];
    for (c.body) |b| {
        if (i >= rest.len) break;
        rest[i] = if (b == '\n' or b == '\r') ' ' else b;
        i += 1;
    }
    return buf[0 .. prefix.len + i];
}

fn paintCommentList(
    scr: *tui.Screen,
    size: tui.Size,
    items: []const store.Comment,
    cursor: usize,
    scroll: *usize,
    line_buf: []u8,
) void {
    const bg = tui.Color{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } };
    const fg = tui.Color{ .rgb = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 } };
    const panel_bg = tui.Style{ .fg = fg, .bg = bg };
    const panel_frame = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x5d, .g = 0x81, .b = 0xb7 } },
        .bg = bg,
        .bold = true,
    };
    const row_cur = tui.Style{
        .fg = fg,
        .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x30 } },
        .bold = true,
    };
    const bar_track = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x6a, .g = 0x7a, .b = 0x9a } },
        .bg = bg,
        .dim = true,
    };
    const bar_thumb = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
        .bg = .{ .rgb = .{ .r = 0x4a, .g = 0x6a, .b = 0x9a } },
        .bold = true,
    };

    const panel = listOverlayRect(size.cols, size.rows, items.len);
    scr.fillRect(panel, ' ', panel_bg);
    scr.drawBox(panel, panel_frame);
    const inner = panel.inset(1);
    if (panel.h > 0 and panel.w > 2) {
        scr.putStr(panel.x + 2, panel.y, " comments ", panel_frame, panel);
    }
    ensureListCursorVisible(scroll, cursor, inner.h, items.len);
    if (inner.h == 0 or inner.w == 0) return;
    if (items.len == 0) {
        scr.putStr(inner.x, inner.y, "no comments", panel_bg, inner);
        return;
    }
    const show_bar = items.len > inner.h;
    const text_area = if (show_bar)
        tui.Rect{ .x = inner.x, .y = inner.y, .w = inner.w -| 2, .h = inner.h }
    else
        inner;
    const start = scroll.*;
    var row: u16 = 0;
    while (row < inner.h) : (row += 1) {
        const idx = start + row;
        if (idx >= items.len) break;
        const y = inner.y + row;
        const st = if (idx == cursor) row_cur else panel_bg;
        scr.fillRect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, ' ', st);
        const text = formatListRow(line_buf, items[idx]);
        scr.putStr(inner.x, y, text, st, text_area);
    }
    if (show_bar) {
        const bar_x: u16 = inner.x + inner.w - 1;
        const thumb = comment_input.scrollbarThumb(items.len, inner.h, start, inner.h);
        var br: u16 = 0;
        while (br < inner.h) : (br += 1) {
            const in_thumb = br >= thumb.start and br < thumb.start + thumb.len;
            const st = if (in_thumb) bar_thumb else bar_track;
            const ch: u21 = if (in_thumb) '█' else '│';
            scr.setCell(bar_x, inner.y + br, .{ .char = ch, .width = 1, .style = st });
        }
    }
}

fn paint(
    scr: *tui.Screen,
    size: tui.Size,
    rows: []const view.Row,
    sbs_slots: []const view.SbsSlot,
    layout_pref: view.LayoutPref,
    cursor: usize,
    scroll: *usize,
    col_scroll: *usize,
    review: *const store.Review,
    source: cli.Source,
    focus: Focus,
    search_kind: SearchKind,
    draft: []const u8,
    draft_caret: usize,
    draft_scroll: *usize,
    draft_anchor: view.Anchor,
    status_note: []const u8,
    list_items: []const store.Comment,
    list_cursor: usize,
    list_scroll: *usize,
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
    const footer_bar_track = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x6a, .g = 0x7a, .b = 0x9a } },
        .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x3f, .b = 0x5f } },
        .dim = true,
    };
    const footer_bar_thumb = tui.Style{
        .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
        .bg = .{ .rgb = .{ .r = 0x4a, .g = 0x6a, .b = 0x9a } },
        .bold = true,
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
        const help = switch (focus) {
            .commenting => switch (sideForAnchor(draft_anchor)) {
                .new => "rv  create/edit new  Enter save  Esc cancel  ↑↓ scroll",
                .old => "rv  create/edit old  Enter save  Esc cancel  ↑↓ scroll",
                .context => "rv  create/edit  Enter save  Esc cancel  ↑↓ scroll",
            },
            .searching => switch (search_kind) {
                .text => "rv  search  Enter jump  Esc cancel",
                .file => "rv  file  Enter jump  Esc cancel",
            },
            .listing => "rv  comments  j/k move  Enter jump  Esc close  q quit",
            .normal => "rv  j/k line  h/l pan  0/$  J/K change  [/] hunk  {/} file  (/) comment  / n/N search  Space f files  Space l comments  t layout  i/I create/edit  d/D dismiss  r reload  q quit",
        };
        scr.putStr(1, 0, help, title_style, null);
    }

    // Footer: 1 status row, search prompt, or soft-wrapped comment box.
    const has_footer = size.rows >= 2;
    const cm: ?comment_input.Metrics = if (focus == .commenting and has_footer)
        commentMetrics(size.cols, size.rows, draft)
    else
        null;
    const footer_h: u16 = if (!has_footer) 0 else if (cm) |m| m.height else 1;
    const footer_top: u16 = if (has_footer) size.rows - footer_h else 0;
    const content_top: u16 = 1;
    const content_bottom: u16 = if (has_footer) footer_top else size.rows;
    const content_rows: usize = if (content_bottom > content_top)
        content_bottom - content_top
    else
        0;

    const cur = view.clampCursor(cursor, rows.len);
    const layout = view.effectiveLayout(layout_pref, size.cols);
    const gutter_style = tui.Style{
        .fg = .{ .rgb = .{ .r = 0x50, .g = 0x50, .b = 0x58 } },
        .bg = bg,
    };

    var line_buf: [512]u8 = undefined;
    // Only lines in the cursor's hunk pan; file/hunk headers never pan.
    const pan_span = view.hunkSpanAt(rows, cur);
    const hunk_w = hunkMaxLineWidth(rows, pan_span);
    const pan_vp: usize = panViewportCols(layout_pref, size.cols);
    col_scroll.* = view.clampColScroll(col_scroll.*, hunk_w, pan_vp);
    const cs = col_scroll.*;

    switch (layout) {
        .unified => {
            const settled = view.ensureVisibleSticky(scroll.*, cur, content_rows, rows);
            scroll.* = settled.scroll;
            const sticky = settled.sticky;
            var screen_y: u16 = content_top;

            // Sticky file path under the title bar (hunk headers scroll with body).
            if (sticky.file_idx) |fi| {
                if (screen_y < content_bottom) {
                    const text = formatRow(&line_buf, rows[fi], false);
                    const st = if (fi == cur) file_cur_style else file_style;
                    fillRow(scr, screen_y, st);
                    scr.putStr(0, screen_y, text, st, null);
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
                const pan = pan_span.containsBody(i);
                const visible = if (pan) text[tui.screen.byteAtCol(text, cs)..] else text;
                scr.putStr(0, screen_y, visible, st, null);
                screen_y += 1;
            }
        },
        .side_by_side => {
            const settled = view.ensureVisibleStickySbs(scroll.*, cur, content_rows, sbs_slots, rows);
            scroll.* = settled.scroll;
            const sticky = settled.sticky;
            const panes = view.sbsPaneWidths(size.cols);
            var screen_y: u16 = content_top;

            if (sticky.file_idx) |fi| {
                if (screen_y < content_bottom) {
                    const text = formatRow(&line_buf, rows[fi], false);
                    const st = if (fi == cur) file_cur_style else file_style;
                    fillRow(scr, screen_y, st);
                    scr.putStr(0, screen_y, text, st, null);
                    screen_y += 1;
                }
            }

            var si: usize = scroll.*;
            while (si < sbs_slots.len and screen_y < content_bottom) : (si += 1) {
                switch (sbs_slots[si]) {
                    .header => |ri| {
                        const is_cur = ri == cur;
                        const text = formatRow(&line_buf, rows[ri], false);
                        const st = rowStyle(
                            rows[ri],
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
                        scr.putStr(0, screen_y, text, st, null);
                    },
                    .pair => |p| {
                        // Whole slot is current when the cursor sits on either pane
                        // (paired del|add highlight together as one split row).
                        const slot_cur = sbs_slots[si].containsRow(cur);
                        const left_st = if (p.left) |ri|
                            rowStyle(
                                rows[ri],
                                slot_cur,
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
                            )
                        else if (slot_cur) ctx_cur_style else body;
                        const right_st = if (p.right) |ri|
                            rowStyle(
                                rows[ri],
                                slot_cur,
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
                            )
                        else if (slot_cur) ctx_cur_style else body;

                        fillSpan(scr, 0, panes.gutter_x, screen_y, left_st);
                        if (panes.right_w > 0 or panes.gutter_x < size.cols) {
                            fillSpan(scr, panes.gutter_x, panes.gutter_x + 1, screen_y, gutter_style);
                            if (panes.gutter_x < size.cols) {
                                scr.setCell(panes.gutter_x, screen_y, .{
                                    .char = '│',
                                    .width = 1,
                                    .style = gutter_style,
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
        if (cm) |m| {
            // Reflow (e.g. resize) can move the caret line; keep it on-screen.
            const caret_byte = @min(draft_caret, draft.len);
            const pos = comment_input.VisualPos.init(draft, m.text_w, caret_byte);
            draft_scroll.* = comment_input.ensureVisible(draft_scroll.*, pos.line, m.height, m.line_count);
            const ds = draft_scroll.*;

            var row: u16 = 0;
            while (row < footer_h) : (row += 1) {
                const y: u16 = footer_top + row;
                fillRow(scr, y, footer_style);
                const vline = ds + row;
                const piece = comment_input.writeVisualLine(&line_buf, draft, m.text_w, vline);
                // Prefix + text start at column 1 (one-cell left gutter).
                scr.putStr(1, y, piece, footer_style, null);
            }

            // Right pad is always reserved (text_w stable). Scrollbar uses the
            // rightmost column of that pad when needed; the pad column left of
            // it stays empty so wrap does not reflow when the bar appears.
            if (m.show_scrollbar and size.cols > 0) {
                const bar_x: u16 = size.cols - 1;
                const thumb = comment_input.scrollbarThumb(
                    m.line_count,
                    m.height,
                    ds,
                    m.height,
                );
                var br: u16 = 0;
                while (br < footer_h) : (br += 1) {
                    const y: u16 = footer_top + br;
                    const in_thumb = br >= thumb.start and br < thumb.start + thumb.len;
                    const st = if (in_thumb) footer_bar_thumb else footer_bar_track;
                    const ch: u21 = if (in_thumb) '█' else '│';
                    scr.setCell(bar_x, y, .{ .char = ch, .width = 1, .style = st });
                }
            }

            // Hardware caret at draft_caret (insert position). Clamp x to cols.
            const caret = comment_input.cursorAt(draft, m.text_w, ds, m.height, caret_byte);
            const max_x: u16 = if (size.cols == 0) 0 else size.cols - 1;
            const cx: u16 = @min(caret.x, max_x);
            const cy: u16 = footer_top + caret.y_off;
            scr.setCursor(cx, cy);
        } else if (focus == .searching) {
            // Single-line prompt (`/` text or `Space` `f` paths): gutter col 0,
            // `/` at 1, query at 2+. Caret 0 sits after `/` (column 2).
            const footer_y = footer_top;
            fillRow(scr, footer_y, footer_style);
            const caret_byte = @min(draft_caret, draft.len);
            const prompt = bufPrintTrunc(&line_buf, "/{s}", .{draft});
            scr.putStr(1, footer_y, prompt, footer_style, null);
            const max_x: u16 = if (size.cols == 0) 0 else size.cols - 1;
            const raw_x: usize = 2 + caret_byte;
            const cx: u16 = if (raw_x > max_x) max_x else @intCast(raw_x);
            scr.setCursor(cx, footer_y);
        } else {
            const footer_y = footer_top;
            fillRow(scr, footer_y, footer_style);
            if (status_note.len > 0) {
                scr.putStr(1, footer_y, status_note, footer_style, null);
            } else {
                const st = view.statusAt(rows, cur);
                const footer_text = formatFooter(&line_buf, st, review.openCount(), layout_pref, size.cols, source);
                scr.putStr(1, footer_y, footer_text, footer_style, null);
            }
            scr.hideCursor();
        }
    } else {
        scr.hideCursor();
    }

    if (focus == .listing) {
        paintCommentList(scr, size, list_items, list_cursor, list_scroll, &line_buf);
        scr.hideCursor();
    }
}

fn rowMarked(row: view.Row, review: *const store.Review) bool {
    return switch (row) {
        .line => |ln| switch (ln.kind) {
            .meta => false,
            else => review.firstAt(ln.path, ln.old_no, ln.new_no) != null,
        },
        else => false,
    };
}

/// Short layout label for the status footer.
fn layoutFooterLabel(pref: view.LayoutPref, cols: u16) []const u8 {
    return switch (view.effectiveLayout(pref, cols)) {
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
    st: view.Status,
    open_n: usize,
    layout_pref: view.LayoutPref,
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
    fillSpan(scr, 0, scr.cols, y, style);
}

/// Fill columns `[x0, x1)` on row `y` (clamped to the screen).
fn fillSpan(scr: *tui.Screen, x0: u16, x1: u16, y: u16, style: tui.Style) void {
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
