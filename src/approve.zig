//! Hunk/file fingerprints and `.rv/approved.json`.
//!
//! A hunk hash is add/delete lines in order, including kind so `-foo` ≠ `+foo`.
//! `@@` numbers, context, meta, section text, and git group are ignored. A
//! hunk-less file hashes its bytes with a distinct type tag.
//!
//! The store is a multiset of `{path, hash}` (hex on disk). Missing file → empty.
//! `save` is atomic. An entry matches a live hunk with the same path when the
//! hash is a contiguous add/delete run (context skipped), or when git has
//! grouped that run's deletions and then its additions inside one change
//! block. A hunk-less file matches when its bytes hash the same. One entry is
//! consumed once. `unapprove` removes one match; `prune` drops entries that
//! cannot be placed. Group is not part of identity.
//!
//! Local load hides those runs: a hunk with no add/delete lines left is
//! dropped, then a file with nothing left, then an empty section. A partial
//! match leaves the hunk header, context, and the other changes. Hunk-less
//! files hash worktree bytes; unreadable files stay visible.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const diff = @import("diff");
const view = @import("view");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [Sha256.digest_length]u8;
const hash_hex_len = Sha256.digest_length * 2;

const hunk_tag: u8 = 1;
const file_tag: u8 = 2;

/// SHA-256 of this hunk's add/delete lines (kind + length + text, in order).
pub fn fingerprintHunk(hunk: diff.Hunk) Hash {
    var hasher = Sha256.init(.{});
    hasher.update(&.{hunk_tag});
    for (hunk.lines) |line| feedChange(&hasher, line);
    return hasher.finalResult();
}

/// Kind byte, length, and text for one add or delete. Context and meta add nothing.
fn feedChange(hasher: *Sha256, line: diff.Line) void {
    const kind_byte: u8 = switch (line.kind) {
        .add => '+',
        .delete => '-',
        .context, .meta => return,
    };
    hasher.update(&.{kind_byte});
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(line.text.len), .little);
    hasher.update(&len_buf);
    hasher.update(line.text);
}

/// SHA-256 of file bytes with a type tag that cannot collide with a hunk hash.
pub fn fingerprintFile(bytes: []const u8) Hash {
    var hasher = Sha256.init(.{});
    hasher.update(&.{file_tag});
    hasher.update(bytes);
    return hasher.finalResult();
}

pub const schema_version: u32 = 1;
pub const rel_path = ".rv/approved.json";

pub const Entry = struct {
    path: []const u8,
    hash: Hash,
};

pub const Approved = struct {
    arena: ArenaAllocator,
    entries: std.ArrayList(Entry),

    pub fn deinit(self: *Approved) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Path is copied into the arena. Duplicate path+hash pairs are kept (multiset).
    pub fn append(self: *Approved, path: []const u8, hash: Hash) Allocator.Error!void {
        const alloc = self.arena.allocator();
        try self.entries.append(alloc, .{
            .path = try alloc.dupe(u8, path),
            .hash = hash,
        });
    }

    /// First unused store entry with this path+hash. `used` is parallel to `entries`.
    /// Returns that entry's index.
    pub fn take(self: *const Approved, used: []bool, path: []const u8, hash: Hash) ?usize {
        for (self.entries.items, used, 0..) |e, *u, i| {
            if (u.*) continue;
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (!std.mem.eql(u8, &e.hash, &hash)) continue;
            u.* = true;
            return i;
        }
        return null;
    }

    /// Remove one matching entry (store order). Remaining entries keep order.
    pub fn unapprove(self: *Approved, path: []const u8, hash: Hash) error{NotFound}!void {
        for (self.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (!std.mem.eql(u8, &e.hash, &hash)) continue;
            _ = self.entries.orderedRemove(i);
            return;
        }
        return error.NotFound;
    }

    /// Drop entries that cannot be placed on `d` (a hunk run, or a hunk-less file).
    pub fn prune(self: *Approved, alloc: Allocator, io: Io, root: Io.Dir, d: *const diff.Diff) Allocator.Error!void {
        const placed = try place(alloc, io, root, d, self);
        defer alloc.free(placed);
        const used = try alloc.alloc(bool, self.entries.items.len);
        defer alloc.free(used);
        @memset(used, false);
        for (placed) |p| used[p.entry_i] = true;
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (!used[i]) _ = self.entries.orderedRemove(i);
        }
    }

    /// Append identities in `file` that are not already in the store.
    pub fn appendFile(
        self: *Approved,
        alloc: Allocator,
        io: Io,
        root: Io.Dir,
        file: diff.File,
    ) Allocator.Error!void {
        var used = try alloc.alloc(bool, self.entries.items.len);
        defer alloc.free(used);
        @memset(used, false);
        const path = file.displayPath();
        if (file.hunks.len == 0) {
            if (hunklessHash(alloc, io, root, file)) |hash| {
                if (self.take(used, path, hash) == null) try self.append(path, hash);
            }
            return;
        }
        for (file.hunks) |*h| {
            for (h.identityHunks()) |id| {
                const hash = fingerprintHunk(id);
                if (self.take(used, path, hash) != null) continue;
                try self.append(path, hash);
                used = try alloc.realloc(used, self.entries.items.len);
                used[used.len - 1] = true;
            }
        }
    }

    /// Append unapproved identities for every file in `group`.
    pub fn appendGroup(
        self: *Approved,
        alloc: Allocator,
        io: Io,
        root: Io.Dir,
        d: *const diff.Diff,
        group: diff.Group,
    ) Allocator.Error!void {
        for (d.files) |f| {
            const g = f.group orelse continue;
            if (g != group) continue;
            try self.appendFile(alloc, io, root, f);
        }
    }
};

pub const LoadError = error{ InvalidJson, InvalidHash } ||
    Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError;

pub const SaveError = error{WriteFailed} || Allocator.Error ||
    Io.Dir.CreateFileAtomicError || Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

pub fn initEmpty(alloc: Allocator) Approved {
    return .{ .arena = ArenaAllocator.init(alloc), .entries = .empty };
}

pub fn load(alloc: Allocator, io: Io, root: Io.Dir) LoadError!Approved {
    const raw = root.readFileAlloc(io, rel_path, alloc, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return initEmpty(alloc),
        else => return err,
    };
    defer alloc.free(raw);
    return try parseJson(alloc, raw);
}

