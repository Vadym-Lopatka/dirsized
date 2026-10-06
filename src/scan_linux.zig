//! Linux folder reader: raw getdents64 + one statx per regular file.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const scan = @import("scan.zig");
const FolderRead = scan.FolderRead;
const ReadError = scan.ReadError;

/// What the watcher needs to keep a folder's size right. The same value for every folder.
pub const watch_mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW | linux.IN.EXCL_UNLINK;

// Kept on the stack of the calling worker: no shared state, no allocation.
const buf_size = 64 * 1024;

const at_flags: u32 = linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT;
const file_mask: linux.STATX = .{ .SIZE = true, .TYPE = true };
const dir_mask: linux.STATX = .{ .TYPE = true, .MNT_ID = true };
const any_mask: linux.STATX = .{ .SIZE = true, .TYPE = true, .MNT_ID = true };

/// `out` is already reset (scan.readFolder does it).
pub fn readFolder(gpa: Allocator, dir_path: [:0]const u8, opts: scan.ReadOptions, out: *FolderRead) (ReadError || Allocator.Error)!void {
    // Watch first, read second: a change after the watch is queued, so none is lost.
    if (opts.inotify_fd >= 0) {
        const r = linux.inotify_add_watch(opts.inotify_fd, dir_path, watch_mask);
        switch (linux.errno(r)) {
            .SUCCESS => out.wd = @intCast(r),
            .NOSPC, .NOMEM => out.watch_failed = true,
            // The open below reports these the same way.
            .NOENT, .NOTDIR, .ACCES, .PERM, .LOOP => {},
            else => |e| return mapErrno(e),
        }
    }
    // A failed read gives the caller no wd to bind, so the watch must not outlive it.
    errdefer if (out.wd >= 0) {
        _ = linux.inotify_rm_watch(opts.inotify_fd, out.wd);
    };

    const fd = try openDir(dir_path);
    defer _ = linux.close(fd);

    var st: linux.Statx = undefined;
    try statxRetry(fd, "", linux.AT.EMPTY_PATH, dir_mask, &st);
    return readEntries(gpa, fd, &st, out);
}

const mapErrno = scan.mapErrno;

fn openDir(path: [:0]const u8) ReadError!i32 {
    while (true) {
        const r = linux.openat(linux.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0);
        switch (linux.errno(r)) {
            .SUCCESS => return @intCast(r),
            .INTR => {},
            else => |e| return mapErrno(e),
        }
    }
}

fn statxRetry(dirfd: i32, path: [*:0]const u8, flags: u32, mask: linux.STATX, st: *linux.Statx) ReadError!void {
    while (true) {
        switch (linux.errno(linux.statx(dirfd, path, flags, mask, st))) {
            .SUCCESS => return,
            .INTR => {},
            else => |e| return mapErrno(e),
        }
    }
}

/// True when `child` is on another mount than the folder `parent`. The mount id tells bind
/// mounts of the same file system apart; without it (kernel before 5.8) the device id is used.
fn isMount(parent: *const linux.Statx, child: *const linux.Statx) bool {
    if (parent.mask.MNT_ID and child.mask.MNT_ID) return parent.mnt_id != child.mnt_id;
    return parent.dev_major != child.dev_major or parent.dev_minor != child.dev_minor;
}

const S_IFMT = 0o170000;
const S_IFREG = 0o100000;
const S_IFDIR = 0o040000;

fn readEntries(gpa: Allocator, fd: i32, parent: *const linux.Statx, out: *FolderRead) (ReadError || Allocator.Error)!void {
    var buf: [buf_size]u8 align(8) = undefined;
    var st: linux.Statx = undefined;
    while (true) {
        const r = linux.getdents64(fd, &buf, buf.len);
        switch (linux.errno(r)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| return mapErrno(e),
        }
        if (r == 0) return;
        var off: usize = 0;
        while (off < r) {
            if (r - off < @sizeOf(linux.dirent64)) return error.Unexpected;
            const ent: *const linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
            const reclen = ent.reclen;
            if (reclen < @sizeOf(linux.dirent64) or reclen > r - off) return error.Unexpected;
            defer off += reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")]);
            if (name_ptr[0] == '.' and (name_ptr[1] == 0 or (name_ptr[1] == '.' and name_ptr[2] == 0))) continue;

            var kind = ent.type;
            if (kind == linux.DT.UNKNOWN) {
                // The file system gave no type: ask, and keep the answer in `st`.
                if (!try statEntry(fd, name_ptr, any_mask, &st, out)) continue;
                kind = switch (st.mode & S_IFMT) {
                    S_IFREG => linux.DT.REG,
                    S_IFDIR => linux.DT.DIR,
                    else => continue,
                };
                if (kind == linux.DT.REG) {
                    out.addFile(st.size);
                    continue;
                }
                if (!isMount(parent, &st)) try out.addDir(gpa, std.mem.span(name_ptr));
                continue;
            }
            switch (kind) {
                linux.DT.REG => {
                    if (!try statEntry(fd, name_ptr, file_mask, &st, out)) continue;
                    // A file replaced by something else since getdents is not a regular file.
                    if (st.mask.TYPE and st.mode & S_IFMT != S_IFREG) continue;
                    out.addFile(st.size);
                },
                linux.DT.DIR => {
                    if (!try statEntry(fd, name_ptr, dir_mask, &st, out)) continue;
                    if (!isMount(parent, &st)) try out.addDir(gpa, std.mem.span(name_ptr));
                },
                else => {},
            }
        }
    }
}

