//! # Screen buffer + diff render
//!
//! We never "paint the whole terminal" every frame (that flickers).
//! Instead:
//! 1. App draws into **front** (desired cells).
//! 2. **back** holds what we last actually sent to the emulator.
//! 3. `present` walks both; only **changed** cells emit output.
//!
//! Per changed cell we send:
//!   **CUP** (Cursor Position) — move cursor there (`\x1b[row;colH`, 1-based)
//!   **SGR** (Select Graphic Rendition) — set style (`\x1b[...m`) if style changed
//!   char — the glyph bytes
//!
//! Both CUP and SGR are **CSI** sequences (Control Sequence Introducer: `ESC […`).

const std = @import("std");
const builtin = @import("builtin");
const tty_mod = @import("tty.zig"); // need Tty.write / Size / reset_attrs
const Tty = tty_mod.Tty;
const Size = tty_mod.Size;

/// How we name a color for a cell. The renderer turns this into SGR params.
pub const Color = union(enum) {
    default, // terminal's default fg or bg
    /// 0–15 classic/bright ANSI; 16–255 xterm 256-color cube/grayscale.
    indexed: u8,
    /// 24-bit truecolor (when the emulator supports it).
    rgb: struct { r: u8, g: u8, b: u8 },

    /// Structural equality — used so we can skip redundant SGR.
    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |ai| switch (b) {
                .indexed => |bi| ai == bi,
                else => false,
            },
            .rgb => |ar| switch (b) {
                .rgb => |br| ar.r == br.r and ar.g == br.g and ar.b == br.b,
                else => false,
            },
        };
    }
};

/// Logical style for a cell. Renderer expands this to **SGR** (Select Graphic Rendition).
pub const Style = struct {
    fg: Color = .default, // foreground (text) color
    bg: Color = .default, // background color
    bold: bool = false, // SGR 1
    dim: bool = false, // SGR 2
    italic: bool = false, // SGR 3
    underline: bool = false, // SGR 4
    reverse: bool = false, // SGR 7 (swap fg/bg)

    /// true if every field matches (so we can reuse the last SGR).
    pub fn eql(a: Style, b: Style) bool {
        return a.bold == b.bold and
            a.dim == b.dim and
            a.italic == b.italic and
            a.underline == b.underline and
            a.reverse == b.reverse and
            a.fg.eql(b.fg) and
            a.bg.eql(b.bg);
    }
};

/// One grid slot ≈ one terminal column. Wide glyphs use two slots.
pub const Cell = struct {
    /// Unicode codepoint to show. Space means "empty".
    char: u21 = ' ',
    /// Display columns: 1 = normal, 2 = wide (CJK/emoji-ish), 0 = continuation of wide.
    width: u8 = 1,
    style: Style = .{}, // colors + attributes for this cell

    /// Used by the diff: identical cells need no output.
    pub fn eql(a: Cell, b: Cell) bool {
        return a.char == b.char and a.width == b.width and a.style.eql(b.style);
    }

    /// Default empty cell (space, width 1, default style).
    pub fn blank() Cell {
        return .{}; // all field defaults
    }
};

/// Axis-aligned rectangle in cell coordinates (origin top-left, x right, y down).
pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    /// Center a `w`×`h` rect in an `outer_w`×`outer_h` grid. Clamps so the
    /// result stays on-screen: a 10×5 request on an 8×3 grid is 8×3 at (0, 0).
    pub fn centered(outer_w: u16, outer_h: u16, w: u16, h: u16) Rect {
        const cw: u16 = @min(w, outer_w);
        const ch: u16 = @min(h, outer_h);
        return .{
            .x = (outer_w - cw) / 2,
            .y = (outer_h - ch) / 2,
            .w = cw,
            .h = ch,
        };
    }

    /// Overlap of `self` and `other`, or null if they do not share a cell.
    pub fn intersect(self: Rect, other: Rect) ?Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x +| self.w, other.x +| other.w);
        const y1 = @min(self.y +| self.h, other.y +| other.h);
        if (x0 >= x1 or y0 >= y1) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Shrink by `n` cells on each side. Degenerate (zero size) if too small.
    pub fn inset(self: Rect, n: u16) Rect {
        return .{
            .x = self.x +| n,
            .y = self.y +| n,
            .w = self.w -| n -| n,
            .h = self.h -| n -| n,
        };
    }
};

