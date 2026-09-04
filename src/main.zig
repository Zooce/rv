//! `rv` entry point — CLI dispatch + full-screen diff review (MVP-1 / MVP-2.2).
//!
//! With no args: load local-only git diff → flatten rows → load `.rv`
//! comments → TUI (title bar is a short hint; `?` opens help). Keys: `j`/`k`,
//! `h`/`l` pan, `0`/`$` col home/end, `[`/`]` hunk, `{`/`}` file header,
//! `(`/`)` prev/next comment, `/` text search, `n`/`N` next/prev match,
//! `Space` `f` file list, `Space` `l` comment list, `i`/`c`/`a`/`Enter`
//! create or edit new, `I`/`C`/`A` old, `d` dismiss new, `D` dismiss old,
//! `r` reload the loaded diff, `q` quit).
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
//! File list: `Space` then `f` opens a centered overlay of changed-file
//! paths (flatten order). `j`/`k` move; Enter jumps to that file header and
//! closes. Esc closes without moving the cursor. `q` still quits. Empty
//! diff: empty overlay. Opens on the file under the cursor when there is
//! one. Local only: `Space` `Space` stages or unstages the current file
//! (on a file header), hunk (in a hunk), or whole group (on a section
//! header; always confirms); `Space` `S` does the containing file from a
//! hunk. After a successful stage/unstage, live comments on the target
//! keep the same file, side, and line (line numbers updated if the
//! reloaded diff numbers that line differently). `Space` `d` discards the current file or hunk;
//! `Space` `x` discards the containing file from a hunk (stand-in until
//! Ctrl). Discard always confirms (`No` selected; `yes` proceeds). If the
//! target has live comments, a second overlay asks to delete them (`Yes`
//! selected; `no` keeps them). Git discard runs first; comments are
//! deleted only on success. Staged rows are no-ops (unstage first). Range
//! loads ignore those chords. An unmatched `Space` leader is dropped; the
//! next key is handled as normal
//! (`Space` then `d` still dismisses on a range load). Git failure opens
//! a centered overlay with git’s error; Enter or Esc dismisses. The list
//! is unchanged. Local load paints stage/unstage chords on the current
//! section, file, and hunk rows; unstaged/untracked file and hunk rows
//! also show discard chords (no hints on a range load).
//!
//! Comment list: `Space` then `l` opens a centered overlay of live comments
//! (same store as `rv list`). `j`/`k` move; Enter jumps with the same landing
//! as `(`/`)` and closes the overlay. Esc closes without moving the cursor.
//! A row whose path/line is gone from the flatten stays in the list and shows
//! a footer note. `q` still quits.
//!
//! Help: `?` in normal (or from a list overlay) opens a centered overlay
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
        const parsed_rows = try view.row.flatten(alloc, &parsed);
        errdefer alloc.free(parsed_rows);
        const parsed_sbs = try view.layout.pairSideBySide(alloc, parsed_rows);
        break :blk .{ .diff = parsed, .rows = parsed_rows, .sbs_slots = parsed_sbs };
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
    // `Space` leader: next key may be `f` (file list), `l` (comment list),
    // `Space` (stage/unstage current file or hunk, or the group on a
    // section header), `S` (containing file from a hunk), `d` (discard
    // current file or hunk), or `x` (discard containing file from a hunk).
    // Cleared on that next key. Unmatched leader is dropped; on a range
    // load `Space` then `d` still dismisses.
    var leader_pending: bool = false;
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
                    .searching => switch (try search.handleKey(alloc, key, diff_view.rows, viewport.cursor)) {
                        .closed => focus = .normal,
                        .quit => running = false,
                        .jump => |hit| {
                            viewport.cursor = hit.index;
                            focus = .normal;
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
                            viewport.cursor = row;
                            focus = .normal;
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
                        const after_leader = leader_pending;
                        leader_pending = false;
                        const layout = view.layout.effectiveLayout(viewport.layout_pref, size.cols);
                        switch (key) {
                            .char => |c| {
                                if (after_leader and c == 'f') {
                                    try file_list.load(alloc, diff_view.rows, view.nav.currentFileStart(diff_view.rows, viewport.cursor));
                                    focus = .files;
                                } else if (after_leader and c == 'l') {
                                    try comment_list.load(alloc, review.comments.items);
                                    focus = .listing;
                                } else if (after_leader and c == ' ') {
                                    try dispatchStage(
                                        alloc,
                                        io,
                                        source,
                                        &diff_view,
                                        &viewport.cursor,
                                        &frame.note,
                                        &focus,
                                        &failure,
                                        &review,
                                        &discard_confirm,
                                        false,
                                    );
                                } else if (after_leader and c == 'S') {
                                    if (view.nav.currentHunkInFile(diff_view.rows, viewport.cursor) != null) {
                                        try dispatchStage(
                                            alloc,
                                            io,
                                            source,
                                            &diff_view,
                                            &viewport.cursor,
                                            &frame.note,
                                            &focus,
                                            &failure,
                                            &review,
                                            &discard_confirm,
                                            true,
                                        );
                                    }
                                } else if (after_leader and c == 'd') {
                                    if (source == .local) {
                                        if (git.discardTargetAt(diff_view.rows, viewport.cursor, false) != null) {
                                            discard_confirm = .{ .whole_file = false, .yes = false, .comments = false };
                                            focus = .discard_confirm;
                                        }
                                    } else {
                                        dismissAt(&review, alloc, io, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .new, &frame.note);
                                    }
                                } else if (after_leader and c == 'x') {
                                    if (source == .local and view.nav.currentHunkInFile(diff_view.rows, viewport.cursor) != null) {
                                        if (git.discardTargetAt(diff_view.rows, viewport.cursor, true) != null) {
                                            discard_confirm = .{ .whole_file = true, .yes = false, .comments = false };
                                            focus = .discard_confirm;
                                        }
                                    }
                                } else if (viewport.handleKey(.{ .char = c }, size.cols, diff_view.rows, diff_view.sbs_slots) == .handled) {
                                    // j/k/h/l/0/$/J/K/[/]/{/}/t
                                } else if (c == 'q' or c == 'Q') {
                                    running = false;
                                } else if (c == '?') {
                                    help.scroll = 0;
                                    focus = .helping;
                                } else if (c == ' ') {
                                    leader_pending = true;
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
                                    jumpLiveComment(&review, diff_view.rows, &viewport.cursor, &frame.note, .next);
                                } else if (c == '(') {
                                    jumpLiveComment(&review, diff_view.rows, &viewport.cursor, &frame.note, .prev);
                                } else if (c == 'r') {
                                    reloadDiff(alloc, io, source, &diff_view, &viewport.cursor, &frame.note);
                                } else if (c == 'i' or c == 'c' or c == 'a') {
                                    if (try draft.begin(&review, alloc, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .new)) {
                                        focus = .commenting;
                                    }
                                } else if (c == 'I' or c == 'C' or c == 'A') {
                                    if (try draft.begin(&review, alloc, diff_view.rows, diff_view.sbs_slots, layout, viewport.cursor, .old)) {
                                        focus = .commenting;
                                    }
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

/// Parsed diff plus flatten rows and side-by-side slots. The TUI holds one
/// as the live list; reload builds another and swaps it in.
pub const DiffView = struct {
    diff: diff.Diff,
    rows: []view.row.Row,
    sbs_slots: []view.layout.SbsSlot,

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
        const new_rows = view.row.flatten(alloc, &new_diff) catch {
            new_diff.deinit();
            note.set("out of memory");
            return null;
        };
        const new_sbs = view.layout.pairSideBySide(alloc, new_rows) catch {
            alloc.free(new_rows);
            new_diff.deinit();
            note.set("out of memory");
            return null;
        };
        return .{ .diff = new_diff, .rows = new_rows, .sbs_slots = new_sbs };
    }

    fn deinit(self: DiffView, alloc: std.mem.Allocator) void {
        alloc.free(self.rows);
        alloc.free(self.sbs_slots);
        var parsed = self.diff;
        parsed.deinit();
    }
};

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

/// Stage, unstage, or discard the current file or hunk (local source only).
/// `Space` `Space` / `Space` `d` use `whole_file == false` (file header →
/// file, hunk → hunk); `Space` `S` / `Space` `x` pass `true` from a hunk.
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

/// Stage/unstage at the cursor: group confirm overlay, or apply the file/hunk.
fn dispatchStage(
    alloc: std.mem.Allocator,
    io: std.Io,
    source: cli.Source,
    diff_view: *DiffView,
    cursor: *usize,
    note: *StatusNote,
    focus: *Focus,
    failure: *Failure,
    review: *store.Review,
    discard: *DiscardConfirm,
    whole_file: bool,
) std.mem.Allocator.Error!void {
    switch (git.stagePlan(diff_view.rows, cursor.*, whole_file)) {
        .none => {},
        .group => |g| {
            discard.* = .{ .kind = .group, .group = g, .yes = false };
            focus.* = .discard_confirm;
        },
        .cursor => try applyIndex(
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
        ),
    }
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
        if (view.layout.pairSideBySide(alloc, snap.rows)) |new_sbs| {
            const loaded: DiffView = .{ .diff = snap.diff, .rows = snap.rows, .sbs_slots = new_sbs };
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
/// file list, help, git error overlay, or discard confirm.
pub const Focus = enum { normal, commenting, searching, listing, files, helping, git_error, discard_confirm };

/// Confirm overlay for discard (`Space` `d` / `Space` `x`) and for group
/// stage/unstage (`Space` `Space` on a section header). `yes` is the
/// selected choice. Opens with **No** selected (Enter does not apply).
/// Discard: if the target has live comments, `comments` is the second
/// overlay and defaults to **Yes** (delete).
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

    /// Columns available for horizontal pan: full width (unified) or one pane (SBS).
    fn panViewportCols(self: *const Viewport, cols: u16) u16 {
        return switch (view.layout.effectiveLayout(self.layout_pref, cols)) {
            .unified => cols,
            .side_by_side => view.layout.sbsPaneWidths(cols).left_w,
        };
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

    fn panLeft(self: *Viewport, cols: u16) void {
        const step = panStep(self.panViewportCols(cols));
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
                'h' => self.panLeft(cols),
                'l' => self.col_scroll +%= panStep(self.panViewportCols(cols)),
                '0' => self.col_scroll = 0,
                '$' => {
                    const span = view.viewport.hunkSpanAt(rows, self.cursor);
                    self.col_scroll = view.viewport.colScrollToEnd(
                        Frame.hunkMaxLineWidth(rows, span),
                        self.panViewportCols(cols),
                    );
                },
                'J' => self.cursor = view.nav.nextChange(rows, self.cursor),
                'K' => self.cursor = view.nav.prevChange(rows, self.cursor),
                ']' => self.cursor = view.nav.nextHunkHeader(rows, self.cursor),
                '[' => self.cursor = view.nav.prevHunkHeader(rows, self.cursor),
                '}' => self.cursor = view.nav.nextFileHeader(rows, self.cursor),
                '{' => self.cursor = view.nav.prevFileHeader(rows, self.cursor),
                't' => self.layout_pref = view.layout.toggleLayoutPref(self.layout_pref),
                else => return .unhandled,
            },
            .down => self.moveLineDown(cols, rows, slots),
            .up => self.moveLineUp(cols, rows, slots),
            .left => self.panLeft(cols),
            .right => self.col_scroll +%= panStep(self.panViewportCols(cols)),
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
            self.panViewportCols(cols),
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

fn jumpLiveComment(
    review: *const store.Review,
    rows: []const view.row.Row,
    cursor: *usize,
    note: *StatusNote,
    comptime toward: enum { next, prev },
) void {
    const hit = switch (toward) {
        .next => comments.next(review, rows, cursor.*),
        .prev => comments.prev(review, rows, cursor.*),
    };
    if (hit) |h| {
        cursor.* = h.row;
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

/// Comment-list overlay (`Space` `l`): snapshot of live comments, cursor, keys, and paint.
const CommentList = struct {
    const Result = union(enum) {
        open,
        closed,
        quit,
        help,
        jump: usize,
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
                const idx = view.rowForComment(rows, loc) orelse return .missing;
                return .{ .jump = idx };
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

test "indexHintForRow section all" {
    try std.testing.expectEqualStrings(
        "Stage All (Space Space)",
        Frame.indexHintForRow(0, null, null, 0, .unstaged),
    );
    try std.testing.expectEqualStrings(
        "Stage All (Space Space)",
        Frame.indexHintForRow(0, null, null, 0, .untracked),
    );
    try std.testing.expectEqualStrings(
        "Unstage All (Space Space)",
        Frame.indexHintForRow(0, null, null, 0, .staged),
    );
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