/// false = the entry is gone or unreadable: skip it. A vanished entry (ENOENT) is normal; any
/// other failure is counted in `entry_errors`, because the entry may be a folder whose node the
/// owner would otherwise remove.
fn statEntry(dirfd: i32, name: [*:0]const u8, mask: linux.STATX, st: *linux.Statx, out: *FolderRead) ReadError!bool {
    while (true) {
        switch (linux.errno(linux.statx(dirfd, name, at_flags, mask, st))) {
            .SUCCESS => return true,
            .INTR => {},
            .NOENT => return false,
            .ACCES, .PERM, .NOTDIR, .LOOP => {
                out.entry_errors += 1;
                return false;
            },
            else => |e| return mapErrno(e),
        }
    }
}

// Tests need the real file system.

const testing = std.testing;
const io = testing.io;

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

/// Independent answer: std's directory iterator and statFile on each entry (no mount check).
fn reference(gpa: Allocator, path: []const u8, names: *std.ArrayList([]u8)) !u64 {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var own: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const st = dir.statFile(io, e.name, .{ .follow_symlinks = false }) catch continue;
        switch (st.kind) {
            .file => own += st.size,
            .directory => try names.append(gpa, try gpa.dupe(u8, e.name)),
            else => {},
        }
    }
    return own;
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn expectMatches(path: [:0]const u8) !void {
    const gpa = testing.allocator;
    var want: std.ArrayList([]u8) = .empty;
    defer {
        for (want.items) |n| gpa.free(n);
        want.deinit(gpa);
    }
    const want_own = try reference(gpa, path, &want);
    std.mem.sort([]u8, want.items, {}, lessThan);

    var got: FolderRead = .{};
    defer got.deinit(gpa);
    try scan.readFolder(gpa, path, .{}, &got);
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

fn ok(r: usize) !void {
    try testing.expectEqual(.SUCCESS, linux.errno(r));
}

test "sizes, empty files, nested folders only count direct children" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("a", 100);
    try f.file("empty", 0);
    try f.tmp.dir.createDir(io, "sub", .default_dir);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "sub/deep", .data = "0123456789" });
    try f.tmp.dir.createDir(io, "sub/inner", .default_dir);
    try expectMatches(f.path());
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(100, got.own);
    try testing.expectEqualStrings("sub\x00", got.names.items);
    try testing.expectEqual(1, got.count);
}

test "empty folder" {
    var f = try Fixture.init();
    defer f.deinit();
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(0, got.own);
    try testing.expectEqual(0, got.count);
    try testing.expectEqual(0, got.names.items.len);
}

test "symlinks, dangling link and fifo are ignored" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("real", 7);
    try f.tmp.dir.createDir(io, "dir", .default_dir);
    try f.tmp.dir.symLink(io, "real", "link-to-file", .{});
    try f.tmp.dir.symLink(io, "dir", "link-to-dir", .{ .is_directory = true });
    try f.tmp.dir.symLink(io, "nowhere", "dangling", .{});
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    try ok(linux.mknodat(linux.AT.FDCWD, f.abs(&pb, "fifo"), linux.S.IFIFO | 0o644, 0));
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
    try ok(linux.link(f.abs(&pa, "a"), f.abs(&pb, "b")));
    var sparse = try f.tmp.dir.createFile(io, "sparse", .{});
    defer sparse.close(io);
    const huge: u64 = 5 * 1024 * 1024 * 1024 + 7;
    try sparse.setLength(io, huge);
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(20 + huge, got.own);
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
    try testing.expectEqual(7, got.own);
    var it = got.iterator();
    var seen: usize = 0;
    while (it.next()) |n| {
        for (odd) |o| {
            if (std.mem.eql(u8, o, n)) seen += 1;
        }
    }
    try testing.expectEqual(odd.len, seen);
}

test "5000 entries need several getdents64 calls" {
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
    try f.tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });
    try testing.expectError(error.NotDir, scan.readFolder(gpa, f.abs(&pa, "link"), .{}, &got));
    try f.file("plain", 1);
    try testing.expectError(error.NotDir, scan.readFolder(gpa, f.abs(&pa, "plain"), .{}, &got));
    try testing.expectError(error.NotFound, scan.readFolder(gpa, f.abs(&pa, "missing"), .{}, &got));
    try testing.expectError(error.NotFound, scan.readFolder(gpa, "/nonexistent-dirsized-path", .{}, &got));

    try f.tmp.dir.createDir(io, "locked", .default_dir);
    const locked = f.abs(&pa, "locked");
    try ok(linux.chmod(locked, 0));
    defer _ = linux.chmod(locked, 0o755); // the tmp dir cleanup needs it
    if (linux.getuid() != 0) try testing.expectError(error.AccessDenied, scan.readFolder(gpa, locked, .{}, &got));
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