/// Double-buffered character grid + the code that turns a diff into escapes.
pub const Screen = struct {
    alloc: std.mem.Allocator, // owns front/back slices
    cols: u16, // grid width
    rows: u16, // grid height
    /// What the app wants on screen *this* frame (draw target).
    front: []Cell,
    /// What we last successfully wrote to the terminal (for diffing).
    back: []Cell,
    /// Where to leave the hardware cursor after present (null = keep hidden).
    cursor: ?struct { x: u16, y: u16 } = null,
    /// After resize / first frame: treat every cell as dirty (full repaint).
    dirty_all: bool = true,

    /// Allocate front + back grids of `size.cols * size.rows` blank cells.
    pub fn init(alloc: std.mem.Allocator, size: Size) !Screen {
        // Total cells in the grid (row-major: index = y * cols + x).
        const cols: usize = size.cols;
        const rows: usize = size.rows;
        const n = cols * rows;
        const front = try alloc.alloc(Cell, n); // draw buffer
        errdefer alloc.free(front); // free if the next alloc fails
        const back = try alloc.alloc(Cell, n); // last-presented buffer
        errdefer alloc.free(back);
        @memset(front, Cell.blank()); // start empty
        @memset(back, Cell.blank()); // "terminal matches empty" until first present
        return .{
            .alloc = alloc,
            .cols = size.cols,
            .rows = size.rows,
            .front = front,
            .back = back,
            .dirty_all = true, // first present writes everything
        };
    }

    /// Free both grids. Invalidates `self`.
    pub fn deinit(self: *Screen) void {
        self.alloc.free(self.front);
        self.alloc.free(self.back);
        self.* = undefined; // poison so use-after-free is louder in debug
    }

    /// Rebuild the grids for a new terminal size (e.g. after SIGWINCH).
    pub fn resize(self: *Screen, size: Size) !void {
        // No-op if nothing changed (avoids needless full repaint).
        if (size.cols == self.cols and size.rows == self.rows) return;
        const cols: usize = size.cols;
        const rows: usize = size.rows;
        const n = cols * rows;
        const front = try self.alloc.alloc(Cell, n);
        errdefer self.alloc.free(front);
        const back = try self.alloc.alloc(Cell, n);
        errdefer self.alloc.free(back);
        @memset(front, Cell.blank());
        @memset(back, Cell.blank());
        self.alloc.free(self.front); // drop old grids
        self.alloc.free(self.back);
        self.front = front;
        self.back = back;
        self.cols = size.cols;
        self.rows = size.rows;
        self.dirty_all = true; // new geometry → full repaint next present
    }

    /// Set every front cell to a blank (default style).
    pub fn clear(self: *Screen) void {
        @memset(self.front, Cell.blank());
    }

    /// Set every front cell to a space with the given style (colored clear).
    pub fn clearStyle(self: *Screen, style: Style) void {
        const cell = Cell{ .char = ' ', .width = 1, .style = style };
        @memset(self.front, cell);
    }

    /// Row-major index of cell (x, y). x is column, y is row; both 0-based.
    fn index(self: *const Screen, x: u16, y: u16) usize {
        const col: usize = x;
        const row: usize = y;
        const width: usize = self.cols;
        return row * width + col;
    }

    /// Write one cell into the front buffer (clipped to the grid).
    pub fn setCell(self: *Screen, x: u16, y: u16, cell: Cell) void {
        if (x >= self.cols or y >= self.rows) return; // off-screen: ignore
        self.front[self.index(x, y)] = cell;
    }

    /// Read one front cell (blank if out of bounds).
    pub fn getCell(self: *const Screen, x: u16, y: u16) Cell {
        if (x >= self.cols or y >= self.rows) return Cell.blank();
        return self.front[self.index(x, y)];
    }

    /// Decode UTF-8 `text` into cells starting at (x, y), one row only.
    /// `x`/`y` are absolute. Stops at the screen edge. If `clip` is set, also
    /// stays inside that rect. Does not wrap.
    pub fn putStr(self: *Screen, x: u16, y: u16, text: []const u8, style: Style, clip: ?Rect) void {
        const grid = Rect{ .x = 0, .y = 0, .w = self.cols, .h = self.rows };
        const area = (clip orelse grid).intersect(grid) orelse return;
        if (y < area.y or y >= area.y + area.h) return;
        const right = area.x + area.w;
        var col: u16 = x; // current column we're writing
        var i: usize = 0; // byte index into `text`
        while (i < text.len and col < right) {
            // How many bytes is the next UTF-8 character?
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1; // invalid lead byte — skip it
                continue;
            };
            if (i + len > text.len) break; // truncated sequence at end of slice
            // Decode those bytes into a Unicode codepoint.
            const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
                i += 1; // bad sequence — skip a byte and keep going
                continue;
            };
            i += len; // advance past this character's bytes

            const w = codepointWidth(cp); // 0, 1, or 2 terminal columns
            if (w == 0) continue; // combining/control: skip for now
            if (right - col < w) break; // would run past the clip edge

            // Primary cell holds the glyph.
            self.setCell(col, y, .{ .char = cp, .width = w, .style = style });
            if (w == 2 and col + 1 < right) {
                // Wide char: mark the next column as a continuation (not drawn).
                self.setCell(col + 1, y, .{ .char = ' ', .width = 0, .style = style });
            }
            col += w; // advance by display width, not by byte count
        }
    }

    /// Fill `rect` with a single-column `char` and `style`, clipped to the grid.
    /// Width-1 glyphs only (usually space). Multi-column fills are out of scope.
    pub fn fillRect(self: *Screen, rect: Rect, char: u21, style: Style) void {
        const area = rect.intersect(.{ .x = 0, .y = 0, .w = self.cols, .h = self.rows }) orelse return;
        const cell = Cell{ .char = char, .width = 1, .style = style };
        var dy: u16 = 0;
        while (dy < area.h) : (dy += 1) {
            const start = self.index(area.x, area.y + dy);
            @memset(self.front[start .. start + area.w], cell);
        }
    }

    /// Single-line box-drawing frame on `rect`'s edge (`┌─┐│└┘`).
    /// No-op when `w` or `h` is less than 2. Cells off the grid are skipped, so a
    /// box that hangs off-screen does not grow a false corner on the clip edge.
    pub fn drawBox(self: *Screen, rect: Rect, style: Style) void {
        if (rect.w < 2 or rect.h < 2) return;
        const x1 = rect.x +| (rect.w - 1);
        const y1 = rect.y +| (rect.h - 1);

        self.setCell(rect.x, rect.y, .{ .char = '┌', .width = 1, .style = style });
        self.setCell(x1, rect.y, .{ .char = '┐', .width = 1, .style = style });
        self.setCell(rect.x, y1, .{ .char = '└', .width = 1, .style = style });
        self.setCell(x1, y1, .{ .char = '┘', .width = 1, .style = style });

        self.fillRect(.{ .x = rect.x +| 1, .y = rect.y, .w = rect.w -| 2, .h = 1 }, '─', style);
        self.fillRect(.{ .x = rect.x +| 1, .y = y1, .w = rect.w -| 2, .h = 1 }, '─', style);
        self.fillRect(.{ .x = rect.x, .y = rect.y +| 1, .w = 1, .h = rect.h -| 2 }, '│', style);
        self.fillRect(.{ .x = x1, .y = rect.y +| 1, .w = 1, .h = rect.h -| 2 }, '│', style);
    }

    /// After present, leave the hardware cursor visible at (x, y).
    pub fn setCursor(self: *Screen, x: u16, y: u16) void {
        self.cursor = .{ .x = x, .y = y };
    }

    /// After present, keep the hardware cursor hidden.
    pub fn hideCursor(self: *Screen) void {
        self.cursor = null;
    }

    /// Diff front vs back, emit only what changed, then commit front → back.
    ///
    /// Retry safety: on any write/flush failure we discard the userspace write
    /// buffer and leave `back` / `dirty_all` uncommitted so the next present
    /// re-emits a full clean frame instead of prepending onto a half-frame or
    /// skipping cells that never reached the terminal.
    pub fn present(self: *Screen, t: *Tty) !void {
        // Drop partial CSI/glyph bytes if we error mid-frame (or mid-flush).
        errdefer t.write_len = 0;

        // Remember the last SGR we sent so we don't re-send identical styles.
        var last_style: ?Style = null;
        // Track where we believe the *terminal* cursor is (-1 = unknown).
        // Printing a character advances it; CUP jumps it.
        var cursor_x: i32 = -1;
        var cursor_y: i32 = -1;

        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < self.cols) {
                const idx = self.index(x, y);
                const cell = self.front[idx]; // desired content

                // width 0 = continuation of a wide glyph: don't emit a second char.
                // Back commit is deferred until after a successful flush.
                if (cell.width == 0) {
                    x +%= 1; // wrapping add (x is u16; saturating isn't needed here)
                    continue;
                }

                // Did this cell change since last present?
                const changed = self.dirty_all or !cell.eql(self.back[idx]);
                if (!changed) {
                    x +%= cell.width; // skip ahead by the glyph's width
                    continue; // nothing to send for this cell
                }

                // --- emit: move cursor if we aren't already there ---
                // Terminal advances the cursor as we print; only CUP when we jump.
                if (cursor_x != x or cursor_y != y) {
                    try writeCup(t, x, y); // CSI row;col H
                    cursor_x = x;
                    cursor_y = y;
                }

                // --- emit: style if it differs from the last SGR we sent ---
                if (last_style == null or !last_style.?.eql(cell.style)) {
                    try writeStyle(t, cell.style);
                    last_style = cell.style;
                }

                // --- emit: the glyph itself ---
                try writeCodepoint(t, cell.char);
                // Printing advances the terminal cursor by `width` columns.
                cursor_x = x + cell.width;

                // Do not update `back` here — only after flush succeeds below.

                x +%= cell.width; // next column after this glyph
            }
        }

        // Leave attributes clean so stray writes elsewhere don't inherit bold/colors.
        try t.write(tty_mod.seq.reset_attrs);

        // Final cursor visibility / position for the user-visible caret.
        if (self.cursor) |c| {
            try t.write(tty_mod.seq.show_cursor); // mode 25 on
            try writeCup(t, c.x, c.y); // put caret where the app asked
        } else {
            try t.write(tty_mod.seq.hide_cursor); // mode 25 off
        }

        try t.flush(); // push the whole frame's buffered escapes in one go

        // Commit only after the terminal received the frame. Full front→back
        // keeps continuation cells and dirty_all paths consistent for the next diff.
        @memcpy(self.back, self.front);
        self.dirty_all = false; // subsequent presents are incremental
    }
};