pub fn save(self: *const Approved, alloc: Allocator, io: Io, root: Io.Dir) SaveError!void {
    const bytes = try stringify(self, alloc);
    defer alloc.free(bytes);
    var af = try root.createFileAtomic(io, rel_path, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    af.file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
    try af.replace(io);
}

const WireEntry = struct {
    path: []const u8,
    hash: []const u8,
};

const WireFile = struct {
    version: u32 = schema_version,
    entries: []const WireEntry = &.{},
};

fn parseHash(hex: []const u8) error{InvalidHash}!Hash {
    if (hex.len != hash_hex_len) return error.InvalidHash;
    var out: Hash = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidHash;
    return out;
}

fn parseJson(alloc: Allocator, raw: []const u8) LoadError!Approved {
    var parsed = std.json.parseFromSlice(WireFile, alloc, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();

    var approved = initEmpty(alloc);
    errdefer approved.deinit();
    for (parsed.value.entries) |we| {
        try approved.append(we.path, try parseHash(we.hash));
    }
    return approved;
}

fn stringify(self: *const Approved, alloc: Allocator) Allocator.Error![]u8 {
    const hex_bufs = try alloc.alloc([hash_hex_len]u8, self.entries.items.len);
    defer alloc.free(hex_bufs);
    var wire_entries: std.ArrayList(WireEntry) = .empty;
    defer wire_entries.deinit(alloc);
    try wire_entries.ensureTotalCapacity(alloc, self.entries.items.len);
    for (self.entries.items, 0..) |e, i| {
        hex_bufs[i] = std.fmt.bytesToHex(e.hash, .lower);
        wire_entries.appendAssumeCapacity(.{
            .path = e.path,
            .hash = &hex_bufs[i],
        });
    }
    const wire: WireFile = .{
        .version = schema_version,
        .entries = wire_entries.items,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(wire, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

const hunkless_max = 8 * 1024 * 1024;

/// Worktree bytes for a hunk-less file, or `null` if missing/unreadable/too big.
fn hunklessHash(alloc: Allocator, io: Io, root: Io.Dir, file: diff.File) ?Hash {
    const bytes = root.readFileAlloc(io, file.displayPath(), alloc, .limited(hunkless_max)) catch return null;
    defer alloc.free(bytes);
    return fingerprintFile(bytes);
}

const Placement = struct {
    entry_i: usize,
    file_i: usize,
    /// Null for a hunk-less file.
    hunk_i: ?usize,
    /// Inclusive line indexes of the claimed run.
    /// When `add_span` is set, this is the deletion side only.
    /// Null for a hunk-less file or a context-only hunk.
    span: ?[2]usize,
    /// Addition side, when git placed it after the other change's lines.
    add_span: ?[2]usize = null,
    preview: []const u8,
};

fn markKind(bits: []bool, lines: []const diff.Line, span: [2]usize, kind: diff.LineKind) void {
    var i = span[0];
    while (i <= span[1] and i < lines.len) : (i += 1) {
        if (lines[i].kind == kind) bits[i] = true;
    }
}

fn markClaim(bits: []bool, lines: []const diff.Line, span: [2]usize, add_span: ?[2]usize) void {
    if (add_span) |adds| {
        markKind(bits, lines, span, .delete);
        markKind(bits, lines, adds, .add);
        return;
    }
    markChanges(bits, lines, span);
}

fn markChanges(bits: []bool, lines: []const diff.Line, span: [2]usize) void {
    var i = span[0];
    while (i <= span[1]) : (i += 1) {
        switch (lines[i].kind) {
            .add, .delete => bits[i] = true,
            .context, .meta => {},
        }
    }
}

fn anyOmitted(lines: []const diff.Line, omit: []const bool) bool {
    for (lines, 0..) |ln, i| {
        if (i >= omit.len or !omit[i]) continue;
        switch (ln.kind) {
            .add, .delete => return true,
            .context, .meta => {},
        }
    }
    return false;
}

/// Earliest contiguous add/delete run whose fingerprint is `hash`.
/// A run stops at a claimed change line. Context is skipped, same as
/// `fingerprintHunk`. `omit == null` means nothing is claimed yet.
fn firstSpan(lines: []const diff.Line, omit: ?[]const bool, hash: Hash) ?[2]usize {
    const open = if (omit) |bits| !anyOmitted(lines, bits) else true;
    var first: ?usize = null;
    var last: usize = 0;
    for (lines, 0..) |ln, i| {
        switch (ln.kind) {
            .add, .delete => {
                if (first == null) first = i;
                last = i;
            },
            .context, .meta => {},
        }
    }
    const start = first orelse return null;
    if (open) {
        const whole = fingerprintHunk(.{
            .old_start = 0,
            .old_count = null,
            .new_start = 0,
            .new_count = null,
            .lines = lines,
        });
        if (std.mem.eql(u8, &whole, &hash)) return .{ start, last };
    }

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        switch (lines[i].kind) {
            .add, .delete => {},
            .context, .meta => continue,
        }
        if (omit) |bits| if (i < bits.len and bits[i]) continue;

        var hasher = Sha256.init(.{});
        hasher.update(&.{hunk_tag});
        var j = i;
        while (j < lines.len) : (j += 1) {
            switch (lines[j].kind) {
                .add, .delete => {},
                .context, .meta => continue,
            }
            if (omit) |bits| if (j < bits.len and bits[j]) break;
            feedChange(&hasher, lines[j]);
            const got = hasher.peek();
            if (std.mem.eql(u8, &got, &hash)) return .{ i, j };
        }
    }
    return null;
}

const Split = struct {
    del: [2]usize,
    add: [2]usize,
    start: usize,
};

/// Git joins neighboring edits into one block and lists every deletion, then
/// every addition. The stored hash is still that edit's own deletions followed
/// by its own additions. Returns the first such pair in `lines`.
fn firstRegrouped(lines: []const diff.Line, omit: ?[]const bool, hash: Hash) ?Split {
    var b: usize = 0;
    while (b < lines.len) {
        switch (lines[b].kind) {
            .add, .delete => {},
            .context, .meta => {
                b += 1;
                continue;
            },
        }
        const from = b;
        while (b < lines.len) {
            if (lines[b].kind == .context) break;
            b += 1;
        }
        if (matchBlock(lines[from..b], from, omit, hash)) |hit| return hit;
    }
    return null;
}

fn lineOmitted(omit: ?[]const bool, i: usize) bool {
    const bits = omit orelse return false;
    return i < bits.len and bits[i];
}

/// Delete subslices by add subslices inside one change block. Both sides are
/// non-empty; a one-sided edit stays a contiguous run for `firstSpan`.
fn matchBlock(block: []const diff.Line, base: usize, omit: ?[]const bool, hash: Hash) ?Split {
    var nd: usize = 0;
    var na: usize = 0;
    for (block) |ln| {
        switch (ln.kind) {
            .delete => nd += 1,
            .add => na += 1,
            else => {},
        }
    }
    if (nd == 0 or na == 0) return null;

    var ds: usize = 0;
    while (ds < block.len) : (ds += 1) {
        if (block[ds].kind != .delete) continue;
        if (lineOmitted(omit, base + ds)) continue;

        var hasher = Sha256.init(.{});
        hasher.update(&.{hunk_tag});
        var de = ds;
        while (de < block.len) : (de += 1) {
            switch (block[de].kind) {
                .delete => {},
                .add => break,
                .context, .meta => continue,
            }
            if (lineOmitted(omit, base + de)) break;
            feedChange(&hasher, block[de]);
            const after_del = hasher;

            var as: usize = 0;
            while (as < block.len) : (as += 1) {
                if (block[as].kind != .add) continue;
                if (lineOmitted(omit, base + as)) continue;
                var add_hasher = after_del;
                var ae = as;
                while (ae < block.len) : (ae += 1) {
                    switch (block[ae].kind) {
                        .add => {},
                        .delete => break,
                        .context, .meta => continue,
                    }
                    if (lineOmitted(omit, base + ae)) break;
                    feedChange(&add_hasher, block[ae]);
                    const got = add_hasher.peek();
                    if (!std.mem.eql(u8, &got, &hash)) continue;
                    return .{
                        .del = .{ base + ds, base + de },
                        .add = .{ base + as, base + ae },
                        .start = base + @min(ds, as),
                    };
                }
            }
        }
    }
    return null;
}

const Found = struct {
    entry_i: usize,
    span: [2]usize,
    add_span: ?[2]usize,
    start: usize,
};

fn claimOf(lines: []const diff.Line, omit: ?[]const bool, hash: Hash) ?Found {
    if (firstSpan(lines, omit, hash)) |span| {
        return .{
            .entry_i = 0,
            .span = span,
            .add_span = null,
            .start = span[0],
        };
    }
    if (firstRegrouped(lines, omit, hash)) |split| {
        return .{
            .entry_i = 0,
            .span = split.del,
            .add_span = split.add,
            .start = split.start,
        };
    }
    return null;
}

/// Earliest uncovered run among unused entries for `path`.
/// The same start keeps the earlier store entry.
fn earliest(
    approved: *const Approved,
    used: []const bool,
    path: []const u8,
    lines: []const diff.Line,
    omit: []const bool,
) ?Found {
    var best: ?Found = null;
    for (approved.entries.items, 0..) |e, ei| {
        if (ei >= used.len or used[ei]) continue;
        if (!std.mem.eql(u8, e.path, path)) continue;
        var hit = claimOf(lines, omit, e.hash) orelse continue;
        hit.entry_i = ei;
        if (best) |b| {
            if (hit.start > b.start) continue;
            if (hit.start == b.start and ei > b.entry_i) continue;
        }
        best = hit;
    }
    return best;
}

fn hunkContains(hunk: diff.Hunk, hash: Hash) bool {
    var changes: usize = 0;
    for (hunk.lines) |ln| {
        switch (ln.kind) {
            .add, .delete => changes += 1,
            .context, .meta => {},
        }
    }
    if (changes == 0) return std.mem.eql(u8, &fingerprintHunk(hunk), &hash);
    if (firstSpan(hunk.lines, null, hash) != null) return true;
    return firstRegrouped(hunk.lines, null, hash) != null;
}

/// Where each entry sits in `d`. Order is file, then hunk, then the run's
/// first line. One entry is used once. `preview` borrows from `d`.
fn place(
    alloc: Allocator,
    io: Io,
    root: Io.Dir,
    d: *const diff.Diff,
    approved: *const Approved,
) Allocator.Error![]Placement {
    const used = try alloc.alloc(bool, approved.entries.items.len);
    defer alloc.free(used);
    @memset(used, false);

    var list: std.ArrayList(Placement) = .empty;
    errdefer list.deinit(alloc);

    for (d.files, 0..) |f, fi| {
        const path = f.displayPath();
        if (f.hunks.len == 0) {
            // Hunk-less file: one hash of the worktree bytes.
            const hash = hunklessHash(alloc, io, root, f) orelse continue;
            const ei = approved.take(used, path, hash) orelse continue;
            try list.append(alloc, .{
                .entry_i = ei,
                .file_i = fi,
                .hunk_i = null,
                .span = null,
                .preview = "",
            });
            continue;
        }
        for (f.hunks, 0..) |*h, hi| {
            var changes: usize = 0;
            for (h.lines) |ln| {
                switch (ln.kind) {
                    .add, .delete => changes += 1,
                    .context, .meta => {},
                }
            }
            if (changes == 0) {
                // Context-only hunk: the tag-only fingerprint.
                const hash = fingerprintHunk(h.*);
                const ei = approved.take(used, path, hash) orelse continue;
                try list.append(alloc, .{
                    .entry_i = ei,
                    .file_i = fi,
                    .hunk_i = hi,
                    .span = null,
                    .preview = "",
                });
                continue;
            }

            // Claim non-overlapping runs, earlier lines first.
            const omit = try alloc.alloc(bool, h.lines.len);
            defer alloc.free(omit);
            @memset(omit, false);
            while (true) {
                const found = earliest(approved, used, path, h.lines, omit) orelse break;
                used[found.entry_i] = true;
                markClaim(omit, h.lines, found.span, found.add_span);
                try list.append(alloc, .{
                    .entry_i = found.entry_i,
                    .file_i = fi,
                    .hunk_i = hi,
                    .span = found.span,
                    .add_span = found.add_span,
                    .preview = h.lines[found.start].text,
                });
            }
        }
    }
    return try list.toOwnedSlice(alloc);
}

/// Live `{path, hash}` in flatten file/hunk order. Paths borrow from `d`.
/// Hunk-less files that cannot be read are omitted.
pub fn collectLive(alloc: Allocator, io: Io, root: Io.Dir, d: *const diff.Diff) Allocator.Error![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(alloc);
    for (d.files) |f| {
        const path = f.displayPath();
        if (f.hunks.len == 0) {
            if (hunklessHash(alloc, io, root, f)) |hash| {
                try list.append(alloc, .{ .path = path, .hash = hash });
            }
            continue;
        }
        for (f.hunks) |*h| {
            for (h.identityHunks()) |id| {
                try list.append(alloc, .{ .path = path, .hash = fingerprintHunk(id) });
            }
        }
    }
    return try list.toOwnedSlice(alloc);
}

/// One live identity the store currently consumes. Slices borrow from `d`.
/// The approved list (TUI overlay and `rv approved`) prints path, git group,
/// and a short preview derived from this value.
pub const Hidden = struct {
    pub const Kind = enum { hunk, binary, file };

    path: []const u8,
    hash: Hash,
    group: ?diff.Group,
    kind: Kind,
    /// First add/delete line, or empty (binary / hunk-less / context-only).
    preview: []const u8,

    /// `Unstaged` / `Untracked` / `Staged`, or `-` when the diff has no group.
    pub fn groupLabel(self: Hidden) []const u8 {
        return if (self.group) |g| switch (g) {
            .unstaged => "Unstaged",
            .untracked => "Untracked",
            .staged => "Staged",
        } else "-";
    }

    /// Overlay/CLI preview: first add/delete text, or `hunk` / `binary` / `file`.
    pub fn previewText(self: Hidden) []const u8 {
        return switch (self.kind) {
            .hunk => if (self.preview.len > 0) self.preview else "hunk",
            .binary => "binary",
            .file => "file",
        };
    }
};

/// Live approvals `place` consumes, flatten order (group, file, hunk, line).
pub fn collectApproved(
    alloc: Allocator,
    io: Io,
    root: Io.Dir,
    d: *const diff.Diff,
    approved: *const Approved,
) Allocator.Error![]Hidden {
    const placed = try place(alloc, io, root, d, approved);
    defer alloc.free(placed);

    var list: std.ArrayList(Hidden) = .empty;
    errdefer list.deinit(alloc);
    for (placed) |p| {
        const f = d.files[p.file_i];
        const kind: Hidden.Kind = if (p.hunk_i == null)
            (if (f.is_binary) .binary else .file)
        else
            .hunk;
        try list.append(alloc, .{
            .path = f.displayPath(),
            .hash = approved.entries.items[p.entry_i].hash,
            .group = f.group,
            .kind = kind,
            .preview = p.preview,
        });
    }
    return try list.toOwnedSlice(alloc);
}

/// First flatten row of this identity (hunk header, or file header if hunk-less).
pub fn rowForIdentity(
    rows: []const view.row.Row,
    d: *const diff.Diff,
    path: []const u8,
    hash: Hash,
    kind: Hidden.Kind,
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
                const hi = hunkAt(file.*, hh.old_start, hh.new_start) orelse continue;
                if (hunkContains(file.hunks[hi], hash)) return i;
            },
            .section_header, .line => {},
        }
    }
    return null;
}

/// Hunk (or hunk-less file) that owns `row_i`. A file-header row of a file
/// with hunks is the first hunk — used when the whole file is hidden.
pub fn identityAtRow(
    alloc: Allocator,
    d: *const diff.Diff,
    io: Io,
    root: Io.Dir,
    rows: []const view.row.Row,
    row_i: usize,
) ?Hidden {
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
                const hi = hunkAt(file.*, hh.old_start, hh.new_start) orelse return null;
                return .{
                    .path = file.displayPath(),
                    .hash = fingerprintHunk(file.hunks[hi].identityHunks()[0]),
                    .group = file.group,
                    .kind = .hunk,
                    .preview = "",
                };
            },
            .file_header => |fh| {
                const file = fileAt(d, fh.path, fh.group) orelse return null;
                if (file.hunks.len == 0) {
                    const hash = hunklessHash(alloc, io, root, file.*) orelse return null;
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
                    .hash = fingerprintHunk(file.hunks[0].identityHunks()[0]),
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

fn fileAt(d: *const diff.Diff, path: []const u8, group: ?diff.Group) ?*const diff.File {
    for (d.files) |*f| {
        if (f.group != group) continue;
        if (std.mem.eql(u8, f.displayPath(), path)) return f;
    }
    return null;
}

/// Rows for `d` with approved add/delete runs removed. A hunk whose changes
/// are all claimed is dropped, then a file with nothing left. File, hunk, and
/// line rows come from `view.row.appendFile` (same builder as `flatten`).
/// `root` is the worktree for hunk-less hashes.
pub fn hide(
    alloc: Allocator,
    d: *const diff.Diff,
    approved: *const Approved,
    io: Io,
    root: Io.Dir,
) Allocator.Error![]view.row.Row {
    const placed = try place(alloc, io, root, d, approved);
    defer alloc.free(placed);

    var rows: std.ArrayList(view.row.Row) = .empty;
    errdefer rows.deinit(alloc);
    var prev_group: ?diff.Group = null;
    var pi: usize = 0;

    for (d.files, 0..) |f, fi| {
        while (pi < placed.len and placed[pi].file_i < fi) pi += 1;
        const begin = pi;
        while (pi < placed.len and placed[pi].file_i == fi) pi += 1;
        const file_places = placed[begin..pi];

        if (f.hunks.len == 0) {
            if (file_places.len > 0) continue;
            try view.row.appendFile(alloc, &rows, f, &prev_group, null, null);
            continue;
        }

        const keep = try alloc.alloc(bool, f.hunks.len);
        defer alloc.free(keep);
        @memset(keep, true);

        const masks = try alloc.alloc([]bool, f.hunks.len);
        defer alloc.free(masks);
        var allocated: usize = 0;
        defer for (masks[0..allocated]) |m| alloc.free(m);
        for (f.hunks, 0..) |h, hi| {
            masks[hi] = try alloc.alloc(bool, h.lines.len);
            allocated += 1;
            @memset(masks[hi], false);
        }

        for (file_places) |p| {
            const hi = p.hunk_i orelse continue;
            const span = p.span orelse {
                keep[hi] = false;
                continue;
            };
            markClaim(masks[hi], f.hunks[hi].lines, span, p.add_span);
        }

        // Drop a hunk only when every add/delete line is claimed. A context-only
        // hunk stays unless its own tag-only hash was claimed above.
        for (f.hunks, 0..) |h, hi| {
            if (!keep[hi]) continue;
            var changes: usize = 0;
            var visible: usize = 0;
            for (h.lines, 0..) |ln, li| {
                switch (ln.kind) {
                    .add, .delete => {
                        changes += 1;
                        if (!masks[hi][li]) visible += 1;
                    },
                    .context, .meta => {},
                }
            }
            if (changes > 0 and visible == 0) keep[hi] = false;
        }

        var any = false;
        for (keep) |k| if (k) {
            any = true;
            break;
        };
        if (!any) continue;

        const omit = try alloc.alloc([]const bool, f.hunks.len);
        defer alloc.free(omit);
        for (masks, 0..) |m, hi| omit[hi] = m;
        try view.row.appendFile(alloc, &rows, f, &prev_group, keep, omit);
    }
    return try rows.toOwnedSlice(alloc);
}

/// Unapproved flatten plus how many store entries remain after prune.
pub const Visible = struct {
    rows: []view.row.Row,
    approved_n: usize,
};

/// 0-based hunk in `file` with these `@@` starts, or `null` if none.
pub fn hunkAt(file: diff.File, old_start: u32, new_start: u32) ?usize {
    for (file.hunks, 0..) |h, i| {
        if (h.old_start == old_start and h.new_start == new_start) return i;
    }
    return null;
}

/// Load `.rv/approved.json`, prune against `d`, persist if the set shrank,
/// flatten without approved hunks. `approved_n` is remaining live matches.
pub fn loadVisible(alloc: Allocator, io: Io, root: Io.Dir, d: *const diff.Diff) LoadError!Visible {
    var approved = try load(alloc, io, root);
    defer approved.deinit();
    const before = approved.entries.items.len;
    try approved.prune(alloc, io, root, d);
    if (approved.entries.items.len != before) {
        save(&approved, alloc, io, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }
    const rows = try hide(alloc, d, &approved, io, root);
    return .{ .rows = rows, .approved_n = approved.entries.items.len };
}

const testing = std.testing;
const builtin = @import("builtin");
const IsolatedTmp = if (builtin.is_test) @import("isolated_tmp").IsolatedTmp else void;

fn parseOneHunk(input: []const u8) !diff.Diff {
    var d = try diff.parse(testing.allocator, input);
    errdefer d.deinit();
    try testing.expectEqual(1, d.files.len);
    try testing.expectEqual(1, d.files[0].hunks.len);
    return d;
}

test "same add/delete at a new @@ line is the same hash" {
    const a =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-old
        \\+new
    ;
    const b =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -40,3 +40,3 @@ later section
        \\ other context
        \\-old
        \\+new
        \\ more
    ;
    var da = try parseOneHunk(a);
    defer da.deinit();
    var db = try parseOneHunk(b);
    defer db.deinit();
    try testing.expectEqual(fingerprintHunk(da.files[0].hunks[0]), fingerprintHunk(db.files[0].hunks[0]));
}

test "edited add/delete is a different hash" {
    const orig =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const edited =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+changed
    ;
    var da = try parseOneHunk(orig);
    defer da.deinit();
    var db = try parseOneHunk(edited);
    defer db.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        &fingerprintHunk(da.files[0].hunks[0]),
        &fingerprintHunk(db.files[0].hunks[0]),
    ));
}

test "delete foo is not add foo" {
    const del =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +0,0 @@
        \\-foo
    ;
    const add =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -0,0 +1 @@
        \\+foo
    ;
    var da = try parseOneHunk(del);
    defer da.deinit();
    var db = try parseOneHunk(add);
    defer db.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        &fingerprintHunk(da.files[0].hunks[0]),
        &fingerprintHunk(db.files[0].hunks[0]),
    ));
}