test "allocation failure is reported and leaves the result empty" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDir(io, "a", .default_dir);
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, scan.readFolder(failing.allocator(), f.path(), .{}, &got));
    try testing.expectEqual(0, got.count);
    try testing.expectEqual(0, got.names.items.len);
}

test "inotify: a watch number comes back, the same folder gives the same one" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("x", 5);
    try f.tmp.dir.createDir(io, "d", .default_dir);
    const ifd_r = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    try ok(ifd_r);
    const ifd: i32 = @intCast(ifd_r);
    defer _ = linux.close(ifd);

    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, f.path(), .{ .inotify_fd = ifd }, &got);
    try testing.expect(got.wd >= 0);
    try testing.expect(!got.watch_failed);
    try testing.expectEqual(5, got.own);
    try testing.expectEqual(1, got.count);
    const wd = got.wd;
    try scan.readFolder(testing.allocator, f.path(), .{ .inotify_fd = ifd }, &got);
    try testing.expectEqual(wd, got.wd);

    // The watch is live: a new file is reported.
    try f.file("y", 1);
    var ev: [512]u8 align(4) = undefined;
    const n = linux.read(ifd, &ev, ev.len);
    try testing.expect(linux.errno(n) == .SUCCESS and n >= 16);
    try testing.expectEqual(wd, std.mem.readInt(i32, ev[0..4], .little));

    // Without a watch fd: wd stays -1.
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(-1, got.wd);
}

test "inotify: a read that fails leaves no watch behind" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDir(io, "d", .default_dir);
    const ifd_r = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    try ok(ifd_r);
    const ifd: i32 = @intCast(ifd_r);
    defer _ = linux.close(ifd);
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, readFolder(failing.allocator(), f.path(), .{ .inotify_fd = ifd }, &got));
    // The kernel reports a removed watch as IN_IGNORED.
    var ev: [64]u8 align(4) = undefined;
    const n = linux.read(ifd, &ev, ev.len);
    try testing.expect(linux.errno(n) == .SUCCESS and n >= 16);
    try testing.expectEqual(got.wd, std.mem.readInt(i32, ev[0..4], .little));
    try testing.expectEqual(linux.IN.IGNORED, std.mem.readInt(u32, ev[4..8], .little));
}

test "inotify: a missing or non-folder path reports the open error" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("plain", 1);
    const ifd_r = linux.inotify_init1(linux.IN.CLOEXEC);
    try ok(ifd_r);
    const ifd: i32 = @intCast(ifd_r);
    defer _ = linux.close(ifd);
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    var pa: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.NotFound, scan.readFolder(testing.allocator, f.abs(&pa, "missing"), .{ .inotify_fd = ifd }, &got));
    try testing.expectError(error.NotDir, scan.readFolder(testing.allocator, f.abs(&pa, "plain"), .{ .inotify_fd = ifd }, &got));
}

test "mount points are not children: proc, sys and dev under /" {
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, "/", .{}, &got);
    var it = got.iterator();
    var usr = false;
    while (it.next()) |n| {
        try testing.expect(!std.mem.eql(u8, n, "proc"));
        try testing.expect(!std.mem.eql(u8, n, "sys"));
        try testing.expect(!std.mem.eql(u8, n, "dev"));
        if (std.mem.eql(u8, n, "usr")) usr = true;
    }
    try testing.expect(usr);
}

test "a folder that vanishes while open gives a short result" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDir(io, "gone", .default_dir);
    var pa: [std.fs.max_path_bytes]u8 = undefined;
    const fd = try openDir(f.abs(&pa, "gone"));
    defer _ = linux.close(fd);
    try f.tmp.dir.deleteDir(io, "gone");
    var st: linux.Statx = undefined;
    try statxRetry(fd, "", linux.AT.EMPTY_PATH, dir_mask, &st);
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    readEntries(testing.allocator, fd, &st, &got) catch |err| try testing.expect(err == error.NotFound);
    try testing.expectEqual(0, got.count);
}

test "an entry that cannot be inspected is counted, a missing one is not" {
    if (linux.getuid() == 0) return error.SkipZigTest; // root can inspect everything
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDir(io, "d", .default_dir);
    try f.tmp.dir.createDir(io, "d/sub", .default_dir);
    var pa: [std.fs.max_path_bytes]u8 = undefined;
    const d = f.abs(&pa, "d");
    try ok(linux.chmod(d, 0o400)); // readable but not searchable: getdents works, statx fails
    defer _ = linux.chmod(d, 0o755); // the tmp dir cleanup needs it
    var got: FolderRead = .{};
    defer got.deinit(testing.allocator);
    try scan.readFolder(testing.allocator, d, .{}, &got);
    try testing.expectEqual(1, got.entry_errors);
    try testing.expectEqual(0, got.count);
    // A clean folder reports none: `readFolder` resets the count.
    try scan.readFolder(testing.allocator, f.path(), .{}, &got);
    try testing.expectEqual(0, got.entry_errors);
}
