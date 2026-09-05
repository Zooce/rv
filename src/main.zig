//! `rv` entry point — CLI dispatch + full-screen diff review (MVP-1 / MVP-2.2).
//!
//! With no args: load local-only git diff → flatten rows → load `.rv`
//! comments → TUI (title bar is a short hint; `?` opens help). Keys: `j`/`k`,
//! `h`/`l` pan, `0`/`$` col home/end, `[`/`]` hunk, `{`/`}` file header,
//! `(`/`)` prev/next comment (unapproves a hidden hunk if needed), `/` text search, `n`/`N` next/prev match,
//! `Space` `f` file list, `Space` `c` comment list, `Space` `a` approved list
//! (local; Enter unapproves and jumps), `gs`/`gu`/`gd` hunk git and `gS`/`gU`/`gD`
//! file git (local), `a`/`A` approve hunk/file (local),
//! `i`/`c`/`Enter`
//! create or edit new, `I`/`C` old, `d` dismiss new, `D` dismiss old,
//! `r` reload the loaded diff, `q` quit).
//! Diff layout defaults to side-by-side when the terminal is wide enough;
//! falls back to unified when narrow. `t` toggles session preference
//! (explicit unified stays unified even when wide). `#` toggles line numbers
//! (on by default).
//! Error paths never enter raw / alt-screen mode. An empty model still
//! opens the TUI; the footer shows the load source (`HEAD · empty` when
//! the worktree is clean, `HEAD · N approved` when every local change is
//! hidden).
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
//! File list: `Space` then `f` opens a centered overlay of changed-file
//! paths (flatten order). `j`/`k` move; Enter jumps to that file header and
//! closes. Esc closes without moving the cursor. `q` still quits. Empty
//! diff: empty overlay. Opens on the file under the cursor when there is
//! one. Local only: `g` then `s`/`u`/`d` stages, unstages, or discards the
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
//! handled as usual. Local `a` approves the current hunk; `A` approves the
//! remaining hunks of that file in this group (from a hunk or the file
//! header; no-op on a section). No confirm. Range loads ignore `a`/`A`.
//! Git failure opens a centered overlay with git’s error; Enter or Esc
//! dismisses. The list is unchanged. Local load paints git and approve
//! chords on the current file and hunk rows (no hints on a range load).
//!
//! Comment list: `Space` then `c` opens a centered overlay of live comments
//! (same store as `rv list`). `j`/`k` move; Enter jumps with the same landing
//! as `(`/`)` and closes the overlay. A live comment on an approved hunk
//! unapproves that hunk, rebuilds, and lands (same as `(`/`)`). Esc closes
//! without moving the cursor. A row whose path/line is gone from the live
//! diff stays in the list and shows a footer note. `q` still quits.
//!
//! Approved list: `Space` then `a` opens a centered overlay of live approved
//! identities (flatten order). Local only. `j`/`k` move; Enter removes one
//! matching store entry, rebuilds the main list, jumps to that row, and
//! closes. Esc closes without changing approval. Empty set: empty overlay.
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
    var diff_view: DiffView = blk: {
        var parsed = switch (source) {
            .local => git.loadDefaultDiff(alloc, io),
            .range => |r| git.loadRangeDiff(alloc, io, .inherit, r),
        } catch |err| {
            std.debug.print("rv: {s}\n", .{git.errorMessage(err)});
            return 1;
        };
        errdefer parsed.deinit();
        const vis = flattenSource(alloc, io, source, &parsed) catch |err| {
            std.debug.print("rv: {s}\n", .{approvedLoadMessage(err)});
            return 1;
        };
        errdefer alloc.free(vis.rows);
        break :blk try DiffView.build(alloc, parsed, vis.rows, vis.approved_n);
    };
    defer diff_view.deinit(alloc);

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

    var viewport: Viewport = .{};
    var running = true;
    // Exactly one focus; cannot help, comment, search, and list at once.
    var focus: Focus = .normal;
    // Exactly one leader: `Space` lists (`f` files, `c` comments, `a`
    // approved), `g` git (`s`/`u`/`d` hunk, `S`/`U`/`D` file). Cleared on the
    // next key. Unmatched is dropped; the second key is handled as usual.
    const Leader = enum { none, lists, git };
    var leader: Leader = .none;
    var discard_confirm: DiscardConfirm = .{};
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
    var failure: Failure = .{};
    defer failure.buf.deinit(alloc);

    frame.paint(&scr, size, &diff_view, &viewport, &review, source, focus, &draft, discard_confirm);
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
                    .commenting => switch (try draft.handleKey(alloc, io, &review, key, size)) {
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
                            viewport.cursor = hit.index;
                            if (hit.wrapped) frame.note.set("search wrapped");
                        },
                        .missing => {
                            focus = .normal;
                            frame.note.setFmt("Pattern not found: {s}", .{search.last_query.items});
                        },
                        .open => {},
                    },
                    .listing => switch (comment_list.handleKey(key, diff_view.rows)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .help => {
                            help.scroll = 0;
                            focus = .helping;
                        },
                        .jump => |row| {
                            focus = .normal;
                            viewport.cursor = row;
                        },
                        .hidden => |loc| {
                            focus = .normal;
                            _ = try landComment(
                                alloc,
                                io,
                                source,
                                &diff_view,
                                &viewport.cursor,
                                &frame.note,
                                loc,
                            );
                        },
                        .missing => frame.note.set("comment not in this diff"),
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
                                approved_list.items.items[idx],
                            );
                        },
                        .open => {},
                    },
                    .git_error => switch (failure.handleKey(key)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .open => {},
                    },
                    .discard_confirm => switch (discard_confirm.handleKey(
                        key,
                        &review,
                        &diff_view.diff,
                        diff_view.rows,
                        viewport.cursor,
                    )) {
                        .closed => focus = .normal,
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
                                &failure,
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
                                &failure,
                                &review,
                                discard_confirm.whole_file,
                                .discard,
                                delete_them,
                            );
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
                                    focus = .listing;
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
                                    try dispatchGitIndex(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &failure,
                                        &review,
                                        false,
                                        true,
                                    );
                                } else if (pending == .git and c == 'u') {
                                    try dispatchGitIndex(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &failure,
                                        &review,
                                        false,
                                        false,
                                    );
                                } else if (pending == .git and c == 'd') {
                                    beginGitDiscard(source, diff_view.rows, viewport.cursor, &discard_confirm, &focus, false);
                                } else if (pending == .git and c == 'S') {
                                    try dispatchGitIndex(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &failure,
                                        &review,
                                        true,
                                        true,
                                    );
                                } else if (pending == .git and c == 'U') {
                                    try dispatchGitIndex(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &failure,
                                        &review,
                                        true,
                                        false,
                                    );
                                } else if (pending == .git and c == 'D') {
                                    beginGitDiscard(source, diff_view.rows, viewport.cursor, &discard_confirm, &focus, true);
                                } else if (viewport.handleKey(.{ .char = c }, size.cols, diff_view.rows, diff_view.sbs_slots) == .handled) {
                                    // j/k/h/l/0/$/J/K/[/]/{/}/t/#
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
                                    search.buf.clearRetainingCapacity();
                                    search.caret = 0;
                                    focus = .searching;
                                } else if (c == 'n') {
                                    switch (search.next(diff_view.rows, viewport.cursor)) {
                                        .none => {},
                                        .missing => frame.note.set("Pattern not found"),
                                        .hit => |hit| {
                                            viewport.cursor = hit.index;
                                            if (hit.wrapped) frame.note.set("search wrapped");
                                        },
                                    }
                                } else if (c == 'N') {
                                    switch (search.prev(diff_view.rows, viewport.cursor)) {
                                        .none => {},
                                        .missing => frame.note.set("Pattern not found"),
                                        .hit => |hit| {
                                            viewport.cursor = hit.index;
                                            if (hit.wrapped) frame.note.set("search wrapped");
                                        },
                                    }
                                } else if (c == ')') {
                                    try jumpLiveComment(&review, &diff_view, alloc, io, source, &viewport.cursor, &frame.note, .next);
                                } else if (c == '(') {
                                    try jumpLiveComment(&review, &diff_view, alloc, io, source, &viewport.cursor, &frame.note, .prev);
                                } else if (c == 'r') {
                                    reloadDiff(alloc, io, source, &diff_view, &viewport.cursor, &frame.note);
                                } else if (c == 'i' or c == 'c') {
                                    if (try draft.begin(&review, alloc, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .new)) {
                                        focus = .commenting;
                                    }
                                } else if (c == 'I' or c == 'C') {
                                    if (try draft.begin(&review, alloc, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .old)) {
                                        focus = .commenting;
                                    }
                                } else if (c == 'a') {
                                    try applyApprove(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        false,
                                    );
                                } else if (c == 'A') {
                                    try applyApprove(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
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
        }
        if (running) {
            frame.paint(&scr, size, &diff_view, &viewport, &review, source, focus, &draft, discard_confirm);
            if (focus == .helping) {
                help.paint(&scr, size);
                scr.hideCursor();
            } else if (focus == .git_error) {
                failure.paint(&scr, size);
                scr.hideCursor();
            } else if (focus == .files) {
                file_list.paint(&scr, size, diff_view.rows);
                scr.hideCursor();
            } else if (focus == .listing) {
                comment_list.paint(&scr, size);
                scr.hideCursor();
            } else if (focus == .approved) {
                approved_list.paint(&scr, size);
                scr.hideCursor();
            } else if (focus == .discard_confirm) {
                discard_confirm.paint(&scr, size, diff_view.rows, viewport.cursor);
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
pub const DiffView = struct {
    diff: diff.Diff,
    /// Flatten rows (paint, nav, git targeting). Strings borrow from `diff`.
    rows: []view.row.Row,
    sbs_slots: []view.layout.SbsSlot,
    /// Live approved identities still in `diff` after prune. 0 on range loads.
    approved_n: usize,

    fn maybeInit(
        alloc: std.mem.Allocator,
        io: std.Io,
        source: cli.Source,
        note: *StatusNote,
    ) ?DiffView {
        var new_diff = switch (source) {
            .local => git.loadDefaultDiff(alloc, io),
            .range => |r| git.loadRangeDiff(alloc, io, .inherit, r),
        } catch |err| {
            note.set(git.errorMessage(err));
            return null;
        };
        const vis = flattenSource(alloc, io, source, &new_diff) catch |err| {
            new_diff.deinit();
            note.set(approvedLoadMessage(err));
            return null;
        };
        return build(alloc, new_diff, vis.rows, vis.approved_n) catch {
            alloc.free(vis.rows);
            new_diff.deinit();
            note.set("out of memory");
            return null;
        };
    }

    fn build(
        alloc: std.mem.Allocator,
        parsed: diff.Diff,
        rows: []view.row.Row,
        approved_n: usize,
    ) std.mem.Allocator.Error!DiffView {
        const sbs = try view.layout.pairSideBySide(alloc, rows);
        return .{
            .diff = parsed,
            .rows = rows,
            .sbs_slots = sbs,
            .approved_n = approved_n,
        };
    }

    fn deinit(self: DiffView, alloc: std.mem.Allocator) void {
        alloc.free(self.rows);
        alloc.free(self.sbs_slots);
        var parsed = self.diff;
        parsed.deinit();
    }

    fn replaceRows(
        self: *DiffView,
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

fn flattenSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
    d: *const diff.Diff,
) approve.LoadError!approve.Visible {
    return switch (source) {
        .local => approve.loadVisible(alloc, io, .cwd(), d),
        .range => .{ .rows = try view.row.flatten(alloc, d), .approved_n = 0 },
    };
}

fn approvedLoadMessage(err: approve.LoadError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.InvalidJson, error.InvalidHash => "invalid .rv approved JSON",
        else => "failed to load .rv approved store",
    };
}

/// Re-run the startup load. On success, replace the live DiffView and restore
/// the cursor to the same path+line. On failure, leave the previous list and
/// set `note`. Does not touch the comment store. `r` is only bound in normal
/// focus.
fn reloadDiff(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
) void {
    const loaded = DiffView.maybeInit(alloc, io, source, note) orelse return;
    const new_cursor: usize = blk: {
        const mark = view.nav.cursorMarkAt(diff_view.rows, cursor.*);
        break :blk if (mark) |m| view.nav.restoreCursor(loaded.rows, m) else 0;
    };
    diff_view.deinit(alloc);
    diff_view.* = loaded;
    cursor.* = new_cursor;
}

/// Approve the hunk (`whole_file == false`, requires a hunk) or the remaining
/// hunks of that file in this group (`true`, from a hunk or the file header).
/// Local only. No-op on a section, on a file header for hunk approve, and
/// when the source is a range. Save, hide, restore onto the neighbor change
/// (same rule as staging a row away). Does not mutate git.
fn applyApprove(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
    whole_file: bool,
) std.mem.Allocator.Error!void {
    if (source != .local) return;
    const rows = diff_view.rows;
    const target = git.indexTargetAt(rows, cursor.*, whole_file) orelse return;
    if (!whole_file and target.hunk_i == null) return;
    const file = groupedFile(&diff_view.diff, target.path, target.group) orelse return;
    const root: std.Io.Dir = .cwd();
    var approved = approve.load(alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set(approvedLoadMessage(err));
            return;
        },
    };
    defer approved.deinit();

    const hunk_mark = git.neighborMark(rows, target);
    if (whole_file) {
        try approved.appendFile(alloc, io, root, file.*);
    } else {
        const hh = switch (rows[target.first]) {
            .hunk_header => |h| h,
            else => return,
        };
        const hi = approve.hunkAt(file.*, hh.old_start, hh.new_start) orelse return;
        try approved.append(file.displayPath(), approve.fingerprintHunk(file.hunks[hi]));
    }

    const live = try approve.collectLive(alloc, io, root, &diff_view.diff);
    defer alloc.free(live);
    try approved.prune(alloc, live);
    approve.save(&approved, alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set("failed to save .rv approved store");
            return;
        },
    };

    const new_rows = try approve.hide(alloc, &diff_view.diff, &approved, io, root);
    const restored: usize = if (hunk_mark) |m|
        git.restoreNeighbor(new_rows, m)
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
    source: cli.Source,
    diff_view: *DiffView,
    note: *StatusNote,
    item: approve.Hidden,
) std.mem.Allocator.Error!bool {
    if (source != .local) return false;
    const root: std.Io.Dir = .cwd();
    var approved = approve.load(alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set(approvedLoadMessage(err));
            return false;
        },
    };
    defer approved.deinit();
    approved.unapprove(item.path, item.hash) catch return false;

    const live = try approve.collectLive(alloc, io, root, &diff_view.diff);
    defer alloc.free(live);
    try approved.prune(alloc, live);
    approve.save(&approved, alloc, io, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            note.set("failed to save .rv approved store");
            return false;
        },
    };

    const new_rows = try approve.hide(alloc, &diff_view.diff, &approved, io, root);
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
    source: cli.Source,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
    item: approve.Hidden,
) std.mem.Allocator.Error!void {
    if (!try unapproveRebuild(alloc, io, source, diff_view, note, item)) return;
    const jump = approve.rowForIdentity(
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

/// Stage, unstage, or discard the current file or hunk (local source only).
/// Hunk chords (`gs`/`gu`/`gd`) pass `whole_file == false` and require a
/// hunk; file chords (`gS`/`gU`/`gD`) pass `true`.
fn applyIndex(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    failure: *Failure,
    review: *store.Review,
    whole_file: bool,
    kind: git.MutationKind,
    delete_comments: bool,
) std.mem.Allocator.Error!void {
    if (source != .local) return;
    try commitApply(alloc, diff_view, cursor, note, focus, failure, try git.applyAtCursor(
        alloc,
        io,
        .inherit,
        &diff_view.diff,
        diff_view.rows,
        cursor.*,
        review,
        whole_file,
        kind,
        delete_comments,
    ));
}

/// Stage or unstage every file in the section under the cursor (local only).
fn applyGroupIndex(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    failure: *Failure,
    review: *store.Review,
) std.mem.Allocator.Error!void {
    if (source != .local) return;
    try commitApply(alloc, diff_view, cursor, note, focus, failure, try git.applyGroupAtCursor(
        alloc,
        io,
        .inherit,
        &diff_view.diff,
        diff_view.rows,
        cursor.*,
        review,
    ));
}

/// Stage (`stage`) or unstage (`!stage`) the hunk or file at the cursor.
/// Hunk chords require a hunk (no-op on a file header). Already-staged
/// stage and not-staged unstage are no-ops. Local only.
fn dispatchGitIndex(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    failure: *Failure,
    review: *store.Review,
    whole_file: bool,
    stage: bool,
) std.mem.Allocator.Error!void {
    const target = git.indexTargetAt(diff_view.rows, cursor.*, whole_file) orelse return;
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
        failure,
        review,
        whole_file,
        .stage_unstage,
        false,
    );
}

/// Open the discard confirm for the hunk or file at the cursor. Hunk
/// discard requires a hunk. Staged and range loads are no-ops.
fn beginGitDiscard(
    source: cli.Source,
    rows: []const view.row.Row,
    cursor: usize,
    discard: *DiscardConfirm,
    focus: *Focus,
    whole_file: bool,
) void {
    if (source != .local) return;
    const target = git.discardTargetAt(rows, cursor, whole_file) orelse return;
    if (!whole_file and target.hunk_i == null) return;
    discard.* = .{ .whole_file = whole_file, .yes = false, .comments = false };
    focus.* = .discard_confirm;
}

/// Map a mutation result onto the live DiffView, status note, and git-error overlay.
fn commitApply(
    alloc: std.mem.Allocator,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    failure: *Failure,
    status: git.MutationStatus,
) std.mem.Allocator.Error!void {
    const result = switch (status) {
        .noop => return,
        .result => |r| r,
    };
    if (result.snapshot) |snap| {
        if (DiffView.build(alloc, snap.diff, snap.rows, snap.approved_n)) |loaded| {
            diff_view.deinit(alloc);
            diff_view.* = loaded;
            cursor.* = snap.cursor;
        } else |_| {
            snap.deinit(alloc);
            note.set("out of memory");
        }
    } else if (result.reload_err) |err| {
        note.set(git.errorMessage(err));
    }
    if (result.save_failed) note.set("failed to save .rv comment store");
    if (result.fail_message) |msg| {
        defer alloc.free(msg);
        failure.buf.clearRetainingCapacity();
        try failure.buf.appendSlice(alloc, msg);
        focus.* = .git_error;
    }
}

/// Key ownership: normal nav, comment draft, `/` search prompt, comment list,
/// file list, approved list, help, git error overlay, or discard confirm.
pub const Focus = enum { normal, commenting, searching, listing, files, approved, helping, git_error, discard_confirm };

/// Confirm overlay for discard (`gd` / `gD`). `yes` is the selected
/// choice. Opens with **No** selected (Enter does not apply). Discard:
/// if the target has live comments, `comments` is the second overlay
/// and defaults to **Yes** (delete).
pub const DiscardConfirm = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        group,
        discard: bool,
    };

    kind: git.ConfirmKind = .discard,
    group: diff.Group = .unstaged,
    whole_file: bool = false,
    yes: bool = false,
    comments: bool = false,

    fn handleKey(
        self: *DiscardConfirm,
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
        switch (git.confirmNext(
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
        }
    }

    fn paint(
        self: DiscardConfirm,
        scr: *tui.Screen,
        size: tui.Size,
        rows: []const view.row.Row,
        cursor: usize,
    ) void {
        const bg = tui.Color{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } };
        const fg = tui.Color{ .rgb = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 } };
        const panel_bg = tui.Style{ .fg = fg, .bg = bg };
        const panel_frame = tui.Style{
            .fg = .{ .rgb = .{ .r = 0x5d, .g = 0x81, .b = 0xb7 } },
            .bg = bg,
            .bold = true,
        };
        const choice_cur = tui.Style{
            .fg = fg,
            .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x30 } },
            .bold = true,
        };

        var hunk_buf: [512]u8 = undefined;
        const group = self.kind == .group;
        const hunk_text: []const u8, const path: []const u8 = if (group or self.comments)
            .{ "", "" }
        else blk: {
            const target = git.indexTargetAt(rows, cursor, self.whole_file);
            const hunk_row: ?view.row.Row = if (target) |t|
                if (t.hunk_i != null) rows[t.first] else null
            else
                null;
            const ht: []const u8 = if (hunk_row) |hr| Frame.formatRow(&hunk_buf, hr, false) else "";
            break :blk .{ ht, if (target) |t| t.path else "" };
        };

        const content_n: u16 = if (group or self.comments)
            3
        else if (hunk_text.len > 0)
            4
        else
            3;
        const want_w: u16 = @min(size.cols -| 4, 60);
        const panel = tui.Rect.centered(size.cols, size.rows, want_w, content_n + 2);
        scr.fillRect(panel, ' ', panel_bg);
        scr.drawBox(panel, panel_frame);
        if (panel.h > 0 and panel.w > 2) {
            const title: []const u8 = switch (self.kind) {
                .group => switch (self.group) {
                    .unstaged, .untracked => " stage ",
                    .staged => " unstage ",
                },
                .discard => if (self.comments) " comments " else " discard ",
            };
            scr.putStr(panel.x + 2, panel.y, title, panel_frame, panel);
        }
        const inner = panel.inset(1);
        if (inner.h == 0 or inner.w == 0) return;
        var row: u16 = 0;
        if (group) {
            const question: []const u8 = switch (self.group) {
                .unstaged => "Stage all unstaged?",
                .untracked => "Stage all untracked?",
                .staged => "Unstage all staged?",
            };
            if (row < inner.h) {
                scr.putStr(inner.x, inner.y + row, question, panel_bg, inner);
                row += 1;
            }
        } else if (self.comments) {
            if (row < inner.h) {
                scr.putStr(inner.x, inner.y + row, "delete comments with this change?", panel_bg, inner);
                row += 1;
            }
        } else {
            if (path.len > 0 and row < inner.h) {
                scr.putStr(inner.x, inner.y + row, path, panel_bg, inner);
                row += 1;
            }
            if (hunk_text.len > 0 and row < inner.h) {
                const start: usize = if (hunk_text[0] == ' ') 1 else 0;
                scr.putStr(inner.x, inner.y + row, hunk_text[start..], panel_bg, inner);
                row += 1;
            }
        }
        if (row < inner.h) row += 1;
        if (row >= inner.h) return;
        paintYesNoChoices(scr, inner, inner.y + row, self.yes, self.comments, panel_bg, choice_cur);
    }

    pub fn titleBar(self: DiscardConfirm) []const u8 {
        return switch (self.kind) {
            .group => switch (self.group) {
                .unstaged, .untracked => "rv  stage all  No/yes  Enter  Esc cancel  q quit",
                .staged => "rv  unstage all  No/yes  Enter  Esc cancel  q quit",
            },
            .discard => if (self.comments)
                "rv  discard comments  no/Yes  Enter  Esc cancel  q quit"
            else
                "rv  discard  No/yes  Enter  Esc cancel  q quit",
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
        scr.putStr(no_x, y, no_label, n_st, inner);
        scr.fillRect(.{ .x = yes_x -| 1, .y = y, .w = yes_w + 2, .h = 1 }, ' ', y_st);
        scr.putStr(yes_x, y, yes_label, y_st, inner);
    }
};

