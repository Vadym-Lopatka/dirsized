//! The snapshot file (DESIGN.md section 10): the table's three big arrays written raw, so a save
//! is a few large writes and a load is a few large reads straight into the final allocations.
//!
//! Layout, little endian: Header | roots | watcher blob | nodes | names | slots.
//! The checksum covers everything after its own field. It finds damage (a torn or edited
//! file); it is not a security measure. Any problem on load means "no snapshot", never a crash.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = std.c;
const table_mod = @import("table.zig");
const Table = table_mod.Table;
const Node = table_mod.Node;
const NodeId = table_mod.NodeId;
const Watcher = @import("watch.zig").Watcher;

comptime {
    // The arrays are written as they are in memory.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

pub const format_version: u32 = 1;
const magic = "dirsized".*;
/// A file larger than this cannot be a snapshot of a table that fits in 2^32 nodes.
const max_file = 1 << 40;

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    header_size: u32,
    /// Hash of every byte after this field.
    checksum: u64,
    /// The daemon's hash of roots, patterns and each root's letter case.
    config_hash: u64,
    saved_unix: i64,
    /// Last completed verification scan; 0 = never.
    verified_unix: i64,
    n_roots: u32,
    free_head: u32,
    /// Byte lengths of the sections: roots, watcher blob, then element counts of the arrays.
    roots_bytes: u64,
    watch_bytes: u64,
    nodes_count: u64,
    names_bytes: u64,
    slots_count: u64,
    free_count: u64,
};

const hashed_from = @offsetOf(Header, "config_hash");

pub const Loaded = struct {
    /// Its roots are exactly the `roots` given to `load`, in that order.
    table: Table,
    /// What `Watcher.saveState` wrote, allocated with the `gpa` given to `load`; the daemon frees it.
    watch_state: ?[]u8 = null,
    /// Wall-clock seconds of the last completed verification scan; 0 = never.
    verified_unix: i64 = 0,
    saved_unix: i64 = 0,
};

pub const SaveArgs = struct {
    gpa: Allocator,
    table: *const Table,
    watcher: *const Watcher,
    config_hash: u64,
    verified_unix: i64,
};

pub fn unixNow() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print("dirsized: " ++ fmt ++ "\n", args);
}

pub const Snapshot = struct {
    path: []const u8,

    /// Null when there is no usable file: missing, damaged, or from another config.
    pub fn load(self: *const Snapshot, gpa: Allocator, config_hash: u64, roots: []const []const u8) ?Loaded {
        return loadFile(gpa, self.path, config_hash, roots) catch |e| {
            if (e != error.NoFile) log("snapshot ignored ({t}), scanning everything", .{e});
            return null;
        };
    }

    /// Best effort: a failure is logged and leaves the old file as it was. Returns the file size.
    pub fn save(self: *const Snapshot, args: SaveArgs) ?u64 {
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(args.gpa);
        // A watcher without a usable state writes nothing; the next start is then fresh.
        args.watcher.saveState(&blob, args.gpa) catch blob.clearRetainingCapacity();
        return saveFile(args.gpa, self.path, args.table, args.config_hash, args.verified_unix, blob.items) catch |e| {
            log("cannot save the snapshot ({t}); keeping the old one", .{e});
            return null;
        };
    }
};

// ---------------------------------------------------------------- write

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, @min(rest.len, 1 << 30));
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

fn pathZ(buf: *[std.fs.max_path_bytes]u8, path: []const u8, suffix: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ path, suffix }, 0) catch error.NameTooLong;
}

