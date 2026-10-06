//! `rv` entry point — CLI dispatch + full-screen diff review (MVP-1 / MVP-2.2).
//!
//! With no args: load local-only git diff → flatten rows → load `.rv`
//! comments → TUI (title bar is a short hint; `?` opens help). Keys: `j`/`k`,
//! `h`/`l` pan, `0`/`$` col home/end, `[`/`]` hunk, `{`/`}` file header,
//! `(`/`)` prev/next comment (unapproves a hidden hunk if needed), `/` text search, `n`/`N` next/prev match,
//! `Space` `f` file list, `Space` `c` comment list, `Space` `a` approved list
//! (local; Enter unapproves and jumps, does not unstage), `gs`/`gu`/`gd` hunk git and `gS`/`gU`/`gD`
//! file git (local), `a`/`A` approve hunk/file (local; stages, then hides),
//! `i`/`c`/`Enter`
//! create or edit new, `I`/`C` old, `d` dismiss new, `D` dismiss old,
//! `e` expand the current hunk's context, `r` reload the diff and comments, `q` quit).
//! Diff layout defaults to side-by-side when the terminal is wide enough;
//! falls back to unified when narrow. `t` toggles session preference
//! (explicit unified stays unified even when wide). `#` toggles line numbers
//! (on by default). `w` toggles wrap of diff body lines (off by default).
//! Error paths never enter raw / alt-screen mode. An empty model still
//! opens the TUI; the footer shows the load source (`HEAD · empty` when
//! the worktree is clean, `HEAD · N approved` when every local change is
//! hidden).
//!
//! With a git commit-ish arg: load that commit's patch → same TUI (read-only
//! git mutate / approve). With a range that contains `..` or `...`: load
//! `git diff <range>` as written → same TUI.
//! With a subcommand: headless CLI (`status`, `approved`, `unapprove`, `list`,
//! `show`, `resolve`, `export`, `version`, help). Comment-only commands
//! do not load git. `status` / `approved` / `unapprove` load the local diff.
//! No raw TTY modes.
//!
//! Comment UX: soft-wrapped multi-line footer prompt (grows up to 4 rows, then
//! scrolls with a right-edge scrollbar). Arrow keys move the caret; insert and
//! backspace edit at the caret. Esc cancels; Enter saves. Open-comment marker:
//! `*` in the gutter. Add/delete lines use green/red backgrounds (no `+/-`).
//! Comments are stored in `.rv/reviews/current.json`. `r` re-reads that file;
//! starting `rv` again does too.
//!
//! Diff text search (MVP-3a): `/` opens a single-line footer prompt. Enter
//! commits a case-sensitive substring query over add/delete/context body text
//! (not headers/meta); Esc cancels without moving the cursor. `n`/`N` walk
//! those text matches with wrap. No match leaves the cursor put and shows a
//! footer note.
//!
//! File list: `Space` then `f` opens a centered overlay of changed-file
//! paths (flatten order). `j`/`k` move; Enter jumps to that file header and
//! closes. `a`/`A` approve the remaining hunks of that file in its group
//! (same as `A` on the file header; stages, then hides; local only; range no-op). The overlay stays
//! open and refreshes; a fully approved file leaves the list. Live comments
//! on the file open the same approve confirm; Esc on that confirm returns
//! to the list. Esc on the list closes without moving the cursor. `q` still
//! quits. Empty diff: empty overlay. Opens on the file under the cursor
//! when there is one. Local only: `g` then `s`/`u`/`d` stages, unstages, or discards the
//! current hunk; `S`/`U`/`D` do the containing file (file header or inside
//! that file). Hunk chords are no-ops on a file header; all six are no-ops
//! on a section. Stage and unstage are separate keys (already-staged `gs`/`gS`
//! and not-staged `gu`/`gU` are no-ops). After a successful stage/unstage,
//! live comments on the target keep the same file, side, and line (line
//! numbers updated if the reloaded diff numbers that line differently).
//! Discard always confirms (`No` selected; `yes` proceeds). If the target
//! has live comments, a second overlay asks to delete them (`Yes` selected;
//! `no` keeps them). Git discard runs first; comments are deleted only on
//! success. Staged `gd`/`gD` are no-ops (unstage first). Range loads ignore
//! git and approve keys. Exactly one leader at a time (`Space` lists, `g`
//! git); an unmatched leader is dropped and the next key is
//! handled as usual. Local `a` stages the current hunk then hides it; `A`
//! stages the remaining hunks of that file in this group then hides them
//! (from a hunk or the file header; no-op on a section). Already staged:
//! hide only. Unapprove does not unstage. Live comments on that hunk (`a`)
//! or on the file / any of its hunks (`A`) open a confirm (No selected;
//! `yes` proceeds). Range and commit loads ignore `a`/`A`.
//! A git error opens a centered overlay with git’s stderr; Enter or Esc
//! dismisses. The list is unchanged. Local load paints git and approve
//! chords on the current file and hunk rows (no git/approve hints on a range
//! load). `e` expands the current hunk’s context (local and range); a hunk
//! that can still grow shows Expand (e) on the hunk header. Not bound while
//! commenting, searching, or in a list/help overlay. `r` restores git’s
//! default context and re-reads the comment file.
//!
//! Comment list: `Space` then `c` opens a centered overlay of live comments
//! (same store as `rv list`). `j`/`k` move; Enter jumps with the same landing
//! as `(`/`)` and closes the overlay. A live comment on an approved hunk
//! unapproves that hunk, rebuilds, and lands (same as `(`/`)`); unapprove
//! does not unstage. `d`/`D` dismisses the selected comment (list stays
//! open; cursor stays on a neighbor). `i`/`c`/`I`/`C` jump the same way as
//! Enter and open the create-or-edit box on that comment. Esc closes
//! without moving the cursor. A row whose path/line is gone from the live
//! diff stays in the list and shows a footer note. `q` still quits.
//!
//! Approved list: `Space` then `a` opens a centered overlay of live approved
//! identities (flatten order). Local only. `j`/`k` move; Enter removes one
//! matching store entry, rebuilds the main list, jumps to that row, and
//! closes. Unapprove does not unstage. Esc closes without changing approval.
//! Empty set: empty overlay.
//! Opens on an approved identity in the file under the cursor when there is
//! one; otherwise the first row. `q` still quits.
//!
//! Help: `?` in normal (or from a file, comment, or approved list) opens a centered overlay
//! with the grouped key catalog. `j`/`k` scroll when it does not fit. `?` or
//! Esc closes; `q` still quits. Other keys are ignored. While commenting or
//! searching, `?` inserts a question mark. The title bar is a short hint.

const std = @import("std");
const git = @import("git");
const diff = @import("diff");
const tui = @import("tui");
const view = @import("view");
const store = @import("store");
const comments = @import("comments");
const cli = @import("cli");
const comment_input = @import("comment_input");
const Help = @import("Help");
const Frame = @import("Frame.zig");
const approve = @import("approve");

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
            return cli.run(alloc, io, cmd, .cwd());
        },
    }
}

/// Rows reserved under the body. A comment box uses `comment_h`; every other
/// mode uses one status row. Zero when the terminal is a single row or less.
fn footerHeight(term_rows: u16, focus: Focus, comment_h: u16) u16 {
    if (term_rows < 2) return 0;
    if (focus == .commenting) return comment_h;
    return 1;
}

/// Title-bar text. `comment` and `confirm` are the open draft and confirm
/// dialog; other modes use a fixed label.
fn frameTitle(focus: Focus, comment: []const u8, confirm: []const u8) []const u8 {
    return switch (focus) {
        .commenting => comment,
        .searching => "rv  search  Enter jump  Esc cancel",
        .comments => "rv  comments  j/k  Enter jump  i edit  d dismiss  Esc close  q quit",
        .files => "rv  files  j/k  Enter jump  a/A approve  Esc close  q quit",
        .approved => "rv  approved  j/k move  Enter unapprove  Esc close  q quit",
        .helping => "rv  help  j/k  Esc/? close  q quit",
        .git_error => "rv  git error  Enter/Esc close  q quit",
        .confirm => confirm,
        .normal => "rv  j/k  /  i/I  ? help  q quit",
    };
}

/// Empty-list footer. A local load that only hid approved hunks is not a
/// clean worktree. Other loads keep the source label.
fn emptyFooterLabel(buf: []u8, source: git.Origin, approved_n: usize) []const u8 {
    if (source == .local and approved_n > 0) {
        return std.fmt.bufPrint(buf, "HEAD · {d} approved", .{approved_n}) catch "HEAD";
    }
    return cli.sourceLabel(source, true);
}

/// Git, approve, and expand labels for the cursor. Git and approve are local
/// and normal only. Expand is any normal-focus hunk that can still grow.
fn rowHints(
    rows: []const view.row.Row,
    cur: usize,
    source: git.Origin,
    focus: Focus,
) Frame.RowHints {
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

/// Clamp the viewport to the body area, then draw the review frame.
/// The comment box and confirm dialog supply their own title and height.
/// Comment marks are one bool per row, filled here so the painter does not
/// know which comment kind a row is.
fn presentFrame(
    alloc: std.mem.Allocator,
    frame: *Frame,
    scr: *tui.Screen,
    size: tui.Size,
    diff_view: *const OpenDiff,
    viewport: *Viewport,
    review: *const store.Review,
    source: git.Origin,
    focus: Focus,
    draft: *const Draft,
    confirm: Confirm,
    marks: *std.ArrayList(bool),
) !void {
    const footer_h = footerHeight(size.rows, focus, draft.metrics(size).height);
    const area = Frame.ContentArea.init(size, footer_h);
    viewport.settle(size.cols, area.rows, diff_view.rows, diff_view.sbs_slots);

    // One mark per row. Resize keeps the buffer across paints.
    try marks.resize(alloc, diff_view.rows.len);
    for (diff_view.rows, 0..) |row, i| marks.items[i] = comments.rowMarked(row, review);

    var empty_buf: [64]u8 = undefined;
    const cur = view.row.clampCursor(viewport.cursor, diff_view.rows.len);
    frame.paint(scr, size, .{
        .rows = diff_view.rows,
        .slots = diff_view.sbs_slots,
        .cursor = viewport.cursor,
        .scroll = viewport.scroll,
        .col_scroll = viewport.col_scroll,
        .pans = viewport.hunk_pans[0..viewport.hunk_pan_n],
        .wrap = viewport.wrap,
        .show_line_numbers = viewport.show_line_numbers,
        .layout_pref = viewport.layout_pref,
        .marked = marks.items,
        .title = frameTitle(focus, draft.titleBar(), confirm.titleBar()),
        .show_footer = focus != .searching and focus != .commenting,
        .source_label = cli.sourceLabel(source, false),
        .empty_label = emptyFooterLabel(&empty_buf, source, diff_view.approved_n),
        .open_n = review.openCount(),
        .hints = rowHints(diff_view.rows, cur, source, focus),
        .area = area,
    });
}

fn runTui(alloc: std.mem.Allocator, io: std.Io, source: git.Origin) !u8 {
    // Load before any TTY setup so error paths never touch the terminal.
    var diff_view: OpenDiff = switch (loadOpenDiff(alloc, io, source)) {
        .open => |loaded| loaded,
        .git => |err| {
            std.debug.print("rv: {s}\n", .{git.errorMessage(err)});
            return 1;
        },
        .approved => |err| {
            std.debug.print("rv: {s}\n", .{approvedLoadMessage(err)});
            return 1;
        },
        .build => |err| return err,
    };
    defer diff_view.deinit(alloc);

    var review = store.load(alloc, io, .cwd(), store.default_review_id) catch |err| {
        std.debug.print("rv: {s}\n", .{reviewLoadMessage(err)});
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

    var viewport: Viewport = .{};
    var running = true;
    // Exactly one focus; cannot help, comment, search, and list at once.
    var focus: Focus = .normal;
    // Exactly one leader: `Space` lists (`f` files, `c` comments, `a`
    // approved), `g` git (`s`/`u`/`d` hunk, `S`/`U`/`D` file). Cleared on the
    // next key. Unmatched is dropped; the second key is handled as usual.
    const Leader = enum { none, lists, git };
    var leader: Leader = .none;
    var confirm: Confirm = .{};
    var draft: Draft = .{};
    defer draft.buf.deinit(alloc);
    var search: Search = .{};
    defer search.buf.deinit(alloc);
    defer search.last_query.deinit(alloc);
    var comment_list: CommentList = .{};
    defer comment_list.items.deinit(alloc);
    var file_list: FileList = .{};
    defer file_list.items.deinit(alloc);
    var approved_list: ApprovedList = .{};
    defer approved_list.items.deinit(alloc);
    var help: Help = .{};
    var frame: Frame = .{};
    var marks: std.ArrayList(bool) = .empty;
    defer marks.deinit(alloc);
    var git_error: GitError = .{};
    defer git_error.buf.deinit(alloc);

    try presentFrame(alloc, &frame, &scr, size, &diff_view, &viewport, &review, source, focus, &draft, confirm, &marks);
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
                frame.note.clear();
                switch (focus) {
                    .commenting => switch (try draft.handleKey(alloc, io, &review, source, key, size)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .save_failed => {
                            focus = .normal;
                            frame.note.set("failed to save .rv comment store");
                        },
                        .open => {},
                    },
                    .searching => switch (try search.handleKey(
                        alloc,
                        key,
                        diff_view.rows,
                        viewport.cursor,
                    )) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .jump => |hit| {
                            focus = .normal;
                            viewport.cursor = hit.row;
                            if (hit.wrapped) frame.note.set("search wrapped");
                        },
                        .missing => {
                            focus = .normal;
                            frame.note.setFmt("Pattern not found: {s}", .{search.last_query.items});
                        },
                        .open => {},
                    },
                    .comments => switch (comment_list.handleKey(key, diff_view.rows)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .help => {
                            help.scroll = 0;
                            focus = .helping;
                        },
                        .jump => |j| {
                            focus = .normal;
                            viewport.cursor = j.row;
                            if (j.edit) {
                                try draft.beginComment(alloc, comment_list.items.items[comment_list.win.cursor]);
                                focus = .commenting;
                            }
                        },
                        .hidden => |h| {
                            focus = .normal;
                            if (try landComment(
                                alloc,
                                io,
                                source,
                                &diff_view,
                                &viewport.cursor,
                                &frame.note,
                                h.loc,
                            ) and h.edit) {
                                try draft.beginComment(alloc, comment_list.items.items[comment_list.win.cursor]);
                                focus = .commenting;
                            }
                        },
                        .missing => frame.note.set("comment not in this diff"),
                        .dismiss => try applyListDismiss(alloc, io, &review, &comment_list, &frame.note),
                        .open => {},
                    },
                    .files => switch (file_list.handleKey(key)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .help => {
                            help.scroll = 0;
                            focus = .helping;
                        },
                        .jump => |row| {
                            viewport.cursor = row;
                            focus = .normal;
                        },
                        .approve => try applyListApprove(
                            alloc,
                            io,
                            source,
                            &diff_view,
                            &viewport.cursor,
                            &frame.note,
                            &focus,
                            &git_error,
                            &review,
                            &confirm,
                            &file_list,
                        ),
                        .open => {},
                    },
                    .approved => switch (approved_list.handleKey(key)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .help => {
                            help.scroll = 0;
                            focus = .helping;
                        },
                        .unapprove => |idx| {
                            focus = .normal;
                            try applyUnapprove(
                                alloc,
                                io,
                                source,
                                &diff_view,
                                &viewport.cursor,
                                &frame.note,
                                .cwd(),
                                approved_list.items.items[idx],
                            );
                        },
                        .open => {},
                    },
                    .git_error => switch (git_error.handleKey(key)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .open => {},
                    },
                    .confirm => switch (confirm.handleKey(
                        key,
                        &review,
                        &diff_view.diff,
                        diff_view.rows,
                        viewport.cursor,
                    )) {
                        .closed => focus = if (confirm.return_to_files) .files else .normal,
                        .quit => running = false,
                        .open => {},
                        .group => {
                            focus = .normal;
                            try applyGroupIndex(
                                alloc,
                                io,
                                source,
                                &diff_view,
                                &viewport.cursor,
                                &frame.note,
                                &focus,
                                &git_error,
                                &review,
                            );
                        },
                        .discard => |delete_them| {
                            focus = .normal;
                            try applyIndex(
                                alloc,
                                io,
                                source,
                                &diff_view,
                                &viewport.cursor,
                                &frame.note,
                                &focus,
                                &git_error,
                                &review,
                                confirm.whole_file,
                                .discard,
                                delete_them,
                            );
                        },
                        .approve => {
                            try applyApprove(
                                alloc,
                                io,
                                source,
                                &diff_view,
                                &viewport.cursor,
                                &frame.note,
                                &focus,
                                &git_error,
                                &review,
                                .inherit,
                                .cwd(),
                                confirm.whole_file,
                            );
                            if (focus != .git_error) {
                                if (confirm.return_to_files) {
                                    try file_list.reload(alloc, diff_view.rows, file_list.win.cursor);
                                    focus = .files;
                                } else {
                                    focus = .normal;
                                }
                            }
                        },
                    },
                    .helping => switch (help.handleKey(key)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .open => {},
                    },
                    .normal => {
                        const pending = leader;
                        leader = .none;
                        const layout = view.layout.effectiveLayout(viewport.layout_pref, size.cols);
                        switch (key) {
                            .char => |c| {
                                if (pending == .lists and c == 'f') {
                                    try file_list.load(alloc, diff_view.rows, view.nav.currentFileStart(diff_view.rows, viewport.cursor));
                                    focus = .files;
                                } else if (pending == .lists and c == 'c') {
                                    try comment_list.load(alloc, review.comments.items);
                                    focus = .comments;
                                } else if (pending == .lists and c == 'a') {
                                    if (source == .local) {
                                        if (approved_list.load(
                                            alloc,
                                            io,
                                            &diff_view.diff,
                                            diff_view.rows,
                                            viewport.cursor,
                                        )) |_| {
                                            focus = .approved;
                                        } else |err| switch (err) {
                                            error.OutOfMemory => return err,
                                            else => frame.note.set(approvedLoadMessage(err)),
                                        }
                                    }
                                } else if (pending == .git and c == 's') {
                                    try dispatchStage(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &git_error,
                                        &review,
                                        false,
                                        true,
                                    );
                                } else if (pending == .git and c == 'u') {
                                    try dispatchStage(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &git_error,
                                        &review,
                                        false,
                                        false,
                                    );
                                } else if (pending == .git and c == 'd') {
                                    beginGitDiscard(source, diff_view.rows, viewport.cursor, &confirm, &focus, false);
                                } else if (pending == .git and c == 'S') {
                                    try dispatchStage(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &git_error,
                                        &review,
                                        true,
                                        true,
                                    );
                                } else if (pending == .git and c == 'U') {
                                    try dispatchStage(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &git_error,
                                        &review,
                                        true,
                                        false,
                                    );
                                } else if (pending == .git and c == 'D') {
                                    beginGitDiscard(source, diff_view.rows, viewport.cursor, &confirm, &focus, true);
                                } else if (viewport.handleKey(.{ .char = c }, size.cols, diff_view.rows, diff_view.sbs_slots) == .handled) {
                                    // j/k/h/l/0/$/J/K/[/]/{/}/t/#/w
                                } else if (c == 'q' or c == 'Q') {
                                    running = false;
                                } else if (c == '?') {
                                    help.scroll = 0;
                                    focus = .helping;
                                } else if (c == ' ') {
                                    leader = .lists;
                                } else if (c == 'g') {
                                    leader = .git;
                                } else if (c == '/') {
                                    search.begin();
                                    focus = .searching;
                                } else if (c == 'n') {
                                    switch (search.next(diff_view.rows, viewport.cursor)) {
                                        .none => {},
                                        .missing => frame.note.set("Pattern not found"),
                                        .hit => |hit| {
                                            viewport.cursor = hit.row;
                                            if (hit.wrapped) frame.note.set("search wrapped");
                                        },
                                    }
                                } else if (c == 'N') {
                                    switch (search.prev(diff_view.rows, viewport.cursor)) {
                                        .none => {},
                                        .missing => frame.note.set("Pattern not found"),
                                        .hit => |hit| {
                                            viewport.cursor = hit.row;
                                            if (hit.wrapped) frame.note.set("search wrapped");
                                        },
                                    }
                                } else if (c == ')') {
                                    try jumpLiveComment(&review, &diff_view, alloc, io, source, &viewport.cursor, &frame.note, .next);
                                } else if (c == '(') {
                                    try jumpLiveComment(&review, &diff_view, alloc, io, source, &viewport.cursor, &frame.note, .prev);
                                } else if (c == 'r') {
                                    reloadReview(alloc, io, .cwd(), &review, &frame.note);
                                    reloadDiff(alloc, io, source, &diff_view, &viewport.cursor, &frame.note);
                                } else if (c == 'e') {
                                    try expandCurrentHunk(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                    );
                                } else if (c == 'i' or c == 'c') {
                                    if (try draft.begin(&review, alloc, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .new)) {
                                        focus = .commenting;
                                    }
                                } else if (c == 'I' or c == 'C') {
                                    if (try draft.begin(&review, alloc, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .old)) {
                                        focus = .commenting;
                                    }
                                } else if (c == 'a') {
                                    try dispatchApprove(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &git_error,
                                        &review,
                                        &confirm,
                                        false,
                                    );
                                } else if (c == 'A') {
                                    try dispatchApprove(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &git_error,
                                        &review,
                                        &confirm,
                                        true,
                                    );
                                } else if (c == 'd') {
                                    dismissAt(&review, alloc, io, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .new, &frame.note);
                                } else if (c == 'D') {
                                    dismissAt(&review, alloc, io, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .old, &frame.note);
                                }
                            },
                            .enter => {
                                if (try draft.begin(&review, alloc, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .new)) {
                                    focus = .commenting;
                                }
                            },
                            .down, .up, .left, .right => {
                                _ = viewport.handleKey(key, size.cols, diff_view.rows, diff_view.sbs_slots);
                            },
                            .ctrl_c => running = false,
                            else => {},
                        }
                    },
                }
            },
            .mouse => |mouse| if (wheelDirection(mouse)) |dir| switch (focus) {
                .normal => {
                    leader = .none;
                    const footer_h = footerHeight(size.rows, focus, draft.metrics(size).height);
                    const area = Frame.ContentArea.init(size, footer_h);
                    viewport.scrollWheel(dir, .{
                        .y = mouse.y,
                        .cols = size.cols,
                        .rows = diff_view.rows,
                        .slots = diff_view.sbs_slots,
                        .area_top = area.top,
                        .area_bottom = area.bottom,
                    });
                },
                .helping => switch (dir) {
                    .up => help.scroll -|= 1,
                    .down => help.scroll +|= 1,
                    .left, .right => {},
                },
                .files => file_list.win.wheel(dir),
                .comments => comment_list.win.wheel(dir),
                .approved => approved_list.win.wheel(dir),
                .commenting => draft.scrollWheel(dir, size),
                .searching, .git_error, .confirm => {},
            },
        }
        if (running) {
            try presentFrame(alloc, &frame, &scr, size, &diff_view, &viewport, &review, source, focus, &draft, confirm, &marks);
            if (focus == .helping) {
                help.paint(&scr, size);
                scr.hideCursor();
            } else if (focus == .git_error) {
                git_error.paint(&scr, size);
                scr.hideCursor();
            } else if (focus == .files) {
                file_list.paint(&scr, size, diff_view.rows);
                scr.hideCursor();
            } else if (focus == .comments) {
                comment_list.paint(&scr, size);
                scr.hideCursor();
            } else if (focus == .approved) {
                approved_list.paint(&scr, size);
                scr.hideCursor();
            } else if (focus == .confirm) {
                confirm.paint(&scr, size, diff_view.rows, viewport.cursor);
                scr.hideCursor();
            } else if (focus == .searching) {
                search.paintFooter(&scr, size);
            } else if (focus == .commenting) {
                draft.paintFooter(&scr, size);
            }
            try scr.present(&term);
        }
    }
    return 0;
}

