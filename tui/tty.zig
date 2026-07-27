//! # Terminal ownership (the hard part of a TUI)
//!
//! Mental model:
//! 1. Open the **real** keyboard/screen device (`/dev/tty` — TTY = teletypewriter).
//! 2. Save how the shell configured it (**termios** = terminal I/O settings).
//! 3. Switch to **raw mode** (bytes in, no line editing / no echo).
//! 4. Enter the **alternate screen** (a second canvas; shell scrollback stays).
//! 5. On exit/crash: undo 3–4 so the user's shell is not left broken.
//!
//! Two channels people mix up:
//! - **termios** → OS line discipline (how keys are delivered to us).
//! - **Escape sequences** (`ESC` = `\x1b`, often as **CSI** = Control Sequence
//!   Introducer `ESC [`) → talk to the terminal *emulator* (draw/cursor/modes).

const std = @import("std"); // Zig standard library
const builtin = @import("builtin"); // compile-time target info (OS, arch, …)
const posix = std.posix; // portable-ish POSIX wrappers (open, termios, signals, …)
const linux = std.os.linux; // Linux-specific bits we may touch via posix.system

/// Columns × rows of the terminal window (not pixels).
pub const Size = struct {
    cols: u16, // width in character cells
    rows: u16, // height in character cells
};

/// Hard-coded escape sequences (no terminfo database).
/// Form: `ESC` (`\x1b`) + rest. Many are **CSI** (`ESC […`) or **DEC private**
/// modes (`ESC [ ? n h/l` — DEC = Digital Equipment Corporation heritage).
/// Trailing `h` = set mode, `l` = reset mode (xterm-compatible numbers).
pub const seq = struct {
    /// DEC private mode 1049 on: use the alternate (private) full-screen buffer.
    pub const enter_alt_screen = "\x1b[?1049h";
    /// Mode 1049 off: back to the normal buffer (shell scrollback reappears).
    pub const leave_alt_screen = "\x1b[?1049l";
    /// DEC private mode 25 off: hide the blinking block/bar cursor.
    pub const hide_cursor = "\x1b[?25l";
    /// Mode 25 on: show the cursor again.
    pub const show_cursor = "\x1b[?25h";
    /// CSI `2J` = erase entire display (cursor position unchanged).
    pub const clear_screen = "\x1b[2J";
    /// **CUP** (Cursor Position) with omitted args → row 1, col 1 (home).
    pub const cursor_home = "\x1b[H";
    /// **SGR** (Select Graphic Rendition) param 0: reset colors / bold / etc.
    pub const reset_attrs = "\x1b[0m";
    /// Concatenated restore bytes for signal handlers (must be one static blob).
    pub const emergency_restore = show_cursor ++ leave_alt_screen ++ reset_attrs;
};

/// Signal handlers cannot take a `*Tty` pointer from the stack safely.
/// They only touch this process-global + async-signal-safe syscalls
/// (write, tcsetattr, exit/raise). No alloc, no locks, no Zig error formatting.
const Global = struct {
    fd: posix.fd_t = -1, // which fd to restore; -1 = not set
    original: posix.termios = undefined, // shell's termios, copied at open()
    /// true while we own raw mode + alt screen (guards double-restore).
    active: std.atomic.Value(bool) = .init(false),
    /// set in SIGWINCH handler; main loop clears it and re-queries size.
    winch: std.atomic.Value(bool) = .init(false),
    /// soft quit flag (rarely seen: quit signals restore+exit immediately).
    quit: std.atomic.Value(bool) = .init(false),
};

/// Single global instance — required because C signal handlers have no userdata.
var g: Global = .{};

