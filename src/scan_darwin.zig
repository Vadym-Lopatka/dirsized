//! macOS folder reader: getattrlistbulk with readdir fallback.

const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const scan = @import("scan.zig");
const FolderRead = scan.FolderRead;
const ReadError = scan.ReadError;

// Hand-written because std.c has none of this. Header paths are relative to the SDK's
// usr/include; line numbers are from the macOS 27 SDK.
const AttrList = extern struct { // sys/attr.h:81
    bitmapcount: u16 = 5, // ATTR_BIT_MAP_COUNT, attr.h:91
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};
comptime {
    std.debug.assert(@sizeOf(AttrList) == 24);
}

extern "c" fn getattrlistbulk(dirfd: c_int, alist: *const AttrList, buf: *align(8) anyopaque, size: usize, options: u64) c_int; // sys/unistd.h:188

const FSOPT_NOFOLLOW = 0x1; // attr.h:46
const ATTR_CMN_NAME = 0x1; // attr.h:409
const ATTR_CMN_OBJTYPE = 0x8; // attr.h:412
const ATTR_CMN_ERROR = 0x20000000; // attr.h:449
const ATTR_CMN_RETURNED_ATTRS = 0x80000000; // attr.h:456
const ATTR_DIR_MOUNTSTATUS = 0x4; // attr.h:527
const DIR_MNTSTATUS_MNTPOINT = 0x1; // attr.h:533
const ATTR_FILE_DATALENGTH = 0x200; // attr.h:546
const VREG = 1; // sys/vnode.h:83 (enum vtype)
const VDIR = 2;

/// A reply holds only the fields whose bit is in its returned set, in this fixed order. The
/// kernel packs defaults for unsupported attributes only with FSOPT_PACK_INVAL_ATTRS, which is
/// not used: the reader would then have to skip fields the returned set does not announce.
const request: AttrList = .{
    .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE,
    .dirattr = ATTR_DIR_MOUNTSTATUS,
    .fileattr = ATTR_FILE_DATALENGTH,
};

// About 450 records of typical size per call. Kept on the stack of the calling worker: no
// shared state to protect, no allocation, and a worker's stack is far larger than this.
const buf_size = 64 * 1024;

const Unsupported = error{Unsupported};

/// `out` is already reset (scan.readFolder does it).
pub fn readFolder(gpa: Allocator, dir_path: [:0]const u8, _: scan.ReadOptions, out: *FolderRead) (ReadError || Allocator.Error)!void {
    const fd = try openDir(dir_path);
    defer _ = c.close(fd);
    readBulk(gpa, fd, out) catch |err| switch (err) {
        // Nothing was consumed yet, so the same fd can be read again the slow way.
        error.Unsupported => return readFallback(gpa, fd, out),
        else => |e| return e,
    };
}

const mapErrno = scan.mapErrno;

fn openDir(path: [:0]const u8) ReadError!c_int {
    while (true) {
        const fd = c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (fd >= 0) return fd;
        switch (c.errno(fd)) {
            .INTR => {},
            else => |e| return mapErrno(e),
        }
    }
}

fn bulkCall(fd: c_int, buf: *align(8) [buf_size]u8) c_int {
    return getattrlistbulk(fd, &request, buf, buf.len, FSOPT_NOFOLLOW);
}

fn readBulk(gpa: Allocator, fd: c_int, out: *FolderRead) (ReadError || Allocator.Error || Unsupported)!void {
    return readBulkWith(bulkCall, gpa, fd, out);
}

/// `bulk` is `getattrlistbulk`, a parameter so tests can make it fail.
fn readBulkWith(bulk: anytype, gpa: Allocator, fd: c_int, out: *FolderRead) (ReadError || Allocator.Error || Unsupported)!void {
    var buf: [buf_size]u8 align(8) = undefined;
    var first = true;
    while (true) {
        const n = bulk(fd, &buf);
        if (n < 0) switch (c.errno(n)) {
            .INTR => continue,
            // ENOTSUP is the documented answer; EINVAL is what a driver that rejects the
            // attribute list may give. Neither was seen on APFS, HFS+, FAT, exFAT or devfs.
            .OPNOTSUPP, .INVAL => return if (first) error.Unsupported else error.Unexpected,
            else => |e| return mapErrno(e),
        };
        first = false; // only after a call that worked: an interrupted first call is still the first
        if (n == 0) return;
        // The call returns a count, not a byte length: walk by record length and
        // check each one against the buffer.
        var off: usize = 0;
        for (0..@intCast(n)) |_| {
            if (off + 4 > buf.len) return error.Unexpected;
            const len = std.mem.readInt(u32, buf[off..][0..4], .little);
            if (len < 4 or len > buf.len - off) return error.Unexpected;
            try addRecord(gpa, buf[off..][0..len], out);
            off += len;
        }
    }
}