pub fn saveFile(gpa: Allocator, path: []const u8, table: *const Table, config_hash: u64, verified_unix: i64, watch_blob: []const u8) !u64 {
    const img = table.image();
    // Header and the two small sections go through one small buffer; the arrays are not copied.
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    try head.appendNTimes(gpa, 0, @sizeOf(Header));
    for (img.roots) |r| {
        try head.appendSlice(gpa, &std.mem.toBytes(@as(u32, @intCast(r.path.len))));
        try head.appendSlice(gpa, r.path);
        try head.appendSlice(gpa, &std.mem.toBytes(@as(u32, r.node)));
    }
    const roots_bytes = head.items.len - @sizeOf(Header);
    try head.appendSlice(gpa, watch_blob);

    const nodes = std.mem.sliceAsBytes(img.nodes);
    const slots = std.mem.sliceAsBytes(img.slots);
    var h: Header = .{
        .magic = magic,
        .version = format_version,
        .header_size = @sizeOf(Header),
        .checksum = 0,
        .config_hash = config_hash,
        .saved_unix = unixNow(),
        .verified_unix = verified_unix,
        .n_roots = @intCast(img.roots.len),
        .free_head = img.free_head,
        .roots_bytes = roots_bytes,
        .watch_bytes = watch_blob.len,
        .nodes_count = img.nodes.len,
        .names_bytes = img.names.len,
        .slots_count = img.slots.len,
        .free_count = img.free_count,
    };
    @memcpy(head.items[0..@sizeOf(Header)], std.mem.asBytes(&h));
    var sum: std.hash.XxHash3 = .init(0);
    sum.update(head.items[hashed_from..]);
    sum.update(nodes);
    sum.update(img.names);
    sum.update(slots);
    h.checksum = sum.final();
    @memcpy(head.items[0..@sizeOf(Header)], std.mem.asBytes(&h));

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try pathZ(&tmp_buf, path, ".tmp");
    const fd = c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    var done = false;
    defer {
        _ = c.close(fd);
        if (!done) _ = c.unlink(tmp);
    }
    try writeAll(fd, head.items);
    try writeAll(fd, nodes);
    try writeAll(fd, img.names);
    try writeAll(fd, slots);
    if (c.fsync(fd) != 0) return error.SyncFailed;
    var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (c.rename(tmp, try pathZ(&dst_buf, path, "")) != 0) return error.RenameFailed;
    done = true;
    return head.items.len + nodes.len + img.names.len + slots.len;
}

// ---------------------------------------------------------------- read

fn readExact(fd: c.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.read(fd, buf.ptr + got, @min(buf.len - got, 1 << 30));
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return error.Truncated;
        got += @intCast(n);
    }
}

pub const LoadError = error{
    NoFile, OpenFailed, ReadFailed, Truncated, BadMagic, BadVersion, BadSize, BadChecksum,
    WrongConfig, BadRoots, BadImage, NameTooLong, OutOfMemory,
};