/// Parsed diff and the flatten the TUI walks. Local load omits approved hunks.
/// Reload builds another and swaps it in.
pub const OpenDiff = struct {
    diff: diff.Diff,
    /// Flatten rows (paint, nav, mutate targeting). Strings borrow from `diff`.
    rows: []view.row.Row,
    sbs_slots: []view.layout.SbsSlot,
    /// Live approved identities still in `diff` after prune. 0 on range/commit loads.
    approved_n: usize,

    fn maybeInit(
        alloc: std.mem.Allocator,
        io: std.Io,
        source: git.Origin,
        note: *StatusNote,
    ) ?OpenDiff {
        switch (loadOpenDiff(alloc, io, source)) {
            .open => |loaded| return loaded,
            .git => |err| note.set(git.errorMessage(err)),
            .approved => |err| note.set(approvedLoadMessage(err)),
            .build => note.set("out of memory"),
        }
        return null;
    }

    fn build(
        alloc: std.mem.Allocator,
        parsed: diff.Diff,
        rows: []view.row.Row,
        approved_n: usize,
    ) std.mem.Allocator.Error!OpenDiff {
        const sbs = try view.layout.pairSideBySide(alloc, rows);
        return .{
            .diff = parsed,
            .rows = rows,
            .sbs_slots = sbs,
            .approved_n = approved_n,
        };
    }

    fn deinit(self: OpenDiff, alloc: std.mem.Allocator) void {
        alloc.free(self.rows);
        alloc.free(self.sbs_slots);
        var parsed = self.diff;
        parsed.deinit();
    }

    fn replaceRows(
        self: *OpenDiff,
        alloc: std.mem.Allocator,
        new_rows: []view.row.Row,
        approved_n: usize,
    ) std.mem.Allocator.Error!void {
        const new_sbs = try view.layout.pairSideBySide(alloc, new_rows);
        alloc.free(self.rows);
        alloc.free(self.sbs_slots);
        self.rows = new_rows;
        self.sbs_slots = new_sbs;
        self.approved_n = approved_n;
    }
};

/// File or hunk to stage/unstage at `cursor`. `path` borrows from `rows`.
/// `whole_file` selects the containing file (`gS` / `gU` / `gD`). On a file
/// header, the target is always the file. `null` on empty lists, section
/// headers, and untagged (range) rows.
const MutateTarget = struct {
    path: []const u8,
    group: diff.Group,
    /// 0-based hunk in this file; `null` means the whole file.
    hunk_i: ?usize,
    first: usize,
    last: usize,
};