/// Fields are only 4-byte aligned in the record, so every read is unaligned.
const Record = struct {
    bytes: []const u8,
    pos: usize = 4, // after the record length

    fn take(r: *Record, comptime T: type) ?T {
        const end = r.pos + @sizeOf(T);
        if (end > r.bytes.len) return null;
        defer r.pos = end;
        return std.mem.readInt(T, r.bytes[r.pos..][0..@sizeOf(T)], .little);
    }
};

/// A record whose entry failed (not "gone meanwhile") or that cannot be read is counted in
/// `entry_errors`: it may be a folder, and the owner must then keep what it knew.
fn addRecord(gpa: Allocator, bytes: []const u8, out: *FolderRead) Allocator.Error!void {
    parseRecord(gpa, bytes, out) catch |err| switch (err) {
        error.Malformed => out.entry_errors += 1,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn parseRecord(gpa: Allocator, bytes: []const u8, out: *FolderRead) (error{Malformed} || Allocator.Error)!void {
    var r: Record = .{ .bytes = bytes };
    // The returned attribute set: common, vol, dir, file, fork.
    const common = r.take(u32) orelse return error.Malformed;
    _ = r.take(u32) orelse return error.Malformed;
    const dir = r.take(u32) orelse return error.Malformed;
    const file = r.take(u32) orelse return error.Malformed;
    _ = r.take(u32) orelse return error.Malformed;

    if (common & ATTR_CMN_ERROR != 0) {
        const err = r.take(u32) orelse return error.Malformed;
        if (err != 0) {
            if (err != @intFromEnum(c.E.NOENT)) out.entry_errors += 1;
            return;
        }
    }
    if (common & ATTR_CMN_NAME == 0 or common & ATTR_CMN_OBJTYPE == 0) return error.Malformed;
    // attrreference_t: the offset is relative to the reference itself, the length counts the NUL.
    const ref = r.pos;
    const name_off = r.take(i32) orelse return error.Malformed;
    const name_len = r.take(u32) orelse return error.Malformed;
    const kind = r.take(u32) orelse return error.Malformed;

    switch (kind) {
        VREG => if (file & ATTR_FILE_DATALENGTH != 0) {
            out.addFile(r.take(u64) orelse return error.Malformed);
        },
        VDIR => {
            if (dir & ATTR_DIR_MOUNTSTATUS != 0 and (r.take(u32) orelse return error.Malformed) & DIR_MNTSTATUS_MNTPOINT != 0) return;
            const start = @as(isize, @intCast(ref)) + name_off;
            if (start < 0 or name_len == 0 or start + name_len > bytes.len) return error.Malformed;
            const name = bytes[@intCast(start)..][0 .. name_len - 1];
            try out.addDir(gpa, name);
        },
        else => {},
    }
}

fn readFallback(gpa: Allocator, fd: c_int, out: *FolderRead) (ReadError || Allocator.Error)!void {
    return fallbackWith(c.readdir, gpa, fd, out);
}

/// Volumes without bulk support. Takes over a duplicate of `fd`, because `closedir` closes its fd.
/// `readdir` is a parameter so tests can make it fail.
fn fallbackWith(readdir: anytype, gpa: Allocator, fd: c_int, out: *FolderRead) (ReadError || Allocator.Error)!void {
    var self_stat: c.Stat = undefined;
    if (c.fstat(fd, &self_stat) != 0) return mapErrno(c.errno(-1));
    const dup_fd = c.dup(fd);
    if (dup_fd < 0) return mapErrno(c.errno(dup_fd));
    const stream = c.fdopendir(dup_fd) orelse {
        const e = c.errno(-1);
        _ = c.close(dup_fd);
        return mapErrno(e);
    };
    defer _ = c.closedir(stream);

    // The end and an error both return null; only errno tells them apart, so clear it first.
    // A short list taken for the truth would delete folders.
    while (true) {
        c._errno().* = 0;
        const ent = readdir(stream) orelse break;
        const name: [*:0]const u8 = @ptrCast(&ent.name);
        const name_slice = std.mem.span(name);
        if (std.mem.eql(u8, name_slice, ".") or std.mem.eql(u8, name_slice, "..")) continue;
        var st: c.Stat = undefined;
        if (c.fstatat(fd, name, &st, c.AT.SYMLINK_NOFOLLOW) != 0) {
            if (c.errno(-1) != .NOENT) out.entry_errors += 1;
            continue;
        }
        switch (st.mode & c.S.IFMT) {
            c.S.IFREG => out.addFile(@intCast(st.size)),
            // The device id is the only mount-point signal here (see DESIGN.md section 4).
            c.S.IFDIR => if (st.dev == self_stat.dev) try out.addDir(gpa, name_slice),
            else => {},
        }
    }
    const e = c.errno(-1);
    if (e != .SUCCESS) return mapErrno(e);
}

// Tests need the real file system.

const testing = std.testing;
const io = testing.io;

extern "c" fn mkfifo(path: [*:0]const u8, mode: c.mode_t) c_int;
extern "c" fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: [*]const u8, size: usize, position: u32, options: c_int) c_int;

const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{ .iterate = true }) };
        f.len = try f.tmp.dir.realPath(io, &f.buf);
        f.buf[f.len] = 0;
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }

    fn path(f: *const Fixture) [:0]const u8 {
        return f.buf[0..f.len :0];
    }

    /// Absolute path of `rel` inside the fixture, in `out`.
    fn abs(f: *const Fixture, out: []u8, rel: []const u8) [:0]const u8 {
        return std.fmt.bufPrintZ(out, "{s}/{s}", .{ f.path(), rel }) catch unreachable;
    }

    fn file(f: *Fixture, name: []const u8, size: usize) !void {
        const data = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(data);
        @memset(data, 'x');
        try f.tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }
};