test "context meta section and group are unused" {
    const with_noise =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,3 +1,3 @@ labeled
        \\ ctx
        \\-old
        \\+new
        \\\ No newline at end of file
        \\ more
    ;
    const bare =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -9 +9 @@
        \\-old
        \\+new
    ;
    var da = try parseOneHunk(with_noise);
    defer da.deinit();
    var db = try parseOneHunk(bare);
    defer db.deinit();
    try testing.expectEqual(fingerprintHunk(da.files[0].hunks[0]), fingerprintHunk(db.files[0].hunks[0]));

    var grouped = try diff.parsePieces(testing.allocator, &.{
        .{ .text = bare, .group = .staged },
    });
    defer grouped.deinit();
    try testing.expectEqual(diff.Group.staged, grouped.files[0].group.?);
    try testing.expectEqual(fingerprintHunk(db.files[0].hunks[0]), fingerprintHunk(grouped.files[0].hunks[0]));
}

test "hunk merge is a different hash from either piece" {
    const split =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\@@ -3 +3 @@
        \\-c
        \\+d
    ;
    const merged =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,3 +1,3 @@
        \\-a
        \\+b
        \\ ctx
        \\-c
        \\+d
    ;
    var ds = try diff.parse(testing.allocator, split);
    defer ds.deinit();
    var dm = try diff.parse(testing.allocator, merged);
    defer dm.deinit();
    try testing.expectEqual(2, ds.files[0].hunks.len);
    try testing.expectEqual(1, dm.files[0].hunks.len);
    const h0 = fingerprintHunk(ds.files[0].hunks[0]);
    const h1 = fingerprintHunk(ds.files[0].hunks[1]);
    const hm = fingerprintHunk(dm.files[0].hunks[0]);
    try testing.expect(!std.mem.eql(u8, &h0, &hm));
    try testing.expect(!std.mem.eql(u8, &h1, &hm));
    try testing.expect(!std.mem.eql(u8, &h0, &h1));
}