fn targetAt(rows: []const view.row.Row, cursor: usize, whole_file: bool) ?MutateTarget {
    if (rows.len == 0) return null;
    const cur = view.row.clampCursor(cursor, rows.len);
    if (rows[cur] == .section_header) return null;
    const fi = view.nav.currentFileStart(rows, cur) orelse return null;
    const fh = rows[fi].file_header;
    const group = fh.group orelse return null;
    const in_hunk = view.nav.currentHunkInFile(rows, cur);
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

/// File and hunk in `d` under `cursor`. `null` on empty lists, sections,
/// file headers, binary files, and hunk-less files. Works for local and range.
const ExpandTarget = struct {
    file_i: usize,
    hunk_i: usize,
};

fn expandTargetAt(d: *const diff.Diff, rows: []const view.row.Row, cursor: usize) ?ExpandTarget {
    if (rows.len == 0) return null;
    const cur = view.row.clampCursor(cursor, rows.len);
    if (rows[cur] == .section_header) return null;
    const fi_row = view.nav.currentFileStart(rows, cur) orelse return null;
    const fh = rows[fi_row].file_header;
    if (fh.is_binary) return null;
    const hunk_row = view.nav.currentHunkInFile(rows, cur) orelse return null;
    const hunk_i = hunkIndexInFile(rows, fi_row, hunk_row);
    for (d.files, 0..) |f, file_i| {
        if (f.group != fh.group) continue;
        if (!std.mem.eql(u8, f.displayPath(), fh.path)) continue;
        if (hunk_i >= f.hunks.len) return null;
        return .{ .file_i = file_i, .hunk_i = hunk_i };
    }
    return null;
}

/// Remaining change to land on after the target is removed from this load.
/// `path` borrows from `rows`. `hunk_i` is the index in that file *after*
/// removing a same-file hunk target (unchanged for a different file).
const NeighborMark = struct {
    path: []const u8,
    group: diff.Group,
    hunk_i: ?usize,
};

/// Prefer the next file/hunk header after `target.last`; else the previous
/// header before `target.first`. `null` when the target is the only change.
fn neighborMark(rows: []const view.row.Row, target: MutateTarget) ?NeighborMark {
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
const GroupSpan = struct {
    group: diff.Group,
    first: usize,
    last: usize,
};

fn groupSpanAt(rows: []const view.row.Row, cursor: usize) ?GroupSpan {
    if (rows.len == 0) return null;
    const cur = view.row.clampCursor(cursor, rows.len);
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
const GroupNeighborMark = union(enum) {
    section: diff.Group,
    file: struct { path: []const u8, group: diff.Group },
};

/// Prefer the following section or file after `span.last`; else the previous
/// section or file before `span.first`. `null` when this group is the only
/// change.
fn groupNeighborMark(rows: []const view.row.Row, span: GroupSpan) ?GroupNeighborMark {
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
fn restoreGroupNeighbor(rows: []const view.row.Row, mark: GroupNeighborMark) usize {
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

/// Land on `mark`'s file (and hunk, if set) after reload. Missing hunk → that
/// file's header. Missing file → row 0.
fn restoreNeighbor(rows: []const view.row.Row, mark: NeighborMark) usize {
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

fn sectionOrFileMark(rows: []const view.row.Row, idx: usize) ?GroupNeighborMark {
    switch (rows[idx]) {
        .section_header => |g| return .{ .section = g },
        .file_header => |fh| {
            const g = fh.group orelse return null;
            return .{ .file = .{ .path = fh.path, .group = g } };
        },
        .hunk_header, .line => return null,
    }
}

fn rowSpanLast(rows: []const view.row.Row, start: usize, whole_file: bool) usize {
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

fn hunkIndexInFile(rows: []const view.row.Row, file_start: usize, hunk_row: usize) usize {
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

fn headerAfter(rows: []const view.row.Row, last: usize) ?usize {
    var i = last + 1;
    while (i < rows.len) : (i += 1) {
        switch (rows[i]) {
            .file_header, .hunk_header => return i,
            .section_header, .line => {},
        }
    }
    return null;
}

fn headerBefore(rows: []const view.row.Row, first: usize) ?usize {
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

fn markAtHeader(rows: []const view.row.Row, idx: usize, target: MutateTarget) ?NeighborMark {
    const fi = view.nav.currentFileStart(rows, idx) orelse return null;
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

/// File or hunk at `cursor` that discard may run. `null` on empty, section,
/// untagged, or staged rows (unstage first).
fn discardTargetAt(rows: []const view.row.Row, cursor: usize, whole_file: bool) ?MutateTarget {
    const target = targetAt(rows, cursor, whole_file) orelse return null;
    return switch (target.group) {
        .staged => null,
        .unstaged, .untracked => target,
    };
}

/// Whether discard of the cursor target would also delete live comments.
fn discardHasComments(
    review: *const store.Review,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    whole_file: bool,
) bool {
    const target = discardTargetAt(rows, cursor, whole_file) orelse return false;
    const file = fileForTarget(d, target) orelse return false;
    return comments.hasMatching(review, file, diffHunkIndex(file, rows, target));
}

/// Whether approve of the cursor target should confirm because of live comments.
/// Hunk `a` (`whole_file == false`) requires a hunk; file-header comments and
/// other hunks do not count. File `A` matches the file header plus every hunk.
fn approveHasComments(
    review: *const store.Review,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    whole_file: bool,
) bool {
    const target = targetAt(rows, cursor, whole_file) orelse return false;
    if (!whole_file and target.hunk_i == null) return false;
    const file = fileForTarget(d, target) orelse return false;
    return comments.hasMatching(review, file, diffHunkIndex(file, rows, target));
}

const ConfirmKind = enum { discard, group, approve };

/// Next step after the user answers a confirm overlay (`yes` is the selected
/// choice). `comments_phase` is whether the comments question is already showing.
const ConfirmNext = union(enum) {
    close,
    comments,
    group,
    discard: bool,
    approve,
};

fn confirmNext(
    kind: ConfirmKind,
    comments_phase: bool,
    yes: bool,
    review: *const store.Review,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    whole_file: bool,
) ConfirmNext {
    return switch (kind) {
        .group => if (yes) .group else .close,
        .approve => if (yes) .approve else .close,
        .discard => {
            if (!comments_phase and !yes) return .close;
            if (!comments_phase and discardHasComments(review, d, rows, cursor, whole_file)) return .comments;
            return .{ .discard = comments_phase and yes };
        },
    };
}

/// Diff hunk index for a hunk `target` (match `@@` starts on the row). `null`
/// when the target is the whole file or the header is gone from `rows`.
fn diffHunkIndex(file: *const diff.File, rows: []const view.row.Row, target: MutateTarget) ?usize {
    if (target.hunk_i == null) return null;
    if (target.first >= rows.len) return null;
    return switch (rows[target.first]) {
        .hunk_header => |hh| approve.hunkAt(file.*, hh.old_start, hh.new_start),
        else => null,
    };
}

/// Parsed file matching `target`. `null` when path/group is missing or the hunk is out of range.
fn fileForTarget(d: *const diff.Diff, target: MutateTarget) ?*const diff.File {
    for (d.files) |*f| {
        const g = f.group orelse continue;
        if (g != target.group) continue;
        if (!std.mem.eql(u8, f.displayPath(), target.path)) continue;
        if (target.hunk_i) |hi| {
            if (hi >= f.hunks.len) return null;
        }
        return f;
    }
    return null;
}

const MutationKind = enum { stage_unstage, discard };

/// Local diff, rows, paired slots, and restored cursor after a successful mutate.
const Apply = struct {
    open: ?OpenDiff = null,
    cursor: usize = 0,
    fail_message: ?[]u8 = null,
    reload_err: ?git.Error = null,
    save_failed: bool = false,
};

const ApplyStatus = union(enum) {
    noop,
    result: Apply,
};

fn gitFailText(alloc: std.mem.Allocator, fail: []const u8, err: git.Error) std.mem.Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, fail, " \t\r\n");
    if (trimmed.len > 0) return try alloc.dupe(u8, trimmed);
    return try alloc.dupe(u8, git.errorMessage(err));
}

/// Unapproved rows plus how many store entries remain after prune.
const Visible = struct {
    rows: []view.row.Row,
    approved_n: usize,
};

/// Rows for `d` with this store's claims removed.
fn rowsForApproved(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    d: *const diff.Diff,
    approved: *const approve.Approved,
) std.mem.Allocator.Error![]view.row.Row {
    const placed = try approve.place(alloc, io, root, d, approved);
    defer alloc.free(placed);
    return view.row.flattenPlaced(alloc, d, placed);
}

/// Load `.rv/approved.json`, drop entries that no longer match `d`, write
/// the file when the set shrank, then build rows with the remaining claims
/// removed. `approved_n` is how many entries remain.
fn loadVisibleRows(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    d: *const diff.Diff,
) approve.LoadError!Visible {
    var approved = try approve.load(alloc, io, root);
    defer approved.deinit();

    // Drop entries this diff cannot place, and write when the set shrank.
    const before = approved.entries.items.len;
    try approved.prune(alloc, io, root, d);
    if (approved.entries.items.len != before) {
        approve.save(&approved, alloc, io, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }

    const rows = try rowsForApproved(alloc, io, root, d, &approved);
    return .{ .rows = rows, .approved_n = approved.entries.items.len };
}

fn localVisible(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    d: *const diff.Diff,
) std.mem.Allocator.Error!Visible {
    return loadVisibleRows(alloc, io, root, d) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => .{ .rows = try view.row.flatten(alloc, d), .approved_n = 0 },
    };
}

fn openFromDiff(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    parsed: diff.Diff,
) git.Error!OpenDiff {
    var d = parsed;
    errdefer d.deinit();
    const vis = try localVisible(alloc, io, root, &d);
    errdefer alloc.free(vis.rows);
    return OpenDiff.build(alloc, d, vis.rows, vis.approved_n) catch return error.OutOfMemory;
}

fn finishApply(
    alloc: std.mem.Allocator,
    open: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    git_error: *GitError,
    result: Apply,
) std.mem.Allocator.Error!void {
    if (result.open) |loaded| {
        open.deinit(alloc);
        open.* = loaded;
        cursor.* = result.cursor;
    } else if (result.reload_err) |err| {
        note.set(git.errorMessage(err));
    }
    if (result.save_failed) note.set("failed to save .rv comment store");
    if (result.fail_message) |msg| {
        defer alloc.free(msg);
        git_error.buf.clearRetainingCapacity();
        try git_error.buf.appendSlice(alloc, msg);
        focus.* = .git_error;
    }
}

fn removeMatchingComments(
    review: *store.Review,
    alloc: std.mem.Allocator,
    io: std.Io,
    ids: []const []const u8,
    saved: []const comments.RemoveSnap,
) bool {
    if (ids.len == 0) return true;
    review.remove(ids) catch return true;
    store.save(review, alloc, io, .cwd()) catch {
        for (saved) |s| {
            review.comments.insert(review.arena.allocator(), s.idx, s.comment) catch {};
        }
        return false;
    };
    return true;
}

fn saveCommentRemap(
    review: *store.Review,
    alloc: std.mem.Allocator,
    io: std.Io,
    priors: []const comments.AnchorSnap,
) bool {
    if (priors.len == 0) return true;
    store.save(review, alloc, io, .cwd()) catch {
        for (priors) |p| {
            review.setLines(p.id, p.old_line, p.new_line, p.side) catch {};
        }
        return false;
    };
    return true;
}

/// Stage, unstage, or discard the file or hunk at `cursor`. On success, reload
/// that path, pair slots once, and restore onto the neighbor change. Other
/// files stay as loaded. Stage/unstage remaps live comments only after that
/// visible diff is built. `delete_comments` (discard only) removes matching
/// live comments after a successful mutate. Mutate failure, and a failed
/// rebuild, leave the list and comment anchors unchanged.
fn applyAtCursor(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.process.Child.Cwd,
    root: std.Io.Dir,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    review: *store.Review,
    whole_file: bool,
    kind: MutationKind,
    delete_comments: bool,
) std.mem.Allocator.Error!ApplyStatus {
    const target = targetAt(rows, cursor, whole_file) orelse return .noop;
    const file = fileForTarget(d, target) orelse return .noop;
    const diff_hunk_i = diffHunkIndex(file, rows, target);
    if (target.hunk_i != null and diff_hunk_i == null) return .noop;
    const action: git.Action = switch (kind) {
        .stage_unstage => switch (target.group) {
            .unstaged, .untracked => .stage,
            .staged => .unstage,
        },
        .discard => switch (target.group) {
            .unstaged, .untracked => .discard,
            .staged => return .noop,
        },
    };
    const neighbor = neighborMark(rows, target);

    // Collect comments to delete after a successful discard.
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    var saved: std.ArrayList(comments.RemoveSnap) = .empty;
    defer saved.deinit(alloc);
    if (delete_comments and kind == .discard) {
        try comments.collectMatching(review, file, diff_hunk_i, alloc, &ids, &saved);
    }

    var fail: []u8 = &.{};
    git.mutate(alloc, io, cwd, .{
        .action = action,
        .path = file.displayPath(),
        .group = target.group,
        .hunk = if (diff_hunk_i) |hi| &file.hunks[hi] else null,
        .file = if (diff_hunk_i != null) file else null,
        .fail_output = &fail,
    }) catch |err| switch (err) {
        error.OutOfMemory => {
            if (fail.len > 0) alloc.free(fail);
            return error.OutOfMemory;
        },
        error.NotARepository, error.GitNotFound, error.GitFailed, error.BadHunkHeader => {
            defer if (fail.len > 0) alloc.free(fail);
            return .{ .result = .{ .fail_message = try gitFailText(alloc, fail, err) } };
        },
    };

    var save_failed = false;
    if (ids.items.len > 0) {
        save_failed = !removeMatchingComments(review, alloc, io, ids.items, saved.items);
    }

    // Reload only the mutated path; other files stay as loaded.
    var path_buf: [2][]const u8 = undefined;
    path_buf[0] = file.displayPath();
    var path_n: usize = 1;
    if (file.old_path) |old_p| {
        if (!std.mem.eql(u8, old_p, path_buf[0])) {
            path_buf[1] = old_p;
            path_n = 2;
        }
    }
    const spliced = git.reloadPaths(alloc, io, cwd, d, path_buf[0..path_n]) catch |err| {
        return .{ .result = .{ .reload_err = err, .save_failed = save_failed } };
    };

    // Visible diff first. A failure here leaves comment anchors unchanged.
    const loaded = openFromDiff(alloc, io, root, spliced) catch |err| {
        return .{ .result = .{ .reload_err = err, .save_failed = save_failed } };
    };

    // Stage/unstage: re-anchor live comments onto the new diff, then save.
    if (kind == .stage_unstage) {
        var priors: std.ArrayList(comments.AnchorSnap) = .empty;
        defer priors.deinit(alloc);
        comments.remapMatching(review, file, &loaded.diff, diff_hunk_i, alloc, &priors) catch |err| {
            for (priors.items) |p| {
                review.setLines(p.id, p.old_line, p.new_line, p.side) catch {};
            }
            loaded.deinit(alloc);
            return err;
        };
        if (!saveCommentRemap(review, alloc, io, priors.items)) save_failed = true;
    }

    const new_cursor: usize = if (neighbor) |m| restoreNeighbor(loaded.rows, m) else 0;
    return .{ .result = .{
        .open = loaded,
        .cursor = new_cursor,
        .save_failed = save_failed,
    } };
}

/// Stage or unstage every file in the section at `cursor`. File-level mutate
/// in flatten order. Always reload after the loop (list matches git). A git
/// error is returned with that reload so the overlay can open. Comment
/// anchors move only after the visible diff is built.
fn applyGroupAtCursor(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.process.Child.Cwd,
    root: std.Io.Dir,
    d: *const diff.Diff,
    rows: []const view.row.Row,
    cursor: usize,
    review: *store.Review,
) std.mem.Allocator.Error!ApplyStatus {
    const span = groupSpanAt(rows, cursor) orelse return .noop;
    const action: git.Action = switch (span.group) {
        .unstaged, .untracked => .stage,
        .staged => .unstage,
    };
    const neighbor = groupNeighborMark(rows, span);
    var fail: []u8 = &.{};
    const first_err: ?git.Error = blk: {
        for (d.files) |f| {
            const g = f.group orelse continue;
            if (g != span.group) continue;
            git.mutate(alloc, io, cwd, .{
                .action = action,
                .path = f.displayPath(),
                .group = span.group,
                .fail_output = &fail,
            }) catch |err| switch (err) {
                error.OutOfMemory => {
                    if (fail.len > 0) alloc.free(fail);
                    return error.OutOfMemory;
                },
                error.NotARepository, error.GitNotFound, error.GitFailed, error.BadHunkHeader => break :blk err,
            };
        }
        break :blk null;
    };

    var reload_err: ?git.Error = null;
    var next: ?OpenDiff = null;
    var new_cursor: usize = 0;
    var group_save_failed = false;
    if (git.loadDefaultDiffCwd(alloc, io, cwd)) |loaded_diff| {
        if (openFromDiff(alloc, io, root, loaded_diff)) |opened| {
            var priors: std.ArrayList(comments.AnchorSnap) = .empty;
            defer priors.deinit(alloc);
            for (d.files) |*f| {
                const g = f.group orelse continue;
                if (g != span.group) continue;
                comments.remapMatching(review, f, &opened.diff, null, alloc, &priors) catch |err| {
                    for (priors.items) |p| {
                        review.setLines(p.id, p.old_line, p.new_line, p.side) catch {};
                    }
                    opened.deinit(alloc);
                    if (fail.len > 0) alloc.free(fail);
                    return err;
                };
            }
            group_save_failed = !saveCommentRemap(review, alloc, io, priors.items);
            new_cursor = if (neighbor) |m| restoreGroupNeighbor(opened.rows, m) else 0;
            next = opened;
        } else |err| {
            reload_err = err;
        }
    } else |err| {
        reload_err = err;
    }

    const fail_message: ?[]u8 = if (first_err) |err| try gitFailText(alloc, fail, err) else null;
    if (fail.len > 0) alloc.free(fail);
    return .{ .result = .{
        .open = next,
        .cursor = new_cursor,
        .fail_message = fail_message,
        .reload_err = reload_err,
        .save_failed = group_save_failed,
    } };
}

/// A loaded review, or the step that failed. On failure any partial
/// allocation is already freed. Startup and reload report the failure
/// differently; both call `loadOpenDiff`.
const DiffLoad = union(enum) {
    open: OpenDiff,
    git: git.Error,
    approved: approve.LoadError,
    build: std.mem.Allocator.Error,
};

fn loadOpenDiff(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
) DiffLoad {
    var parsed = switch (source) {
        .local => git.loadDefaultDiff(alloc, io),
        .range => |r| git.loadRangeDiff(alloc, io, .inherit, r),
        .commit => |c| git.loadCommitDiff(alloc, io, .inherit, c),
    } catch |err| return .{ .git = err };

    const vis = flattenSource(alloc, io, source, &parsed) catch |err| {
        parsed.deinit();
        return .{ .approved = err };
    };
    const loaded = OpenDiff.build(alloc, parsed, vis.rows, vis.approved_n) catch |err| {
        alloc.free(vis.rows);
        parsed.deinit();
        return .{ .build = err };
    };
    return .{ .open = loaded };
}

fn flattenSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    d: *const diff.Diff,
) approve.LoadError!Visible {
    return switch (source) {
        .local => loadVisibleRows(alloc, io, .cwd(), d),
        .range, .commit => .{ .rows = try view.row.flatten(alloc, d), .approved_n = 0 },
    };
}

fn approvedLoadMessage(err: approve.LoadError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.InvalidJson, error.InvalidHash => "invalid .rv approved JSON",
        else => "failed to load .rv approved store",
    };
}

fn reviewLoadMessage(err: store.LoadError) []const u8 {
    return switch (err) {
        error.InvalidJson => "invalid .rv review JSON",
        error.InvalidState => "invalid comment state in .rv store",
        error.InvalidSide => "invalid comment side in .rv store",
        error.OutOfMemory => "out of memory",
        else => "failed to load .rv comment store",
    };
}

/// Re-read `.rv/reviews/current.json` into `review`. On failure, keep the
/// previous comments and set `note`.
fn reloadReview(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    review: *store.Review,
    note: *StatusNote,
) void {
    const loaded = store.load(alloc, io, root, store.default_review_id) catch |err| {
        note.set(reviewLoadMessage(err));
        return;
    };
    review.deinit();
    review.* = loaded;
}

/// Re-run the startup load. On success, replace the live OpenDiff and restore
/// the cursor to the same path+line. On failure, leave the previous list and
/// set `note`. Does not touch the comment store. `r` is only bound in normal
/// focus.
fn reloadDiff(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
) void {
    const loaded = OpenDiff.maybeInit(alloc, io, source, note) orelse return;
    const new_cursor: usize = blk: {
        const mark = view.nav.cursorMarkAt(diff_view.rows, cursor.*);
        break :blk if (mark) |m| view.nav.restoreCursor(loaded.rows, m) else 0;
    };
    diff_view.deinit(alloc);
    diff_view.* = loaded;
    cursor.* = new_cursor;
}

/// Grow the hunk under the cursor by `diff.expand_amount` context lines per
/// side. No-op on a section, file header, binary / hunk-less file, empty
/// list, or when the hunk already sits at both file bounds. Rebuilds the
/// flatten from the in-memory `Diff` (does not re-run `git diff`).
fn expandCurrentHunk(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
) std.mem.Allocator.Error!void {
    const rows = diff_view.rows;
    const cur = view.row.clampCursor(cursor.*, rows.len);
    const target = expandTargetAt(&diff_view.diff, rows, cur) orelse return;

    // Snapshot the current line/hunk so we can land after the flatten grows.
    const mark = view.nav.cursorMarkAt(rows, cur);
    const fi_row = view.nav.currentFileStart(rows, cur) orelse return;
    const fh = rows[fi_row].file_header;
    const hunk_row = view.nav.currentHunkInFile(rows, cur) orelse return;
    const hh = rows[hunk_row].hunk_header;

    const file = &diff_view.diff.files[target.file_i];
    const text = git.survivingFileText(alloc, io, .inherit, file, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set(git.errorMessage(err));
            return;
        },
    };
    defer alloc.free(text);

    switch (try diff_view.diff.expandHunk(target.file_i, target.hunk_i, text)) {
        .noop => return,
        .expanded => {},
    }

    // Rebuild rows from the expanded Diff; do not reload git.
    const vis = flattenSource(alloc, io, source, &diff_view.diff) catch |err| {
        note.set(approvedLoadMessage(err));
        return;
    };
    diff_view.replaceRows(alloc, vis.rows, vis.approved_n) catch {
        alloc.free(vis.rows);
        note.set("out of memory");
        return;
    };
    cursor.* = restoreExpandCursor(diff_view.rows, mark, fh.path, fh.group, hh.old_start, hh.new_start);
}

fn restoreExpandCursor(
    rows: []const view.row.Row,
    mark: ?view.row.DiffLoc,
    path: []const u8,
    group: ?diff.Group,
    old_start: u32,
    new_start: u32,
) usize {
    if (mark) |m| {
        if (m == .line) return view.nav.restoreCursor(rows, m);
    }
    var found: ?usize = null;
    for (rows, 0..) |row, i| {
        switch (row) {
            .file_header => |fh| {
                if (!std.mem.eql(u8, fh.path, path) or fh.group != group) continue;
                var j = i + 1;
                while (j < rows.len) : (j += 1) {
                    switch (rows[j]) {
                        .hunk_header => |hh| {
                            if (hh.old_start <= old_start and hh.new_start <= new_start) found = j;
                        },
                        .file_header, .section_header => break,
                        .line => {},
                    }
                }
                if (found) |idx| return idx;
            },
            else => {},
        }
    }
    return if (mark) |m| view.nav.restoreCursor(rows, m) else 0;
}

/// Approve the hunk (`whole_file == false`, requires a hunk) or the remaining
/// hunks of that file in this group (`true`, from a hunk or the file header).
/// Local only. No-op on a section, on a file header for hunk approve, and
/// when the source is a range. Unstaged/untracked: stage first (same as
/// `gs`/`gS`); GitFailed opens the git-error overlay and does not write the
/// store. Already staged: skip mutate. Then save, hide, restore onto the
/// neighbor of the original target (same rule as staging a row away).
fn applyApprove(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    git_error: *GitError,
    review: *store.Review,
    cwd: std.process.Child.Cwd,
    root: std.Io.Dir,
    whole_file: bool,
) std.mem.Allocator.Error!void {
    if (source != .local) return;
    const rows = diff_view.rows;
    const target = targetAt(rows, cursor.*, whole_file) orelse return;
    if (!whole_file and target.hunk_i == null) return;
    const file = groupedFile(&diff_view.diff, target.path, target.group) orelse return;

    // Identities must outlive stage: applyAtCursor replaces the diff.
    var hashes: std.ArrayList(approve.Hash) = .empty;
    defer hashes.deinit(alloc);
    var old_start: u32 = 0;
    var new_start: u32 = 0;
    if (!whole_file) {
        const hh = switch (rows[target.first]) {
            .hunk_header => |h| h,
            else => return,
        };
        old_start = hh.old_start;
        new_start = hh.new_start;
        const hi = approve.hunkAt(file.*, old_start, new_start) orelse return;
        for (file.hunks[hi].identityHunks()) |id| {
            try hashes.append(alloc, approve.fingerprintHunk(id));
        }
    } else if (file.hunks.len == 0) {
        if (approve.hunklessHash(alloc, io, root, file.*)) |hash| {
            try hashes.append(alloc, hash);
        }
    } else {
        for (file.hunks) |*h| {
            for (h.identityHunks()) |id| {
                try hashes.append(alloc, approve.fingerprintHunk(id));
            }
        }
    }
    const hunk_mark = neighborMark(rows, target);
    const mark_path = if (hunk_mark) |m| try alloc.dupe(u8, m.path) else null;
    defer if (mark_path) |p| alloc.free(p);
    const path = try alloc.dupe(u8, file.displayPath());
    defer alloc.free(path);
    const needs_stage = target.group != .staged;

    // Stage first. GitFailed opens the git-error overlay and does not write the store.
    if (needs_stage) {
        switch (try applyAtCursor(
            alloc,
            io,
            cwd,
            root,
            &diff_view.diff,
            diff_view.rows,
            cursor.*,
            review,
            whole_file,
            .stage_unstage,
            false,
        )) {
            .noop => return,
            .result => |r| {
                const stage_ok = r.open != null;
                try finishApply(alloc, diff_view, cursor, note, focus, git_error, r);
                if (!stage_ok) return;
            },
        }
    }

    // After a successful stage the file is under Staged. A path-only reload
    // can miss that file; still write the identities taken before stage.
    const live_file = groupedFile(&diff_view.diff, path, .staged);
    var approved = approve.load(alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set(approvedLoadMessage(err));
            return;
        },
    };
    defer approved.deinit();

    const store_path = if (live_file) |f| f.displayPath() else path;
    if (whole_file) {
        if (live_file) |f| {
            try approved.appendFile(alloc, io, root, f.*);
        } else {
            for (hashes.items) |hash| {
                try approved.append(store_path, hash);
            }
        }
    } else if (live_file) |f| {
        var any_place = false;
        for (hashes.items) |hash| {
            for (f.hunks) |h| {
                if (approve.hunkContains(h, hash)) {
                    any_place = true;
                    break;
                }
            }
            if (any_place) break;
        }
        if (any_place) {
            for (hashes.items) |hash| {
                try approved.append(store_path, hash);
            }
        } else {
            const only: ?usize = if (f.hunks.len == 1) 0 else null;
            const hi = approve.hunkAt(f.*, old_start, new_start) orelse only;
            if (hi) |i| {
                for (f.hunks[i].identityHunks()) |id| {
                    try approved.append(store_path, approve.fingerprintHunk(id));
                }
            } else {
                for (hashes.items) |hash| {
                    try approved.append(store_path, hash);
                }
            }
        }
    } else {
        for (hashes.items) |hash| {
            try approved.append(store_path, hash);
        }
    }

    // Prune only when the staged file is in this load; otherwise the new
    // entries cannot be placed yet and must survive until the next reload.
    if (live_file != null) {
        try approved.prune(alloc, io, root, &diff_view.diff);
    }
    approve.save(&approved, alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set("failed to save .rv approved store");
            return;
        },
    };

    const new_rows = try rowsForApproved(alloc, io, root, &diff_view.diff, &approved);
    const restored: usize = if (hunk_mark) |m|
        restoreNeighbor(new_rows, .{
            .path = mark_path.?,
            .group = m.group,
            .hunk_i = m.hunk_i,
        })
    else
        0;
    diff_view.replaceRows(alloc, new_rows, approved.entries.items.len) catch {
        alloc.free(new_rows);
        note.set("out of memory");
        return;
    };
    cursor.* = restored;
}

/// Drop one matching store entry, prune, save, replace the hidden flatten.
/// Local only. False when nothing changed (`note` set on load/save failure).
fn unapproveRebuild(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    note: *StatusNote,
    root: std.Io.Dir,
    item: approve.Hidden,
) std.mem.Allocator.Error!bool {
    if (source != .local) return false;
    var approved = approve.load(alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set(approvedLoadMessage(err));
            return false;
        },
    };
    defer approved.deinit();
    approved.unapprove(item.path, item.hash) catch return false;

    try approved.prune(alloc, io, root, &diff_view.diff);
    approve.save(&approved, alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set("failed to save .rv approved store");
            return false;
        },
    };

    const new_rows = try rowsForApproved(alloc, io, root, &diff_view.diff, &approved);
    diff_view.replaceRows(alloc, new_rows, approved.entries.items.len) catch {
        alloc.free(new_rows);
        note.set("out of memory");
        return false;
    };
    return true;
}

/// Enter on the approved list: drop one matching store entry, hide again,
/// jump to the restored row. Local only.
fn applyUnapprove(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    root: std.Io.Dir,
    item: approve.Hidden,
) std.mem.Allocator.Error!void {
    if (!try unapproveRebuild(alloc, io, source, diff_view, note, root, item)) return;
    const jump = rowForIdentity(
        diff_view.rows,
        &diff_view.diff,
        item.path,
        item.hash,
        item.kind,
    ) orelse 0;
    cursor.* = jump;
}

fn groupedFile(d: *const diff.Diff, path: []const u8, group: diff.Group) ?*const diff.File {
    for (d.files) |*f| {
        const g = f.group orelse continue;
        if (g != group) continue;
        if (std.mem.eql(u8, f.displayPath(), path)) return f;
    }
    return null;
}

fn fileAt(d: *const diff.Diff, path: []const u8, group: ?diff.Group) ?*const diff.File {
    for (d.files) |*f| {
        if (f.group != group) continue;
        if (std.mem.eql(u8, f.displayPath(), path)) return f;
    }
    return null;
}

/// First row of this identity (hunk header, or file header if hunk-less).
fn rowForIdentity(
    rows: []const view.row.Row,
    d: *const diff.Diff,
    path: []const u8,
    hash: approve.Hash,
    kind: approve.Hidden.Kind,
) ?usize {
    var cur_path: []const u8 = "";
    var cur_group: ?diff.Group = null;
    for (rows, 0..) |item, i| {
        switch (item) {
            .file_header => |fh| {
                cur_path = fh.path;
                cur_group = fh.group;
                if (kind == .hunk) continue;
                if (!std.mem.eql(u8, fh.path, path)) continue;
                const file = fileAt(d, fh.path, fh.group) orelse continue;
                if (file.hunks.len == 0) return i;
            },
            .hunk_header => |hh| {
                if (kind != .hunk) continue;
                if (!std.mem.eql(u8, cur_path, path)) continue;
                const file = fileAt(d, cur_path, cur_group) orelse continue;
                const hi = approve.hunkAt(file.*, hh.old_start, hh.new_start) orelse continue;
                if (approve.hunkContains(file.hunks[hi], hash)) return i;
            },
            .section_header, .line => {},
        }
    }
    return null;
}

/// Hunk (or hunk-less file) that owns `row_i`. A file-header row of a file
/// with hunks is the first hunk — used when the whole file is hidden.
fn identityAtRow(
    alloc: std.mem.Allocator,
    d: *const diff.Diff,
    io: std.Io,
    root: std.Io.Dir,
    rows: []const view.row.Row,
    row_i: usize,
) ?approve.Hidden {
    if (rows.len == 0) return null;
    const start = if (row_i >= rows.len) rows.len - 1 else row_i;
    var i = start;
    while (true) {
        switch (rows[i]) {
            .hunk_header => |hh| {
                const file = blk: {
                    var j = i;
                    while (j > 0) {
                        j -= 1;
                        switch (rows[j]) {
                            .file_header => |fh| break :blk fileAt(d, fh.path, fh.group),
                            else => {},
                        }
                    }
                    break :blk null;
                } orelse return null;
                const hi = approve.hunkAt(file.*, hh.old_start, hh.new_start) orelse return null;
                return .{
                    .path = file.displayPath(),
                    .hash = approve.fingerprintHunk(file.hunks[hi].identityHunks()[0]),
                    .group = file.group,
                    .kind = .hunk,
                    .preview = "",
                };
            },
            .file_header => |fh| {
                const file = fileAt(d, fh.path, fh.group) orelse return null;
                if (file.hunks.len == 0) {
                    const hash = approve.hunklessHash(alloc, io, root, file.*) orelse return null;
                    return .{
                        .path = file.displayPath(),
                        .hash = hash,
                        .group = file.group,
                        .kind = if (file.is_binary) .binary else .file,
                        .preview = "",
                    };
                }
                return .{
                    .path = file.displayPath(),
                    .hash = approve.fingerprintHunk(file.hunks[0].identityHunks()[0]),
                    .group = file.group,
                    .kind = .hunk,
                    .preview = "",
                };
            },
            .section_header, .line => {
                if (i == 0) return null;
                i -= 1;
            },
        }
    }
}

/// Stage, unstage, or discard the current file or hunk (local source only).
/// Hunk chords (`gs`/`gu`/`gd`) pass `whole_file == false` and require a
/// hunk; file chords (`gS`/`gU`/`gD`) pass `true`.
fn applyIndex(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    git_error: *GitError,
    review: *store.Review,
    whole_file: bool,
    kind: MutationKind,
    delete_comments: bool,
) std.mem.Allocator.Error!void {
    if (source != .local) return;
    switch (try applyAtCursor(
        alloc,
        io,
        .inherit,
        .cwd(),
        &diff_view.diff,
        diff_view.rows,
        cursor.*,
        review,
        whole_file,
        kind,
        delete_comments,
    )) {
        .noop => {},
        .result => |r| try finishApply(alloc, diff_view, cursor, note, focus, git_error, r),
    }
}

/// Stage or unstage every file in the section under the cursor (local only).
fn applyGroupIndex(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    git_error: *GitError,
    review: *store.Review,
) std.mem.Allocator.Error!void {
    if (source != .local) return;
    switch (try applyGroupAtCursor(
        alloc,
        io,
        .inherit,
        .cwd(),
        &diff_view.diff,
        diff_view.rows,
        cursor.*,
        review,
    )) {
        .noop => {},
        .result => |r| try finishApply(alloc, diff_view, cursor, note, focus, git_error, r),
    }
}

/// Stage (`stage`) or unstage (`!stage`) the hunk or file at the cursor.
/// Hunk chords require a hunk (no-op on a file header). Already-staged
/// stage and not-staged unstage are no-ops. Local only.
fn dispatchStage(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    git_error: *GitError,
    review: *store.Review,
    whole_file: bool,
    stage: bool,
) std.mem.Allocator.Error!void {
    const target = targetAt(diff_view.rows, cursor.*, whole_file) orelse return;
    if (!whole_file and target.hunk_i == null) return;
    if (stage) {
        if (target.group == .staged) return;
    } else if (target.group != .staged) return;
    try applyIndex(
        alloc,
        io,
        source,
        diff_view,
        cursor,
        note,
        focus,
        git_error,
        review,
        whole_file,
        .stage_unstage,
        false,
    );
}

/// Approve the hunk or remaining file hunks. Local only. Live comments on
/// that target open a confirm (No selected); otherwise the same silent
/// approve as today.
fn dispatchApprove(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    git_error: *GitError,
    review: *store.Review,
    confirm: *Confirm,
    whole_file: bool,
) std.mem.Allocator.Error!void {
    if (source != .local) return;
    if (approveHasComments(review, &diff_view.diff, diff_view.rows, cursor.*, whole_file)) {
        confirm.* = .{ .kind = .approve, .whole_file = whole_file, .yes = false, .comments = false };
        focus.* = .confirm;
        return;
    }
    try applyApprove(alloc, io, source, diff_view, cursor, note, focus, git_error, review, .inherit, .cwd(), whole_file);
}

/// Open the discard confirm for the hunk or file at the cursor. Hunk
/// discard requires a hunk. Staged and range loads are no-ops.
fn beginGitDiscard(
    source: git.Origin,
    rows: []const view.row.Row,
    cursor: usize,
    confirm: *Confirm,
    focus: *Focus,
    whole_file: bool,
) void {
    if (source != .local) return;
    const target = discardTargetAt(rows, cursor, whole_file) orelse return;
    if (!whole_file and target.hunk_i == null) return;
    confirm.* = .{ .whole_file = whole_file, .yes = false, .comments = false };
    focus.* = .confirm;
}

/// Key ownership: normal nav, comment draft, `/` search prompt, comment list,
/// file list, approved list, help, git error overlay, or confirm overlay
/// (discard, group, or approve).
pub const Focus = enum { normal, commenting, searching, comments, files, approved, helping, git_error, confirm };

/// Confirm overlay for discard (`gd` / `gD`), group stage/unstage, and
/// approve (`a` / `A` when the target has live comments). `yes` is the
/// selected choice. Opens with **No** selected (Enter does not apply).
/// Discard: if the target has live comments, `comments` is the second
/// overlay and defaults to **Yes** (delete).
pub const Confirm = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        group,
        discard: bool,
        approve,
    };

    kind: ConfirmKind = .discard,
    group: diff.Group = .unstaged,
    whole_file: bool = false,
    yes: bool = false,
    comments: bool = false,
    /// Approve confirm opened from the file list: Esc or a successful yes
    /// returns to that overlay (refreshed after yes).
    return_to_files: bool = false,

    fn handleKey(
        self: *Confirm,
        key: tui.Key,
        review: *const store.Review,
        d: *const diff.Diff,
        rows: []const view.row.Row,
        cursor: usize,
    ) Result {
        var abort = false;
        var answered = false;
        switch (key) {
            .esc => abort = true,
            .enter => answered = true,
            .left, .up => self.yes = false,
            .right, .down => self.yes = true,
            .char => |c| {
                if (c == 'q' or c == 'Q') return .quit;
                if (c == 'n' or c == 'N') {
                    self.yes = false;
                    answered = true;
                } else if (c == 'y' or c == 'Y') {
                    self.yes = true;
                    answered = true;
                }
            },
            .ctrl_c => return .quit,
            else => {},
        }
        if (abort) return .closed;
        if (!answered) return .open;
        switch (confirmNext(
            self.kind,
            self.comments,
            self.yes,
            review,
            d,
            rows,
            cursor,
            self.whole_file,
        )) {
            .close => return .closed,
            .comments => {
                self.comments = true;
                self.yes = true;
                return .open;
            },
            .group => return .group,
            .discard => |delete_them| return .{ .discard = delete_them },
            .approve => return .approve,
        }
    }

    fn paint(
        self: Confirm,
        scr: *tui.Screen,
        size: tui.Size,
        rows: []const view.row.Row,
        cursor: usize,
    ) void {
        var hunk_buf: [512]u8 = undefined;
        const group = self.kind == .group;
        const question_only = self.kind == .group or self.kind == .approve or self.comments;
        const hunk_text: []const u8, const path: []const u8 = if (question_only)
            .{ "", "" }
        else blk: {
            const target = targetAt(rows, cursor, self.whole_file);
            const hunk_row: ?view.row.Row = if (target) |t|
                if (t.hunk_i != null) rows[t.first] else null
            else
                null;
            const ht: []const u8 = if (hunk_row) |hr| Frame.formatRow(&hunk_buf, hr, false) else "";
            break :blk .{ ht, if (target) |t| t.path else "" };
        };

        const content_n: u16 = if (question_only)
            3
        else if (hunk_text.len > 0)
            4
        else
            3;
        const want_w: u16 = @min(size.cols -| 4, 60);
        const title: []const u8 = switch (self.kind) {
            .group => switch (self.group) {
                .unstaged, .untracked => " stage ",
                .staged => " unstage ",
            },
            .discard => if (self.comments) " comments " else " discard ",
            .approve => " approve ",
        };
        const panel = tui.Panel.fromRect(tui.Rect.centered(size.cols, size.rows, want_w, content_n + 2));
        panel.paint(scr, title);
        const inner = panel.inner;
        if (inner.h == 0 or inner.w == 0) return;
        var row: u16 = 0;
        if (group) {
            const question: []const u8 = switch (self.group) {
                .unstaged => "Stage all unstaged?",
                .untracked => "Stage all untracked?",
                .staged => "Unstage all staged?",
            };
            if (row < inner.h) {
                scr.putStr(inner.x, inner.y + row, question, tui.Panel.body, 0, inner);
                row += 1;
            }
        } else if (self.kind == .approve) {
            const question: []const u8 = if (self.whole_file)
                "This file has unresolved comments. Approve anyway?"
            else
                "This hunk has unresolved comments. Approve anyway?";
            if (row < inner.h) {
                scr.putStr(inner.x, inner.y + row, question, tui.Panel.body, 0, inner);
                row += 1;
            }
        } else if (self.comments) {
            if (row < inner.h) {
                scr.putStr(inner.x, inner.y + row, "delete comments with this change?", tui.Panel.body, 0, inner);
                row += 1;
            }
        } else {
            if (path.len > 0 and row < inner.h) {
                scr.putStr(inner.x, inner.y + row, path, tui.Panel.body, 0, inner);
                row += 1;
            }
            if (hunk_text.len > 0 and row < inner.h) {
                const start: usize = if (hunk_text[0] == ' ') 1 else 0;
                scr.putStr(inner.x, inner.y + row, hunk_text[start..], tui.Panel.body, 0, inner);
                row += 1;
            }
        }
        if (row < inner.h) row += 1;
        if (row >= inner.h) return;
        paintYesNoChoices(scr, inner, inner.y + row, self.yes, self.comments, tui.Panel.body, tui.Panel.row_cur);
    }

    pub fn titleBar(self: Confirm) []const u8 {
        return switch (self.kind) {
            .group => switch (self.group) {
                .unstaged, .untracked => "rv  stage all  No/yes  Enter  Esc cancel  q quit",
                .staged => "rv  unstage all  No/yes  Enter  Esc cancel  q quit",
            },
            .discard => if (self.comments)
                "rv  discard comments  no/Yes  Enter  Esc cancel  q quit"
            else
                "rv  discard  No/yes  Enter  Esc cancel  q quit",
            .approve => "rv  approve  No/yes  Enter  Esc cancel  q quit",
        };
    }

    /// Default choice is capitalized (`No`/`Yes`); the other stays lowercase.
    /// Highlight follows the current selection.
    fn paintYesNoChoices(
        scr: *tui.Screen,
        inner: tui.Rect,
        y: u16,
        yes: bool,
        default_yes: bool,
        panel_bg: tui.Style,
        choice_cur: tui.Style,
    ) void {
        const no_label: []const u8 = if (default_yes) "no" else "No";
        const yes_label: []const u8 = if (default_yes) "Yes" else "yes";
        const no_w: u16 = 2;
        const yes_w: u16 = 3;
        const mid: u16 = inner.x + inner.w / 2;
        const no_x: u16 = mid -| 6;
        const yes_x: u16 = mid +| 2;
        const n_st = if (!yes) choice_cur else panel_bg;
        const y_st = if (yes) choice_cur else panel_bg;
        scr.fillRect(.{ .x = no_x -| 1, .y = y, .w = no_w + 2, .h = 1 }, ' ', n_st);
        scr.putStr(no_x, y, no_label, n_st, 0, inner);
        scr.fillRect(.{ .x = yes_x -| 1, .y = y, .w = yes_w + 2, .h = 1 }, ' ', y_st);
        scr.putStr(yes_x, y, yes_label, y_st, 0, inner);
    }
};

