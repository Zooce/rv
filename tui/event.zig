//! # Input events
//!
//! In raw mode the kernel gives **bytes**, not "keys".
//! We turn those bytes into a small `Event` union.
//!
//! Special keys are multi-byte **escape sequences**, e.g. Up = `ESC [ A`.
//! - **ESC** = escape character `0x1b`
//! - **CSI** = Control Sequence Introducer = `ESC [` (what arrows use)
//!
//! ESC alone vs ESC-as-prefix: wait a few ms for more input; if none, it was Esc.

const std = @import("std");
const posix = std.posix; // only used lightly (pollfd type kept for reference)
const tty_mod = @import("tty.zig"); // we read from Tty and use Size
const Tty = tty_mod.Tty;
const Size = tty_mod.Size;

/// A decoded keypress (after we interpret raw bytes).
pub const Key = union(enum) {
    /// Printable character. `u21` holds a full Unicode codepoint; we fill ASCII for now.
    char: u21,
    enter, // Enter / Return (we accept both `\r` and `\n`)
    esc, // bare Escape key (not the start of a longer sequence)
    backspace, // Backspace or Delete-as-backspace
    tab,
    up, // arrow keys (from CSI sequences)
    down,
    left,
    right,
    /// Byte `0x03`. With **ISIG** (input signals) off, Ctrl-C is *this byte*, not SIGINT.
    ctrl_c,
    /// Incomplete or unrecognized sequence.
    unknown,
};

/// Anything the event loop can report to the app.
pub const Event = union(enum) {
    key: Key, // user pressed something
    /// Terminal was resized (after SIGWINCH). Payload = new size from ioctl.
    resize: Size,
    quit, // soft quit flag (rare with current tty handlers that exit immediately)
};

/// Errors bubbling up from reads / size queries.
pub const PollError = Tty.ReadError || error{Unexpected};

/// One attempt to get an event.
/// - `timeout_ms < 0`: wait until something happens (sliced — see readWithTimeout)
/// - `timeout_ms == 0`: non-blocking
/// - `timeout_ms > 0`: wait at most that many milliseconds
/// - returns `null` on timeout with no event
/// - hangup/EOF on the tty (`error.EndOfStream` from read) → `.quit` so apps exit
///   cleanly instead of busy-spinning the wait loop
pub fn poll(t: *Tty, timeout_ms: i32) PollError!?Event {
    // Signal handlers only set flags. Check those *before* we might block on read.

    // 1) Resize pending? take clears the flag.
    if (t.takeWinch()) {
        // Flag was set by SIGWINCH; ask the kernel for the actual new size.
        const size = t.getSize() catch |err| switch (err) {
            else => return error.Unexpected, // ioctl failed — treat as hard error
        };
        return .{ .resize = size };
    }

    // 2) Soft quit pending? same as winch: one take, then return the event.
    if (t.takeQuit()) {
        return .quit;
    }

    // 3) Try to read one byte of keyboard input.
    var byte: [1]u8 = undefined; // single-byte scratch buffer
    const n = readWithTimeout(t, &byte, timeout_ms) catch |err| switch (err) {
        // Terminal gone (PTY torn down, peer closed): soft quit, not a hard error.
        error.EndOfStream => return .quit,
        else => |e| return e,
    };
    if (n == 0) {
        // Timeout, or wait returned early because a flag is set. Check again.
        if (t.takeWinch()) {
            const size = t.getSize() catch return error.Unexpected;
            return .{ .resize = size };
        }
        if (t.takeQuit()) {
            return .quit;
        }
        return null; // genuine timeout / no event
    }

    // 4) We have a byte — turn it into a Key (may read more bytes for escapes).
    // EOF mid-sequence (rare) also maps to quit: the input stream is gone.
    return decodeKey(t, byte[0]) catch |err| switch (err) {
        error.EndOfStream => return .quit,
        else => |e| return e,
    };
}

/// Block until an event is available (never returns null).
pub fn next(t: *Tty) PollError!Event {
    while (true) {
        // poll with -1 means "wait"; our implementation slices into 200ms polls.
        if (try poll(t, -1)) |ev| return ev;
        // null can still happen if a sliced wait returns 0 without a flag —
        // just loop again.
    }
}

/// Read into `buf` honoring `timeout_ms`. For infinite wait, slice into 200ms
/// chunks so SIGWINCH / quit flags can be observed (a bare blocking read would
/// not return until a key arrives).
///
/// `error.EndOfStream` from `readTimeout` (poll-ready + read 0) is returned
/// immediately — must not treat it as a soft timeout or this loop busy-spins.
fn readWithTimeout(t: *Tty, buf: []u8, timeout_ms: i32) Tty.ReadError!usize {
    if (timeout_ms < 0) {
        // Indefinite wait, implemented as a loop of short timed polls.
        while (true) {
            // Peek only: take would clear the flag before poll can return it.
            if (t.peekWinch() or t.peekQuit()) return 0;
            const n = t.readTimeout(buf, 200) catch |err| switch (err) {
                error.WouldBlock => continue, // shouldn't happen often; keep waiting
                else => |e| return e, // EndOfStream / I/O — poll maps EOF → .quit
            };
            if (n > 0) return n; // got data
            // else: 200ms elapsed, loop and check flags again
        }
    }
    // Finite or zero timeout: single poll+read.
    return t.readTimeout(buf, timeout_ms);
}