test "approving a merged expand hunk takes the original hunks after reload" {
    const split =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-a
        \\+A
        \\@@ -3 +3 @@
        \\-c
        \\+C
    ;
    const new_file =
        \\A
        \\b
        \\C
        \\
    ;

    var d = try diff.parse(testing.allocator, split);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const h0 = fingerprintHunk(d.files[0].hunks[0]);
    const h1 = fingerprintHunk(d.files[0].hunks[1]);
    try testing.expectEqual(.expanded, try d.expandHunk(0, 0, new_file));
    try testing.expectEqual(1, d.files[0].hunks.len);

    const ids = d.files[0].hunks[0].identityHunks();
    try testing.expectEqual(2, ids.len);
    try testing.expectEqual(h0, fingerprintHunk(ids[0]));
    try testing.expectEqual(h1, fingerprintHunk(ids[1]));

    const io = testing.io;
    const alloc = testing.allocator;
    const live = try collectLive(alloc, io, .cwd(), &d);
    defer alloc.free(live);
    try testing.expectEqual(2, live.len);
    try testing.expectEqual(h0, live[0].hash);
    try testing.expectEqual(h1, live[1].hash);

    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.appendFile(alloc, io, .cwd(), d.files[0]);
    try testing.expectEqual(2, approved.entries.items.len);
    try approved.prune(alloc, io, .cwd(), &d);
    try testing.expectEqual(2, approved.entries.items.len);

    const hidden = try hide(alloc, &d, &approved, io, .cwd());
    defer alloc.free(hidden);
    try testing.expectEqual(0, hidden.len);

    var reload = try diff.parse(alloc, split);
    defer reload.deinit();
    var used = [_]bool{ false, false };
    try testing.expect(approved.take(&used, path, fingerprintHunk(reload.files[0].hunks[0])) != null);
    try testing.expect(approved.take(&used, path, fingerprintHunk(reload.files[0].hunks[1])) != null);
}