/// Comment prompt: buffer, caret, keys, save, and footer paint.
pub const Draft = struct {
    const Result = enum { open, closed, quit, save_failed };

    buf: std.ArrayList(u8) = .empty,
    scroll: usize = 0,
    /// Wheel moved the comment window. Paint then leaves the caret where it is.
    window_moved: bool = false,
    caret: usize = 0,
    loc: view.row.DiffLoc = .{ .file = "" },
    edit_id: ?[]const u8 = null,

    fn clear(self: *Draft) void {
        self.buf.clearRetainingCapacity();
        self.scroll = 0;
        self.window_moved = false;
        self.caret = 0;
        self.edit_id = null;
    }

    /// Vertical wheel scrolls the comment text. The caret stays put.
    fn scrollWheel(self: *Draft, wheel: Wheel, term_size: tui.Size) void {
        switch (wheel) {
            .up => self.scroll -|= 1,
            .down => self.scroll +|= 1,
            .left, .right => return,
        }
        const m = self.metrics(term_size);
        self.scroll = comment_input.clampScroll(self.scroll, m.line_count, m.height);
        self.window_moved = true;
    }

    pub fn metrics(self: *const Draft, size: tui.Size) comment_input.Metrics {
        const available: usize = if (size.rows <= 1) 1 else size.rows - 1;
        return comment_input.metricsLimited(size.cols, self.buf.items, @min(comment_input.max_rows, available));
    }

    fn ensureCaretVisible(self: *Draft, size: tui.Size) void {
        const m = self.metrics(size);
        const pos = comment_input.VisualPos.init(self.buf.items, m.text_w, self.caret);
        self.scroll = comment_input.ensureVisible(self.scroll, pos.line, m.height, m.line_count);
    }

    /// Open the comment box on `want` at `cursor`. Missing side: silent no-op.
    /// File header: both sides open the file comment (no missing-side).
    /// Hunk header: both sides open the hunk comment (no missing-side).
    /// Existing comment: pre-fill the first in store order; caret at end. None: create.
    /// Returns true when the box opened.
    fn begin(
        self: *Draft,
        review: *const store.Review,
        alloc: std.mem.Allocator,
        rows: []const view.row.Row,
        slots: []const view.layout.SbsSlot,
        layout: view.layout.EffectiveLayout,
        cursor: usize,
        want: view.row.CommentSide,
    ) std.mem.Allocator.Error!bool {
        const found = comments.atSide(review, rows, slots, layout, cursor, want) orelse return false;
        if (found.idx) |idx| {
            try self.beginComment(alloc, review.comments.items[idx]);
            return true;
        }
        self.clear();
        self.loc = found.loc;
        return true;
    }

    /// Open the comment box on an existing store row (list edit, or `begin`
    /// when that loc already has a comment).
    fn beginComment(self: *Draft, alloc: std.mem.Allocator, c: store.Comment) std.mem.Allocator.Error!void {
        self.clear();
        self.loc = comments.loc(c) orelse .{ .file = c.path };
        try self.buf.appendSlice(alloc, c.body);
        self.caret = self.buf.items.len;
        self.edit_id = c.id;
    }

    pub fn titleBar(self: *const Draft) []const u8 {
        return switch (self.loc) {
            .hunk => "rv  create/edit hunk  Enter save  Esc cancel  ↑↓ scroll",
            .file => "rv  create/edit file  Enter save  Esc cancel  ↑↓ scroll",
            .line => |l| switch (l.side) {
                .new => "rv  create/edit new  Enter save  Esc cancel  ↑↓ scroll",
                .old => "rv  create/edit old  Enter save  Esc cancel  ↑↓ scroll",
            },
        };
    }

    fn handleKey(
        self: *Draft,
        alloc: std.mem.Allocator,
        io: std.Io,
        review: *store.Review,
        source: git.Origin,
        key: tui.Key,
        size: tui.Size,
    ) std.mem.Allocator.Error!Result {
        self.window_moved = false;
        switch (key) {
            .esc => {
                self.clear();
                return .closed;
            },
            .enter => {
                if (self.buf.items.len > 0) {
                    if (self.edit_id) |id| {
                        if (review.find(id)) |c| {
                            const prior = c.body;
                            if (review.setBody(id, self.buf.items)) |_| {
                                store.save(review, alloc, io, .cwd()) catch {
                                    review.setBody(id, prior) catch {};
                                    self.clear();
                                    return .save_failed;
                                };
                            } else |err| switch (err) {
                                error.NotFound => {},
                                error.OutOfMemory => return error.OutOfMemory,
                            }
                        }
                    } else {
                        const path = self.loc.path();
                        const old_line: ?u32, const new_line: ?u32, const side: ?store.Side = switch (self.loc) {
                            .file => .{ null, null, null },
                            .hunk => |h| .{ h.old_start, h.new_start, null },
                            .line => |l| switch (l.side) {
                                .old => .{ l.line, null, .old },
                                .new => .{ null, l.line, .new },
                            },
                        };
                        _ = try review.addOpen(
                            path,
                            old_line,
                            new_line,
                            side,
                            self.buf.items,
                            switch (source) {
                                .local => .local,
                                .range => |r| .{ .range = r },
                                .commit => |c| .{ .commit = c },
                            },
                        );
                        store.save(review, alloc, io, .cwd()) catch {
                            // Stay in review; next save can retry. Marker is in-memory.
                        };
                    }
                }
                self.clear();
                return .closed;
            },
            .backspace => {
                if (self.caret > 0) {
                    self.caret -= 1;
                    _ = self.buf.orderedRemove(self.caret);
                    self.ensureCaretVisible(size);
                }
            },
            .char => |c| {
                if (c >= 0x20 and c < 0x7f) {
                    try self.buf.insert(alloc, self.caret, @intCast(c));
                    self.caret += 1;
                    self.ensureCaretVisible(size);
                }
            },
            .left => {
                if (self.caret > 0) self.caret -= 1;
                self.ensureCaretVisible(size);
            },
            .right => {
                if (self.caret < self.buf.items.len) self.caret += 1;
                self.ensureCaretVisible(size);
            },
            .up => {
                const m = self.metrics(size);
                const pos = comment_input.VisualPos.init(self.buf.items, m.text_w, self.caret);
                // On the first visual line, stay put (keep column).
                if (pos.line > 0) {
                    self.caret = comment_input.byteAtVisual(self.buf.items, m.text_w, pos.line - 1, pos.col);
                    self.ensureCaretVisible(size);
                }
            },
            .down => {
                const m = self.metrics(size);
                const pos = comment_input.VisualPos.init(self.buf.items, m.text_w, self.caret);
                if (pos.line + 1 < m.line_count) {
                    self.caret = comment_input.byteAtVisual(self.buf.items, m.text_w, pos.line + 1, pos.col);
                }
                self.ensureCaretVisible(size);
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn paintFooter(self: *Draft, scr: *tui.Screen, size: tui.Size) void {
        if (size.rows < 2) return;
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

        const m = self.metrics(size);
        const footer_h = m.height;
        const footer_top: u16 = size.rows - footer_h;
        if (self.window_moved) {
            self.scroll = comment_input.clampScroll(self.scroll, m.line_count, m.height);
        } else {
            self.ensureCaretVisible(size);
        }
        const ds = self.scroll;
        const text = self.buf.items;

        var line_buf: [512]u8 = undefined;
        var row: u16 = 0;
        while (row < footer_h) : (row += 1) {
            const y: u16 = footer_top + row;
            Frame.fillRow(scr, y, footer_style);
            const vline = ds + row;
            const piece = comment_input.writeVisualLine(&line_buf, text, m.text_w, vline);
            // Prefix + text start at column 1 (one-cell left gutter).
            scr.putStr(1, y, piece, footer_style, 0, null);
        }

        // Right pad is always reserved (text_w stable). Scrollbar uses the
        // rightmost column of that pad when needed; the pad column left of
        // it stays empty so wrap does not reflow when the bar appears.
        if (m.show_scrollbar and size.cols > 0) {
            const bar_x: u16 = size.cols - 1;
            const thumb = tui.scrollbarThumb(
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

        const caret_byte = @min(self.caret, text.len);
        const caret = comment_input.cursorAt(text, m.text_w, ds, m.height, caret_byte);
        const max_x: u16 = if (size.cols == 0) 0 else size.cols - 1;
        const cx: u16 = @min(caret.x, max_x);
        const cy: u16 = footer_top + caret.y_off;
        scr.setCursor(cx, cy);
    }
};

/// `/` text search: prompt, committed query for `n`/`N`, keys, and footer paint.
const Search = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        jump: view.row.Hit,
        missing,
    };

    const Match = union(enum) {
        none,
        missing,
        hit: view.row.Hit,
    };

    buf: std.ArrayList(u8) = .empty,
    caret: usize = 0,
    last_query: std.ArrayList(u8) = .empty,

    fn begin(self: *Search) void {
        self.buf.clearRetainingCapacity();
        self.caret = 0;
    }

    fn handleKey(
        self: *Search,
        alloc: std.mem.Allocator,
        key: tui.Key,
        rows: []const view.row.Row,
        cursor: usize,
    ) std.mem.Allocator.Error!Result {
        switch (key) {
            .esc => {
                self.buf.clearRetainingCapacity();
                self.caret = 0;
                return .closed;
            },
            .enter => {
                if (self.buf.items.len == 0) {
                    self.caret = 0;
                    return .closed;
                }
                self.last_query.clearRetainingCapacity();
                try self.last_query.appendSlice(alloc, self.buf.items);
                self.buf.clearRetainingCapacity();
                self.caret = 0;
                if (view.search.firstMatch(rows, self.last_query.items, cursor)) |hit| {
                    return .{ .jump = hit };
                }
                return .missing;
            },
            .backspace => {
                if (self.caret > 0) {
                    self.caret -= 1;
                    _ = self.buf.orderedRemove(self.caret);
                }
            },
            .char => |c| {
                if (c >= 0x20 and c < 0x7f) {
                    try self.buf.insert(alloc, self.caret, @intCast(c));
                    self.caret += 1;
                }
            },
            .left => {
                if (self.caret > 0) self.caret -= 1;
            },
            .right => {
                if (self.caret < self.buf.items.len) self.caret += 1;
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn next(self: *const Search, rows: []const view.row.Row, cursor: usize) Match {
        if (self.last_query.items.len == 0) return .none;
        if (view.search.nextMatch(rows, self.last_query.items, cursor)) |hit| return .{ .hit = hit };
        return .missing;
    }

    fn prev(self: *const Search, rows: []const view.row.Row, cursor: usize) Match {
        if (self.last_query.items.len == 0) return .none;
        if (view.search.prevMatch(rows, self.last_query.items, cursor)) |hit| return .{ .hit = hit };
        return .missing;
    }

    fn paintFooter(self: *const Search, scr: *tui.Screen, size: tui.Size) void {
        if (size.rows < 2) return;
        const footer_style = tui.Style{
            .fg = .{ .rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee } },
            .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x3f, .b = 0x5f } },
        };
        const footer_y = size.rows - 1;
        Frame.fillRow(scr, footer_y, footer_style);
        var line_buf: [512]u8 = undefined;
        const caret_byte = @min(self.caret, self.buf.items.len);
        const prompt = Frame.bufPrintTrunc(&line_buf, "/{s}", .{self.buf.items});
        scr.putStr(1, footer_y, prompt, footer_style, 0, null);
        const max_x: u16 = if (size.cols == 0) 0 else size.cols - 1;
        const raw_x: usize = 2 + caret_byte;
        const cx: u16 = if (raw_x > max_x) max_x else @intCast(raw_x);
        scr.setCursor(cx, footer_y);
    }
};

const StatusNote = Frame.StatusNote;

/// Session viewport: cursor, scroll, pan, layout preference, and motion keys.
pub const Viewport = struct {
    const Result = enum { handled, unhandled };

    const HunkPan = view.window.Pan;
    const hunk_pan_cap = 48;

    cursor: usize = 0,
    scroll: usize = 0,
    /// First visible display column of the cursor's hunk.
    /// Other hunks keep their own column in `hunk_pans`.
    col_scroll: usize = 0,
    /// Prefer side-by-side; auto-unified when narrow. `t` flips session preference.
    layout_pref: view.layout.LayoutPref = .side_by_side,
    /// Line numbers in the body gutter. `#` flips. Default on.
    show_line_numbers: bool = true,
    /// Wrap diff body lines to the pane. `w` flips. Default off (truncate + pan).
    wrap: bool = false,
    /// Wheel moved the window without moving the cursor. `settle` then clamps
    /// the window and leaves the selected line where it is.
    window_moved: bool = false,
    /// Last settle. A cursor, layout, or wrap change clears `window_moved`
    /// so the window follows the selected line again.
    settled_cursor: usize = 0,
    settled_layout: view.layout.EffectiveLayout = .side_by_side,
    settled_wrap: bool = false,
    /// Header of the hunk whose pan is `col_scroll`, after the last settle.
    /// Null when the cursor is not in a hunk, or before the first settle.
    settled_hunk: ?usize = null,
    /// False until settle has recorded `settled_hunk` for the current rows.
    /// The first settle keeps a `col_scroll` set before it.
    pan_settled: bool = false,
    /// Column pans for hunks other than the cursor's, keyed by header index.
    /// Valid only for the row slice settle last saw. A column of 0 is omitted.
    hunk_pans: [hunk_pan_cap]HunkPan = @splat(.{}),
    hunk_pan_n: usize = 0,
    rows_ptr: usize = 0,
    rows_len: usize = 0,
    rows_seen: bool = false,

    /// Columns available for horizontal pan of the file at `at`: text area after the gutter.
    fn panViewportCols(self: *const Viewport, cols: u16, rows: []const view.row.Row, at: usize) u16 {
        const layout = view.layout.effectiveLayout(self.layout_pref, cols);
        const one_sided_file = if (view.nav.currentFileStart(rows, at)) |fi| switch (rows[fi]) {
            .file_header => |fh| fh.old_path == null or fh.new_path == null,
            else => false,
        } else false;
        // Same rule as pairing: an add-only or delete-only hunk is full width.
        const one_kind_hunk = if (view.nav.currentHunkInFile(rows, at)) |header|
            view.layout.addOnlyOrDeleteOnly(rows, header + 1)
        else
            false;
        const full_body = one_sided_file or one_kind_hunk;
        const full: u16 = switch (layout) {
            .unified => cols,
            .side_by_side => if (full_body) cols else view.layout.sbsPaneWidths(cols).left_w,
        };
        const num_w = if (self.show_line_numbers) view.row.lineNumberWidth(rows) else 0;
        const gw_layout: view.layout.EffectiveLayout = if (full_body) .unified else layout;
        const gw = view.layout.lineGutterCols(num_w, gw_layout);
        const gw_u16: u16 = std.math.cast(u16, gw) orelse std.math.maxInt(u16);
        return full -| gw_u16;
    }

    /// Horizontal pan step: about a quarter of the pan viewport (at least 1).
    fn panStep(cols: u16) usize {
        if (cols == 0) return 1;
        return @max(1, cols / 4);
    }

    /// One step down: unified row in unified layout; next SBS slot in side-by-side.
    fn moveLineDown(self: *Viewport, cols: u16, rows: []const view.row.Row, slots: []const view.layout.SbsSlot) void {
        self.cursor = switch (view.layout.effectiveLayout(self.layout_pref, cols)) {
            .unified => if (self.cursor + 1 < rows.len) self.cursor + 1 else self.cursor,
            .side_by_side => view.layout.nextSbsCursor(slots, rows, self.cursor),
        };
    }

    /// One step up: unified row in unified layout; previous SBS slot in side-by-side.
    fn moveLineUp(self: *Viewport, cols: u16, rows: []const view.row.Row, slots: []const view.layout.SbsSlot) void {
        self.cursor = switch (view.layout.effectiveLayout(self.layout_pref, cols)) {
            .unified => if (self.cursor > 0) self.cursor - 1 else self.cursor,
            .side_by_side => view.layout.prevSbsCursor(slots, rows, self.cursor),
        };
    }

    fn panLeft(self: *Viewport, cols: u16, rows: []const view.row.Row) void {
        const step = panStep(self.panViewportCols(cols, rows, self.cursor));
        self.col_scroll = if (self.col_scroll > step) self.col_scroll - step else 0;
    }

    /// Column pan stored for `header`, or 0 when that hunk has not been panned.
    fn storedPan(self: *const Viewport, header: usize) usize {
        for (self.hunk_pans[0..self.hunk_pan_n]) |pan| {
            if (pan.header == header) return pan.col;
        }
        return 0;
    }

    fn removePan(self: *Viewport, index: usize) void {
        var j = index;
        while (j + 1 < self.hunk_pan_n) : (j += 1) {
            self.hunk_pans[j] = self.hunk_pans[j + 1];
        }
        self.hunk_pan_n -= 1;
    }

    /// Remember `col` for `header`. A column of 0 drops the entry.
    fn storePan(self: *Viewport, header: usize, col: usize) void {
        var i: usize = 0;
        while (i < self.hunk_pan_n) : (i += 1) {
            if (self.hunk_pans[i].header != header) continue;
            if (col == 0) {
                self.removePan(i);
            } else {
                self.hunk_pans[i].col = col;
            }
            return;
        }
        if (col == 0) return;
        if (self.hunk_pan_n == self.hunk_pans.len) self.removePan(0);
        self.hunk_pans[self.hunk_pan_n] = .{ .header = header, .col = col };
        self.hunk_pan_n += 1;
    }

    /// Take and forget the stored pan for `header` (0 when none).
    fn takePan(self: *Viewport, header: usize) usize {
        var i: usize = 0;
        while (i < self.hunk_pan_n) : (i += 1) {
            if (self.hunk_pans[i].header != header) continue;
            const col = self.hunk_pans[i].col;
            self.removePan(i);
            return col;
        }
        return 0;
    }

    fn clampStoredPans(self: *Viewport, cols: u16, rows: []const view.row.Row) void {
        var i: usize = 0;
        while (i < self.hunk_pan_n) {
            const header = self.hunk_pans[i].header;
            if (header >= rows.len or rows[header] != .hunk_header) {
                self.removePan(i);
                continue;
            }
            const span = view.window.hunkSpanAt(rows, header);
            const col = view.window.clampColScroll(
                self.hunk_pans[i].col,
                view.row.hunkMaxLineWidth(rows, span.body_start, span.body_end),
                self.panViewportCols(cols, rows, header),
            );
            if (col == 0) {
                self.removePan(i);
                continue;
            }
            self.hunk_pans[i].col = col;
            i += 1;
        }
    }

    /// Display row under the pointer, using the same heights paint uses.
    fn rowUnderPointer(self: *const Viewport, target: WheelTarget) ?usize {
        const layout = view.layout.effectiveLayout(self.layout_pref, target.cols);
        const num_w = if (self.show_line_numbers) view.row.lineNumberWidth(target.rows) else 0;
        const panes = view.layout.sbsPaneWidths(target.cols);
        return view.window.rowAtY(.{
            .y = target.y,
            .top = target.area_top,
            .bottom = target.area_bottom,
            .scroll = self.scroll,
            .wrap_on = self.wrap,
            .full_tw = view.layout.bodyTextCols(target.cols, num_w, .unified),
            .left_tw = view.layout.bodyTextCols(panes.left_w, num_w, .side_by_side),
            .right_tw = view.layout.bodyTextCols(panes.right_w, num_w, .side_by_side),
            .layout = layout,
        }, target.rows, target.slots);
    }

    /// One wheel event: one row, or one column of the hunk under the pointer.
    /// A null target pans the cursor's hunk. Wrap leaves horizontal pan unchanged.
    /// The terminal decides how many events a gesture produces.
    fn scrollWheel(self: *Viewport, wheel: Wheel, target: ?WheelTarget) void {
        switch (wheel) {
            .up => {
                self.scroll -|= 1;
                self.window_moved = true;
            },
            .down => {
                self.scroll +|= 1;
                self.window_moved = true;
            },
            .left, .right => self.panWheel(wheel == .left, target),
        }
    }

    /// Move one hunk's column by one. The pointer's hunk wins; with no pointer,
    /// or when that hunk is the cursor's, the column is `col_scroll`.
    fn panWheel(self: *Viewport, left: bool, target: ?WheelTarget) void {
        if (self.wrap) return;
        const hit = target orelse {
            if (left) self.col_scroll -|= 1 else self.col_scroll +|= 1;
            return;
        };
        const row_i = self.rowUnderPointer(hit) orelse return;
        const header = view.window.hunkSpanAt(hit.rows, row_i).header orelse return;
        const cursor_hunk = view.window.hunkSpanAt(hit.rows, self.cursor).header;
        if (cursor_hunk != null and cursor_hunk.? == header) {
            if (left) self.col_scroll -|= 1 else self.col_scroll +|= 1;
            return;
        }
        var col = self.storedPan(header);
        if (left) col -|= 1 else col +|= 1;
        self.storePan(header, col);
    }

    fn handleKey(
        self: *Viewport,
        key: tui.Key,
        cols: u16,
        rows: []const view.row.Row,
        slots: []const view.layout.SbsSlot,
    ) Result {
        switch (key) {
            .char => |c| switch (c) {
                'j' => self.moveLineDown(cols, rows, slots),
                'k' => self.moveLineUp(cols, rows, slots),
                'h' => if (!self.wrap) self.panLeft(cols, rows),
                'l' => if (!self.wrap) {
                    self.col_scroll +%= panStep(self.panViewportCols(cols, rows, self.cursor));
                },
                '0' => if (!self.wrap) {
                    self.col_scroll = 0;
                },
                '$' => if (!self.wrap) {
                    const span = view.window.hunkSpanAt(rows, self.cursor);
                    self.col_scroll = view.window.colScrollToEnd(
                        view.row.hunkMaxLineWidth(rows, span.body_start, span.body_end),
                        self.panViewportCols(cols, rows, self.cursor),
                    );
                },
                'J' => self.cursor = view.nav.nextChange(rows, self.cursor),
                'K' => self.cursor = view.nav.prevChange(rows, self.cursor),
                ']' => self.cursor = view.nav.nextHunkHeader(rows, self.cursor),
                '[' => self.cursor = view.nav.prevHunkHeader(rows, self.cursor),
                '}' => self.cursor = view.nav.nextFileHeader(rows, self.cursor),
                '{' => self.cursor = view.nav.prevFileHeader(rows, self.cursor),
                't' => self.layout_pref = view.layout.toggleLayoutPref(self.layout_pref),
                '#' => self.show_line_numbers = !self.show_line_numbers,
                'w' => self.wrap = !self.wrap,
                else => return .unhandled,
            },
            .down => self.moveLineDown(cols, rows, slots),
            .up => self.moveLineUp(cols, rows, slots),
            .left => if (!self.wrap) self.panLeft(cols, rows),
            .right => if (!self.wrap) {
                self.col_scroll +%= panStep(self.panViewportCols(cols, rows, self.cursor));
            },
            else => return .unhandled,
        }
        return .handled;
    }

    /// Clamp pan. A wheel scroll clamps the window and leaves the cursor on
    /// its row. Any other change pulls the window so the cursor stays visible.
    /// Paint reads the clamped scroll and derives the sticky file header.
    pub fn settle(
        self: *Viewport,
        cols: u16,
        content_rows: usize,
        rows: []const view.row.Row,
        slots: []const view.layout.SbsSlot,
    ) void {
        const cur = view.row.clampCursor(self.cursor, rows.len);
        const layout = view.layout.effectiveLayout(self.layout_pref, cols);
        if (cur != self.settled_cursor or layout != self.settled_layout or self.wrap != self.settled_wrap) {
            self.window_moved = false;
        }

        // Header indexes belong to one row slice. A new slice drops stored pans.
        const ptr = @intFromPtr(rows.ptr);
        if (self.rows_seen and (ptr != self.rows_ptr or rows.len != self.rows_len)) {
            self.hunk_pan_n = 0;
            self.settled_hunk = null;
            self.pan_settled = false;
            self.col_scroll = 0;
        }
        self.rows_seen = true;
        self.rows_ptr = ptr;
        self.rows_len = rows.len;

        // Moving into another hunk keeps each hunk's column. `col_scroll` is
        // always the cursor hunk's column, so keyboard pan stays on that field.
        const new_hunk = view.window.hunkSpanAt(rows, cur).header;
        if (self.pan_settled) {
            const same = if (self.settled_hunk) |old|
                if (new_hunk) |h| old == h else false
            else
                new_hunk == null;
            if (!same) {
                if (self.settled_hunk) |old| self.storePan(old, self.col_scroll);
                self.col_scroll = if (new_hunk) |h| self.takePan(h) else 0;
            }
        }
        self.settled_hunk = new_hunk;
        self.pan_settled = true;

        const pan_span = view.window.hunkSpanAt(rows, cur);
        self.col_scroll = view.window.clampColScroll(
            self.col_scroll,
            view.row.hunkMaxLineWidth(rows, pan_span.body_start, pan_span.body_end),
            self.panViewportCols(cols, rows, cur),
        );
        self.clampStoredPans(cols, rows);
        const num_w = if (self.show_line_numbers) view.row.lineNumberWidth(rows) else 0;
        if (self.window_moved) {
            self.scroll = switch (layout) {
                .unified => view.window.clampScrollSticky(
                    self.scroll,
                    content_rows,
                    rows,
                    self.wrap,
                    view.layout.bodyTextCols(cols, num_w, .unified),
                ),
                .side_by_side => blk: {
                    const panes = view.layout.sbsPaneWidths(cols);
                    break :blk view.window.clampScrollStickySbs(
                        self.scroll,
                        content_rows,
                        slots,
                        rows,
                        self.wrap,
                        view.layout.bodyTextCols(panes.left_w, num_w, .side_by_side),
                        view.layout.bodyTextCols(panes.right_w, num_w, .side_by_side),
                        view.layout.bodyTextCols(cols, num_w, .unified),
                    );
                },
            };
        } else switch (layout) {
            .unified => {
                const settled = view.window.ensureVisibleSticky(
                    self.scroll,
                    cur,
                    content_rows,
                    rows,
                    self.wrap,
                    view.layout.bodyTextCols(cols, num_w, .unified),
                );
                self.scroll = settled.scroll;
            },
            .side_by_side => {
                const panes = view.layout.sbsPaneWidths(cols);
                const settled = view.window.ensureVisibleStickySbs(
                    self.scroll,
                    cur,
                    content_rows,
                    slots,
                    rows,
                    self.wrap,
                    view.layout.bodyTextCols(panes.left_w, num_w, .side_by_side),
                    view.layout.bodyTextCols(panes.right_w, num_w, .side_by_side),
                    view.layout.bodyTextCols(cols, num_w, .unified),
                );
                self.scroll = settled.scroll;
            },
        }
        self.settled_cursor = cur;
        self.settled_layout = layout;
        self.settled_wrap = self.wrap;
    }
};

/// Vertical wheel scrolls. Shift+wheel and a sideways wheel pan.
const Wheel = enum { up, down, left, right };

/// Where the pointer is, so a sideways wheel pans that hunk.
const WheelTarget = struct {
    y: u16,
    cols: u16,
    rows: []const view.row.Row,
    slots: []const view.layout.SbsSlot,
    area_top: u16,
    area_bottom: u16,
};

fn wheelDirection(mouse: tui.Mouse) ?Wheel {
    if (mouse.action != .press) return null;
    return switch (mouse.button) {
        .wheel_up => if (mouse.shift) .left else .up,
        .wheel_down => if (mouse.shift) .right else .down,
        .wheel_left => .left,
        .wheel_right => .right,
        else => null,
    };
}

/// Cursor and window for an overlay list. `j`/`k` and the wheel share this.
const ListWin = struct {
    cursor: usize = 0,
    scroll: usize = 0,
    window_moved: bool = false,

    fn key(self: *ListWin, n: usize, k: tui.Key) void {
        self.window_moved = false;
        switch (k) {
            .char => |c| {
                if (c == 'j') {
                    if (self.cursor + 1 < n) self.cursor += 1;
                } else if (c == 'k') {
                    if (self.cursor > 0) self.cursor -= 1;
                }
            },
            .down => {
                if (self.cursor + 1 < n) self.cursor += 1;
            },
            .up => {
                if (self.cursor > 0) self.cursor -= 1;
            },
            else => {},
        }
    }

    fn wheel(self: *ListWin, dir: Wheel) void {
        switch (dir) {
            .up => self.scroll -|= 1,
            .down => self.scroll +|= 1,
            .left, .right => return,
        }
        self.window_moved = true;
    }

    /// A wheel scroll clamps the window. Any other paint pulls the selected row into view.
    fn place(self: *ListWin, view_h: usize, n: usize) void {
        if (n == 0 or view_h == 0) {
            self.scroll = 0;
            return;
        }
        if (!self.window_moved) {
            if (self.cursor < self.scroll) {
                self.scroll = self.cursor;
            } else if (self.cursor >= self.scroll + view_h) {
                self.scroll = self.cursor - view_h + 1;
            }
        }
        const max_scroll = if (n > view_h) n - view_h else 0;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
    }
};

fn rowEql(a: view.row.Row, b: view.row.Row) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .section_header => |g| return g == b.section_header,
        .file_header => |fh| {
            const other = b.file_header;
            return fh.group == other.group and std.mem.eql(u8, fh.path, other.path);
        },
        .hunk_header => |hh| {
            const other = b.hunk_header;
            return hh.group == other.group and hh.old_start == other.old_start and hh.new_start == other.new_start and
                std.mem.eql(u8, hh.path, other.path);
        },
        .line => |ln| {
            const other = b.line;
            return ln.kind == other.kind and ln.old_no == other.old_no and ln.new_no == other.new_no and
                std.mem.eql(u8, ln.path, other.path) and std.mem.eql(u8, ln.text, other.text);
        },
    }
}

/// Hidden flatten is a subsequence of the unfiltered flatten. Map a hidden
/// index onto that full list for comment next/prev.
fn fullIndexOfHidden(full: []const view.row.Row, hidden: []const view.row.Row, hidden_i: usize) usize {
    if (hidden.len == 0 or full.len == 0) return 0;
    const want = view.row.clampCursor(hidden_i, hidden.len);
    var h: usize = 0;
    for (full, 0..) |row, f| {
        if (h >= hidden.len) break;
        if (!rowEql(row, hidden[h])) continue;
        if (h == want) return f;
        h += 1;
    }
    return 0;
}

/// Land on `loc`. If that row is hidden because its hunk is approved, unapprove
/// one matching store entry, rebuild, then land. False when the path/line is
/// gone from the live diff (footer note) or save failed.
fn landComment(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    loc: view.row.DiffLoc,
) std.mem.Allocator.Error!bool {
    if (view.rowForComment(diff_view.rows, loc)) |row| {
        cursor.* = row;
        return true;
    }
    if (source != .local) {
        note.set("comment not in this diff");
        return false;
    }
    const full = view.row.flatten(alloc, &diff_view.diff) catch {
        note.set("out of memory");
        return false;
    };
    defer alloc.free(full);
    const full_row = view.rowForComment(full, loc) orelse {
        note.set("comment not in this diff");
        return false;
    };
    const item = identityAtRow(alloc, &diff_view.diff, io, .cwd(), full, full_row) orelse {
        note.set("comment not in this diff");
        return false;
    };
    if (!try unapproveRebuild(alloc, io, source, diff_view, note, .cwd(), item)) return false;
    const row = view.rowForComment(diff_view.rows, loc) orelse {
        note.set("comment not in this diff");
        return false;
    };
    cursor.* = row;
    return true;
}

fn jumpLiveComment(
    review: *const store.Review,
    diff_view: *OpenDiff,
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    cursor: *usize,
    note: *StatusNote,
    comptime toward: enum { next, prev },
) std.mem.Allocator.Error!void {
    var full_buf: ?[]view.row.Row = null;
    defer if (full_buf) |owned| alloc.free(owned);

    const walk_rows: []const view.row.Row = blk: {
        if (diff_view.approved_n == 0) break :blk diff_view.rows;
        const owned = view.row.flatten(alloc, &diff_view.diff) catch {
            note.set("out of memory");
            return;
        };
        full_buf = owned;
        break :blk owned;
    };

    const walk_cur = if (diff_view.approved_n == 0)
        cursor.*
    else
        fullIndexOfHidden(walk_rows, diff_view.rows, cursor.*);

    const hit = switch (toward) {
        .next => comments.next(review, walk_rows, walk_cur),
        .prev => comments.prev(review, walk_rows, walk_cur),
    } orelse {
        note.set("no comments");
        return;
    };
    const loc = view.row.locAt(walk_rows[hit.row]) orelse {
        note.set("no comments");
        return;
    };
    if (try landComment(alloc, io, source, diff_view, cursor, note, loc)) {
        if (hit.wrapped) note.set("comment wrapped");
    }
}

/// Dismiss the first live comment on `want` at `cursor`. Missing side or no
/// comment: footer note, store unchanged. Save failure puts the comment back.
fn dismissAt(
    review: *store.Review,
    alloc: std.mem.Allocator,
    io: std.Io,
    rows: []const view.row.Row,
    slots: []const view.layout.SbsSlot,
    layout: view.layout.EffectiveLayout,
    cursor: usize,
    want: view.row.CommentSide,
    note: *StatusNote,
) void {
    const found = comments.atSide(review, rows, slots, layout, cursor, want) orelse {
        note.set("no comment on this side");
        return;
    };
    const idx = found.idx orelse {
        switch (found.loc) {
            .file => note.set("no comment on this file"),
            .hunk => note.set("no comment on this hunk"),
            .line => note.set("no comment on this side"),
        }
        return;
    };
    _ = dismissById(review, alloc, io, review.comments.items[idx].id, note);
}

/// Delete `id` and save. True when the store dropped it. Not found: false,
/// store unchanged. Save failure puts the comment back and sets the note.
fn dismissById(
    review: *store.Review,
    alloc: std.mem.Allocator,
    io: std.Io,
    id: []const u8,
    note: *StatusNote,
) bool {
    const idx = blk: {
        for (review.comments.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.id, id)) break :blk i;
        }
        return false;
    };
    const saved = review.comments.items[idx];
    review.remove(&.{id}) catch return false;
    store.save(review, alloc, io, .cwd()) catch {
        review.comments.insert(review.arena.allocator(), idx, saved) catch {};
        note.set("failed to save .rv comment store");
        return false;
    };
    note.setFmt("deleted {s}", .{id});
    return true;
}