/// How many terminal columns a codepoint occupies (rough heuristic).
/// Real apps eventually use an East Asian Width table; this is "good enough" for demos.
pub fn codepointWidth(cp: u21) u8 {
    if (cp < 0x20 or cp == 0x7f) return 0; // C0 controls + DEL: not printable
    // A few common wide ranges (incomplete on purpose — learning stub).
    if (cp >= 0x1100 and cp <= 0x115f) return 2; // Hangul Jamo
    if (cp >= 0x2e80 and cp <= 0xa4cf) return 2; // CJK / radical blocks (broad)
    if (cp >= 0xac00 and cp <= 0xd7a3) return 2; // Hangul syllables
    if (cp >= 0xf900 and cp <= 0xfaff) return 2; // CJK compatibility ideographs
    if (cp >= 0xfe10 and cp <= 0xfe19) return 2;
    if (cp >= 0xfe30 and cp <= 0xfe6f) return 2;
    if (cp >= 0xff00 and cp <= 0xff60) return 2; // fullwidth forms
    if (cp >= 0xffe0 and cp <= 0xffe6) return 2;
    if (cp >= 0x1f300 and cp <= 0x1faff) return 2; // emoji (very rough)
    return 1; // everything else: one column
}

/// Display columns of UTF-8 `text` (same width rules as `putStr` / `codepointWidth`).
pub fn displayWidth(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        i += len;
        cols += codepointWidth(cp);
    }
    return cols;
}