test "length-prefix: add a then delete b is not add a-b" {
    const two =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\+a
        \\-b
    ;
    const one =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -0,0 +1 @@
        \\+a-b
    ;
    var da = try parseOneHunk(two);
    defer da.deinit();
    var db = try parseOneHunk(one);
    defer db.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        &fingerprintHunk(da.files[0].hunks[0]),
        &fingerprintHunk(db.files[0].hunks[0]),
    ));
}

test "hunk-less file bytes change is a new hash" {
    try testing.expectEqual(fingerprintFile(""), fingerprintFile(""));
    try testing.expect(!std.mem.eql(u8, &fingerprintFile("abc"), &fingerprintFile("abd")));
    try testing.expect(!std.mem.eql(u8, &fingerprintFile(""), &fingerprintFile("x")));
}

test "hunk tag cannot collide with file tag" {
    const empty_hunk =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\ same
    ;
    var d = try parseOneHunk(empty_hunk);
    defer d.deinit();
    try testing.expect(!std.mem.eql(u8, &fingerprintHunk(d.files[0].hunks[0]), &fingerprintFile("")));
}

test "load missing file is empty" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    var approved = try load(alloc, io, tmp.dir);
    defer approved.deinit();
    try testing.expectEqual(0, approved.entries.items.len);
}

test "two identical entries roundtrip as a multiset" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    const hash = fingerprintFile("bytes");
    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append("bin.dat", hash);
    try approved.append("bin.dat", hash);
    try save(&approved, alloc, io, tmp.dir);

    var loaded = try load(alloc, io, tmp.dir);
    defer loaded.deinit();
    try testing.expectEqual(2, loaded.entries.items.len);
    try testing.expectEqualStrings("bin.dat", loaded.entries.items[0].path);
    try testing.expectEqualStrings("bin.dat", loaded.entries.items[1].path);
    try testing.expectEqual(hash, loaded.entries.items[0].hash);
    try testing.expectEqual(hash, loaded.entries.items[1].hash);

    const raw = try tmp.dir.readFileAlloc(io, rel_path, alloc, .limited(1024 * 1024));
    defer alloc.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"version\": 1") != null);
    const hex = std.fmt.bytesToHex(hash, .lower);
    try testing.expect(std.mem.indexOf(u8, raw, &hex) != null);
}

test "invalid json and invalid hash" {
    try testing.expectError(error.InvalidJson, parseJson(testing.allocator, "{"));
    const bad_len =
        \\{"version":1,"entries":[{"path":"f","hash":"abcd"}]}
    ;
    try testing.expectError(error.InvalidHash, parseJson(testing.allocator, bad_len));
    const bad_hex =
        \\{"version":1,"entries":[{"path":"f","hash":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}]}
    ;
    try testing.expectError(error.InvalidHash, parseJson(testing.allocator, bad_hex));
}