/// Independent answer: std's directory iterator, then fstatat on each entry. Returns the
/// own size; the caller frees the names.
fn reference(gpa: Allocator, path: []const u8, names: *std.ArrayList([]u8)) !u64 {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var dir_st: c.Stat = undefined;
    try testing.expectEqual(0, c.fstat(dir.handle, &dir_st));
    var own: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const z = try gpa.dupeZ(u8, e.name);
        defer gpa.free(z);
        var st: c.Stat = undefined;
        if (c.fstatat(dir.handle, z, &st, c.AT.SYMLINK_NOFOLLOW) != 0) continue;
        switch (st.mode & c.S.IFMT) {
            c.S.IFREG => own += @intCast(st.size),
            c.S.IFDIR => if (st.dev == dir_st.dev) try names.append(gpa, try gpa.dupe(u8, e.name)),
            else => {},
        }
    }
    return own;
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Both readers must equal the reference for the folder at `path`.
fn expectMatches(path: [:0]const u8) !void {
    const gpa = testing.allocator;
    var want: std.ArrayList([]u8) = .empty;
    defer {
        for (want.items) |n| gpa.free(n);
        want.deinit(gpa);
    }
    const want_own = try reference(gpa, path, &want);
    std.mem.sort([]u8, want.items, {}, lessThan);

    inline for (.{ readBulk, readFallback }) |reader| {
        const fd = try openDir(path); // a read consumes the directory offset
        defer _ = c.close(fd);
        var got: FolderRead = .{};
        defer got.deinit(gpa);
        try reader(gpa, fd, &got);
        try testing.expectEqual(want_own, got.own);
        try testing.expectEqual(want.items.len, got.count);
        var names: std.ArrayList([]u8) = .empty;
        defer names.deinit(gpa);
        var it = got.iterator();
        while (it.next()) |n| try names.append(gpa, @constCast(n));
        std.mem.sort([]u8, names.items, {}, lessThan);
        try testing.expectEqual(want.items.len, names.items.len);
        for (want.items, names.items) |w, g| try testing.expectEqualStrings(w, g);
    }
    // And the public entry point, which is the bulk path on this volume.
    var got: FolderRead = .{};
    defer got.deinit(gpa);
    try scan.readFolder(gpa, path, .{}, &got);
    try testing.expectEqual(want_own, got.own);
    try testing.expectEqual(want.items.len, got.count);
}