pub fn loadFile(gpa: Allocator, path: []const u8, config_hash: u64, roots: []const []const u8) LoadError!Loaded {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try pathZ(&buf, path, "");
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return if (c.errno(fd) == .NOENT) error.NoFile else error.OpenFailed;
    defer _ = c.close(fd);

    const end = c.lseek(fd, 0, c.SEEK.END);
    if (end < @sizeOf(Header) or end > max_file) return error.BadSize;
    if (c.lseek(fd, 0, c.SEEK.SET) != 0) return error.ReadFailed;
    const size: u64 = @intCast(end);

    var h: Header = undefined;
    try readExact(fd, std.mem.asBytes(&h));
    if (!std.mem.eql(u8, &h.magic, &magic)) return error.BadMagic;
    if (h.version != format_version or h.header_size != @sizeOf(Header)) return error.BadVersion;
    if (h.config_hash != config_hash) return error.WrongConfig;
    // Each length is bounded by the file size before any arithmetic, so nothing can overflow;
    // the sections must then add up to the file exactly.
    if (h.roots_bytes > size or h.watch_bytes > size or h.nodes_count > size or h.names_bytes > size or h.slots_count > size)
        return error.BadSize;
    if (h.names_bytes > table_mod.max_names or h.n_roots != roots.len) return error.BadSize;
    const expect = @sizeOf(Header) + h.roots_bytes + h.watch_bytes + h.nodes_count * @sizeOf(Node) + h.names_bytes + h.slots_count * @sizeOf(NodeId);
    if (expect != size) return error.BadSize;

    const small = try gpa.alloc(u8, h.roots_bytes + h.watch_bytes);
    defer gpa.free(small);
    const nodes = try gpa.alloc(Node, h.nodes_count);
    errdefer gpa.free(nodes);
    const names = try gpa.alloc(u8, h.names_bytes);
    errdefer gpa.free(names);
    const slots = try gpa.alloc(NodeId, h.slots_count);
    errdefer gpa.free(slots);
    try readExact(fd, small);
    try readExact(fd, std.mem.sliceAsBytes(nodes));
    try readExact(fd, names);
    try readExact(fd, std.mem.sliceAsBytes(slots));

    var sum: std.hash.XxHash3 = .init(0);
    sum.update(std.mem.asBytes(&h)[hashed_from..]);
    sum.update(small);
    sum.update(std.mem.sliceAsBytes(nodes));
    sum.update(names);
    sum.update(std.mem.sliceAsBytes(slots));
    if (sum.final() != h.checksum) return error.BadChecksum;

    const image_roots = try gpa.alloc(table_mod.Root, roots.len);
    defer gpa.free(image_roots);
    var pos: usize = 0;
    const rs = small[0..h.roots_bytes];
    for (roots, image_roots) |want, *out| {
        if (rs.len - pos < 4) return error.BadRoots;
        const len = std.mem.readInt(u32, rs[pos..][0..4], .little);
        pos += 4;
        if (rs.len - pos < @as(u64, len) + 4) return error.BadRoots;
        if (!std.mem.eql(u8, rs[pos..][0..len], want)) return error.BadRoots;
        pos += len;
        out.* = .{ .path = want, .node = std.mem.readInt(u32, rs[pos..][0..4], .little) };
        pos += 4;
    }
    if (pos != rs.len) return error.BadRoots;

    // Before `fromImage`: once it succeeds it owns the arrays, and a failure here would leak them.
    const blob: ?[]u8 = if (h.watch_bytes == 0) null else try gpa.dupe(u8, small[h.roots_bytes..]);
    errdefer if (blob) |b| gpa.free(b);
    const table = Table.fromImage(gpa, nodes, names, slots, h.free_head, h.free_count, image_roots) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadImage,
    };
    return .{ .table = table, .watch_state = blob, .verified_unix = h.verified_unix, .saved_unix = h.saved_unix };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const tio = testing.io;

const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init(fx: *Fixture) !void {
        fx.tmp = testing.tmpDir(.{});
        fx.len = try fx.tmp.dir.realPath(tio, &fx.buf);
    }

    fn deinit(fx: *Fixture) void {
        fx.tmp.cleanup();
    }

    fn file(fx: *Fixture, name: []const u8) []const u8 {
        // Reuse the tail of the buffer for the full path.
        const n = fx.len;
        fx.buf[n] = '/';
        @memcpy(fx.buf[n + 1 ..][0..name.len], name);
        return fx.buf[0 .. n + 1 + name.len];
    }
};

/// A small table: /r with a, b (a has x, y), one folder removed (free list), one pending, one denied.
fn sampleTable(gpa: Allocator) !Table {
    var t = Table.init(gpa);
    errdefer t.deinit();
    var fresh: std.ArrayList(NodeId) = .empty;
    defer fresh.deinit(gpa);
    const r = try t.addRoot("/r");
    _ = try t.applyRead(r, 5, &.{ "a", "b", "gone" }, &fresh, gpa);
    const a = t.child(r, "a").?;
    const b = t.child(r, "b").?;
    _ = try t.applyRead(a, 7, &.{ "x", "y" }, &fresh, gpa);
    _ = try t.applyRead(b, 1, &.{}, &fresh, gpa);
    _ = try t.applyRead(t.child(a, "x").?, 100, &.{}, &fresh, gpa);
    _ = try t.applyDenied(t.child(a, "y").?);
    _ = try t.applyRead(t.child(r, "gone").?, 3, &.{}, &fresh, gpa);
    _ = try t.applyRead(r, 5, &.{ "a", "b" }, &fresh, gpa);
    _ = t.markRecheck(b);
    return t;
}

fn saveSample(gpa: Allocator, path: []const u8, hash: u64, blob: []const u8) !void {
    var t = try sampleTable(gpa);
    defer t.deinit();
    _ = try saveFile(gpa, path, &t, hash, 1234, blob);
}