test "two identical hunks: approve one, one remains unmatched" {
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
    var d = try diff.parse(testing.allocator, txt);
    defer d.deinit();
    try testing.expectEqual(2, d.files[0].hunks.len);
    const path = d.files[0].displayPath();
    const h0 = fingerprintHunk(d.files[0].hunks[0]);
    const h1 = fingerprintHunk(d.files[0].hunks[1]);
    try testing.expectEqual(h0, h1);

    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(path, h0);
    var used = [_]bool{false};
    try testing.expect(approved.take(&used, path, h0) != null);
    try testing.expect(approved.take(&used, path, h1) == null);
    try testing.expectEqual(1, approved.entries.items.len);
}

test "unapprove removes one matching entry" {
    const hash = fingerprintFile("x");
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append("f.txt", hash);
    try approved.append("f.txt", hash);
    try approved.unapprove("f.txt", hash);
    try testing.expectEqual(1, approved.entries.items.len);
    try approved.unapprove("f.txt", hash);
    try testing.expectEqual(0, approved.entries.items.len);
    try testing.expectError(error.NotFound, approved.unapprove("f.txt", hash));
}

test "prune drops entries with no live match" {
    const alloc = testing.allocator;
    const io = testing.io;
    const hunk_txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parse(alloc, hunk_txt);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const hunk_hash = fingerprintHunk(d.files[0].hunks[0]);
    const file_hash = fingerprintFile("abc");

    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, hunk_hash);
    try approved.append("bin.dat", file_hash);

    try approved.prune(alloc, io, .cwd(), &d);
    try testing.expectEqual(1, approved.entries.items.len);
    try testing.expectEqualStrings(path, approved.entries.items[0].path);
    try testing.expectEqual(hunk_hash, approved.entries.items[0].hash);

    const other =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-gone
        \\+away
    ;
    var d2 = try diff.parse(alloc, other);
    defer d2.deinit();
    try approved.prune(alloc, io, .cwd(), &d2);
    try testing.expectEqual(0, approved.entries.items.len);
}

test "group is unused; path change does not match" {
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var unstaged = try diff.parsePieces(testing.allocator, &.{
        .{ .text = txt, .group = .unstaged },
    });
    defer unstaged.deinit();
    var staged = try diff.parsePieces(testing.allocator, &.{
        .{ .text = txt, .group = .staged },
    });
    defer staged.deinit();
    try testing.expectEqual(diff.Group.unstaged, unstaged.files[0].group.?);
    try testing.expectEqual(diff.Group.staged, staged.files[0].group.?);
    const hash = fingerprintHunk(unstaged.files[0].hunks[0]);
    try testing.expectEqual(hash, fingerprintHunk(staged.files[0].hunks[0]));

    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(unstaged.files[0].displayPath(), hash);
    var used = [_]bool{false};
    try testing.expect(approved.take(&used, staged.files[0].displayPath(), hash) != null);

    used[0] = false;
    try testing.expect(approved.take(&used, "renamed.txt", hash) == null);
}

fn twoHunkDiff(alloc: Allocator) !diff.Diff {
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
    try testing.expectEqual(1, d.files.len);
    try testing.expectEqual(2, d.files[0].hunks.len);
    return d;
}

fn threeGroupDiff(alloc: Allocator) !diff.Diff {
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
    return try diff.parsePieces(alloc, &.{
        .{ .text = unstaged_txt, .group = .unstaged },
        .{ .text = untracked_txt, .group = .untracked },
        .{ .text = staged_txt, .group = .staged },
    });
}

test "hide with empty store matches flatten" {
    const io = testing.io;
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    const hidden = try hide(testing.allocator, &d, &approved, io, .cwd());
    defer testing.allocator.free(hidden);
    const full = try view.row.flatten(testing.allocator, &d);
    defer testing.allocator.free(full);
    try testing.expectEqual(full.len, hidden.len);
    for (full, hidden) |a, b| {
        try testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    }
}

test "hide one hunk keeps the file and the other hunk" {
    const io = testing.io;
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(d.files[0].displayPath(), fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try hide(testing.allocator, &d, &approved, io, .cwd());
    defer testing.allocator.free(hidden);
    try testing.expectEqual(4, hidden.len);
    try testing.expect(hidden[0] == .file_header);
    try testing.expect(hidden[1] == .hunk_header);
    try testing.expectEqual(d.files[0].hunks[1].old_start, hidden[1].hunk_header.old_start);
    try testing.expect(hidden[2] == .line);
    try testing.expectEqualStrings("old2", hidden[2].line.text);
    try testing.expect(hidden[3] == .line);
    try testing.expectEqualStrings("new2", hidden[3].line.text);
}

fn hiddenHas(rows: []const view.row.Row, text: []const u8) bool {
    for (rows) |row| {
        switch (row) {
            .line => |ln| if (std.mem.eql(u8, ln.text, text)) return true,
            else => {},
        }
    }
    return false;
}

fn mergedNeighborDiff() []const u8 {
    return
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -5 +5 @@
        \\-l5
        \\+STAGED
    ;
}

fn mergedPieceDiff() []const u8 {
    return
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -6 +6 @@
        \\-l6
        \\+UNSTAGED
    ;
}

fn mergedHunkDiff() []const u8 {
    return
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -4,5 +4,5 @@
        \\ l4
        \\-l5
        \\-l6
        \\+STAGED
        \\+UNSTAGED
        \\ l7
    ;
}

test "hide omits an approved run and keeps the other changes in the hunk" {
    const io = testing.io;
    const alloc = testing.allocator;
    var piece = try parseOneHunk(mergedPieceDiff());
    defer piece.deinit();
    var merged = try parseOneHunk(mergedHunkDiff());
    defer merged.deinit();
    const path = merged.files[0].displayPath();
    const hash = fingerprintHunk(piece.files[0].hunks[0]);

    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, hash);

    const hidden = try hide(alloc, &merged, &approved, io, .cwd());
    defer alloc.free(hidden);
    try testing.expectEqual(6, hidden.len);
    try testing.expect(hidden[0] == .file_header);
    try testing.expect(hidden[1] == .hunk_header);
    try testing.expectEqualStrings("l4", hidden[2].line.text);
    try testing.expectEqualStrings("l5", hidden[3].line.text);
    try testing.expectEqualStrings("STAGED", hidden[4].line.text);
    try testing.expectEqualStrings("l7", hidden[5].line.text);
    try testing.expect(!hiddenHas(hidden, "UNSTAGED"));
    try testing.expect(!hiddenHas(hidden, "l6"));

    try approved.prune(alloc, io, .cwd(), &merged);
    try testing.expectEqual(1, approved.entries.items.len);
    try testing.expectEqual(hash, approved.entries.items[0].hash);

    const items = try collectApproved(alloc, io, .cwd(), &merged, &approved);
    defer alloc.free(items);
    try testing.expectEqual(1, items.len);
    try testing.expectEqualStrings("l6", items[0].preview);
    try testing.expectEqual(1, rowForIdentity(hidden, &merged, path, hash, .hunk).?);
}