/// Comment list `d`/`D`: drop that store id, reload the overlay, keep the
/// cursor on a neighbor. Empty list: stay in the overlay. Failed save: list
/// unchanged.
fn applyListDismiss(
    alloc: std.mem.Allocator,
    io: std.Io,
    review: *store.Review,
    list: *CommentList,
    note: *StatusNote,
) std.mem.Allocator.Error!void {
    const idx = list.win.cursor;
    if (idx >= list.items.items.len) return;
    if (!dismissById(review, alloc, io, list.items.items[idx].id, note)) return;
    try list.load(alloc, review.comments.items);
    if (list.items.items.len > 0) {
        list.win.cursor = @min(idx, list.items.items.len - 1);
    }
}

/// File list `a`/`A`: approve remaining hunks of that file (same as `A` on
/// the header). Local only. Range: no-op. Unresolved comments open the existing
/// confirm and return here afterward. After a silent approve the overlay
/// stays open and refreshes; cursor stays on a neighbor.
fn applyListApprove(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: git.Origin,
    diff_view: *OpenDiff,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    git_error: *GitError,
    review: *store.Review,
    confirm: *Confirm,
    list: *FileList,
) std.mem.Allocator.Error!void {
    if (source != .local) return;
    const idx = list.win.cursor;
    if (idx >= list.items.items.len) return;
    cursor.* = list.items.items[idx];
    try dispatchApprove(alloc, io, source, diff_view, cursor, note, focus, git_error, review, confirm, true);
    if (focus.* == .confirm) {
        confirm.return_to_files = true;
        return;
    }
    if (focus.* == .git_error) return;
    try list.reload(alloc, diff_view.rows, idx);
}

/// Comment-list overlay (`Space` `c`): snapshot of live comments, cursor, keys, and paint.
const CommentList = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        help,
        jump: struct { row: usize, edit: bool },
        hidden: struct { loc: view.row.DiffLoc, edit: bool },
        missing,
        dismiss,
    };

    items: std.ArrayList(store.Comment) = .empty,
    win: ListWin = .{},

    fn load(
        self: *CommentList,
        alloc: std.mem.Allocator,
        live: []const store.Comment,
    ) std.mem.Allocator.Error!void {
        self.items.clearRetainingCapacity();
        try self.items.appendSlice(alloc, live);
        self.win = .{};
    }

    fn jumpResult(self: *const CommentList, rows: []const view.row.Row, edit: bool) Result {
        if (self.win.cursor >= self.items.items.len) return .open;
        const loc = comments.loc(self.items.items[self.win.cursor]) orelse return .missing;
        if (view.rowForComment(rows, loc)) |idx| return .{ .jump = .{ .row = idx, .edit = edit } };
        return .{ .hidden = .{ .loc = loc, .edit = edit } };
    }

    fn handleKey(self: *CommentList, key: tui.Key, rows: []const view.row.Row) Result {
        self.win.key(self.items.items.len, key);
        switch (key) {
            .esc => return .closed,
            .enter => return self.jumpResult(rows, false),
            .char => |c| {
                if (c == 'q' or c == 'Q') return .quit;
                if (c == '?') return .help;
                if (c == 'i' or c == 'I' or c == 'c' or c == 'C') return self.jumpResult(rows, true);
                if (c == 'd' or c == 'D') {
                    if (self.win.cursor >= self.items.items.len) return .open;
                    return .dismiss;
                }
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn formatLineCol(buf: []u8, c: store.Comment) []const u8 {
        const found = comments.loc(c) orelse return "-";
        return switch (found) {
            .hunk => |h| Frame.bufPrintTrunc(buf, "-{d},+{d}", .{ h.old_start, h.new_start }),
            .line => |l| switch (l.side) {
                .old => Frame.bufPrintTrunc(buf, "-{d}", .{l.line}),
                .new => Frame.bufPrintTrunc(buf, "+{d}", .{l.line}),
            },
            .file => "-",
        };
    }

    fn formatLine(buf: []u8, c: store.Comment) []const u8 {
        var line_col_buf: [32]u8 = undefined;
        const line_col = formatLineCol(&line_col_buf, c);
        const side: []const u8 = if (c.old_line == null and c.new_line == null)
            "file"
        else if (c.old_line != null and c.new_line != null and c.side == null)
            "hunk"
        else if (c.side) |s| switch (s) {
            .old => "old",
            .new => "new",
            .context => "ctx",
        } else "-";
        const prefix = Frame.bufPrintTrunc(buf, "{s}  {s}  {s}  {s}  {s}  ", .{
            c.id,
            if (c.source) |s| s.label() else "-",
            c.path,
            side,
            line_col,
        });
        var i: usize = 0;
        const rest = buf[prefix.len..];
        for (c.body) |b| {
            if (i >= rest.len) break;
            rest[i] = if (b == '\n' or b == '\r') ' ' else b;
            i += 1;
        }
        return buf[0 .. prefix.len + i];
    }

    fn paint(self: *CommentList, scr: *tui.Screen, size: tui.Size) void {
        const items = self.items.items;
        const panel = tui.Panel.overlay(size.cols, size.rows, items.len);
        panel.paint(scr, " comments ");
        const inner = panel.inner;
        self.win.place(inner.h, items.len);
        if (inner.h == 0 or inner.w == 0) return;
        if (items.len == 0) {
            scr.putStr(inner.x, inner.y, "no comments", tui.Panel.body, 0, inner);
            return;
        }
        const text_area = panel.text(items.len);
        const start = self.win.scroll;
        var line_buf: [512]u8 = undefined;
        var row: u16 = 0;
        while (row < inner.h) : (row += 1) {
            const idx = start + row;
            if (idx >= items.len) break;
            const y = inner.y + row;
            const st = if (idx == self.win.cursor) tui.Panel.row_cur else tui.Panel.body;
            scr.fillRect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, ' ', st);
            const text = formatLine(&line_buf, items[idx]);
            scr.putStr(inner.x, y, text, st, 0, text_area);
        }
        panel.paintBar(scr, items.len, start);
    }
};

/// File-list overlay (`Space` `f`): snapshot of file-header rows, cursor, keys, and paint.
const FileList = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        help,
        jump: usize,
        approve,
    };

    items: std.ArrayList(usize) = .empty,
    win: ListWin = .{},

    fn load(
        self: *FileList,
        alloc: std.mem.Allocator,
        rows: []const view.row.Row,
        current_file: ?usize,
    ) std.mem.Allocator.Error!void {
        self.items.clearRetainingCapacity();
        for (rows, 0..) |row, i| {
            if (row == .file_header) try self.items.append(alloc, i);
        }
        self.win = .{};
        if (current_file) |start| {
            for (self.items.items, 0..) |idx, n| {
                if (idx == start) {
                    self.win.cursor = n;
                    break;
                }
            }
        }
    }

    fn reload(self: *FileList, alloc: std.mem.Allocator, rows: []const view.row.Row, keep: usize) std.mem.Allocator.Error!void {
        try self.load(alloc, rows, null);
        if (self.items.items.len > 0) {
            self.win.cursor = @min(keep, self.items.items.len - 1);
        }
    }

    fn handleKey(self: *FileList, key: tui.Key) Result {
        self.win.key(self.items.items.len, key);
        switch (key) {
            .esc => return .closed,
            .enter => {
                if (self.win.cursor < self.items.items.len) return .{ .jump = self.items.items[self.win.cursor] };
            },
            .char => |c| {
                if (c == 'q' or c == 'Q') return .quit;
                if (c == '?') return .help;
                if (c == 'a' or c == 'A') {
                    if (self.win.cursor >= self.items.items.len) return .open;
                    return .approve;
                }
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn paint(self: *FileList, scr: *tui.Screen, size: tui.Size, rows: []const view.row.Row) void {
        const items = self.items.items;
        const panel = tui.Panel.overlay(size.cols, size.rows, items.len);
        panel.paint(scr, " files ");
        const inner = panel.inner;
        self.win.place(inner.h, items.len);
        if (inner.h == 0 or inner.w == 0) return;
        if (items.len == 0) {
            scr.putStr(inner.x, inner.y, "no files", tui.Panel.body, 0, inner);
            return;
        }
        const text_area = panel.text(items.len);
        const start = self.win.scroll;
        var path_buf: [512]u8 = undefined;
        var row: u16 = 0;
        while (row < inner.h) : (row += 1) {
            const idx = start + row;
            if (idx >= items.len) break;
            const y = inner.y + row;
            const st = if (idx == self.win.cursor) tui.Panel.row_cur else tui.Panel.body;
            scr.fillRect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, ' ', st);
            const path = view.row.fileHeaderPathLabel(rows[items[idx]].file_header, &path_buf);
            scr.putStr(inner.x, y, path, st, 0, text_area);
        }
        panel.paintBar(scr, items.len, start);
    }
};

/// Approved-list overlay (`Space` `a`): snapshot of live approved identities,
/// cursor, keys, and paint. Enter unapproves one matching store entry.
const ApprovedList = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        help,
        unapprove: usize,
    };

    items: std.ArrayList(approve.Hidden) = .empty,
    win: ListWin = .{},

    fn load(
        self: *ApprovedList,
        alloc: std.mem.Allocator,
        io: std.Io,
        d: *const diff.Diff,
        rows: []const view.row.Row,
        cursor: usize,
    ) approve.LoadError!void {
        self.items.clearRetainingCapacity();
        var approved = try approve.load(alloc, io, .cwd());
        defer approved.deinit();
        const hidden = try approve.collectApproved(alloc, io, .cwd(), d, &approved);
        defer alloc.free(hidden);
        try self.items.appendSlice(alloc, hidden);
        self.win = .{};
        if (rows.len == 0) return;
        const cur = view.row.clampCursor(cursor, rows.len);
        if (rows[cur] == .section_header) return;
        const start = view.nav.currentFileStart(rows, cur) orelse return;
        const fh = rows[start].file_header;
        for (self.items.items, 0..) |item, n| {
            if (!std.mem.eql(u8, item.path, fh.path)) continue;
            if (item.group != fh.group) continue;
            self.win.cursor = n;
            break;
        }
    }

    fn handleKey(self: *ApprovedList, key: tui.Key) Result {
        self.win.key(self.items.items.len, key);
        switch (key) {
            .esc => return .closed,
            .enter => {
                if (self.win.cursor < self.items.items.len) return .{ .unapprove = self.win.cursor };
            },
            .char => |c| {
                if (c == 'q' or c == 'Q') return .quit;
                if (c == '?') return .help;
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn formatLine(buf: []u8, item: approve.Hidden) []const u8 {
        const prefix = Frame.bufPrintTrunc(buf, "{s}  {s}  ", .{ item.path, item.groupLabel() });
        const preview = item.previewText();
        var i: usize = 0;
        const rest = buf[prefix.len..];
        for (preview) |b| {
            if (i >= rest.len) break;
            rest[i] = if (b == '\n' or b == '\r') ' ' else b;
            i += 1;
        }
        return buf[0 .. prefix.len + i];
    }

    fn paint(self: *ApprovedList, scr: *tui.Screen, size: tui.Size) void {
        const items = self.items.items;
        const panel = tui.Panel.overlay(size.cols, size.rows, items.len);
        panel.paint(scr, " approved ");
        const inner = panel.inner;
        self.win.place(inner.h, items.len);
        if (inner.h == 0 or inner.w == 0) return;
        if (items.len == 0) {
            scr.putStr(inner.x, inner.y, "no approved", tui.Panel.body, 0, inner);
            return;
        }
        const text_area = panel.text(items.len);
        const start = self.win.scroll;
        var line_buf: [512]u8 = undefined;
        var row: u16 = 0;
        while (row < inner.h) : (row += 1) {
            const idx = start + row;
            if (idx >= items.len) break;
            const y = inner.y + row;
            const st = if (idx == self.win.cursor) tui.Panel.row_cur else tui.Panel.body;
            scr.fillRect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, ' ', st);
            const text = formatLine(&line_buf, items[idx]);
            scr.putStr(inner.x, y, text, st, 0, text_area);
        }
        panel.paintBar(scr, items.len, start);
    }
};

/// Dismissible git-error overlay: stderr text, keys, and paint.
const GitError = struct {
    const Result = enum { open, closed, quit };

    buf: std.ArrayList(u8) = .empty,

    fn handleKey(self: *GitError, key: tui.Key) Result {
        switch (key) {
            .esc, .enter => {
                self.buf.clearRetainingCapacity();
                return .closed;
            },
            .char => |c| {
                if (c == 'q' or c == 'Q') return .quit;
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn paint(self: *const GitError, scr: *tui.Screen, size: tui.Size) void {
        const text = self.buf.items;
        var n: usize = 0;
        var count_it = std.mem.splitScalar(u8, text, '\n');
        while (count_it.next()) |_| n += 1;

        const panel = tui.Panel.overlay(size.cols, size.rows, n);
        panel.paint(scr, " error ");
        const inner = panel.inner;
        if (inner.h == 0 or inner.w == 0) return;
        var row: u16 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (row >= inner.h) break;
            scr.putStr(inner.x, inner.y + row, line, tui.Panel.body, 0, inner);
            row += 1;
        }
    }
};

test "empty footer local approved is not a clean worktree" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("HEAD · empty", emptyFooterLabel(&buf, .local, 0));
    try std.testing.expectEqualStrings("HEAD · 2 approved", emptyFooterLabel(&buf, .local, 2));
    try std.testing.expectEqualStrings(
        "main...HEAD",
        emptyFooterLabel(&buf, .{ .range = "main...HEAD" }, 3),
    );
    try std.testing.expectEqualStrings(
        "abc123",
        emptyFooterLabel(&buf, .{ .commit = "abc123" }, 3),
    );
}

test "stageHintForRow section has no git hint" {
    const unstaged = Frame.RowHints{ .section = 0, .group = .unstaged };
    const untracked = Frame.RowHints{ .section = 0, .group = .untracked };
    const staged = Frame.RowHints{ .section = 0, .group = .staged };
    try std.testing.expectEqualStrings("", unstaged.stageAt(0));
    try std.testing.expectEqualStrings("", untracked.stageAt(0));
    try std.testing.expectEqualStrings("", staged.stageAt(0));
    try std.testing.expectEqualStrings("", unstaged.stageAt(1));
    const no_section = Frame.RowHints{ .group = .unstaged };
    try std.testing.expectEqualStrings("", no_section.stageAt(0));
}

test "approve confirm titleBar" {
    const c: Confirm = .{ .kind = .approve };
    try std.testing.expectEqualStrings(
        "rv  approve  No/yes  Enter  Esc cancel  q quit",
        c.titleBar(),
    );
}

test "draft titleBar file vs line" {
    var draft: Draft = .{};
    draft.loc = .{ .file = "f" };
    try std.testing.expectEqualStrings(
        "rv  create/edit file  Enter save  Esc cancel  ↑↓ scroll",
        draft.titleBar(),
    );
    draft.loc = .{ .hunk = .{ .path = "f", .old_start = 1, .new_start = 1 } };
    try std.testing.expectEqualStrings(
        "rv  create/edit hunk  Enter save  Esc cancel  ↑↓ scroll",
        draft.titleBar(),
    );
    draft.loc = .{ .line = .{ .path = "f", .side = .new, .line = 1 } };
    try std.testing.expectEqualStrings(
        "rv  create/edit new  Enter save  Esc cancel  ↑↓ scroll",
        draft.titleBar(),
    );
    draft.loc = .{ .line = .{ .path = "f", .side = .old, .line = 1 } };
    try std.testing.expectEqualStrings(
        "rv  create/edit old  Enter save  Esc cancel  ↑↓ scroll",
        draft.titleBar(),
    );
}

test "comment list file row has no line" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "1  -  a.zig  file  -  note",
        CommentList.formatLine(&buf, .{ .id = "1", .path = "a.zig", .body = "note" }),
    );
    try std.testing.expectEqualStrings(
        "2  -  a.zig  new  +10  x",
        CommentList.formatLine(&buf, .{
            .id = "2",
            .path = "a.zig",
            .new_line = 10,
            .side = .new,
            .body = "x",
        }),
    );
    try std.testing.expectEqualStrings(
        "3  -  a.zig  hunk  -1,+2  h",
        CommentList.formatLine(&buf, .{
            .id = "3",
            .path = "a.zig",
            .old_line = 1,
            .new_line = 2,
            .body = "h",
        }),
    );
    try std.testing.expectEqualStrings(
        "4  abc123  a.zig  new  +1  n",
        CommentList.formatLine(&buf, .{
            .id = "4",
            .path = "a.zig",
            .new_line = 1,
            .side = .new,
            .body = "n",
            .source = .{ .commit = "abc123" },
        }),
    );
}