/// Owned connection to the controlling terminal.
pub const Tty = struct {
    /// **fd** = file descriptor: integer the kernel uses for this open device.
    fd: posix.fd_t,
    /// Snapshot of termios *before* we changed anything (what restore writes back).
    original: posix.termios,
    /// Userspace write buffer: many small `write()`s → fewer syscalls (less flicker).
    write_buf: [8192]u8 = undefined,
    /// How many bytes in `write_buf` are currently valid.
    write_len: usize = 0,
    /// true if `deinit` should `close(fd)` (we opened `/dev/tty` ourselves).
    owns_fd: bool,

    /// Errors `open` can return (mapped from OS failures).
    pub const OpenError = error{
        NotATty, // no controlling terminal / not a tty device
        AccessDenied,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        Unexpected,
    } || posix.TermiosGetError || posix.TermiosSetError || WriteError;

    pub const WriteError = error{
        BrokenPipe, // other end closed (rare for a tty)
        DiskQuota,
        FileTooBig,
        InputOutput,
        NoSpaceLeft,
        AccessDenied,
        Unexpected,
    };

    pub const ReadError = error{
        InputOutput,
        NotOpenForReading,
        Unexpected,
    } || error{WouldBlock}; // non-blocking path had no data yet

    /// Take exclusive interactive control of the terminal.
    pub fn open() OpenError!Tty {
        // This module is written against POSIX-style termios + signals.
        if (builtin.os.tag != .linux and builtin.os.tag != .macos and
            builtin.os.tag != .freebsd and builtin.os.tag != .netbsd and
            builtin.os.tag != .openbsd and builtin.os.tag != .dragonfly)
        {
            @compileError("tui.tty currently targets POSIX (Linux / BSD / macOS)");
        }

        // Step 1: get an fd for the real keyboard/screen.
        const fd = try openDevTty();
        // If anything below fails, close that fd so we don't leak it.
        errdefer _ = posix.system.close(fd);

        // Step 2: read current termios (echo, canonical mode, ctrl chars, …).
        const original = try posix.tcgetattr(fd);
        // Build our Tty value holding the fd + the "undo me" snapshot.
        var self: Tty = .{
            .fd = fd,
            .original = original,
            .owns_fd = true, // we opened it, so we close it
        };

        // Step 3: cook → raw (kernel stops line-editing / echoing / ISIG).
        try self.enterRawMode();

        // Publish restore state *before* escape sequences so a signal mid-setup
        // can still put the terminal back.
        g.fd = fd; // handler needs the fd
        g.original = original; // handler needs the old termios
        g.active.store(true, .release); // mark ownership active
        g.winch.store(false, .release); // clear stale resize flag
        g.quit.store(false, .release); // clear stale quit flag

        // Install SIGINT/SIGTERM/SIGWINCH/… handlers that know about `g`.
        installSignalHandlers();

        // Step 4: tell the *emulator* (not the kernel) to enter alt screen, etc.
        // These are just bytes written to the tty device.
        try self.writeAllUnbuffered(
            seq.enter_alt_screen ++ // private full-screen buffer
                seq.hide_cursor ++ // no blinking cursor while we draw
                seq.clear_screen ++ // blank the alt buffer
                seq.cursor_home, // cursor to top-left
        );
        return self; // caller owns this; must call deinit()
    }

    /// Release ownership: restore modes, then close the fd if we opened it.
    pub fn deinit(self: *Tty) void {
        self.restore(); // escapes + termios back to original
        if (self.owns_fd and self.fd >= 0) {
            _ = posix.system.close(self.fd); // give the fd back to the kernel
            self.fd = -1; // poison so double-deinit is a no-op
            self.owns_fd = false;
        }
    }

    /// Undo raw mode + alt screen. Safe to call more than once.
    pub fn restore(self: *Tty) void {
        // Atomically clear "active". If we were not active, another path already restored.
        const was_active = g.active.swap(false, .acq_rel);
        if (!was_active and self.fd < 0) return; // nothing to do

        self.write_len = 0; // drop any unflushed draw bytes (don't paint after restore)
        // Best-effort: show cursor, leave alt screen, reset SGR. Ignore write errors.
        writeAllFd(self.fd, seq.emergency_restore) catch {};
        // Put the *kernel* line discipline back exactly as the shell left it.
        // `.NOW` = apply immediately (don't wait for output drain).
        posix.tcsetattr(self.fd, .NOW, self.original) catch {};
    }

    /// Ask the kernel for the current window size (cols × rows).
    pub fn getSize(self: *const Tty) !Size {
        return getWinsize(self.fd);
    }

    /// Queue bytes into our userspace buffer (escapes + text). Call `flush` to ship.
    pub fn write(self: *Tty, bytes: []const u8) WriteError!void {
        var remaining = bytes; // slice we still need to copy
        while (remaining.len > 0) {
            const space = self.write_buf.len - self.write_len; // free room in buffer
            if (space == 0) try self.flush(); // full → push to kernel, free space
            const space2 = self.write_buf.len - self.write_len; // recompute after possible flush
            const n = @min(space2, remaining.len); // copy as much as fits
            @memcpy(self.write_buf[self.write_len..][0..n], remaining[0..n]);
            self.write_len += n; // advance fill pointer
            remaining = remaining[n..]; // consume copied prefix
        }
    }

    /// Push the write buffer to the kernel (one or more `write` syscalls).
    pub fn flush(self: *Tty) WriteError!void {
        if (self.write_len == 0) return; // nothing queued
        try writeAllFd(self.fd, self.write_buf[0..self.write_len]);
        self.write_len = 0; // buffer is empty again
    }

    /// One blocking `read` of the tty.
    /// With VMIN=1 / VTIME=0 (see enterRawMode), this waits until ≥1 byte arrives.
    pub fn read(self: *Tty, buf: []u8) ReadError!usize {
        return readFd(self.fd, buf);
    }

    /// Wait up to `timeout_ms` for input, then `read`.
    /// - timeout 0: poll once, don't block
    /// - returns 0 if the timer expired with no data
    pub fn readTimeout(self: *Tty, buf: []u8, timeout_ms: i32) ReadError!usize {
        // poll() watches fds for readiness without consuming data.
        var pfd = [_]posix.pollfd{.{
            .fd = self.fd, // which fd to watch
            .events = posix.POLL.IN, // wake when readable
            .revents = 0, // kernel fills this with what actually happened
        }};
        // n = number of fds with events; 0 means timeout.
        const n = posix.poll(&pfd, timeout_ms) catch return error.Unexpected;
        if (n == 0) return 0; // timed out
        // Only proceed if input (or hangup/error) is set on our fd.
        if (pfd[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) {
            return 0;
        }
        return self.read(buf); // data is ready — actually pull it
    }

    /// true once per **SIGWINCH** (signal: window change); clears the flag.
    /// Call only when returning a `.resize` event (or another explicit consumer).
    pub fn takeWinch(self: *const Tty) bool {
        _ = self; // flag is process-global, not per-instance
        // swap(false): read old value and clear in one atomic step.
        return g.winch.swap(false, .acq_rel);
    }

    /// Look at winch without clearing. Wait paths peek; poll takes on return.
    pub fn peekWinch(self: *const Tty) bool {
        _ = self;
        return g.winch.load(.acquire);
    }

    /// true once if soft quit was requested; clears the flag.
    /// Call only when returning a `.quit` event (or another explicit consumer).
    pub fn takeQuit(self: *const Tty) bool {
        _ = self;
        return g.quit.swap(false, .acq_rel);
    }

    /// Look at quit without clearing. Wait paths peek; poll takes on return.
    pub fn peekQuit(self: *const Tty) bool {
        _ = self;
        return g.quit.load(.acquire);
    }

    /// Test-only: set the process-global SIGWINCH flag without raising a signal.
    pub fn testingSetWinch(v: bool) void {
        g.winch.store(v, .release);
    }

    /// Cooked (default shell) vs raw:
    /// - cooked: kernel does line editing; Enter delivers a line; Ctrl-C → SIGINT
    /// - raw:    every key is a byte (or multi-byte escape); we do all processing
    fn enterRawMode(self: *Tty) (posix.TermiosSetError)!void {
        // Start from the shell's settings, then turn off the bits we don't want.
        var raw = self.original;

        // --- iflag: input processing the kernel does *before* we see bytes ---
        raw.iflag.BRKINT = false; // break condition should not raise SIGINT
        raw.iflag.ICRNL = false; // do not map CR (Enter) → NL; keep `\r` as `\r`
        raw.iflag.INPCK = false; // no parity checking (serial-era leftover)
        raw.iflag.ISTRIP = false; // keep 8-bit characters (don't clear high bit)
        raw.iflag.IXON = false; // disable Ctrl-S / Ctrl-Q software flow control

        // --- oflag: output post-processing ---
        // We drive the cursor with CUP ourselves, so we leave OPOST alone.

        // --- cflag: "control" / character size (serial heritage) ---
        raw.cflag.CSIZE = .CS8; // 8 bits per character

        // --- lflag: local / user-facing behavior (the big TUI knobs) ---
        raw.lflag.ECHO = false; // Echo off: typing must not paint characters
        raw.lflag.ICANON = false; // Canonical off: no line buffer, no kernel backspace
        raw.lflag.ISIG = false; // Signals off: Ctrl-C/Z are data bytes, not signals
        raw.lflag.IEXTEN = false; // Extensions off: no extra platform input processing

        // --- non-canonical read rules (only used when ICANON is off) ---
        // Stored in termios.cc[] (control characters array), indexed by V.*.
        //   **VMIN**  = min bytes before read() returns
        //   **VTIME** = inter-byte timeout in *deciseconds* (tenths of a second)
        // VMIN=1, VTIME=0 → classic interactive: block until at least one byte.
        const V = posix.system.V; // platform's VMIN/VTIME index enum
        raw.cc[@intFromEnum(V.MIN)] = 1;
        raw.cc[@intFromEnum(V.TIME)] = 0;

        // Apply settings. FLUSH = apply now *and* discard pending I/O (clean start).
        try posix.tcsetattr(self.fd, .FLUSH, raw);
    }

    /// Flush any buffered bytes, then write `bytes` immediately (setup / teardown).
    fn writeAllUnbuffered(self: *Tty, bytes: []const u8) WriteError!void {
        try self.flush(); // don't reorder past earlier buffered output
        try writeAllFd(self.fd, bytes);
    }
};

/// Why `/dev/tty` and not stdin/stdout?
/// Redirects like `rv <in >out` still need the *controlling terminal* for keys + UI.
/// `/dev/tty` is always that device (when the process has one).
fn openDevTty() Tty.OpenError!posix.fd_t {
    const path = "/dev/tty"; // special device node for the controlling terminal
    const flags: posix.O = .{
        .ACCMODE = .RDWR, // read keys AND write escapes on the same fd
        .CLOEXEC = true, // close-on-exec: don't leak into child processes
    };
    // openat(AT.FDCWD, path, …) ≈ open(path, …) relative to the current directory.
    const fd = posix.openat(posix.AT.FDCWD, path, flags, 0) catch |err| switch (err) {
        error.AccessDenied => return error.AccessDenied,
        error.ProcessFdQuotaExceeded => return error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => return error.SystemFdQuotaExceeded,
        error.SystemResources => return error.SystemResources,
        // No controlling tty (e.g. some daemon contexts).
        error.FileNotFound, error.NotDir, error.NoDevice => return error.NotATty,
        else => return error.Unexpected,
    };

    // Double-check: only real terminals support termios.
    if (!isTty(fd)) {
        _ = posix.system.close(fd);
        return error.NotATty;
    }
    return fd;
}

/// true if `tcgetattr` succeeds (pipes/files fail; ttys succeed).
fn isTty(fd: posix.fd_t) bool {
    _ = posix.tcgetattr(fd) catch return false;
    return true;
}

/// **ioctl** (I/O control) request `TIOCGWINSZ` ("get window size").
/// Fills a `winsize` struct the kernel maintains for this tty.
fn getWinsize(fd: posix.fd_t) !Size {
    var ws: posix.winsize = .{
        .row = 0, // character rows
        .col = 0, // character columns
        .xpixel = 0, // optional pixel width (often 0)
        .ypixel = 0, // optional pixel height (often 0)
    };
    // ioctl returns a syscall result; we interpret errno on failure.
    const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    switch (posix.errno(rc)) {
        .SUCCESS => {}, // ws is filled
        else => |e| return posix.unexpectedErrno(e),
    }
    // Some environments report 0×0; fall back to a classic default.
    if (ws.col == 0 or ws.row == 0) {
        return Size{ .cols = 80, .rows = 24 };
    }
    return Size{ .cols = ws.col, .rows = ws.row };
}

/// Write every byte of `bytes` to `fd`, handling short writes and EINTR.
fn writeAllFd(fd: posix.fd_t, bytes: []const u8) Tty.WriteError!void {
    var offset: usize = 0; // how many bytes already accepted by the kernel
    while (offset < bytes.len) {
        // Kernel may accept fewer bytes than we asked (short write) — loop.
        const rc = posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc); // bytes written this call
                if (n == 0) return error.Unexpected; // should not happen on a tty
                offset += n;
            },
            .INTR => continue, // EINTR: signal interrupted us mid-write — retry
            .INVAL => return error.Unexpected, // bad args
            .BADF => return error.Unexpected, // closed/invalid fd
            .FAULT => return error.Unexpected, // bad pointer
            .AGAIN => continue, // would block; rare for a blocking tty
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.BrokenPipe,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM, .ACCES => return error.AccessDenied,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// One `read` syscall loop (retry on EINTR). Returns bytes read (0 = EOF).
fn readFd(fd: posix.fd_t, buf: []u8) Tty.ReadError!usize {
    if (buf.len == 0) return 0; // nothing to fill
    while (true) {
        const rc = posix.system.read(fd, buf.ptr, buf.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc), // rc is the byte count
            .INTR => continue, // interrupted by signal — try again
            .AGAIN => return error.WouldBlock, // non-blocking, no data
            .BADF => return error.NotOpenForReading,
            .IO => return error.InputOutput,
            .FAULT, .INVAL => return error.Unexpected,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

// ---------------------------------------------------------------------------
// **SIG** = signal: async kernel interrupt. Handlers must stay tiny + signal-safe.
// ---------------------------------------------------------------------------

fn installSignalHandlers() void {
    // **SIGINT** (interrupt) + **SIGTERM** (terminate): restore tty, then exit.
    // Note: with ISIG off, Ctrl-C is *not* SIGINT — it is the raw byte 0x03.
    // External `kill -INT` still delivers SIGINT.
    const quit_act = posix.Sigaction{
        .handler = .{ .handler = handleQuitSignal }, // simple handler (signo only)
        .mask = posix.sigemptyset(), // don't block extra signals while we run
        .flags = posix.SA.RESTART, // SA = sigaction flags; RESTART interrupted syscalls
    };
    posix.sigaction(.INT, &quit_act, null); // replace SIGINT handler (null = ignore old)
    posix.sigaction(.TERM, &quit_act, null); // same for SIGTERM

    // Fatal-ish signals: restore, then re-raise so the default death still happens.
    const fatal_act = posix.Sigaction{
        .handler = .{ .handler = handleFatalSignal },
        .mask = posix.sigemptyset(),
        // RESETHAND = after one fire, restore default handler (so re-raise works).
        .flags = posix.SA.RESETHAND | posix.SA.RESTART,
    };
    posix.sigaction(.HUP, &fatal_act, null); // hangup: terminal closed / disconnect
    posix.sigaction(.QUIT, &fatal_act, null); // quit (often Ctrl-\ when ISIG on)
    posix.sigaction(.ABRT, &fatal_act, null); // abort()
    // We leave SEGV/ILL/BUS/FPE to Zig's debug handler (may skip tty restore).

    // **SIGWINCH** = SIGnal WINdow CHange. Kernel does *not* pass the new size —
    // only a heads-up. We ioctl(TIOCGWINSZ) later on the main thread.
    const winch_act = posix.Sigaction{
        .handler = .{ .handler = handleWinch },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.WINCH, &winch_act, null);
}

/// Best-effort undo of alt screen + raw termios. Safe to call from a signal handler.
fn emergencyRestore() void {
    // Only the first caller wins (main-thread restore or a signal).
    if (!g.active.swap(false, .acq_rel)) return;
    const fd = g.fd;
    if (fd < 0) return;
    // Only async-signal-safe ops below: raw write + tcsetattr.
    _ = posix.system.write(fd, seq.emergency_restore.ptr, seq.emergency_restore.len);
    _ = posix.system.tcsetattr(fd, .NOW, &g.original); // restore shell termios
}

/// SIGINT / SIGTERM: put the terminal back, then kill the process.
fn handleQuitSignal(sig: posix.SIG) callconv(.c) void {
    _ = sig; // which signal — unused; same action for INT and TERM
    g.quit.store(true, .release); // record intent (usually never read: we exit)
    emergencyRestore();
    // Exit from the handler so we never return into a still-blocked main loop
    // with a half-restored terminal.
    std.process.exit(1);
}

/// Fatal signals: restore, then re-raise so the OS default still kills us.
fn handleFatalSignal(sig: posix.SIG) callconv(.c) void {
    emergencyRestore();
    // RESETHAND already reset this handler to default; raise runs that default.
    posix.raise(sig) catch {
        std.process.exit(128); // fallback if raise fails
    };
}

/// SIGWINCH: only set a flag. No I/O, no alloc.
fn handleWinch(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    g.winch.store(true, .release); // main loop will takeWinch() and getSize()
}

// Keep the linux import referenced on all targets that compile this file.
comptime {
    _ = linux;
}

test "Size layout" {
    const s = Size{ .cols = 80, .rows = 24 };
    try std.testing.expect(s.cols == 80);
}