/// Byte index into UTF-8 `text` at the start of display column `col` (0-based).
/// Past the end → `text.len`. If `col` lands inside a wide glyph, skips past it
/// so callers do not start a slice mid-cell.
pub fn byteAtCol(text: []const u8, col: usize) usize {
    if (col == 0) return 0;
    var c: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (c >= col) return i;
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        const w = codepointWidth(cp);
        i += len;
        if (w == 0) continue;
        if (c + w > col) return i; // mid-wide glyph: start after it
        c += w;
    }
    return text.len;
}

/// **CUP** = Cursor Position. Emit `CSI row ; col H` with 1-based coordinates.
fn writeCup(t: *Tty, x: u16, y: u16) !void {
    var buf: [32]u8 = undefined; // stack buffer for the formatted sequence
    // Our grid is 0-based; terminals are 1-based → add 1.
    const s = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
    try t.write(s); // queue into Tty's write buffer
}

/// **SGR** = Select Graphic Rendition. Emit `CSI … m`.
/// Strategy: always reset (0) then re-apply — simple and correct, not minimal.
fn writeStyle(t: *Tty, style: Style) !void {
    try t.write("\x1b[0"); // start CSI, SGR 0 = reset all attributes
    if (style.bold) try t.write(";1"); // append param 1
    if (style.dim) try t.write(";2");
    if (style.italic) try t.write(";3");
    if (style.underline) try t.write(";4");
    if (style.reverse) try t.write(";7");
    try writeColor(t, style.fg, true); // true = foreground
    try writeColor(t, style.bg, false); // false = background
    try t.write("m"); // 'm' terminates an SGR sequence
}