test "sizes, empty files, nested folders only count direct children" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("empty", 0);
    try f.file("one", 1);
    try f.file("big", 100_000);
    try f.tmp.dir.createDir(io, "sub", .default_dir);
    try f.tmp.dir.createDir(io, "sub/deeper", .default_dir);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "sub/inner", .data = "not counted" });
    try expectMatches(f.path());
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(100_001, got.own);
    try testing.expectEqualStrings("sub\x00", got.names.items);
}

test "empty folder" {
    var f = try Fixture.init();
    defer f.deinit();
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(0, got.own);
    try testing.expectEqual(0, got.count);
    try expectMatches(f.path());
}

test "symlinks, dangling link and fifo are ignored" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("target", 7);
    try f.tmp.dir.createDir(io, "dir", .default_dir);
    try f.tmp.dir.symLink(io, "target", "link-file", .{});
    try f.tmp.dir.symLink(io, "dir", "link-dir", .{});
    try f.tmp.dir.symLink(io, "nowhere", "dangling", .{});
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(0, mkfifo(f.abs(&pb, "fifo"), 0o644));
    try expectMatches(f.path());
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(7, got.own);
    try testing.expectEqualStrings("dir\x00", got.names.items);
}

test "hard links count at each name, sparse files at full length" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("a", 10);
    var pa: [std.fs.max_path_bytes]u8 = undefined;
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(0, c.link(f.abs(&pa, "a"), f.abs(&pb, "b")));
    var sparse = try f.tmp.dir.createFile(io, "sparse", .{});
    defer sparse.close(io);
    const huge: u64 = 5 * 1024 * 1024 * 1024 + 7;
    try sparse.setLength(io, huge);
    try expectMatches(f.path());
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(20 + huge, got.own);
}

test "extended attributes and resource fork are not added" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("f", 5);
    var pa: [std.fs.max_path_bytes]u8 = undefined;
    const p = f.abs(&pa, "f");
    const blob = [_]u8{1} ** 3000;
    try testing.expectEqual(0, setxattr(p, "user.test", &blob, blob.len, 0, 0));
    try testing.expectEqual(0, setxattr(p, "com.apple.ResourceFork", &blob, blob.len, 0, 0));
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(5, got.own);
    try expectMatches(f.path());
}

test "names are bytes: space, newline, non-ASCII, 255 bytes" {
    var f = try Fixture.init();
    defer f.deinit();
    const long = "n" ** 255;
    const odd = [_][]const u8{ "a b", "line\nbreak", "ünïcødé", long };
    for (odd) |n| try f.tmp.dir.createDir(io, n, .default_dir);
    try f.file(long[1..] ++ "f", 3);
    try f.file("line\nfile", 4);
    try expectMatches(f.path());
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(odd.len, got.count);
    var it = got.iterator();
    var seen: usize = 0;
    while (it.next()) |n| {
        for (odd) |o| {
            if (std.mem.eql(u8, o, n)) seen += 1;
        }
    }
    try testing.expectEqual(odd.len, seen);
}

test "5000 entries need several bulk calls" {
    var f = try Fixture.init();
    defer f.deinit();
    var name: [64]u8 = undefined;
    var want: u64 = 0;
    for (0..5000) |i| {
        const n = try std.fmt.bufPrint(&name, "entry-with-a-fairly-long-name-{d:0>6}", .{i});
        if (i % 10 == 0) {
            try f.tmp.dir.createDir(io, n, .default_dir);
        } else {
            try f.tmp.dir.writeFile(io, .{ .sub_path = n, .data = name[0 .. i % 13] });
            want += i % 13;
        }
    }
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(want, got.own);
    try testing.expectEqual(500, got.count);
    try expectMatches(f.path());
}