test "approved list row shows path group preview" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "a.zig  Unstaged  hello",
        ApprovedList.formatLine(&buf, .{
            .path = "a.zig",
            .hash = @splat(0),
            .group = .unstaged,
            .kind = .hunk,
            .preview = "hello",
        }),
    );
    try std.testing.expectEqualStrings(
        "bin.dat  Staged  binary",
        ApprovedList.formatLine(&buf, .{
            .path = "bin.dat",
            .hash = @splat(0),
            .group = .staged,
            .kind = .binary,
            .preview = "",
        }),
    );
}

test "approved list row truncates a long preview" {
    var buf: [24]u8 = undefined;
    const line = ApprovedList.formatLine(&buf, .{
        .path = "a",
        .hash = @splat(0),
        .group = .unstaged,
        .kind = .hunk,
        .preview = "this preview is definitely too long for the buffer",
    });
    try std.testing.expectEqualStrings("a  Unstaged  this previe", line);
}

test "draft begin on file and hunk header" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(std.testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    const empty: []const view.layout.SbsSlot = &.{};

    var review = try store.initEmpty(std.testing.allocator, "t");
    defer review.deinit();
    var draft: Draft = .{};
    defer draft.buf.deinit(std.testing.allocator);

    try std.testing.expect(try draft.begin(&review, std.testing.allocator, rows, empty, .unified, 0, .new));
    try std.testing.expectEqualStrings("f", draft.loc.file);
    try std.testing.expect(draft.edit_id == null);

    try std.testing.expect(try draft.begin(&review, std.testing.allocator, rows, empty, .unified, 1, .new));
    try std.testing.expectEqualStrings("f", draft.loc.hunk.path);
    try std.testing.expectEqual(1, draft.loc.hunk.old_start);
    try std.testing.expectEqual(1, draft.loc.hunk.new_start);
    try std.testing.expect(draft.edit_id == null);

    try std.testing.expect(try draft.begin(&review, std.testing.allocator, rows, empty, .unified, 1, .old));
    try std.testing.expectEqual(1, draft.loc.hunk.old_start);
    try std.testing.expectEqual(1, draft.loc.hunk.new_start);
    try std.testing.expect(draft.edit_id == null);

    _ = try review.addOpen("f", null, null, null, "hello", .local);
    try std.testing.expect(try draft.begin(&review, std.testing.allocator, rows, empty, .unified, 0, .old));
    try std.testing.expectEqualStrings("hello", draft.buf.items);
    try std.testing.expect(draft.edit_id != null);

    _ = try review.addOpen("f", null, 1, .new, "line", .local);
    _ = try review.addOpen("f", 1, 1, null, "hunk body", .local);
    try std.testing.expect(try draft.begin(&review, std.testing.allocator, rows, empty, .unified, 1, .new));
    try std.testing.expectEqualStrings("hunk body", draft.buf.items);
    try std.testing.expect(draft.edit_id != null);
    try std.testing.expect(try draft.begin(&review, std.testing.allocator, rows, empty, .unified, 1, .old));
    try std.testing.expectEqualStrings("hunk body", draft.buf.items);
}

test "hash key toggles line numbers" {
    var vp: Viewport = .{};
    const rows: []const view.row.Row = &.{};
    const slots: []const view.layout.SbsSlot = &.{};
    try std.testing.expect(vp.show_line_numbers);
    try std.testing.expectEqual(.handled, vp.handleKey(.{ .char = '#' }, 80, rows, slots));
    try std.testing.expect(!vp.show_line_numbers);
    try std.testing.expectEqual(.handled, vp.handleKey(.{ .char = '#' }, 80, rows, slots));
    try std.testing.expect(vp.show_line_numbers);
}

test "w key toggles wrap and pan is a no-op while wrap is on" {
    var vp: Viewport = .{};
    const rows: []const view.row.Row = &.{};
    const slots: []const view.layout.SbsSlot = &.{};
    try std.testing.expect(!vp.wrap);
    try std.testing.expectEqual(.handled, vp.handleKey(.{ .char = 'w' }, 80, rows, slots));
    try std.testing.expect(vp.wrap);
    vp.col_scroll = 4;
    try std.testing.expectEqual(.handled, vp.handleKey(.{ .char = 'l' }, 80, rows, slots));
    try std.testing.expectEqual(.handled, vp.handleKey(.{ .char = 'h' }, 80, rows, slots));
    try std.testing.expectEqual(.handled, vp.handleKey(.{ .char = '0' }, 80, rows, slots));
    try std.testing.expectEqual(.handled, vp.handleKey(.{ .char = '$' }, 80, rows, slots));
    try std.testing.expectEqual(.handled, vp.handleKey(.right, 80, rows, slots));
    try std.testing.expectEqual(.handled, vp.handleKey(.left, 80, rows, slots));
    try std.testing.expectEqual(4, vp.col_scroll);
    try std.testing.expectEqual(.handled, vp.handleKey(.{ .char = 'w' }, 80, rows, slots));
    try std.testing.expect(!vp.wrap);
}

test "pan viewport uses 2-char gutter when line numbers are off" {
    var vp: Viewport = .{ .layout_pref = .unified };
    const rows: []const view.row.Row = &.{};
    const on = vp.panViewportCols(80, rows, vp.cursor);
    vp.show_line_numbers = false;
    const off = vp.panViewportCols(80, rows, vp.cursor);
    try std.testing.expectEqual(74, on);
    try std.testing.expectEqual(78, off);
}

test "pan viewport one-sided side-by-side uses full width" {
    const added =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d = try diff.parse(std.testing.allocator, added);
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    const cols: u16 = 80;
    var sbs: Viewport = .{ .layout_pref = .side_by_side, .cursor = 2 };
    var uni: Viewport = .{ .layout_pref = .unified, .cursor = 2 };
    try std.testing.expectEqual(uni.panViewportCols(cols, rows, uni.cursor), sbs.panViewportCols(cols, rows, sbs.cursor));

    const mixed =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d2 = try diff.parse(std.testing.allocator, mixed);
    defer d2.deinit();
    const rows2 = try view.row.flatten(std.testing.allocator, &d2);
    defer std.testing.allocator.free(rows2);
    sbs = .{ .layout_pref = .side_by_side, .cursor = 2 };
    uni = .{ .layout_pref = .unified, .cursor = 2 };
    const mixed_sbs = sbs.panViewportCols(cols, rows2, sbs.cursor);
    const mixed_uni = uni.panViewportCols(cols, rows2, uni.cursor);
    try std.testing.expect(mixed_sbs < mixed_uni);
    const left: usize = view.layout.sbsPaneWidths(cols).left_w;
    const gw = view.layout.lineGutterCols(view.row.lineNumberWidth(rows2), .side_by_side);
    const expected: usize = left - gw;
    const got: usize = mixed_sbs;
    try std.testing.expectEqual(expected, got);
}

test "pan viewport add-only and delete-only hunks use full width" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1,2 @@
        \\ keep
        \\+added
        \\@@ -10,2 +11,2 @@
        \\-old
        \\+new
        \\@@ -20 +20,0 @@
        \\-gone
    ;
    var d = try diff.parse(std.testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    const cols: u16 = 80;
    // 0 file, 1 hunk, 2 ctx, 3 add, 4 hunk, 5 del, 6 add, 7 hunk, 8 del
    var sbs: Viewport = .{ .layout_pref = .side_by_side };
    var uni: Viewport = .{ .layout_pref = .unified };
    for ([_]usize{ 1, 2, 3, 7, 8 }) |at| {
        try std.testing.expectEqual(uni.panViewportCols(cols, rows, at), sbs.panViewportCols(cols, rows, at));
    }
    const paired = sbs.panViewportCols(cols, rows, 5);
    const paired_uni = uni.panViewportCols(cols, rows, 5);
    try std.testing.expect(paired < paired_uni);
    try std.testing.expectEqual(sbs.panViewportCols(cols, rows, 4), paired);
    try std.testing.expectEqual(sbs.panViewportCols(cols, rows, 6), paired);
}