/// Append color parameters to an in-progress SGR (no leading CSI, no trailing m).
fn writeColor(t: *Tty, color: Color, is_fg: bool) !void {
    var buf: [32]u8 = undefined;
    switch (color) {
        .default => {
            // SGR 39 = default fg, 49 = default bg
            const kind: u8 = if (is_fg) 39 else 49;
            const s = try std.fmt.bufPrint(&buf, ";{d}", .{kind});
            try t.write(s);
        },
        .indexed => |idx| {
            if (idx < 8) {
                // classic ANSI: 30–37 fg, 40–47 bg
                const base: u8 = if (is_fg) 30 else 40;
                const s = try std.fmt.bufPrint(&buf, ";{d}", .{base + idx});
                try t.write(s);
            } else if (idx < 16) {
                // bright: 90–97 fg / 100–107 bg
                const base: u8 = if (is_fg) 90 else 100;
                const s = try std.fmt.bufPrint(&buf, ";{d}", .{base + (idx - 8)});
                try t.write(s);
            } else {
                // 256-color: SGR 38;5;n (fg) or 48;5;n (bg)
                const kind: u8 = if (is_fg) 38 else 48;
                const s = try std.fmt.bufPrint(&buf, ";{d};5;{d}", .{ kind, idx });
                try t.write(s);
            }
        },
        .rgb => |rgb| {
            // truecolor: SGR 38;2;r;g;b (fg) or 48;2;r;g;b (bg)
            const kind: u8 = if (is_fg) 38 else 48;
            const s = try std.fmt.bufPrint(&buf, ";{d};2;{d};{d};{d}", .{
                kind,
                rgb.r,
                rgb.g,
                rgb.b,
            });
            try t.write(s);
        },
    }
}

/// Encode a codepoint as UTF-8 and write those bytes to the tty.
fn writeCodepoint(t: *Tty, cp: u21) !void {
    var buf: [4]u8 = undefined; // max UTF-8 length is 4 bytes
    const len = std.unicode.utf8Encode(cp, &buf) catch {
        try t.write("?"); // unencodable → show a fallback
        return;
    };
    try t.write(buf[0..len]);
}