test "errors" {
    var f = try Fixture.init();
    defer f.deinit();
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    const gpa = testing.allocator;
    var pa: [std.fs.max_path_bytes]u8 = undefined;

    try f.tmp.dir.createDir(io, "real", .default_dir);
    try f.tmp.dir.symLink(io, "real", "link", .{});
    try testing.expectError(error.NotDir, scan.readFolder(gpa, f.abs(&pa, "link"), .{}, &got));
    try f.file("plain", 1);
    try testing.expectError(error.NotDir, scan.readFolder(gpa, f.abs(&pa, "plain"), .{}, &got));
    try testing.expectError(error.NotFound, scan.readFolder(gpa, f.abs(&pa, "missing"), .{}, &got));
    try testing.expectError(error.NotFound, scan.readFolder(gpa, "/nonexistent-dirsized-path", .{}, &got));

    try f.tmp.dir.createDir(io, "locked", .default_dir);
    const locked = f.abs(&pa, "locked");
    try testing.expectEqual(0, c.chmod(locked, 0));
    defer _ = c.chmod(locked, 0o755); // the tmp dir cleanup needs it
    if (std.c.getuid() != 0) try testing.expectError(error.AccessDenied, scan.readFolder(gpa, locked, .{}, &got));
}

test "a result is reused without allocating" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDir(io, "a", .default_dir);
    try f.tmp.dir.createDir(io, "b", .default_dir);
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try scan.readFolder(failing.allocator(), f.path(), .{}, &got);
    try testing.expectEqual(2, got.count);
}

test "a folder that vanishes while open gives NotFound or a short result" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDir(io, "gone", .default_dir);
    var pa: [std.fs.max_path_bytes]u8 = undefined;
    const fd = try openDir(f.abs(&pa, "gone"));
    defer _ = c.close(fd);
    try f.tmp.dir.deleteDir(io, "gone");
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    readBulk(testing.allocator, fd, &got) catch |err| try testing.expect(err == error.NotFound);
    try testing.expectEqual(0, got.count);
}

test "a failed entry is counted, a vanished one is not" {
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    // Record: length, the five returned-attribute words (only ERROR), then the error code.
    var rec: [28]u8 = @splat(0);
    std.mem.writeInt(u32, rec[0..4], rec.len, .little);
    std.mem.writeInt(u32, rec[4..8], ATTR_CMN_ERROR, .little);
    std.mem.writeInt(u32, rec[24..28], @intFromEnum(c.E.ACCES), .little);
    try addRecord(testing.allocator, &rec, &got);
    try testing.expectEqual(1, got.entry_errors);
    std.mem.writeInt(u32, rec[24..28], @intFromEnum(c.E.NOENT), .little);
    try addRecord(testing.allocator, &rec, &got);
    try testing.expectEqual(1, got.entry_errors);
    got.reset();
    try testing.expectEqual(0, got.entry_errors);
}

fn setErrno(e: c.E) void {
    c._errno().* = @intFromEnum(e);
}

var bulk_calls: usize = 0;

/// First call interrupted, second says the volume has no bulk support.
fn interruptedThenUnsupported(_: c_int, _: *align(8) [buf_size]u8) c_int {
    bulk_calls += 1;
    setErrno(if (bulk_calls == 1) .INTR else .OPNOTSUPP);
    return -1;
}

test "an interrupted first call is still the first: unsupported falls back" {
    bulk_calls = 0;
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try testing.expectError(error.Unsupported, readBulkWith(interruptedThenUnsupported, testing.allocator, -1, &got));
    try testing.expectEqual(2, bulk_calls);
}

fn failingReaddir(_: *c.DIR) callconv(.c) ?*c.dirent {
    setErrno(.MFILE);
    return null;
}

fn endOfDir(_: *c.DIR) callconv(.c) ?*c.dirent {
    return null; // leaves errno alone, as the real one does
}

test "readdir: an error is not the end of the folder" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDir(io, "sub", .default_dir);
    const fd = try openDir(f.path());
    defer _ = c.close(fd);
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try testing.expectError(error.Transient, fallbackWith(failingReaddir, testing.allocator, fd, &got));
    // A stale errno from an earlier call is not an error at the real end.
    setErrno(.IO);
    got.reset();
    try fallbackWith(endOfDir, testing.allocator, fd, &got);
    try testing.expectEqual(0, got.entry_errors);
}

test "a record that cannot be read is counted" {
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    // Too short for the returned set.
    var short: [8]u8 = @splat(0);
    std.mem.writeInt(u32, short[0..4], short.len, .little);
    try addRecord(testing.allocator, &short, &got);
    try testing.expectEqual(1, got.entry_errors);
    // A full returned set without NAME and OBJTYPE.
    var bare: [24]u8 = @splat(0);
    std.mem.writeInt(u32, bare[0..4], bare.len, .little);
    try addRecord(testing.allocator, &bare, &got);
    try testing.expectEqual(2, got.entry_errors);
}