/// Map the first input byte to a Key; may read more for multi-byte sequences.
fn decodeKey(t: *Tty, first: u8) PollError!Event {
    switch (first) {
        0x03 => return .{ .key = .ctrl_c }, // ETX — Ctrl-C as data (ISIG off)
        '\r', '\n' => return .{ .key = .enter }, // CR or LF both mean Enter to us
        0x7f, 0x08 => return .{ .key = .backspace }, // DEL (common) or BS (0x08)
        '\t' => return .{ .key = .tab },
        0x1b => return try decodeEsc(t), // ESC — bare Esc *or* start of CSI
        else => {
            // Printable ASCII range (space through tilde).
            if (first >= 0x20 and first < 0x7f) {
                return .{ .key = .{ .char = first } }; // promote byte to codepoint
            }
            // Control chars we don't care about yet (Ctrl-A, etc.).
            return .{ .key = .unknown };
        },
    }
}

/// After seeing ESC: wait briefly for a follower.
/// - no follower → user pressed Esc
/// - `[` → CSI sequence (arrows, etc.)
/// - anything else → ignore for now (Alt+key, etc.)
fn decodeEsc(t: *Tty) PollError!Event {
    // 25ms: long enough that a real CSI arrives as one burst,
    // short enough that bare Esc still feels instant.
    var b: [1]u8 = undefined;
    const n = t.readTimeout(&b, 25) catch |err| switch (err) {
        error.WouldBlock => return .{ .key = .esc },
        else => |e| return e,
    };
    if (n == 0) return .{ .key = .esc }; // timer expired → bare Esc

    // CSI (Control Sequence Introducer) continues with '['.
    if (b[0] == '[') {
        return try decodeCsi(t); // parse the rest of ESC [ …
    }
    // Alt+key and other ESC-prefix forms: not handled yet.
    _ = b[0]; // explicitly ignore the follower byte
    return .{ .key = .esc };
}

/// Parse a CSI sequence after we have already consumed `ESC [`.
/// Format: optional parameter bytes, then a final byte in 0x40–0x7E.
/// Arrows (common case): final byte A/B/C/D.
fn decodeCsi(t: *Tty) PollError!Event {
    var param_buf: [16]u8 = undefined; // holds digits/semicolons before the final
    var len: usize = 0; // how many param bytes we stored

    while (true) {
        var b: [1]u8 = undefined;
        // Each intermediate byte should arrive quickly; 25ms gap → give up.
        const n = t.readTimeout(&b, 25) catch |err| switch (err) {
            error.WouldBlock => return .{ .key = .unknown },
            else => |e| return e,
        };
        if (n == 0) return .{ .key = .unknown }; // incomplete sequence

        const c = b[0];
        // CSI "final" bytes live in this range (ECMA-48 / ANSI).
        if (c >= 0x40 and c <= 0x7e) {
            return mapCsiFinal(c, param_buf[0..len]);
        }
        // Otherwise it's a parameter byte (e.g. '1', ';', '5' in "1;5A").
        if (len < param_buf.len) {
            param_buf[len] = c;
            len += 1;
        }
        // If param_buf is full we still keep reading until a final byte,
        // just stop storing — avoids hanging on a flood of garbage.
    }
}

/// Map the CSI final byte (+ optional params) to a Key event.
fn mapCsiFinal(final: u8, params: []const u8) Event {
    // params might be "1;5" for Ctrl+Arrow, etc. — ignored in this iteration.
    _ = params;
    return .{
        .key = switch (final) {
            'A' => .up, // CSI A
            'B' => .down, // CSI B
            'C' => .right, // CSI C
            'D' => .left, // CSI D
            else => .unknown, // Home/End/F-keys etc. not mapped yet
        },
    };
}

// Keep a reference so the type is "used" if we lean on it later.
comptime {
    _ = posix.pollfd;
}

test "Key tags" {
    const k: Key = .{ .char = 'a' };
    try std.testing.expect(k == .char);
}

// Contract: hangup/EOF on the input fd must surface as .quit (not spin / null forever).
// Pipe with closed write end → poll ready + read 0 → EndOfStream from readTimeout.
test "poll maps EOF to quit" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    // TestingPipe: .read = input side for Tty, .write = peer (close → EOF on read).
    const pipe = try tty_mod.TestingPipe.open();
    defer pipe.closeRead();
    pipe.closeWrite(); // EOF on the read end

    var t: Tty = .{
        .fd = pipe.read,
        .original = undefined,
    };
    // Finite timeout so a regression that treats EOF as soft-timeout fails cleanly
    // (returns null) instead of hanging the test runner.
    const ev = try poll(&t, 100);
    try std.testing.expect(ev != null);
    try std.testing.expect(ev.? == .quit);
}

// Contract: infinite-wait may wake because SIGWINCH is pending, but must not
// clear the flag — only takeWinch (when returning .resize) may clear it.
test "readWithTimeout infinite wait does not clear winch" {
    // Dummy Tty: wait path checks flags before any fd I/O when winch is set.
    var t: Tty = .{
        .fd = -1,
        .original = undefined,
    };
    Tty.testingSetWinch(true);
    defer Tty.testingSetWinch(false);

    var buf: [1]u8 = undefined;
    const n = try readWithTimeout(&t, &buf, -1);
    try std.testing.expectEqual(@as(usize, 0), n);
    // After wake, flag must still be observable so poll can takeWinch → .resize.
    try std.testing.expect(t.peekWinch());
}