test "wheel scrolls the window and leaves the selected line" {
    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1,12 +1,12 @@
        \\ line1
        \\ line2
        \\ line3
        \\ line4
        \\ line5
        \\ line6
        \\ line7
        \\ line8
        \\ line9
        \\ line10
        \\ line11
        \\ line12
    ;
    var d = try diff.parse(std.testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    const slots = try view.layout.pairSideBySide(std.testing.allocator, rows);
    defer std.testing.allocator.free(slots);

    var vp: Viewport = .{ .layout_pref = .unified, .cursor = 2 };
    vp.settle(80, 4, rows, slots);
    vp.scrollWheel(.down, null);
    vp.scrollWheel(.down, null);
    vp.scrollWheel(.down, null);
    try std.testing.expectEqual(2, vp.cursor);
    vp.settle(80, 4, rows, slots);
    try std.testing.expectEqual(3, vp.scroll);
    try std.testing.expect(vp.window_moved);
    try std.testing.expectEqual(2, vp.cursor);
    vp.settle(80, 4, rows, slots);
    try std.testing.expectEqual(3, vp.scroll);

    vp.cursor = 0;
    vp.settle(80, 4, rows, slots);
    try std.testing.expect(!vp.window_moved);
    try std.testing.expectEqual(0, vp.scroll);
    try std.testing.expectEqual(0, vp.cursor);

    var sbs: Viewport = .{ .cursor = 2 };
    sbs.settle(80, 4, rows, slots);
    const before = sbs.scroll;
    sbs.scrollWheel(.down, null);
    sbs.settle(80, 4, rows, slots);
    try std.testing.expectEqual(2, sbs.cursor);
    try std.testing.expect(sbs.window_moved);
    try std.testing.expectEqual(before + 1, sbs.scroll);
}

test "sideways wheel pans the hunk and leaves the selected line" {
    var long_line: [180]u8 = undefined;
    @memset(&long_line, 'x');
    var buf: [512]u8 = undefined;
    const fixture = try std.fmt.bufPrint(&buf, "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-{s}\n+{s}\n", .{
        long_line,
        long_line,
    });
    var d = try diff.parse(std.testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    const slots = try view.layout.pairSideBySide(std.testing.allocator, rows);
    defer std.testing.allocator.free(slots);

    var vp: Viewport = .{ .layout_pref = .unified, .cursor = 2 };
    vp.scrollWheel(.right, null);
    try std.testing.expectEqual(1, vp.col_scroll);
    try std.testing.expectEqual(2, vp.cursor);
    try std.testing.expect(!vp.window_moved);
    vp.settle(80, 10, rows, slots);
    try std.testing.expectEqual(1, vp.col_scroll);
    try std.testing.expectEqual(2, vp.cursor);

    vp.scrollWheel(.left, null);
    vp.settle(80, 10, rows, slots);
    try std.testing.expectEqual(0, vp.col_scroll);

    vp.wrap = true;
    vp.col_scroll = 4;
    vp.scrollWheel(.right, null);
    try std.testing.expectEqual(4, vp.col_scroll);
    try std.testing.expectEqual(2, vp.cursor);
}

test "sideways wheel pans the hunk under the pointer" {
    var long_line: [180]u8 = undefined;
    @memset(&long_line, 'x');
    var buf: [1024]u8 = undefined;
    const fixture = try std.fmt.bufPrint(&buf, "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-{s}\n+{s}\n@@ -2 +2 @@\n-{s}\n+{s}\n", .{
        long_line,
        long_line,
        long_line,
        long_line,
    });
    var d = try diff.parse(std.testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    const slots = try view.layout.pairSideBySide(std.testing.allocator, rows);
    defer std.testing.allocator.free(slots);

    // 0 file, 1 hunk, 2 del, 3 add, 4 hunk, 5 del, 6 add.
    // Content starts at screen row 1. Scroll is 0, so screen y = 1 + row.
    var vp: Viewport = .{ .layout_pref = .unified, .cursor = 2 };
    vp.settle(80, 20, rows, slots);
    const base = WheelTarget{
        .y = 3,
        .cols = 80,
        .rows = rows,
        .slots = slots,
        .area_top = 1,
        .area_bottom = 21,
    };

    var on_cursor = base;
    on_cursor.y = 3;
    vp.scrollWheel(.right, on_cursor);
    try std.testing.expectEqual(2, vp.cursor);
    try std.testing.expectEqual(1, vp.col_scroll);
    try std.testing.expectEqual(1, view.window.columnAt(rows, 2, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));

    var on_other = base;
    on_other.y = 6;
    vp.scrollWheel(.right, on_other);
    try std.testing.expectEqual(1, vp.col_scroll);
    try std.testing.expectEqual(1, view.window.columnAt(rows, 5, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));
    try std.testing.expectEqual(0, view.window.columnAt(rows, 4, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));
    vp.settle(80, 20, rows, slots);
    try std.testing.expectEqual(1, view.window.columnAt(rows, 5, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));
    try std.testing.expectEqual(1, vp.col_scroll);

    var on_file = base;
    on_file.y = 1;
    vp.scrollWheel(.right, on_file);
    try std.testing.expectEqual(1, vp.col_scroll);
    try std.testing.expectEqual(1, view.window.columnAt(rows, 5, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));

    var on_title = base;
    on_title.y = 0;
    vp.scrollWheel(.right, on_title);
    try std.testing.expectEqual(1, vp.col_scroll);

    var on_header = base;
    on_header.y = 5;
    vp.scrollWheel(.right, on_header);
    try std.testing.expectEqual(2, view.window.columnAt(rows, 5, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));
    try std.testing.expectEqual(1, vp.col_scroll);

    vp.wrap = true;
    vp.scrollWheel(.right, on_other);
    try std.testing.expectEqual(2, view.window.columnAt(rows, 5, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));
    vp.wrap = false;

    vp.cursor = 5;
    vp.settle(80, 20, rows, slots);
    try std.testing.expectEqual(2, vp.col_scroll);
    try std.testing.expectEqual(1, view.window.columnAt(rows, 2, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));
    vp.cursor = 2;
    vp.settle(80, 20, rows, slots);
    try std.testing.expectEqual(1, vp.col_scroll);
    try std.testing.expectEqual(2, view.window.columnAt(rows, 5, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));

    var sbs: Viewport = .{ .cursor = 2 };
    sbs.settle(80, 20, rows, slots);
    var on_sbs = base;
    on_sbs.y = 5;
    sbs.scrollWheel(.right, on_sbs);
    try std.testing.expectEqual(0, sbs.col_scroll);
    try std.testing.expectEqual(2, sbs.cursor);
    try std.testing.expectEqual(1, view.window.columnAt(rows, 5, sbs.cursor, sbs.col_scroll, sbs.hunk_pans[0..sbs.hunk_pan_n]));

    var d2 = try diff.parse(std.testing.allocator, fixture);
    defer d2.deinit();
    const rows2 = try view.row.flatten(std.testing.allocator, &d2);
    defer std.testing.allocator.free(rows2);
    const slots2 = try view.layout.pairSideBySide(std.testing.allocator, rows2);
    defer std.testing.allocator.free(slots2);
    vp.settle(80, 20, rows2, slots2);
    try std.testing.expectEqual(0, vp.col_scroll);
    try std.testing.expectEqual(0, view.window.columnAt(rows2, 2, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));
    try std.testing.expectEqual(0, view.window.columnAt(rows2, 5, vp.cursor, vp.col_scroll, vp.hunk_pans[0..vp.hunk_pan_n]));
}

test "shift wheel and sideways wheel pan" {
    const shift_up = tui.Mouse{
        .button = .wheel_up,
        .action = .press,
        .x = 0,
        .y = 0,
        .shift = true,
    };
    try std.testing.expectEqual(Wheel.left, wheelDirection(shift_up).?);
    const shift_down = tui.Mouse{
        .button = .wheel_down,
        .action = .press,
        .x = 0,
        .y = 0,
        .shift = true,
    };
    try std.testing.expectEqual(Wheel.right, wheelDirection(shift_down).?);
    const plain = tui.Mouse{ .button = .wheel_up, .action = .press, .x = 0, .y = 0 };
    try std.testing.expectEqual(Wheel.up, wheelDirection(plain).?);
    const side = tui.Mouse{ .button = .wheel_right, .action = .press, .x = 0, .y = 0 };
    try std.testing.expectEqual(Wheel.right, wheelDirection(side).?);
    const click = tui.Mouse{ .button = .left, .action = .press, .x = 1, .y = 1 };
    try std.testing.expect(wheelDirection(click) == null);
    const release = tui.Mouse{ .button = .wheel_down, .action = .release, .x = 0, .y = 0 };
    try std.testing.expect(wheelDirection(release) == null);
}

test "list wheel moves the window and a key follows the selected row" {
    var win: ListWin = .{};
    win.wheel(.down);
    try std.testing.expectEqual(1, win.scroll);
    try std.testing.expect(win.window_moved);
    win.wheel(.left);
    try std.testing.expectEqual(1, win.scroll);
    try std.testing.expect(win.window_moved);

    var list: FileList = .{ .win = .{ .scroll = 4, .window_moved = true } };
    _ = list.handleKey(.{ .char = 'j' });
    try std.testing.expect(!list.win.window_moved);
    try std.testing.expectEqual(0, list.win.cursor);
}

test "comment wheel scrolls the text and leaves the caret" {
    var draft: Draft = .{};
    defer draft.buf.deinit(std.testing.allocator);
    var text: [120]u8 = undefined;
    @memset(&text, 'a');
    try draft.buf.appendSlice(std.testing.allocator, &text);
    const size = tui.Size{ .cols = 20, .rows = 8 };
    draft.scrollWheel(.down, size);
    try std.testing.expect(draft.window_moved);
    try std.testing.expectEqual(1, draft.scroll);
    try std.testing.expectEqual(0, draft.caret);
    draft.scrollWheel(.right, size);
    try std.testing.expectEqual(1, draft.scroll);
    try std.testing.expectEqual(0, draft.caret);
}

test "file list omits a fully approved file and keeps a mixed file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const txt =
        \\diff --git a/mixed.txt b/mixed.txt
        \\--- a/mixed.txt
        \\+++ b/mixed.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
        \\diff --git a/gone.txt b/gone.txt
        \\--- a/gone.txt
        \\+++ b/gone.txt
        \\@@ -1 +1 @@
        \\-goneold
        \\+gonenew
    ;
    var d = try diff.parse(alloc, txt);
    defer d.deinit();
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append("mixed.txt", approve.fingerprintHunk(d.files[0].hunks[0]));
    try approved.append("gone.txt", approve.fingerprintHunk(d.files[1].hunks[0]));
    const hidden = try rowsForApproved(alloc, io, .cwd(), &d, &approved);
    defer alloc.free(hidden);

    var list: FileList = .{};
    defer list.items.deinit(alloc);
    try list.load(alloc, hidden, null);
    try std.testing.expectEqual(1, list.items.items.len);
    try std.testing.expectEqualStrings("mixed.txt", hidden[list.items.items[0]].file_header.path);
}

test "file list a and A approve" {
    const alloc = std.testing.allocator;
    var d = try diff.parse(alloc,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    );
    defer d.deinit();
    const rows = try view.row.flatten(alloc, &d);
    defer alloc.free(rows);

    var list: FileList = .{};
    defer list.items.deinit(alloc);
    try list.load(alloc, rows, null);
    try std.testing.expect(list.handleKey(.{ .char = 'A' }) == .approve);
    try std.testing.expect(list.handleKey(.{ .char = 'a' }) == .approve);
    switch (list.handleKey(.enter)) {
        .jump => |row| try std.testing.expectEqual(0, row),
        else => try std.testing.expect(false),
    }

    var empty: FileList = .{};
    defer empty.items.deinit(alloc);
    try std.testing.expect(empty.handleKey(.{ .char = 'A' }) == .open);
    try std.testing.expect(empty.handleKey(.{ .char = 'a' }) == .open);
}

test "comment list Enter on a hidden loc is hidden not missing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var d = try diff.parse(alloc,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    );
    defer d.deinit();
    const full = try view.row.flatten(alloc, &d);
    defer alloc.free(full);
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append("f.txt", approve.fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try rowsForApproved(alloc, io, .cwd(), &d, &approved);
    defer alloc.free(hidden);

    var list: CommentList = .{};
    defer list.items.deinit(alloc);
    try list.load(alloc, &.{.{
        .id = "1",
        .path = "f.txt",
        .new_line = 1,
        .side = .new,
        .body = "on hidden hunk",
    }});
    switch (list.handleKey(.enter, hidden)) {
        .hidden => |h| {
            try std.testing.expectEqualStrings("f.txt", h.loc.line.path);
            try std.testing.expectEqual(.new, h.loc.line.side);
            try std.testing.expectEqual(1, h.loc.line.line);
            try std.testing.expect(!h.edit);
        },
        else => try std.testing.expect(false),
    }
    switch (list.handleKey(.enter, full)) {
        .jump => |j| {
            try std.testing.expectEqual(view.rowForComment(full, .{
                .line = .{ .path = "f.txt", .side = .new, .line = 1 },
            }).?, j.row);
            try std.testing.expect(!j.edit);
        },
        else => try std.testing.expect(false),
    }
}

test "comment list Enter on a hunk comment jumps to the header" {
    const alloc = std.testing.allocator;
    var d = try diff.parse(alloc,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    );
    defer d.deinit();
    const rows = try view.row.flatten(alloc, &d);
    defer alloc.free(rows);

    var list: CommentList = .{};
    defer list.items.deinit(alloc);
    try list.load(alloc, &.{.{
        .id = "1",
        .path = "f.txt",
        .old_line = 1,
        .new_line = 1,
        .body = "hunk",
    }});
    switch (list.handleKey(.enter, rows)) {
        .jump => |j| {
            try std.testing.expectEqual(1, j.row);
            try std.testing.expect(!j.edit);
        },
        else => try std.testing.expect(false),
    }
}

test "comment list d dismisses and i edits" {
    const alloc = std.testing.allocator;
    var d = try diff.parse(alloc,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    );
    defer d.deinit();
    const rows = try view.row.flatten(alloc, &d);
    defer alloc.free(rows);

    var list: CommentList = .{};
    defer list.items.deinit(alloc);
    try list.load(alloc, &.{.{
        .id = "1",
        .path = "f.txt",
        .new_line = 1,
        .side = .new,
        .body = "note",
    }});
    try std.testing.expect(list.handleKey(.{ .char = 'd' }, rows) == .dismiss);
    try std.testing.expect(list.handleKey(.{ .char = 'D' }, rows) == .dismiss);
    switch (list.handleKey(.{ .char = 'i' }, rows)) {
        .jump => |j| {
            try std.testing.expect(j.edit);
            try std.testing.expectEqual(view.rowForComment(rows, .{
                .line = .{ .path = "f.txt", .side = .new, .line = 1 },
            }).?, j.row);
        },
        else => try std.testing.expect(false),
    }
    switch (list.handleKey(.{ .char = 'C' }, rows)) {
        .jump => |j| try std.testing.expect(j.edit),
        else => try std.testing.expect(false),
    }

    var empty: CommentList = .{};
    defer empty.items.deinit(alloc);
    try std.testing.expect(empty.handleKey(.{ .char = 'd' }, rows) == .open);
    try std.testing.expect(empty.handleKey(.{ .char = 'i' }, rows) == .open);
}

test "comment list i on a hidden loc is hidden with edit" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var d = try diff.parse(alloc,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    );
    defer d.deinit();
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append("f.txt", approve.fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try rowsForApproved(alloc, io, .cwd(), &d, &approved);
    defer alloc.free(hidden);

    var list: CommentList = .{};
    defer list.items.deinit(alloc);
    try list.load(alloc, &.{.{
        .id = "1",
        .path = "f.txt",
        .new_line = 1,
        .side = .new,
        .body = "on hidden hunk",
    }});
    switch (list.handleKey(.{ .char = 'i' }, hidden)) {
        .hidden => |h| {
            try std.testing.expect(h.edit);
            try std.testing.expectEqualStrings("f.txt", h.loc.line.path);
            try std.testing.expectEqual(.new, h.loc.line.side);
            try std.testing.expectEqual(1, h.loc.line.line);
        },
        else => try std.testing.expect(false),
    }
}

test "fullIndexOfHidden maps the remaining hunk onto the full flatten" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var d = try diff.parse(alloc,
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    );
    defer d.deinit();
    const full = try view.row.flatten(alloc, &d);
    defer alloc.free(full);
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append("f.txt", approve.fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try rowsForApproved(alloc, io, .cwd(), &d, &approved);
    defer alloc.free(hidden);
    try std.testing.expectEqual(0, fullIndexOfHidden(full, hidden, 0));
    try std.testing.expectEqual(4, fullIndexOfHidden(full, hidden, 1));
}

fn twoHunkDiff(alloc: std.mem.Allocator) !diff.Diff {
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parse(alloc, txt);
    errdefer d.deinit();
    try std.testing.expectEqual(1, d.files.len);
    try std.testing.expectEqual(2, d.files[0].hunks.len);
    return d;
}

test "loadVisibleRows prunes a stale entry and omits the hunk" {
    if (builtin.os.tag == .wasi) return;
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const path = d.files[0].displayPath();
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, approve.fingerprintHunk(d.files[0].hunks[0]));
    try approved.append("gone.txt", approve.fingerprintFile("x"));
    try approve.save(&approved, alloc, io, tmp.dir);

    const vis = try loadVisibleRows(alloc, io, tmp.dir, &d);
    defer alloc.free(vis.rows);
    try std.testing.expectEqual(1, vis.approved_n);
    try std.testing.expectEqual(4, vis.rows.len);
    try std.testing.expect(vis.rows[0] == .file_header);

    var reloaded = try approve.load(alloc, io, tmp.dir);
    defer reloaded.deinit();
    try std.testing.expectEqual(1, reloaded.entries.items.len);
    try std.testing.expectEqualStrings(path, reloaded.entries.items[0].path);
}

test "rowForIdentity after unapprove restores one hunk and leaves the other hidden" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const h0 = approve.fingerprintHunk(d.files[0].hunks[0]);
    const h1 = approve.fingerprintHunk(d.files[0].hunks[1]);
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, h0);
    try approved.append(path, h1);
    try approved.unapprove(path, h0);
    const rows = try rowsForApproved(alloc, io, .cwd(), &d, &approved);
    defer alloc.free(rows);
    try std.testing.expectEqual(4, rows.len);
    try std.testing.expectEqual(1, rowForIdentity(rows, &d, path, h0, .hunk).?);
    try std.testing.expect(rowForIdentity(rows, &d, path, h1, .hunk) == null);
}

test "rowForIdentity identical hunks: unapprove restores the unmatched live hunk" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\@@ -10 +10 @@
        \\-a
        \\+b
    ;
    var d = try diff.parse(alloc, txt);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const hash = approve.fingerprintHunk(d.files[0].hunks[0]);
    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, hash);
    try approved.append(path, hash);
    try approved.unapprove(path, hash);
    const rows = try rowsForApproved(alloc, io, .cwd(), &d, &approved);
    defer alloc.free(rows);
    try std.testing.expectEqual(4, rows.len);
    try std.testing.expectEqual(1, rowForIdentity(rows, &d, path, hash, .hunk).?);
    try std.testing.expectEqual(d.files[0].hunks[1].old_start, rows[1].hunk_header.old_start);
}

test "identityAtRow hunk line and file header" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const full = try view.row.flatten(alloc, &d);
    defer alloc.free(full);
    const h0 = approve.fingerprintHunk(d.files[0].hunks[0]);
    const h1 = approve.fingerprintHunk(d.files[0].hunks[1]);
    const at_add = identityAtRow(alloc, &d, io, .cwd(), full, 3).?;
    try std.testing.expectEqual(approve.Hidden.Kind.hunk, at_add.kind);
    try std.testing.expectEqual(h0, at_add.hash);
    const at_file = identityAtRow(alloc, &d, io, .cwd(), full, 0).?;
    try std.testing.expectEqual(h0, at_file.hash);
    const at_h1 = identityAtRow(alloc, &d, io, .cwd(), full, 6).?;
    try std.testing.expectEqual(h1, at_h1.hash);
}

test "identityAtRow then unapprove restores a hidden comment line" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const loc: view.row.DiffLoc = .{ .line = .{ .path = path, .side = .new, .line = 1 } };
    const full = try view.row.flatten(alloc, &d);
    defer alloc.free(full);
    const full_row = view.rowForComment(full, loc).?;

    var approved = approve.initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, approve.fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try rowsForApproved(alloc, io, .cwd(), &d, &approved);
    defer alloc.free(hidden);
    try std.testing.expect(view.rowForComment(hidden, loc) == null);

    const item = identityAtRow(alloc, &d, io, .cwd(), full, full_row).?;
    try approved.unapprove(item.path, item.hash);
    const restored = try rowsForApproved(alloc, io, .cwd(), &d, &approved);
    defer alloc.free(restored);
    try std.testing.expectEqual(full_row, view.rowForComment(restored, loc).?);
}

const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

const ten_lines = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n";
const accepted_body = "line1\naccepted\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n";
const nearby_body = "line1\naccepted\nnearby\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n";

fn expectGitOk(io: std.Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.TestUnexpectedResult;
    defer child.kill(io);
    const term = child.wait(io) catch return error.TestUnexpectedResult;
    switch (term) {
        .exited => |code| if (code != 0) return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    }
}

fn initTrackedRepo(io: std.Io, tmp: IsolatedTmp) !void {
    const cwd = tmp.cwd();
    try expectGitOk(io, cwd, &.{ "git", "init", "-b", "main" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.email", "rv@test" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.name", "rv test" });
    try tmp.write(io, "f.txt", ten_lines);
    try expectGitOk(io, cwd, &.{ "git", "add", "f.txt" });
    try expectGitOk(io, cwd, &.{ "git", "commit", "-m", "init" });
}

fn loadLocalView(alloc: std.mem.Allocator, io: std.Io, cwd: std.process.Child.Cwd, root: std.Io.Dir) !OpenDiff {
    var parsed = try git.loadDefaultDiffCwd(alloc, io, cwd);
    errdefer parsed.deinit();
    const vis = try loadVisibleRows(alloc, io, root, &parsed);
    errdefer alloc.free(vis.rows);
    return try OpenDiff.build(alloc, parsed, vis.rows, vis.approved_n);
}

fn firstHunkRow(rows: []const view.row.Row) ?usize {
    for (rows, 0..) |row, i| {
        if (row == .hunk_header) return i;
    }
    return null;
}

fn hasDiffFile(d: diff.Diff, path: []const u8, group: diff.Group) bool {
    for (d.files) |f| {
        const g = f.group orelse continue;
        if (g == group and std.mem.eql(u8, f.displayPath(), path)) return true;
    }
    return false;
}

fn rowsHaveLine(rows: []const view.row.Row, text: []const u8) bool {
    for (rows) |row| {
        switch (row) {
            .line => |ln| if (std.mem.eql(u8, ln.text, text)) return true,
            else => {},
        }
    }
    return false;
}

fn hasRowFile(rows: []const view.row.Row, path: []const u8, group: diff.Group) bool {
    for (rows) |row| {
        switch (row) {
            .file_header => |fh| {
                const g = fh.group orelse continue;
                if (g == group and std.mem.eql(u8, fh.path, path)) return true;
            },
            else => {},
        }
    }
    return false;
}

test "reloadReview takes comments from the file and keeps them when the file is invalid" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    _ = try review.addOpen("f.txt", null, 1, .new, "stale", .local);
    try store.save(&review, alloc, io, tmp.dir);

    var disk = try store.load(alloc, io, tmp.dir, store.default_review_id);
    defer disk.deinit();
    try disk.remove(&.{"1"});
    _ = try disk.addOpen("f.txt", null, 2, .new, "fresh", .local);
    try store.save(&disk, alloc, io, tmp.dir);

    var note: StatusNote = .{};
    reloadReview(alloc, io, tmp.dir, &review, &note);
    try std.testing.expectEqual(1, review.comments.items.len);
    try std.testing.expectEqualStrings("fresh", review.comments.items[0].body);
    try std.testing.expectEqual(0, note.slice().len);

    try tmp.write(io, ".rv/reviews/current.json", "{");
    reloadReview(alloc, io, tmp.dir, &review, &note);
    try std.testing.expectEqual(1, review.comments.items.len);
    try std.testing.expectEqualStrings("fresh", review.comments.items[0].body);
    try std.testing.expectEqualStrings("invalid .rv review JSON", note.slice());
}

fn hunkAdds(file: diff.File, text: []const u8) bool {
    for (file.hunks) |h| {
        for (h.lines) |ln| {
            if (ln.kind == .add and std.mem.eql(u8, ln.text, text)) return true;
        }
    }
    return false;
}

test "applyApprove stages an unstaged hunk and hides it; nearby edit is unstaged only" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try initTrackedRepo(io, tmp);
    try tmp.write(io, "f.txt", accepted_body);

    var diff_view = try loadLocalView(alloc, io, tmp.cwd(), tmp.dir);
    defer diff_view.deinit(alloc);
    var cursor: usize = firstHunkRow(diff_view.rows) orelse return error.TestUnexpectedResult;
    var note: StatusNote = .{};
    var focus: Focus = .normal;
    var git_error: GitError = .{};
    defer git_error.buf.deinit(alloc);
    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    try applyApprove(alloc, io, .local, &diff_view, &cursor, &note, &focus, &git_error, &review, tmp.cwd(), tmp.dir, false);
    try std.testing.expect(focus != .git_error);
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .unstaged));
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .staged));
    {
        var raw = try git.loadDefaultDiffCwd(alloc, io, tmp.cwd());
        defer raw.deinit();
        try std.testing.expect(!hasDiffFile(raw, "f.txt", .unstaged));
        try std.testing.expect(hasDiffFile(raw, "f.txt", .staged));
    }

    try tmp.write(io, "f.txt", nearby_body);
    const next = try loadLocalView(alloc, io, tmp.cwd(), tmp.dir);
    diff_view.deinit(alloc);
    diff_view = next;
    try std.testing.expect(hasRowFile(diff_view.rows, "f.txt", .unstaged));
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .staged));
    const unstaged = blk: {
        for (diff_view.diff.files) |f| {
            const g = f.group orelse continue;
            if (g == .unstaged and std.mem.eql(u8, f.displayPath(), "f.txt")) break :blk f;
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(hunkAdds(unstaged, "nearby"));
    try std.testing.expect(!hunkAdds(unstaged, "accepted"));
}

test "applyApprove hides a further edit of a line that was already staged" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();
    try expectGitOk(io, cwd, &.{ "git", "init", "-b", "main" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.email", "rv@test" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.name", "rv test" });
    try tmp.write(io, "f.txt", "alpha\n");
    try expectGitOk(io, cwd, &.{ "git", "add", "f.txt" });
    try expectGitOk(io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "f.txt", "beta\n");
    try expectGitOk(io, cwd, &.{ "git", "add", "f.txt" });
    try tmp.write(io, "f.txt", "gamma\n");

    var diff_view = try loadLocalView(alloc, io, tmp.cwd(), tmp.dir);
    defer diff_view.deinit(alloc);
    var cursor: usize = firstHunkRow(diff_view.rows) orelse return error.TestUnexpectedResult;
    var note: StatusNote = .{};
    var focus: Focus = .normal;
    var git_error: GitError = .{};
    defer git_error.buf.deinit(alloc);
    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    try applyApprove(alloc, io, .local, &diff_view, &cursor, &note, &focus, &git_error, &review, tmp.cwd(), tmp.dir, false);
    try std.testing.expect(focus != .git_error);
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .unstaged));
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .staged));
    {
        var raw = try git.loadDefaultDiffCwd(alloc, io, tmp.cwd());
        defer raw.deinit();
        try std.testing.expect(!hasDiffFile(raw, "f.txt", .unstaged));
        try std.testing.expect(hasDiffFile(raw, "f.txt", .staged));
        const staged = blk: {
            for (raw.files) |f| {
                const g = f.group orelse continue;
                if (g == .staged and std.mem.eql(u8, f.displayPath(), "f.txt")) break :blk f;
            }
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(hunkAdds(staged, "gamma"));
        try std.testing.expect(!hunkAdds(staged, "beta"));
    }
    var stored = try approve.load(alloc, io, tmp.dir);
    defer stored.deinit();
    try std.testing.expectEqual(1, stored.entries.items.len);

    const hidden = try approve.collectApproved(alloc, io, tmp.dir, &diff_view.diff, &stored);
    defer alloc.free(hidden);
    try std.testing.expectEqual(1, hidden.len);
    try applyUnapprove(alloc, io, .local, &diff_view, &cursor, &note, tmp.dir, hidden[0]);
    try std.testing.expect(hasRowFile(diff_view.rows, "f.txt", .staged));
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .unstaged));
    {
        var raw = try git.loadDefaultDiffCwd(alloc, io, tmp.cwd());
        defer raw.deinit();
        try std.testing.expect(hasDiffFile(raw, "f.txt", .staged));
        try std.testing.expect(!hasDiffFile(raw, "f.txt", .unstaged));
    }
}

test "applyApprove hides one unstaged hunk and leaves the other unstaged" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();
    try expectGitOk(io, cwd, &.{ "git", "init", "-b", "main" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.email", "rv@test" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.name", "rv test" });
    const head = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n";
    const both = "tokA\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\ntokB\nl11\nl12\n";
    try tmp.write(io, "f.txt", head);
    try expectGitOk(io, cwd, &.{ "git", "add", "f.txt" });
    try expectGitOk(io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "f.txt", both);

    var diff_view = try loadLocalView(alloc, io, cwd, tmp.dir);
    defer diff_view.deinit(alloc);
    var cursor: usize = firstHunkRow(diff_view.rows) orelse return error.TestUnexpectedResult;
    var note: StatusNote = .{};
    var focus: Focus = .normal;
    var git_error: GitError = .{};
    defer git_error.buf.deinit(alloc);
    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    try applyApprove(alloc, io, .local, &diff_view, &cursor, &note, &focus, &git_error, &review, cwd, tmp.dir, false);
    try std.testing.expect(focus != .git_error);
    try std.testing.expect(hasRowFile(diff_view.rows, "f.txt", .unstaged));
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .staged));
    try std.testing.expect(rowsHaveLine(diff_view.rows, "tokB"));
    try std.testing.expect(!rowsHaveLine(diff_view.rows, "tokA"));
    {
        var raw = try git.loadDefaultDiffCwd(alloc, io, cwd);
        defer raw.deinit();
        try std.testing.expect(hasDiffFile(raw, "f.txt", .unstaged));
        try std.testing.expect(hasDiffFile(raw, "f.txt", .staged));
        const unstaged = blk: {
            for (raw.files) |f| {
                const g = f.group orelse continue;
                if (g == .unstaged and std.mem.eql(u8, f.displayPath(), "f.txt")) break :blk f;
            }
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(hunkAdds(unstaged, "tokB"));
        try std.testing.expect(!hunkAdds(unstaged, "tokA"));
    }
}