/// Comment prompt: buffer, caret, keys, save, and footer paint.
pub const Draft = struct {
    const Result = enum { open, closed, quit, save_failed };

    buf: std.ArrayList(u8) = .empty,
    scroll: usize = 0,
    caret: usize = 0,
    anchor: view.row.Anchor = .{ .path = "", .old_line = null, .new_line = null },
    edit_id: ?[]const u8 = null,

    fn clear(self: *Draft) void {
        self.buf.clearRetainingCapacity();
        self.scroll = 0;
        self.caret = 0;
        self.edit_id = null;
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
        self.clear();
        self.anchor = found.anchor;
        if (found.idx) |idx| {
            const c = review.comments.items[idx];
            try self.buf.appendSlice(alloc, c.body);
            self.caret = self.buf.items.len;
            self.edit_id = c.id;
        }
        return true;
    }

    pub fn titleBar(self: *const Draft) []const u8 {
        const side = sideForAnchor(self.anchor) orelse
            return "rv  create/edit file  Enter save  Esc cancel  ↑↓ scroll";
        return switch (side) {
            .new => "rv  create/edit new  Enter save  Esc cancel  ↑↓ scroll",
            .old => "rv  create/edit old  Enter save  Esc cancel  ↑↓ scroll",
            .context => "rv  create/edit  Enter save  Esc cancel  ↑↓ scroll",
        };
    }

    fn handleKey(
        self: *Draft,
        alloc: std.mem.Allocator,
        io: std.Io,
        review: *store.Review,
        key: tui.Key,
        size: tui.Size,
    ) std.mem.Allocator.Error!Result {
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
                        const side = sideForAnchor(self.anchor);
                        _ = try review.addOpen(
                            self.anchor.path,
                            self.anchor.old_line,
                            self.anchor.new_line,
                            side,
                            self.buf.items,
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
        self.ensureCaretVisible(size);
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
        jump: view.search.SearchHit,
        missing,
    };

    const Match = union(enum) {
        none,
        missing,
        hit: view.search.SearchHit,
    };

    buf: std.ArrayList(u8) = .empty,
    caret: usize = 0,
    last_query: std.ArrayList(u8) = .empty,

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
        scr.putStr(1, footer_y, prompt, footer_style, null);
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

    cursor: usize = 0,
    scroll: usize = 0,
    /// First visible display column for lines in the cursor's hunk only.
    col_scroll: usize = 0,
    /// Prefer side-by-side; auto-unified when narrow. `t` flips session preference.
    layout_pref: view.layout.LayoutPref = .side_by_side,
    /// Line numbers in the body gutter. `#` flips. Default on.
    show_line_numbers: bool = true,

    /// Columns available for horizontal pan: text area after the sticky gutter.
    fn panViewportCols(self: *const Viewport, cols: u16, rows: []const view.row.Row) u16 {
        const layout = view.layout.effectiveLayout(self.layout_pref, cols);
        const full: u16 = switch (layout) {
            .unified => cols,
            .side_by_side => view.layout.sbsPaneWidths(cols).left_w,
        };
        const num_w = if (self.show_line_numbers) Frame.lineNumberWidth(rows) else 0;
        const gw = Frame.lineGutterCols(num_w, layout);
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
        const step = panStep(self.panViewportCols(cols, rows));
        self.col_scroll = if (self.col_scroll > step) self.col_scroll - step else 0;
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
                'h' => self.panLeft(cols, rows),
                'l' => self.col_scroll +%= panStep(self.panViewportCols(cols, rows)),
                '0' => self.col_scroll = 0,
                '$' => {
                    const span = view.viewport.hunkSpanAt(rows, self.cursor);
                    self.col_scroll = view.viewport.colScrollToEnd(
                        Frame.hunkMaxLineWidth(rows, span),
                        self.panViewportCols(cols, rows),
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
                else => return .unhandled,
            },
            .down => self.moveLineDown(cols, rows, slots),
            .up => self.moveLineUp(cols, rows, slots),
            .left => self.panLeft(cols, rows),
            .right => self.col_scroll +%= panStep(self.panViewportCols(cols, rows)),
            else => return .unhandled,
        }
        return .handled;
    }

    /// Clamp pan and vertical scroll for the current cursor and content area.
    /// Returns the sticky file header to pin above the body.
    pub fn settle(
        self: *Viewport,
        cols: u16,
        content_rows: usize,
        rows: []const view.row.Row,
        slots: []const view.layout.SbsSlot,
    ) view.viewport.Sticky {
        const cur = view.row.clampCursor(self.cursor, rows.len);
        const pan_span = view.viewport.hunkSpanAt(rows, cur);
        self.col_scroll = view.viewport.clampColScroll(
            self.col_scroll,
            Frame.hunkMaxLineWidth(rows, pan_span),
            self.panViewportCols(cols, rows),
        );
        switch (view.layout.effectiveLayout(self.layout_pref, cols)) {
            .unified => {
                const settled = view.viewport.ensureVisibleSticky(self.scroll, cur, content_rows, rows);
                self.scroll = settled.scroll;
                return settled.sticky;
            },
            .side_by_side => {
                const settled = view.viewport.ensureVisibleStickySbs(self.scroll, cur, content_rows, slots, rows);
                self.scroll = settled.scroll;
                return settled.sticky;
            },
        }
    }
};

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

/// Comment side implied by which line numbers the anchor has.
/// Path-only (file) anchors have no side.
fn sideForAnchor(a: view.row.Anchor) ?store.Side {
    if (a.old_line == null and a.new_line == null) return null;
    if (a.old_line != null and a.new_line != null) return .context;
    if (a.new_line != null) return .new;
    return .old;
}

fn locFromRow(row: view.row.Row) ?view.CommentLoc {
    return switch (row) {
        .file_header => |fh| .{ .path = fh.path },
        .line => |ln| blk: {
            if (ln.new_no) |n| break :blk .{ .path = ln.path, .side = .new, .line = n };
            if (ln.old_no) |n| break :blk .{ .path = ln.path, .side = .old, .line = n };
            break :blk null;
        },
        .hunk_header, .section_header => null,
    };
}

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
            return hh.group == other.group and hh.old_start == other.old_start and hh.new_start == other.new_start;
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
    source: cli.Source,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
    loc: view.CommentLoc,
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
    const item = approve.identityAtRow(alloc, &diff_view.diff, io, .cwd(), full, full_row) orelse {
        note.set("comment not in this diff");
        return false;
    };
    if (!try unapproveRebuild(alloc, io, source, diff_view, note, item)) return false;
    const row = view.rowForComment(diff_view.rows, loc) orelse {
        note.set("comment not in this diff");
        return false;
    };
    cursor.* = row;
    return true;
}