test "round trip keeps values, flags, the free list and the watcher blob" {
    const gpa = testing.allocator;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const path = fx.file("table");
    try saveSample(gpa, path, 77, "WATCH");
    var l = try loadFile(gpa, path, 77, &.{"/r"});
    defer l.table.deinit();
    defer gpa.free(l.watch_state.?);
    try testing.expectEqualStrings("WATCH", l.watch_state.?);
    try testing.expectEqual(@as(i64, 1234), l.verified_unix);
    var want = try sampleTable(gpa);
    defer want.deinit();
    try testing.expectEqual(want.count(), l.table.count());
    const r = l.table.lookup("/r").?;
    try testing.expectEqual(want.total(want.lookup("/r").?), l.table.total(r));
    try testing.expectEqual(@as(u64, 113), l.table.total(r));
    try testing.expectEqual(table_mod.State.partial, l.table.state(r));
    try testing.expect(l.table.needsRead(l.table.lookup("/r/b").?));
    try testing.expectEqual(table_mod.State.partial, l.table.state(l.table.lookup("/r/a").?));
    try testing.expect(l.table.lookup("/r/gone") == null);
    // The loaded table is a working table: the free node is reused, the index still finds names.
    var fresh: std.ArrayList(NodeId) = .empty;
    defer fresh.deinit(gpa);
    _ = try l.table.applyRead(r, 5, &.{ "a", "b", "new" }, &fresh, gpa);
    try testing.expect(l.table.lookup("/r/new") != null);
}

test "a load that runs out of memory frees everything" {
    const gpa = testing.allocator;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const path = fx.file("table");
    try saveSample(gpa, path, 77, "WATCH");
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var fa = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_at });
        var l = loadFile(fa.allocator(), path, 77, &.{"/r"}) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        l.table.deinit();
        fa.allocator().free(l.watch_state.?);
        break;
    }
    try testing.expect(fail_at > 4);
}

test "a missing file, another config, other roots: no snapshot" {
    const gpa = testing.allocator;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const path = fx.file("table");
    try testing.expectError(error.NoFile, loadFile(gpa, path, 1, &.{"/r"}));
    try saveSample(gpa, path, 1, "");
    try testing.expectError(error.WrongConfig, loadFile(gpa, path, 2, &.{"/r"}));
    try testing.expectError(error.BadSize, loadFile(gpa, path, 1, &.{ "/r", "/s" }));
    try testing.expectError(error.BadRoots, loadFile(gpa, path, 1, &.{"/q"}));
    var l = try loadFile(gpa, path, 1, &.{"/r"});
    try testing.expect(l.watch_state == null);
    l.table.deinit();
}

test "save over an existing file replaces it; a failed save keeps the old one" {
    const gpa = testing.allocator;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const path = fx.file("table");
    try saveSample(gpa, path, 1, "");
    var t = Table.init(gpa);
    defer t.deinit();
    _ = try t.addRoot("/r");
    _ = try saveFile(gpa, path, &t, 1, 0, "");
    var l = try loadFile(gpa, path, 1, &.{"/r"});
    try testing.expectEqual(@as(usize, 1), l.table.count());
    l.table.deinit();
    // The folder is missing: the save fails, the file stays.
    var bad_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bad = try std.fmt.bufPrint(&bad_buf, "{s}/nope/table", .{path[0 .. path.len - "/table".len]});
    try testing.expectError(error.OpenFailed, saveFile(gpa, bad, &t, 1, 0, ""));
    var again = try loadFile(gpa, path, 1, &.{"/r"});
    again.table.deinit();
}