test "hide drops a merged hunk when every change run is approved" {
    const io = testing.io;
    const alloc = testing.allocator;
    var neighbor = try parseOneHunk(mergedNeighborDiff());
    defer neighbor.deinit();
    var piece = try parseOneHunk(mergedPieceDiff());
    defer piece.deinit();
    var merged = try parseOneHunk(mergedHunkDiff());
    defer merged.deinit();
    const path = merged.files[0].displayPath();

    var approved = initEmpty(alloc);
    defer approved.deinit();
    // Store order is the opposite of file order. The list still reads top to bottom.
    try approved.append(path, fingerprintHunk(piece.files[0].hunks[0]));
    try approved.append(path, fingerprintHunk(neighbor.files[0].hunks[0]));

    const items = try collectApproved(alloc, io, .cwd(), &merged, &approved);
    defer alloc.free(items);
    try testing.expectEqual(2, items.len);
    try testing.expectEqualStrings("l5", items[0].preview);
    try testing.expectEqualStrings("l6", items[1].preview);

    const hidden = try hide(alloc, &merged, &approved, io, .cwd());
    defer alloc.free(hidden);
    try testing.expectEqual(0, hidden.len);

    try approved.prune(alloc, io, .cwd(), &merged);
    try testing.expectEqual(2, approved.entries.items.len);
}

test "a replacement that no longer matches is not hidden" {
    const io = testing.io;
    const alloc = testing.allocator;
    const was =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    const now =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+newer
    ;
    var dw = try parseOneHunk(was);
    defer dw.deinit();
    var dn = try parseOneHunk(now);
    defer dn.deinit();
    const path = dn.files[0].displayPath();

    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, fingerprintHunk(dw.files[0].hunks[0]));

    const hidden = try hide(alloc, &dn, &approved, io, .cwd());
    defer alloc.free(hidden);
    try testing.expect(hiddenHas(hidden, "old"));
    try testing.expect(hiddenHas(hidden, "newer"));
    try testing.expect(!hiddenHas(hidden, "new"));

    try approved.prune(alloc, io, .cwd(), &dn);
    try testing.expectEqual(0, approved.entries.items.len);
}

test "hide all hunks of a file drops the file header" {
    const io = testing.io;
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(d.files[0].displayPath(), fingerprintHunk(d.files[0].hunks[0]));
    try approved.append(d.files[0].displayPath(), fingerprintHunk(d.files[0].hunks[1]));
    const hidden = try hide(testing.allocator, &d, &approved, io, .cwd());
    defer testing.allocator.free(hidden);
    try testing.expectEqual(0, hidden.len);
}

test "hide drops an empty section and keeps a mixed file" {
    const io = testing.io;
    var d = try threeGroupDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append("a", fingerprintHunk(d.files[0].hunks[0]));
    try approved.append("u", fingerprintHunk(d.files[1].hunks[0]));
    const hidden = try hide(testing.allocator, &d, &approved, io, .cwd());
    defer testing.allocator.free(hidden);
    try testing.expect(hidden[0] == .section_header);
    try testing.expectEqual(diff.Group.staged, hidden[0].section_header);
    try testing.expect(hidden[1] == .file_header);
    try testing.expectEqualStrings("a", hidden[1].file_header.path);
    try testing.expect(hidden[2] == .hunk_header);
}

test "one store entry hides the first matching live hunk only" {
    const io = testing.io;
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ;
    var d = try diff.parsePieces(testing.allocator, &.{
        .{ .text = txt, .group = .unstaged },
        .{ .text = txt, .group = .staged },
    });
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append("f.txt", fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try hide(testing.allocator, &d, &approved, io, .cwd());
    defer testing.allocator.free(hidden);
    try testing.expect(hidden[0] == .section_header);
    try testing.expectEqual(diff.Group.staged, hidden[0].section_header);
    try testing.expect(hidden[1] == .file_header);
}

test "hide hunk-less file when worktree bytes match" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try tmp.write(io, "pic.png", "abc");
    const binary =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var d = try diff.parse(alloc, binary);
    defer d.deinit();
    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append("pic.png", fingerprintFile("abc"));
    const hidden = try hide(alloc, &d, &approved, io, tmp.dir);
    defer alloc.free(hidden);
    try testing.expectEqual(0, hidden.len);
}

test "loadVisible prunes stale identities and reports approved_n" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);

    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const path = d.files[0].displayPath();
    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, fingerprintHunk(d.files[0].hunks[0]));
    try approved.append("gone.txt", fingerprintFile("x"));
    try save(&approved, alloc, io, tmp.dir);

    const vis = try loadVisible(alloc, io, tmp.dir, &d);
    defer alloc.free(vis.rows);
    try testing.expectEqual(1, vis.approved_n);
    try testing.expectEqual(4, vis.rows.len);
    try testing.expect(vis.rows[0] == .file_header);

    var reloaded = try load(alloc, io, tmp.dir);
    defer reloaded.deinit();
    try testing.expectEqual(1, reloaded.entries.items.len);
    try testing.expectEqualStrings(path, reloaded.entries.items[0].path);
}

test "hunkAt matches @@ starts" {
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    const f = d.files[0];
    try testing.expectEqual(0, hunkAt(f, f.hunks[0].old_start, f.hunks[0].new_start).?);
    try testing.expectEqual(1, hunkAt(f, f.hunks[1].old_start, f.hunks[1].new_start).?);
    try testing.expect(hunkAt(f, 99, 99) == null);
}

test "appendFile empty store adds every hunk" {
    const io = testing.io;
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.appendFile(testing.allocator, io, .cwd(), d.files[0]);
    try testing.expectEqual(2, approved.entries.items.len);
}

test "appendFile skips stored hunks and hide drops the rest" {
    const io = testing.io;
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(d.files[0].displayPath(), fingerprintHunk(d.files[0].hunks[0]));
    try approved.appendFile(testing.allocator, io, .cwd(), d.files[0]);
    try testing.expectEqual(2, approved.entries.items.len);
    const hidden = try hide(testing.allocator, &d, &approved, io, .cwd());
    defer testing.allocator.free(hidden);
    try testing.expectEqual(0, hidden.len);
}

test "appendGroup approves one group only" {
    const io = testing.io;
    var d = try threeGroupDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.appendGroup(testing.allocator, io, .cwd(), &d, .unstaged);
    try testing.expectEqual(1, approved.entries.items.len);
    const hidden = try hide(testing.allocator, &d, &approved, io, .cwd());
    defer testing.allocator.free(hidden);
    try testing.expect(hidden[0] == .section_header);
    try testing.expectEqual(diff.Group.untracked, hidden[0].section_header);
}

test "collectApproved empty store is empty" {
    const io = testing.io;
    var d = try twoHunkDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    const items = try collectApproved(testing.allocator, io, .cwd(), &d, &approved);
    defer testing.allocator.free(items);
    try testing.expectEqual(0, items.len);
}