fn jumpLiveComment(
    review: *const store.Review,
    diff_view: *DiffView,
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
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
    const loc = locFromRow(walk_rows[hit.row]) orelse {
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
        if (found.anchor.old_line == null and found.anchor.new_line == null)
            note.set("no comment on this file")
        else
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

/// Comment-list overlay (`Space` `c`): snapshot of live comments, cursor, keys, and paint.
const CommentList = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        help,
        jump: usize,
        hidden: view.CommentLoc,
        missing,
    };

    items: std.ArrayList(store.Comment) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,

    fn load(
        self: *CommentList,
        alloc: std.mem.Allocator,
        live: []const store.Comment,
    ) std.mem.Allocator.Error!void {
        self.items.clearRetainingCapacity();
        try self.items.appendSlice(alloc, live);
        self.cursor = 0;
        self.scroll = 0;
    }

    fn handleKey(self: *CommentList, key: tui.Key, rows: []const view.row.Row) Result {
        switch (key) {
            .esc => return .closed,
            .enter => {
                if (self.cursor >= self.items.items.len) return .open;
                const loc = comments.loc(self.items.items[self.cursor]) orelse return .missing;
                if (view.rowForComment(rows, loc)) |idx| return .{ .jump = idx };
                return .{ .hidden = loc };
            },
            .char => |c| {
                if (c == 'q' or c == 'Q') return .quit;
                if (c == '?') return .help;
                if (c == 'j') {
                    if (self.cursor + 1 < self.items.items.len) self.cursor += 1;
                } else if (c == 'k') {
                    if (self.cursor > 0) self.cursor -= 1;
                }
            },
            .down => {
                if (self.cursor + 1 < self.items.items.len) self.cursor += 1;
            },
            .up => {
                if (self.cursor > 0) self.cursor -= 1;
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn formatLineCol(buf: []u8, c: store.Comment) []const u8 {
        const found = comments.loc(c) orelse return "-";
        const side = found.side orelse return "-";
        const line = found.line orelse return "-";
        return switch (side) {
            .old => Frame.bufPrintTrunc(buf, "-{d}", .{line}),
            .new => Frame.bufPrintTrunc(buf, "+{d}", .{line}),
        };
    }

    fn formatLine(buf: []u8, c: store.Comment) []const u8 {
        var line_col_buf: [16]u8 = undefined;
        const line_col = formatLineCol(&line_col_buf, c);
        const side: []const u8 = if (c.old_line == null and c.new_line == null)
            "file"
        else if (c.side) |s| switch (s) {
            .old => "old",
            .new => "new",
            .context => "ctx",
        } else "-";
        const prefix = Frame.bufPrintTrunc(buf, "{s}  {s}  {s}  {s}  ", .{ c.id, c.path, side, line_col });
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

        const items = self.items.items;
        const panel = listOverlayRect(size.cols, size.rows, items.len);
        scr.fillRect(panel, ' ', panel_bg);
        scr.drawBox(panel, panel_frame);
        const inner = panel.inset(1);
        if (panel.h > 0 and panel.w > 2) {
            scr.putStr(panel.x + 2, panel.y, " comments ", panel_frame, panel);
        }
        ensureListCursorVisible(&self.scroll, self.cursor, inner.h, items.len);
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
        const start = self.scroll;
        var line_buf: [512]u8 = undefined;
        var row: u16 = 0;
        while (row < inner.h) : (row += 1) {
            const idx = start + row;
            if (idx >= items.len) break;
            const y = inner.y + row;
            const st = if (idx == self.cursor) row_cur else panel_bg;
            scr.fillRect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, ' ', st);
            const text = formatLine(&line_buf, items[idx]);
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
};

/// File-list overlay (`Space` `f`): snapshot of file-header rows, cursor, keys, and paint.
const FileList = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        help,
        jump: usize,
    };

    items: std.ArrayList(usize) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,

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
        self.cursor = 0;
        self.scroll = 0;
        if (current_file) |start| {
            for (self.items.items, 0..) |idx, n| {
                if (idx == start) {
                    self.cursor = n;
                    break;
                }
            }
        }
    }

    fn handleKey(self: *FileList, key: tui.Key) Result {
        switch (key) {
            .esc => return .closed,
            .enter => {
                if (self.cursor < self.items.items.len) return .{ .jump = self.items.items[self.cursor] };
            },
            .char => |c| {
                if (c == 'q' or c == 'Q') return .quit;
                if (c == '?') return .help;
                if (c == 'j') {
                    if (self.cursor + 1 < self.items.items.len) self.cursor += 1;
                } else if (c == 'k') {
                    if (self.cursor > 0) self.cursor -= 1;
                }
            },
            .down => {
                if (self.cursor + 1 < self.items.items.len) self.cursor += 1;
            },
            .up => {
                if (self.cursor > 0) self.cursor -= 1;
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn paint(self: *FileList, scr: *tui.Screen, size: tui.Size, rows: []const view.row.Row) void {
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

        const items = self.items.items;
        const panel = listOverlayRect(size.cols, size.rows, items.len);
        scr.fillRect(panel, ' ', panel_bg);
        scr.drawBox(panel, panel_frame);
        const inner = panel.inset(1);
        if (panel.h > 0 and panel.w > 2) {
            scr.putStr(panel.x + 2, panel.y, " files ", panel_frame, panel);
        }
        ensureListCursorVisible(&self.scroll, self.cursor, inner.h, items.len);
        if (inner.h == 0 or inner.w == 0) return;
        if (items.len == 0) {
            scr.putStr(inner.x, inner.y, "no files", panel_bg, inner);
            return;
        }
        const show_bar = items.len > inner.h;
        const text_area = if (show_bar)
            tui.Rect{ .x = inner.x, .y = inner.y, .w = inner.w -| 2, .h = inner.h }
        else
            inner;
        const start = self.scroll;
        var path_buf: [512]u8 = undefined;
        var row: u16 = 0;
        while (row < inner.h) : (row += 1) {
            const idx = start + row;
            if (idx >= items.len) break;
            const y = inner.y + row;
            const st = if (idx == self.cursor) row_cur else panel_bg;
            scr.fillRect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, ' ', st);
            const path = view.row.fileHeaderPathLabel(rows[items[idx]].file_header, &path_buf);
            scr.putStr(inner.x, y, path, st, text_area);
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
    cursor: usize = 0,
    scroll: usize = 0,

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
        self.cursor = 0;
        self.scroll = 0;
        if (rows.len == 0) return;
        const cur = view.row.clampCursor(cursor, rows.len);
        if (rows[cur] == .section_header) return;
        const start = view.nav.currentFileStart(rows, cur) orelse return;
        const fh = rows[start].file_header;
        for (self.items.items, 0..) |item, n| {
            if (!std.mem.eql(u8, item.path, fh.path)) continue;
            if (item.group != fh.group) continue;
            self.cursor = n;
            break;
        }
    }

    fn handleKey(self: *ApprovedList, key: tui.Key) Result {
        switch (key) {
            .esc => return .closed,
            .enter => {
                if (self.cursor < self.items.items.len) return .{ .unapprove = self.cursor };
            },
            .char => |c| {
                if (c == 'q' or c == 'Q') return .quit;
                if (c == '?') return .help;
                if (c == 'j') {
                    if (self.cursor + 1 < self.items.items.len) self.cursor += 1;
                } else if (c == 'k') {
                    if (self.cursor > 0) self.cursor -= 1;
                }
            },
            .down => {
                if (self.cursor + 1 < self.items.items.len) self.cursor += 1;
            },
            .up => {
                if (self.cursor > 0) self.cursor -= 1;
            },
            .ctrl_c => return .quit,
            else => {},
        }
        return .open;
    }

    fn formatLine(buf: []u8, item: approve.Hidden) []const u8 {
        const group: []const u8 = if (item.group) |g| switch (g) {
            .unstaged => "Unstaged",
            .untracked => "Untracked",
            .staged => "Staged",
        } else "-";
        const preview: []const u8 = switch (item.kind) {
            .hunk => if (item.preview.len > 0) item.preview else "hunk",
            .binary => "binary",
            .file => "file",
        };
        const prefix = Frame.bufPrintTrunc(buf, "{s}  {s}  ", .{ item.path, group });
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

        const items = self.items.items;
        const panel = listOverlayRect(size.cols, size.rows, items.len);
        scr.fillRect(panel, ' ', panel_bg);
        scr.drawBox(panel, panel_frame);
        const inner = panel.inset(1);
        if (panel.h > 0 and panel.w > 2) {
            scr.putStr(panel.x + 2, panel.y, " approved ", panel_frame, panel);
        }
        ensureListCursorVisible(&self.scroll, self.cursor, inner.h, items.len);
        if (inner.h == 0 or inner.w == 0) return;
        if (items.len == 0) {
            scr.putStr(inner.x, inner.y, "no approved", panel_bg, inner);
            return;
        }
        const show_bar = items.len > inner.h;
        const text_area = if (show_bar)
            tui.Rect{ .x = inner.x, .y = inner.y, .w = inner.w -| 2, .h = inner.h }
        else
            inner;
        const start = self.scroll;
        var line_buf: [512]u8 = undefined;
        var row: u16 = 0;
        while (row < inner.h) : (row += 1) {
            const idx = start + row;
            if (idx >= items.len) break;
            const y = inner.y + row;
            const st = if (idx == self.cursor) row_cur else panel_bg;
            scr.fillRect(.{ .x = inner.x, .y = y, .w = inner.w, .h = 1 }, ' ', st);
            const text = formatLine(&line_buf, items[idx]);
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
};

/// Dismissible error overlay: message text, keys, and paint.
const Failure = struct {
    const Result = enum { open, closed, quit };

    buf: std.ArrayList(u8) = .empty,

    fn handleKey(self: *Failure, key: tui.Key) Result {
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

    fn paint(self: *const Failure, scr: *tui.Screen, size: tui.Size) void {
        const text = self.buf.items;
        const bg = tui.Color{ .rgb = .{ .r = 0x12, .g = 0x12, .b = 0x14 } };
        const fg = tui.Color{ .rgb = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 } };
        const panel_bg = tui.Style{ .fg = fg, .bg = bg };
        const panel_frame = tui.Style{
            .fg = .{ .rgb = .{ .r = 0x5d, .g = 0x81, .b = 0xb7 } },
            .bg = bg,
            .bold = true,
        };

        var n: usize = 0;
        var count_it = std.mem.splitScalar(u8, text, '\n');
        while (count_it.next()) |_| n += 1;

        const panel = listOverlayRect(size.cols, size.rows, n);
        scr.fillRect(panel, ' ', panel_bg);
        scr.drawBox(panel, panel_frame);
        const inner = panel.inset(1);
        if (panel.h > 0 and panel.w > 2) {
            scr.putStr(panel.x + 2, panel.y, " error ", panel_frame, panel);
        }
        if (inner.h == 0 or inner.w == 0) return;
        var row: u16 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (row >= inner.h) break;
            scr.putStr(inner.x, inner.y + row, line, panel_bg, inner);
            row += 1;
        }
    }
};

test "indexHintForRow section has no git hint" {
    try std.testing.expectEqualStrings("", Frame.indexHintForRow(0, null, null, 0, .unstaged));
    try std.testing.expectEqualStrings("", Frame.indexHintForRow(0, null, null, 0, .untracked));
    try std.testing.expectEqualStrings("", Frame.indexHintForRow(0, null, null, 0, .staged));
    try std.testing.expectEqualStrings("", Frame.indexHintForRow(1, null, null, 0, .unstaged));
    try std.testing.expectEqualStrings("", Frame.indexHintForRow(0, null, null, null, .unstaged));
}

test "draft titleBar file vs line" {
    var draft: Draft = .{};
    draft.anchor = .{ .path = "f", .old_line = null, .new_line = null };
    try std.testing.expectEqualStrings(
        "rv  create/edit file  Enter save  Esc cancel  ↑↓ scroll",
        draft.titleBar(),
    );
    draft.anchor = .{ .path = "f", .old_line = null, .new_line = 1 };
    try std.testing.expectEqualStrings(
        "rv  create/edit new  Enter save  Esc cancel  ↑↓ scroll",
        draft.titleBar(),
    );
    draft.anchor = .{ .path = "f", .old_line = 1, .new_line = null };
    try std.testing.expectEqualStrings(
        "rv  create/edit old  Enter save  Esc cancel  ↑↓ scroll",
        draft.titleBar(),
    );
}

test "comment list file row has no line" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "1  a.zig  file  -  note",
        CommentList.formatLine(&buf, .{ .id = "1", .path = "a.zig", .body = "note" }),
    );
    try std.testing.expectEqualStrings(
        "2  a.zig  new  +10  x",
        CommentList.formatLine(&buf, .{
            .id = "2",
            .path = "a.zig",
            .new_line = 10,
            .side = .new,
            .body = "x",
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

test "draft begin on file header" {
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
    try std.testing.expectEqualStrings("f", draft.anchor.path);
    try std.testing.expect(draft.anchor.old_line == null);
    try std.testing.expect(draft.anchor.new_line == null);
    try std.testing.expect(draft.edit_id == null);

    try std.testing.expect(!try draft.begin(&review, std.testing.allocator, rows, empty, .unified, 1, .new));

    _ = try review.addOpen("f", null, null, null, "hello");
    try std.testing.expect(try draft.begin(&review, std.testing.allocator, rows, empty, .unified, 0, .old));
    try std.testing.expectEqualStrings("hello", draft.buf.items);
    try std.testing.expect(draft.edit_id != null);
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

test "pan viewport uses 2-char gutter when line numbers are off" {
    var vp: Viewport = .{ .layout_pref = .unified };
    const rows: []const view.row.Row = &.{};
    const on = vp.panViewportCols(80, rows);
    vp.show_line_numbers = false;
    const off = vp.panViewportCols(80, rows);
    try std.testing.expectEqual(74, on);
    try std.testing.expectEqual(78, off);
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
    const hidden = try approve.hide(alloc, &d, &approved, io, .cwd());
    defer alloc.free(hidden);

    var list: FileList = .{};
    defer list.items.deinit(alloc);
    try list.load(alloc, hidden, null);
    try std.testing.expectEqual(1, list.items.items.len);
    try std.testing.expectEqualStrings("mixed.txt", hidden[list.items.items[0]].file_header.path);
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
    const hidden = try approve.hide(alloc, &d, &approved, io, .cwd());
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
        .hidden => |loc| {
            try std.testing.expectEqualStrings("f.txt", loc.path);
            try std.testing.expectEqual(.new, loc.side.?);
            try std.testing.expectEqual(1, loc.line.?);
        },
        else => try std.testing.expect(false),
    }
    switch (list.handleKey(.enter, full)) {
        .jump => |row| try std.testing.expectEqual(view.rowForComment(full, .{
            .path = "f.txt",
            .side = .new,
            .line = 1,
        }).?, row),
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
    const hidden = try approve.hide(alloc, &d, &approved, io, .cwd());
    defer alloc.free(hidden);
    try std.testing.expectEqual(0, fullIndexOfHidden(full, hidden, 0));
    try std.testing.expectEqual(4, fullIndexOfHidden(full, hidden, 1));
}