test "cell eql" {
    const a = Cell.blank();
    const b = Cell.blank();
    try std.testing.expect(a.eql(b));
}

test "Rect.centered stays on-screen" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 8, .h = 3 }, Rect.centered(8, 3, 10, 5));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 8, .h = 3 }, Rect.centered(8, 3, 8, 3));
    try std.testing.expectEqual(Rect{ .x = 2, .y = 1, .w = 4, .h = 2 }, Rect.centered(8, 4, 4, 2));
    try std.testing.expectEqual(Rect{ .x = 1, .y = 0, .w = 5, .h = 3 }, Rect.centered(8, 3, 5, 3));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, Rect.centered(0, 0, 10, 5));
}

test "Rect.intersect" {
    const a = Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };
    const b = Rect{ .x = 2, .y = 2, .w = 4, .h = 4 };
    try std.testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 2, .h = 2 }, a.intersect(b).?);
    try std.testing.expect(a.intersect(.{ .x = 10, .y = 10, .w = 2, .h = 2 }) == null);
    try std.testing.expect(a.intersect(.{ .x = 0, .y = 0, .w = 0, .h = 4 }) == null);
}

test "Rect.inset" {
    try std.testing.expectEqual(
        Rect{ .x = 2, .y = 2, .w = 4, .h = 2 },
        (Rect{ .x = 1, .y = 1, .w = 6, .h = 4 }).inset(1),
    );
    try std.testing.expectEqual(
        Rect{ .x = 2, .y = 2, .w = 0, .h = 0 },
        (Rect{ .x = 1, .y = 1, .w = 2, .h = 2 }).inset(1),
    );
}

test "fillRect paints only the rect" {
    const alloc = std.testing.allocator;
    var scr = try Screen.init(alloc, .{ .cols = 8, .rows = 4 });
    defer scr.deinit();

    scr.setCell(0, 0, .{ .char = 'A', .width = 1, .style = .{} });
    scr.setCell(7, 3, .{ .char = 'Z', .width = 1, .style = .{} });

    const fill_style = Style{ .bg = .{ .indexed = 4 }, .fg = .{ .indexed = 15 } };
    scr.fillRect(.{ .x = 2, .y = 1, .w = 3, .h = 2 }, '#', fill_style);

    const filled = Cell{ .char = '#', .width = 1, .style = fill_style };
    try std.testing.expect(scr.getCell(2, 1).eql(filled));
    try std.testing.expect(scr.getCell(3, 1).eql(filled));
    try std.testing.expect(scr.getCell(4, 1).eql(filled));
    try std.testing.expect(scr.getCell(2, 2).eql(filled));
    try std.testing.expect(scr.getCell(3, 2).eql(filled));
    try std.testing.expect(scr.getCell(4, 2).eql(filled));

    try std.testing.expect(scr.getCell(0, 0).eql(.{ .char = 'A', .width = 1, .style = .{} }));
    try std.testing.expect(scr.getCell(7, 3).eql(.{ .char = 'Z', .width = 1, .style = .{} }));
    try std.testing.expect(scr.getCell(1, 1).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(5, 1).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(2, 0).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(2, 3).eql(Cell.blank()));
}

test "fillRect clips to the grid" {
    const alloc = std.testing.allocator;
    var scr = try Screen.init(alloc, .{ .cols = 8, .rows = 4 });
    defer scr.deinit();

    const fill_style = Style{ .bg = .{ .indexed = 1 } };
    scr.fillRect(.{ .x = 6, .y = 2, .w = 8, .h = 8 }, '+', fill_style);

    const filled = Cell{ .char = '+', .width = 1, .style = fill_style };
    try std.testing.expect(scr.getCell(6, 2).eql(filled));
    try std.testing.expect(scr.getCell(7, 2).eql(filled));
    try std.testing.expect(scr.getCell(6, 3).eql(filled));
    try std.testing.expect(scr.getCell(7, 3).eql(filled));
    try std.testing.expect(scr.getCell(5, 2).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(5, 3).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(6, 1).eql(Cell.blank()));

    // Fully off-screen and empty rects are no-ops.
    scr.fillRect(.{ .x = 20, .y = 20, .w = 4, .h = 4 }, 'X', .{});
    scr.fillRect(.{ .x = 0, .y = 0, .w = 0, .h = 4 }, 'X', .{});
    try std.testing.expect(scr.getCell(0, 0).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(6, 2).eql(filled));
}