test "collectApproved flatten order is group then file then hunk" {
    const io = testing.io;
    var d = try threeGroupDiff(testing.allocator);
    defer d.deinit();
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append("a", fingerprintHunk(d.files[0].hunks[0]));
    try approved.append("u", fingerprintHunk(d.files[1].hunks[0]));
    try approved.append("a", fingerprintHunk(d.files[2].hunks[0]));
    const items = try collectApproved(testing.allocator, io, .cwd(), &d, &approved);
    defer testing.allocator.free(items);
    try testing.expectEqual(3, items.len);
    try testing.expectEqualStrings("a", items[0].path);
    try testing.expectEqual(diff.Group.unstaged, items[0].group.?);
    try testing.expectEqual(Hidden.Kind.hunk, items[0].kind);
    try testing.expectEqualStrings("old", items[0].preview);
    try testing.expectEqualStrings("u", items[1].path);
    try testing.expectEqual(diff.Group.untracked, items[1].group.?);
    try testing.expectEqualStrings("hi", items[1].preview);
    try testing.expectEqualStrings("a", items[2].path);
    try testing.expectEqual(diff.Group.staged, items[2].group.?);
    try testing.expectEqualStrings("staged", items[2].preview);
}

test "collectApproved identical hunks are a multiset" {
    const io = testing.io;
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
    var d = try diff.parse(testing.allocator, txt);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const hash = fingerprintHunk(d.files[0].hunks[0]);
    var approved = initEmpty(testing.allocator);
    defer approved.deinit();
    try approved.append(path, hash);
    {
        const items = try collectApproved(testing.allocator, io, .cwd(), &d, &approved);
        defer testing.allocator.free(items);
        try testing.expectEqual(1, items.len);
    }
    try approved.append(path, hash);
    const items = try collectApproved(testing.allocator, io, .cwd(), &d, &approved);
    defer testing.allocator.free(items);
    try testing.expectEqual(2, items.len);
    try testing.expectEqual(items[0].hash, items[1].hash);
    try testing.expectEqualStrings("a", items[0].preview);
}

test "rowForIdentity after unapprove restores one hunk and leaves the other hidden" {
    const io = testing.io;
    const alloc = testing.allocator;
    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const h0 = fingerprintHunk(d.files[0].hunks[0]);
    const h1 = fingerprintHunk(d.files[0].hunks[1]);
    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, h0);
    try approved.append(path, h1);
    try approved.unapprove(path, h0);
    const rows = try hide(alloc, &d, &approved, io, .cwd());
    defer alloc.free(rows);
    try testing.expectEqual(4, rows.len);
    try testing.expectEqual(1, rowForIdentity(rows, &d, path, h0, .hunk).?);
    try testing.expect(rowForIdentity(rows, &d, path, h1, .hunk) == null);
}

test "rowForIdentity identical hunks: unapprove restores the unmatched live hunk" {
    const io = testing.io;
    const alloc = testing.allocator;
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
    const hash = fingerprintHunk(d.files[0].hunks[0]);
    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, hash);
    try approved.append(path, hash);
    try approved.unapprove(path, hash);
    const rows = try hide(alloc, &d, &approved, io, .cwd());
    defer alloc.free(rows);
    try testing.expectEqual(4, rows.len);
    try testing.expectEqual(1, rowForIdentity(rows, &d, path, hash, .hunk).?);
    // Remaining store entry still consumes the first live match.
    try testing.expectEqual(d.files[0].hunks[1].old_start, rows[1].hunk_header.old_start);
}

test "collectApproved hunk-less binary" {
    if (builtin.os.tag == .wasi) return;
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = try IsolatedTmp.init(alloc, io);
    defer tmp.deinit(alloc, io);
    try tmp.write(io, "pic.png", "abc");
    const binary =
        \\diff --git a/pic.png b/pic.png
        \\Binary files a/pic.png and b/pic.png differ
    ;
    var d = try diff.parse(alloc, binary);
    defer d.deinit();
    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append("pic.png", fingerprintFile("abc"));
    const items = try collectApproved(alloc, io, tmp.dir, &d, &approved);
    defer alloc.free(items);
    try testing.expectEqual(1, items.len);
    try testing.expectEqualStrings("pic.png", items[0].path);
    try testing.expectEqual(Hidden.Kind.binary, items[0].kind);
    try testing.expectEqualStrings("", items[0].preview);
}

test "identityAtRow hunk line and file header" {
    const io = testing.io;
    const alloc = testing.allocator;
    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const full = try view.row.flatten(alloc, &d);
    defer alloc.free(full);
    const h0 = fingerprintHunk(d.files[0].hunks[0]);
    const h1 = fingerprintHunk(d.files[0].hunks[1]);
    // 0 file, 1 hunk0, 2 del, 3 add, 4 hunk1, 5 del, 6 add
    const at_add = identityAtRow(alloc, &d, io, .cwd(), full, 3).?;
    try testing.expectEqual(Hidden.Kind.hunk, at_add.kind);
    try testing.expectEqual(h0, at_add.hash);
    const at_file = identityAtRow(alloc, &d, io, .cwd(), full, 0).?;
    try testing.expectEqual(h0, at_file.hash);
    const at_h1 = identityAtRow(alloc, &d, io, .cwd(), full, 6).?;
    try testing.expectEqual(h1, at_h1.hash);
}

test "identityAtRow then unapprove restores a hidden comment line" {
    const io = testing.io;
    const alloc = testing.allocator;
    var d = try twoHunkDiff(alloc);
    defer d.deinit();
    const path = d.files[0].displayPath();
    const loc: view.CommentLoc = .{ .path = path, .side = .new, .line = 1 };
    const full = try view.row.flatten(alloc, &d);
    defer alloc.free(full);
    const full_row = view.rowForComment(full, loc).?;

    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(path, fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try hide(alloc, &d, &approved, io, .cwd());
    defer alloc.free(hidden);
    try testing.expect(view.rowForComment(hidden, loc) == null);

    const item = identityAtRow(alloc, &d, io, .cwd(), full, full_row).?;
    try approved.unapprove(item.path, item.hash);
    const restored = try hide(alloc, &d, &approved, io, .cwd());
    defer alloc.free(restored);
    try testing.expectEqual(full_row, view.rowForComment(restored, loc).?);
}

test "search on hidden flatten misses approved hunk text" {
    const io = testing.io;
    const alloc = testing.allocator;
    const txt =
        \\diff --git a/f.txt b/f.txt
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1 +1 @@
        \\-alpha
        \\+beta
        \\@@ -10 +10 @@
        \\-gamma
        \\+delta
    ;
    var d = try diff.parse(alloc, txt);
    defer d.deinit();
    var approved = initEmpty(alloc);
    defer approved.deinit();
    try approved.append(d.files[0].displayPath(), fingerprintHunk(d.files[0].hunks[0]));
    const hidden = try hide(alloc, &d, &approved, io, .cwd());
    defer alloc.free(hidden);
    try testing.expect(view.search.firstMatch(hidden, "alpha", 0) == null);
    try testing.expect(view.search.firstMatch(hidden, "beta", 0) == null);
    try testing.expectEqual(2, view.search.firstMatch(hidden, "gamma", 0).?.index);
}