test "applyApprove hides approved lines when git merges them with a staged neighbor" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();
    try expectGitOk(io, cwd, &.{ "git", "init", "-b", "main" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.email", "rv@test" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.name", "rv test" });

    const head = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n";
    const staged_body = "l1\nl2\nl3\nl4\nSTAGED\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n";
    const both = "l1\nl2\nl3\nl4\nSTAGED\nUNSTAGED\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n";
    try tmp.write(io, "f.txt", head);
    try expectGitOk(io, cwd, &.{ "git", "add", "f.txt" });
    try expectGitOk(io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "f.txt", staged_body);
    try expectGitOk(io, cwd, &.{ "git", "add", "f.txt" });
    try tmp.write(io, "f.txt", both);

    var diff_view = try loadLocalView(alloc, io, cwd, tmp.dir);
    defer diff_view.deinit(alloc);
    try std.testing.expect(rowsHaveLine(diff_view.rows, "UNSTAGED"));
    try std.testing.expect(rowsHaveLine(diff_view.rows, "STAGED"));

    var cursor: usize = firstHunkRow(diff_view.rows) orelse return error.TestUnexpectedResult;
    var note: StatusNote = .{};
    var focus: Focus = .normal;
    var git_error: GitError = .{};
    defer git_error.buf.deinit(alloc);
    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    try applyApprove(alloc, io, .local, &diff_view, &cursor, &note, &focus, &git_error, &review, cwd, tmp.dir, false);
    try std.testing.expect(focus != .git_error);
    try std.testing.expect(rowsHaveLine(diff_view.rows, "STAGED"));
    try std.testing.expect(!rowsHaveLine(diff_view.rows, "UNSTAGED"));
    try std.testing.expect(!rowsHaveLine(diff_view.rows, "l6"));
    {
        var raw = try git.loadDefaultDiffCwd(alloc, io, cwd);
        defer raw.deinit();
        try std.testing.expect(!hasDiffFile(raw, "f.txt", .unstaged));
        const staged = blk: {
            for (raw.files) |f| {
                const g = f.group orelse continue;
                if (g == .staged and std.mem.eql(u8, f.displayPath(), "f.txt")) break :blk f;
            }
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(1, staged.hunks.len);
        try std.testing.expect(hunkAdds(staged, "STAGED"));
        try std.testing.expect(hunkAdds(staged, "UNSTAGED"));
    }
    var stored = try approve.load(alloc, io, tmp.dir);
    defer stored.deinit();
    try std.testing.expectEqual(1, stored.entries.items.len);
}

test "applyApprove on already-staged only hides" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try initTrackedRepo(io, tmp);
    try tmp.write(io, "f.txt", accepted_body);
    try expectGitOk(io, tmp.cwd(), &.{ "git", "add", "f.txt" });

    var diff_view = try loadLocalView(alloc, io, tmp.cwd(), tmp.dir);
    defer diff_view.deinit(alloc);
    var cursor: usize = firstHunkRow(diff_view.rows) orelse return error.TestUnexpectedResult;
    var note: StatusNote = .{};
    var focus: Focus = .normal;
    var git_error: GitError = .{};
    defer git_error.buf.deinit(alloc);
    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    try applyApprove(alloc, io, .local, &diff_view, &cursor, &note, &focus, &git_error, &review, tmp.cwd(), tmp.dir, false);
    try std.testing.expect(focus != .git_error);
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .staged));
    {
        var raw = try git.loadDefaultDiffCwd(alloc, io, tmp.cwd());
        defer raw.deinit();
        try std.testing.expect(hasDiffFile(raw, "f.txt", .staged));
        try std.testing.expect(!hasDiffFile(raw, "f.txt", .unstaged));
    }
}

test "applyApprove GitFailed does not write the store" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try initTrackedRepo(io, tmp);
    try tmp.write(io, "f.txt", accepted_body);

    var diff_view = try loadLocalView(alloc, io, tmp.cwd(), tmp.dir);
    defer diff_view.deinit(alloc);
    const before_len = diff_view.rows.len;
    var cursor: usize = firstHunkRow(diff_view.rows) orelse return error.TestUnexpectedResult;
    var note: StatusNote = .{};
    var focus: Focus = .normal;
    var git_error: GitError = .{};
    defer git_error.buf.deinit(alloc);
    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    // Index no longer matches the loaded hunk's old side, so apply --cached fails.
    try tmp.write(io, "f.txt", "this no longer matches the loaded hunk\n");
    try expectGitOk(io, tmp.cwd(), &.{ "git", "add", "f.txt" });
    try applyApprove(alloc, io, .local, &diff_view, &cursor, &note, &focus, &git_error, &review, tmp.cwd(), tmp.dir, false);
    try std.testing.expectEqual(Focus.git_error, focus);
    try std.testing.expect(git_error.buf.items.len > 0);
    try std.testing.expectEqual(before_len, diff_view.rows.len);
    try std.testing.expect(hasRowFile(diff_view.rows, "f.txt", .unstaged));
    {
        var approved = try approve.load(alloc, io, tmp.dir);
        defer approved.deinit();
        try std.testing.expectEqual(0, approved.entries.items.len);
    }
}

test "applyUnapprove restores the row under Staged and leaves the index" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try initTrackedRepo(io, tmp);
    try tmp.write(io, "f.txt", accepted_body);

    var diff_view = try loadLocalView(alloc, io, tmp.cwd(), tmp.dir);
    defer diff_view.deinit(alloc);
    var cursor: usize = firstHunkRow(diff_view.rows) orelse return error.TestUnexpectedResult;
    var note: StatusNote = .{};
    var focus: Focus = .normal;
    var git_error: GitError = .{};
    defer git_error.buf.deinit(alloc);
    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    try applyApprove(alloc, io, .local, &diff_view, &cursor, &note, &focus, &git_error, &review, tmp.cwd(), tmp.dir, false);
    try std.testing.expect(focus != .git_error);

    var stored = try approve.load(alloc, io, tmp.dir);
    defer stored.deinit();
    const hidden = try approve.collectApproved(alloc, io, tmp.dir, &diff_view.diff, &stored);
    defer alloc.free(hidden);
    try std.testing.expectEqual(1, hidden.len);

    try applyUnapprove(alloc, io, .local, &diff_view, &cursor, &note, tmp.dir, hidden[0]);
    try std.testing.expect(hasRowFile(diff_view.rows, "f.txt", .staged));
    try std.testing.expect(!hasRowFile(diff_view.rows, "f.txt", .unstaged));
    const restored = diff_view.rows[cursor];
    const restored_group = switch (restored) {
        .file_header => |fh| fh.group,
        .hunk_header => |hh| hh.group,
        else => null,
    };
    try std.testing.expectEqual(diff.Group.staged, restored_group.?);
    {
        var raw = try git.loadDefaultDiffCwd(alloc, io, tmp.cwd());
        defer raw.deinit();
        try std.testing.expect(hasDiffFile(raw, "f.txt", .staged));
        try std.testing.expect(!hasDiffFile(raw, "f.txt", .unstaged));
    }
}

fn threeGroupRows(alloc: std.mem.Allocator) !struct { d: diff.Diff, rows: []view.row.Row } {
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
    const rows = try view.row.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "targetAt empty section and untagged" {
    try std.testing.expect(targetAt(&.{}, 0, false) == null);

    const fixture =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(std.testing.allocator, fixture);
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    try std.testing.expect(targetAt(rows, 0, false) == null);
    try std.testing.expect(targetAt(rows, 2, false) == null);

    var fix = try threeGroupRows(std.testing.allocator);
    defer fix.d.deinit();
    defer std.testing.allocator.free(fix.rows);
    try std.testing.expect(targetAt(fix.rows, 0, false) == null);
    try std.testing.expect(targetAt(fix.rows, 5, true) == null);
}

test "targetAt file hunk and file-from-hunk" {
    var fix = try threeGroupRows(std.testing.allocator);
    defer fix.d.deinit();
    defer std.testing.allocator.free(fix.rows);
    const rows = fix.rows;
    // 0 Unstaged, 1 file a, 2 hunk, 3 del, 4 add, 5 Untracked, 6 file u, …
    // 9 Staged, 10 file a, 11 hunk, 12 ctx, 13 add.

    const file = targetAt(rows, 1, false).?;
    try std.testing.expectEqualStrings("a", file.path);
    try std.testing.expectEqual(diff.Group.unstaged, file.group);
    try std.testing.expect(file.hunk_i == null);
    try std.testing.expectEqual(1, file.first);
    try std.testing.expectEqual(4, file.last);

    const hunk = targetAt(rows, 3, false).?;
    try std.testing.expectEqualStrings("a", hunk.path);
    try std.testing.expectEqual(diff.Group.unstaged, hunk.group);
    try std.testing.expectEqual(0, hunk.hunk_i.?);
    try std.testing.expectEqual(2, hunk.first);
    try std.testing.expectEqual(4, hunk.last);

    const from_hunk = targetAt(rows, 3, true).?;
    try std.testing.expect(from_hunk.hunk_i == null);
    try std.testing.expectEqual(1, from_hunk.first);
    try std.testing.expectEqual(4, from_hunk.last);

    const staged = targetAt(rows, 12, false).?;
    try std.testing.expectEqualStrings("a", staged.path);
    try std.testing.expectEqual(diff.Group.staged, staged.group);
    try std.testing.expectEqual(0, staged.hunk_i.?);
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
    var d = try diff.parsePieces(std.testing.allocator, &.{
        .{ .text = two_hunks, .group = .unstaged },
    });
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    // 0 Unstaged, 1 file, 2 h0, 3 del, 4 add, 5 h1, 6 del, 7 add.

    const first = targetAt(rows, 3, false).?;
    const after_first = neighborMark(rows, first).?;
    try std.testing.expectEqualStrings("a", after_first.path);
    try std.testing.expectEqual(diff.Group.unstaged, after_first.group);
    try std.testing.expectEqual(0, after_first.hunk_i.?);

    const second = targetAt(rows, 6, false).?;
    const before_second = neighborMark(rows, second).?;
    try std.testing.expectEqualStrings("a", before_second.path);
    try std.testing.expectEqual(0, before_second.hunk_i.?);

    var fix = try threeGroupRows(std.testing.allocator);
    defer fix.d.deinit();
    defer std.testing.allocator.free(fix.rows);
    const next_file = neighborMark(fix.rows, targetAt(fix.rows, 3, false).?).?;
    try std.testing.expectEqualStrings("u", next_file.path);
    try std.testing.expectEqual(diff.Group.untracked, next_file.group);
    try std.testing.expect(next_file.hunk_i == null);

    const only =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d_only = try diff.parsePieces(std.testing.allocator, &.{
        .{ .text = only, .group = .untracked },
    });
    defer d_only.deinit();
    const only_rows = try view.row.flatten(std.testing.allocator, &d_only);
    defer std.testing.allocator.free(only_rows);
    // Whole file is the only change: no following or previous header.
    try std.testing.expect(neighborMark(only_rows, targetAt(only_rows, 1, false).?) == null);
    // Only hunk: previous header is that file’s row.
    const prev_file = neighborMark(only_rows, targetAt(only_rows, 2, false).?).?;
    try std.testing.expectEqualStrings("u", prev_file.path);
    try std.testing.expectEqual(diff.Group.untracked, prev_file.group);
    try std.testing.expect(prev_file.hunk_i == null);
}

test "restoreNeighbor dest hunk file fallback and gone" {
    try std.testing.expectEqual(0, restoreNeighbor(&.{}, .{
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
    var d = try diff.parsePieces(std.testing.allocator, &.{
        .{ .text = remaining, .group = .unstaged },
    });
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    // 0 Unstaged, 1 file, 2 hunk, 3 del, 4 add.

    try std.testing.expectEqual(2, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = 0,
    }));
    try std.testing.expectEqual(1, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = 4,
    }));
    try std.testing.expectEqual(1, restoreNeighbor(rows, .{
        .path = "a",
        .group = .unstaged,
        .hunk_i = null,
    }));
    try std.testing.expectEqual(0, restoreNeighbor(rows, .{
        .path = "a",
        .group = .staged,
        .hunk_i = 0,
    }));
    try std.testing.expectEqual(0, restoreNeighbor(rows, .{
        .path = "gone",
        .group = .unstaged,
        .hunk_i = null,
    }));
}

test "groupSpanAt empty untagged and three groups" {
    try std.testing.expect(groupSpanAt(&.{}, 0) == null);

    const untagged =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(std.testing.allocator, untagged);
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    try std.testing.expect(groupSpanAt(rows, 0) == null);

    var fix = try threeGroupRows(std.testing.allocator);
    defer fix.d.deinit();
    defer std.testing.allocator.free(fix.rows);
    // 0 Unstaged, 1-4 file a, 5 Untracked, 6-8 file u, 9 Staged, 10-13 file a.
    try std.testing.expect(groupSpanAt(fix.rows, 1) == null);

    const unstaged = groupSpanAt(fix.rows, 0).?;
    try std.testing.expectEqual(diff.Group.unstaged, unstaged.group);
    try std.testing.expectEqual(0, unstaged.first);
    try std.testing.expectEqual(4, unstaged.last);

    const untracked = groupSpanAt(fix.rows, 5).?;
    try std.testing.expectEqual(diff.Group.untracked, untracked.group);
    try std.testing.expectEqual(5, untracked.first);
    try std.testing.expectEqual(8, untracked.last);

    const staged = groupSpanAt(fix.rows, 9).?;
    try std.testing.expectEqual(diff.Group.staged, staged.group);
    try std.testing.expectEqual(9, staged.first);
    try std.testing.expectEqual(13, staged.last);
}

test "groupNeighborMark following section previous file and only group" {
    var fix = try threeGroupRows(std.testing.allocator);
    defer fix.d.deinit();
    defer std.testing.allocator.free(fix.rows);

    const after_unstaged = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 0).?).?;
    try std.testing.expect(after_unstaged == .section);
    try std.testing.expectEqual(diff.Group.untracked, after_unstaged.section);

    const after_untracked = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 5).?).?;
    try std.testing.expect(after_untracked == .section);
    try std.testing.expectEqual(diff.Group.staged, after_untracked.section);

    const before_staged = groupNeighborMark(fix.rows, groupSpanAt(fix.rows, 9).?).?;
    try std.testing.expect(before_staged == .file);
    try std.testing.expectEqualStrings("u", before_staged.file.path);
    try std.testing.expectEqual(diff.Group.untracked, before_staged.file.group);

    const only =
        \\diff --git a/u b/u
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/u
        \\@@ -0,0 +1 @@
        \\+hi
    ;
    var d_only = try diff.parsePieces(std.testing.allocator, &.{
        .{ .text = only, .group = .untracked },
    });
    defer d_only.deinit();
    const only_rows = try view.row.flatten(std.testing.allocator, &d_only);
    defer std.testing.allocator.free(only_rows);
    try std.testing.expect(groupNeighborMark(only_rows, groupSpanAt(only_rows, 0).?) == null);
}

test "restoreGroupNeighbor dest section file fallback and gone" {
    try std.testing.expectEqual(0, restoreGroupNeighbor(&.{}, .{ .section = .unstaged }));

    var fix = try threeGroupRows(std.testing.allocator);
    defer fix.d.deinit();
    defer std.testing.allocator.free(fix.rows);

    try std.testing.expectEqual(5, restoreGroupNeighbor(fix.rows, .{ .section = .untracked }));
    try std.testing.expectEqual(6, restoreGroupNeighbor(fix.rows, .{
        .file = .{ .path = "u", .group = .untracked },
    }));
    try std.testing.expectEqual(0, restoreGroupNeighbor(fix.rows, .{
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
    var d = try diff.parsePieces(std.testing.allocator, &.{
        .{ .text = remaining, .group = .staged },
    });
    defer d.deinit();
    const rows = try view.row.flatten(std.testing.allocator, &d);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(0, restoreGroupNeighbor(rows, .{ .section = .untracked }));
}

test "expandTargetAt hunk not file or section" {
    var fix = try threeGroupRows(std.testing.allocator);
    defer fix.d.deinit();
    defer std.testing.allocator.free(fix.rows);
    const rows = fix.rows;

    try std.testing.expect(expandTargetAt(&fix.d, rows, 0) == null);
    try std.testing.expect(expandTargetAt(&fix.d, rows, 1) == null);
    const unstaged = expandTargetAt(&fix.d, rows, 3).?;
    try std.testing.expectEqual(0, unstaged.file_i);
    try std.testing.expectEqual(0, unstaged.hunk_i);
    const staged = expandTargetAt(&fix.d, rows, 12).?;
    try std.testing.expectEqual(2, staged.file_i);
    try std.testing.expectEqual(0, staged.hunk_i);

    var range_d = try diff.parse(std.testing.allocator,
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old
        \\+new
    );
    defer range_d.deinit();
    const range_rows = try view.row.flatten(std.testing.allocator, &range_d);
    defer std.testing.allocator.free(range_rows);
    try std.testing.expect(expandTargetAt(&range_d, range_rows, 0) == null);
    const in_hunk = expandTargetAt(&range_d, range_rows, 2).?;
    try std.testing.expectEqual(0, in_hunk.file_i);
    try std.testing.expectEqual(0, in_hunk.hunk_i);
}


fn findDiffFile(d: diff.Diff, path: []const u8, group: diff.Group) !diff.File {
    for (d.files) |f| {
        const g = f.group orelse continue;
        if (g == group and std.mem.eql(u8, f.displayPath(), path)) return f;
    }
    return error.TestExpectedEqual;
}

fn fileHasLine(f: diff.File, text: []const u8) bool {
    for (f.hunks) |h| {
        for (h.lines) |ln| {
            if (std.mem.eql(u8, ln.text, text)) return true;
        }
    }
    return false;
}

test "applyAtCursor reloads the mutated path and leaves other files" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    const cwd = tmp.cwd();

    try expectGitOk(io, cwd, &.{ "git", "init", "-b", "main" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.email", "rv@test" });
    try expectGitOk(io, cwd, &.{ "git", "config", "user.name", "rv test" });
    const before = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\nfourteen\nfifteen\nsixteen\nseventeen\neighteen\n";
    const after = "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\nthirteen\nfourteen\nfifteen\nsixteen\nSEVENTEEN\neighteen\n";
    try tmp.write(io, "keep.txt", "keep\n");
    try tmp.write(io, "target.txt", before);
    try expectGitOk(io, cwd, &.{ "git", "add", "keep.txt", "target.txt" });
    try expectGitOk(io, cwd, &.{ "git", "commit", "-m", "init" });
    try tmp.write(io, "keep.txt", "keep-me\n");
    try tmp.write(io, "target.txt", after);

    var d = try git.loadDefaultDiffCwd(alloc, io, cwd);
    defer d.deinit();
    const rows = try view.row.flatten(alloc, &d);
    defer alloc.free(rows);
    const cursor: usize = blk: {
        for (rows, 0..) |row, i| {
            switch (row) {
                .hunk_header => |h| if (std.mem.eql(u8, h.path, "target.txt")) break :blk i,
                else => {},
            }
        }
        return error.TestExpectedEqual;
    };
    for (d.files) |*f| {
        if (f.group == .unstaged and std.mem.eql(u8, f.displayPath(), "keep.txt")) {
            f.hunks[0].can_grow = false;
        }
    }
    const marked = try alloc.alloc(diff.File, d.files.len + 1);
    defer alloc.free(marked);
    @memcpy(marked[0..d.files.len], d.files);
    marked[d.files.len] = .{ .new_path = "zzz-kept.txt", .group = .unstaged };
    d.files = marked;

    var review = try store.initEmpty(alloc, store.default_review_id);
    defer review.deinit();
    const status = try applyAtCursor(alloc, io, cwd, tmp.dir, &d, rows, cursor, &review, false, .stage_unstage, false);
    const loaded = switch (status) {
        .noop => return error.TestExpectedEqual,
        .result => |r| blk: {
            defer if (r.fail_message) |msg| alloc.free(msg);
            break :blk r.open orelse return error.TestExpectedEqual;
        },
    };
    defer loaded.deinit(alloc);

    try std.testing.expect(hasDiffFile(loaded.diff, "zzz-kept.txt", .unstaged));
    const keep = try findDiffFile(loaded.diff, "keep.txt", .unstaged);
    try std.testing.expect(!hasDiffFile(loaded.diff, "keep.txt", .staged));
    try std.testing.expect(!keep.hunks[0].can_grow);
    try std.testing.expect(fileHasLine(keep, "keep-me"));

    const unstaged = try findDiffFile(loaded.diff, "target.txt", .unstaged);
    const staged = try findDiffFile(loaded.diff, "target.txt", .staged);
    try std.testing.expect(fileHasLine(unstaged, "SEVENTEEN"));
    try std.testing.expect(!fileHasLine(unstaged, "TWO"));
    try std.testing.expect(fileHasLine(staged, "TWO"));
    try std.testing.expect(!fileHasLine(staged, "SEVENTEEN"));
}

fn twoHunkUnstaged(alloc: std.mem.Allocator) !struct { d: diff.Diff, rows: []view.row.Row } {
    const txt =
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-old1
        \\+new1
        \\@@ -10 +10 @@
        \\-old2
        \\+new2
    ;
    var d = try diff.parsePieces(alloc, &.{.{ .text = txt, .group = .unstaged }});
    errdefer d.deinit();
    const rows = try view.row.flatten(alloc, &d);
    return .{ .d = d, .rows = rows };
}

test "approveHasComments hunk vs other hunk vs file" {
    const alloc = std.testing.allocator;
    var fix = try twoHunkUnstaged(alloc);
    defer fix.d.deinit();
    defer alloc.free(fix.rows);
    const rows = fix.rows;
    try std.testing.expect(rows[2] == .hunk_header);
    try std.testing.expect(rows[5] == .hunk_header);

    var review = try store.initEmpty(alloc, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, 10, .new, "hunk1", .local);

    try std.testing.expect(!approveHasComments(&review, &fix.d, rows, 4, false));
    try std.testing.expect(approveHasComments(&review, &fix.d, rows, 7, false));
    try std.testing.expect(approveHasComments(&review, &fix.d, rows, 4, true));
    try std.testing.expect(approveHasComments(&review, &fix.d, rows, 1, true));
    try std.testing.expect(!approveHasComments(&review, &fix.d, rows, 1, false));
    try std.testing.expect(!approveHasComments(&review, &fix.d, rows, 0, false));
}

test "approveHasComments file header does not trigger hunk a" {
    const alloc = std.testing.allocator;
    var fix = try twoHunkUnstaged(alloc);
    defer fix.d.deinit();
    defer alloc.free(fix.rows);
    const rows = fix.rows;

    var review = try store.initEmpty(alloc, "t");
    defer review.deinit();
    _ = try review.addOpen("f", null, null, null, "file", .local);

    try std.testing.expect(!approveHasComments(&review, &fix.d, rows, 4, false));
    try std.testing.expect(!approveHasComments(&review, &fix.d, rows, 7, false));
    try std.testing.expect(approveHasComments(&review, &fix.d, rows, 1, true));
    try std.testing.expect(approveHasComments(&review, &fix.d, rows, 4, true));
}

test "confirmNext approve yes and no" {
    const alloc = std.testing.allocator;
    var review = try store.initEmpty(alloc, "t");
    defer review.deinit();
    var d = try diff.parse(alloc, "");
    defer d.deinit();
    try std.testing.expect(confirmNext(.approve, false, true, &review, &d, &.{}, 0, false) == .approve);
    try std.testing.expect(confirmNext(.approve, false, false, &review, &d, &.{}, 0, false) == .close);
}