test "drawBox corners and edges" {
    const alloc = std.testing.allocator;
    var scr = try Screen.init(alloc, .{ .cols = 8, .rows = 5 });
    defer scr.deinit();

    const st = Style{ .fg = .{ .indexed = 7 } };
    scr.drawBox(.{ .x = 1, .y = 1, .w = 4, .h = 3 }, st);

    const tl = Cell{ .char = '┌', .width = 1, .style = st };
    const tr = Cell{ .char = '┐', .width = 1, .style = st };
    const bl = Cell{ .char = '└', .width = 1, .style = st };
    const br = Cell{ .char = '┘', .width = 1, .style = st };
    const hbar = Cell{ .char = '─', .width = 1, .style = st };
    const vbar = Cell{ .char = '│', .width = 1, .style = st };

    try std.testing.expect(scr.getCell(1, 1).eql(tl));
    try std.testing.expect(scr.getCell(4, 1).eql(tr));
    try std.testing.expect(scr.getCell(1, 3).eql(bl));
    try std.testing.expect(scr.getCell(4, 3).eql(br));
    try std.testing.expect(scr.getCell(2, 1).eql(hbar));
    try std.testing.expect(scr.getCell(3, 1).eql(hbar));
    try std.testing.expect(scr.getCell(2, 3).eql(hbar));
    try std.testing.expect(scr.getCell(3, 3).eql(hbar));
    try std.testing.expect(scr.getCell(1, 2).eql(vbar));
    try std.testing.expect(scr.getCell(4, 2).eql(vbar));
    try std.testing.expect(scr.getCell(2, 2).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(0, 0).eql(Cell.blank()));
}