/// Writes `bytes` to the fixture file and loads it.
fn loadBytes(fx: *Fixture, bytes: []const u8) LoadError!Loaded {
    const path = fx.file("fuzz");
    var z: [std.fs.max_path_bytes]u8 = undefined;
    const zp = std.fmt.bufPrintSentinel(&z, "{s}", .{path}, 0) catch unreachable;
    const fd = c.open(zp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    std.debug.assert(fd >= 0);
    writeAll(fd, bytes) catch unreachable;
    _ = c.close(fd);
    return loadFile(testing.allocator, path, 9, &.{"/r"});
}

fn slurp(gpa: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(tio, path, gpa, .limited(1 << 24));
}

test "fuzz: truncation at every length and a flipped byte at every offset never crash" {
    const gpa = testing.allocator;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try saveSample(gpa, fx.file("table"), 9, "blob");
    const good = try slurp(gpa, fx.file("table"));
    defer gpa.free(good);
    {
        var l = try loadBytes(&fx, good);
        l.table.deinit();
        gpa.free(l.watch_state.?);
    }
    for (0..good.len) |cut| {
        if (loadBytes(&fx, good[0..cut])) |*l| {
            var ll = l.*;
            ll.table.deinit();
            return error.TruncatedFileAccepted;
        } else |_| {}
    }
    const copy = try gpa.dupe(u8, good);
    defer gpa.free(copy);
    for (0..good.len) |i| {
        copy[i] = good[i] ^ 0x5a;
        defer copy[i] = good[i];
        if (loadBytes(&fx, copy)) |*l| {
            var ll = l.*;
            ll.table.deinit();
            if (ll.watch_state) |w| gpa.free(w);
            return error.DamagedFileAccepted;
        } else |_| {}
    }
}

test "fuzz: header fields that lie, with a matching checksum, are caught by the size and image checks" {
    const gpa = testing.allocator;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try saveSample(gpa, fx.file("table"), 9, "blob");
    const good = try slurp(gpa, fx.file("table"));
    defer gpa.free(good);
    const copy = try gpa.dupe(u8, good);
    defer gpa.free(copy);
    // Every 8-byte aligned header field set to a few hostile values; the checksum is fixed up
    // so only the structure checks stand in the way.
    const hostile = [_]u64{ 0, 1, 3, 5, 0xff, 1 << 20, 1 << 32, std.math.maxInt(u64), std.math.maxInt(u64) - 3 };
    var field: usize = hashed_from;
    while (field + 8 <= @sizeOf(Header)) : (field += 4) {
        for (hostile) |v| {
            @memcpy(copy, good);
            std.mem.writeInt(u32, copy[field..][0..4], @truncate(v), .little);
            var sum: std.hash.XxHash3 = .init(0);
            sum.update(copy[hashed_from..]);
            std.mem.writeInt(u64, copy[@offsetOf(Header, "checksum")..][0..8], sum.final(), .little);
            if (loadBytes(&fx, copy)) |*l| {
                // Harmless fields (times) may still load; the table must then be usable.
                var ll = l.*;
                _ = ll.table.count();
                ll.table.deinit();
                if (ll.watch_state) |w| gpa.free(w);
            } else |_| {}
        }
    }
}

test "fuzz: damaged arrays with a matching checksum are rejected or give a usable table" {
    const gpa = testing.allocator;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try saveSample(gpa, fx.file("table"), 9, "");
    const good = try slurp(gpa, fx.file("table"));
    defer gpa.free(good);
    const copy = try gpa.dupe(u8, good);
    defer gpa.free(copy);
    var prng = std.Random.DefaultPrng.init(42);
    for (0..300) |_| {
        @memcpy(copy, good);
        for (0..1 + prng.random().uintLessThan(usize, 3)) |_| {
            copy[@sizeOf(Header) + prng.random().uintLessThan(usize, good.len - @sizeOf(Header))] = prng.random().int(u8);
        }
        var sum: std.hash.XxHash3 = .init(0);
        sum.update(copy[hashed_from..]);
        std.mem.writeInt(u64, copy[@offsetOf(Header, "checksum")..][0..8], sum.final(), .little);
        if (loadBytes(&fx, copy)) |*l| {
            var ll = l.*;
            // Whatever loaded must be walkable without a crash.
            if (ll.table.lookup("/r")) |r| _ = ll.table.total(r);
            _ = ll.table.state(ll.table.roots()[0].node);
            ll.table.deinit();
        } else |_| {}
    }
}