test "drawBox no-op when tiny; clips without a false corner" {
    const alloc = std.testing.allocator;
    var scr = try Screen.init(alloc, .{ .cols = 8, .rows = 4 });
    defer scr.deinit();

    scr.setCell(0, 0, .{ .char = 'A', .width = 1, .style = .{} });
    scr.drawBox(.{ .x = 0, .y = 0, .w = 1, .h = 5 }, .{});
    scr.drawBox(.{ .x = 0, .y = 0, .w = 5, .h = 1 }, .{});
    try std.testing.expect(scr.getCell(0, 0).eql(.{ .char = 'A', .width = 1, .style = .{} }));

    const st = Style{ .fg = .{ .indexed = 3 } };
    // Right and bottom edges sit off the 8×4 grid.
    scr.drawBox(.{ .x = 6, .y = 1, .w = 5, .h = 4 }, st);

    try std.testing.expect(scr.getCell(6, 1).eql(.{ .char = '┌', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(7, 1).eql(.{ .char = '─', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(6, 2).eql(.{ .char = '│', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(6, 3).eql(.{ .char = '│', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(7, 2).eql(Cell.blank()));
}

test "putStr clips to an optional rect" {
    const alloc = std.testing.allocator;
    var scr = try Screen.init(alloc, .{ .cols = 8, .rows = 4 });
    defer scr.deinit();

    const st = Style{ .fg = .{ .indexed = 15 } };
    const rect = Rect{ .x = 2, .y = 1, .w = 4, .h = 2 };
    scr.putStr(rect.x, rect.y, "HELLO", st, rect);

    try std.testing.expect(scr.getCell(2, 1).eql(.{ .char = 'H', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(3, 1).eql(.{ .char = 'E', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(4, 1).eql(.{ .char = 'L', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(5, 1).eql(.{ .char = 'L', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(6, 1).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(1, 1).eql(Cell.blank()));

    scr.putStr(rect.x + 1, rect.y + 1, "xyz", st, rect);
    try std.testing.expect(scr.getCell(3, 2).eql(.{ .char = 'x', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(4, 2).eql(.{ .char = 'y', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(5, 2).eql(.{ .char = 'z', .width = 1, .style = st }));

    scr.putStr(rect.x, rect.y + 5, "nope", st, rect);
    scr.putStr(rect.x + 10, rect.y, "nope", st, rect);
    try std.testing.expect(scr.getCell(2, 1).eql(.{ .char = 'H', .width = 1, .style = st }));
}

test "putStr on a tiny off-origin rect" {
    const alloc = std.testing.allocator;
    var scr = try Screen.init(alloc, .{ .cols = 8, .rows = 4 });
    defer scr.deinit();

    const st = Style{};
    const rect = Rect{ .x = 5, .y = 2, .w = 2, .h = 1 };
    scr.putStr(rect.x, rect.y, "ABCD", st, rect);
    try std.testing.expect(scr.getCell(5, 2).eql(.{ .char = 'A', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(6, 2).eql(.{ .char = 'B', .width = 1, .style = st }));
    try std.testing.expect(scr.getCell(7, 2).eql(Cell.blank()));
    try std.testing.expect(scr.getCell(5, 1).eql(Cell.blank()));
}

test "displayWidth and byteAtCol ASCII" {
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(usize, 0), byteAtCol("hello", 0));
    try std.testing.expectEqual(@as(usize, 2), byteAtCol("hello", 2));
    try std.testing.expectEqual(@as(usize, 5), byteAtCol("hello", 5));
    try std.testing.expectEqual(@as(usize, 5), byteAtCol("hello", 99));
    try std.testing.expectEqualStrings("llo", "hello"[byteAtCol("hello", 2)..]);
}

test "displayWidth wide glyph" {
    // U+4E00 CJK ideograph → 2 columns under codepointWidth.
    const wide = "\u{4e00}";
    try std.testing.expectEqual(@as(usize, 2), displayWidth(wide));
    try std.testing.expectEqual(@as(usize, 0), byteAtCol(wide, 0));
    // Column 1 is the second half of the wide cell → skip past the glyph.
    try std.testing.expectEqual(wide.len, byteAtCol(wide, 1));
    try std.testing.expectEqual(wide.len, byteAtCol(wide, 2));
}

// Contract: failed present must be safe to retry.
// - discard any partial userspace write buffer (stale CSI must not prepend next frame)
// - do not commit back until the frame is fully flushed (no half-updated diff state)
test "present failure discards write buffer and does not commit back" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Write end of a pipe whose read end is closed → flush/write gets BrokenPipe.
    const dead = try tty_mod.TestingPipe.open();
    dead.closeRead();
    defer dead.closeWrite();

    var t: Tty = .{
        .fd = dead.write,
        .original = undefined,
    };

    var screen = try Screen.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer screen.deinit();

    // Pre-present back is blank (init). Snapshot cell 0 for the no-commit check.
    const back0 = screen.back[0];
    try std.testing.expect(back0.eql(Cell.blank()));

    // Force a real emit path (CUP / SGR / glyphs) so write_buf fills before flush.
    screen.putStr(0, 0, "ab", .{}, null);
    screen.dirty_all = true;

    try std.testing.expectError(error.BrokenPipe, screen.present(&t));

    // Primary bug: partial escape stream must not remain queued for the next present.
    try std.testing.expectEqual(@as(usize, 0), t.write_len);

    // Back must not look "presented" when the terminal never got the frame.
    try std.testing.expect(screen.back[0].eql(back0));
    // dirty_all stays set so the next present re-emits safely.
    try std.testing.expect(screen.dirty_all);

    // Retry on a live sink: must succeed and commit front → back.
    const live = try tty_mod.TestingPipe.open();
    defer live.closeRead();
    defer live.closeWrite();
    t.fd = live.write;

    try screen.present(&t);
    try std.testing.expectEqual(@as(usize, 0), t.write_len);
    try std.testing.expect(screen.front[0].eql(screen.back[0]));
    try std.testing.expect(!screen.dirty_all);
}
