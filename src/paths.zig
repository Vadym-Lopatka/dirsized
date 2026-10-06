//! Where things live (DESIGN.md sections 10 and 11). No global environment access: the
//! caller passes `home` and the XDG variables. Every function returns allocated paths.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Paths = struct {
    cache_dir: []const u8,
    socket_dir: []const u8,
    socket: []const u8,
    snapshot: []const u8,
    lock: []const u8,

    /// Everything is allocated from `arena`; free it all at once.
    /// error.SocketPathTooLong if the socket path does not fit in `sockaddr_un.sun_path`.
    pub fn init(arena: Allocator, home: []const u8, xdg_runtime_dir: ?[]const u8, xdg_cache_home: ?[]const u8) !Paths {
        return initFor(builtin.os.tag, arena, home, xdg_runtime_dir, xdg_cache_home);
    }
};

/// Size of `sockaddr_un.sun_path`; the path needs one more byte for its NUL.
fn sunPathSize(os: std.Target.Os.Tag) usize {
    return switch (os) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .openbsd, .dragonfly => 104,
        else => 108,
    };
}

/// `Paths.init` with the platform as a parameter, so both layouts are testable anywhere.
fn initFor(os: std.Target.Os.Tag, arena: Allocator, home: []const u8, xdg_runtime_dir: ?[]const u8, xdg_cache_home: ?[]const u8) !Paths {
    const p = try layoutFor(os, arena, home, xdg_runtime_dir, xdg_cache_home);
    if (p.socket.len >= sunPathSize(os)) return error.SocketPathTooLong;
    return p;
}

/// The paths without the length check (tests need long temp folders).
fn layoutFor(os: std.Target.Os.Tag, arena: Allocator, home: []const u8, xdg_runtime_dir: ?[]const u8, xdg_cache_home: ?[]const u8) !Paths {
    const cache = try cacheDirFor(os, arena, home, xdg_cache_home);
    const sdir = try socketDirFor(os, arena, home, xdg_runtime_dir, xdg_cache_home);
    const sock = try std.fs.path.join(arena, &.{ sdir, "sock" });
    return .{
        .cache_dir = cache,
        .socket_dir = sdir,
        .socket = sock,
        .snapshot = try std.fs.path.join(arena, &.{ cache, "table" }),
        .lock = try std.fs.path.join(arena, &.{ cache, "lock" }),
    };
}

/// An unset, empty or relative XDG value is ignored, as the XDG spec says.
fn usable(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    if (s.len == 0 or s[0] != '/') return null;
    return s;
}

/// macOS: <home>/.cache/dirsized. Linux: <XDG_CACHE_HOME or home/.cache>/dirsized.
fn cacheDirFor(os: std.Target.Os.Tag, gpa: Allocator, home: []const u8, xdg_cache_home: ?[]const u8) ![]u8 {
    if (os != .macos) {
        if (usable(xdg_cache_home)) |x| return std.fs.path.join(gpa, &.{ x, "dirsized" });
    }
    return std.fs.path.join(gpa, &.{ home, ".cache", "dirsized" });
}

/// The folder of the socket (mode 0700). macOS: the cache folder. Linux: <XDG_RUNTIME_DIR>/dirsized,
/// or the cache folder if XDG_RUNTIME_DIR is unset or empty. The socket is `<this>/sock`.
fn socketDirFor(os: std.Target.Os.Tag, gpa: Allocator, home: []const u8, xdg_runtime_dir: ?[]const u8, xdg_cache_home: ?[]const u8) ![]u8 {
    if (os != .macos) {
        if (usable(xdg_runtime_dir)) |x| return std.fs.path.join(gpa, &.{ x, "dirsized" });
    }
    // The socket sits directly in the cache folder (<cacheDir>/sock).
    return cacheDirFor(os, gpa, home, xdg_cache_home);
}

/// The socket file itself.
pub fn socketPath(gpa: Allocator, home: []const u8, xdg_runtime_dir: ?[]const u8, xdg_cache_home: ?[]const u8) ![]u8 {
    const d = try socketDirFor(builtin.os.tag, gpa, home, xdg_runtime_dir, xdg_cache_home);
    defer gpa.free(d);
    return std.fs.path.join(gpa, &.{ d, "sock" });
}

/// Creates the cache folder and the socket folder, with parents. The socket folder is 0700
/// even if it existed before (`chmod`). Parents and the cache folder get 0700 / 0755 only
/// when this call creates them; existing ones are not touched.
pub fn ensureDirs(p: *const Paths) !void {
    try mkdirAll(p.cache_dir, 0o700);
    try mkdirAll(p.socket_dir, 0o700);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try terminate(&buf, p.socket_dir);
    if (std.c.chmod(z, 0o700) != 0) return errnoError();
}

fn terminate(buf: []u8, path: []const u8) error{NameTooLong}![:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn errnoError() error{ AccessDenied, NotDir, NoSpace, ReadOnly, Unexpected } {
    return switch (std.c.errno(-1)) {
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDir,
        .NOSPC, .DQUOT => error.NoSpace,
        .ROFS => error.ReadOnly,
        else => error.Unexpected,
    };
}

/// `mkdir -p`. Parents get 0755; the last component gets `mode`. EEXIST is success.
fn mkdirAll(path: []const u8, mode: std.c.mode_t) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    var i: usize = 1; // skip the leading '/'
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        if (i > 0 and path[i - 1] == '/') continue; // "//" or trailing '/'
        const z = try terminate(&buf, path[0..i]);
        const m: std.c.mode_t = if (i == path.len) mode else 0o755;
        if (std.c.mkdir(z, m) != 0) {
            switch (std.c.errno(-1)) {
                .EXIST => {},
                else => return errnoError(),
            }
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectPaths(p: Paths, cache: []const u8, sdir: []const u8) !void {
    try testing.expectEqualStrings(cache, p.cache_dir);
    try testing.expectEqualStrings(sdir, p.socket_dir);
}

test "macOS layout ignores the XDG variables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try initFor(.macos, arena.allocator(), "/Users/x", "/run/user/1", "/xc");
    try expectPaths(p, "/Users/x/.cache/dirsized", "/Users/x/.cache/dirsized");
    try testing.expectEqualStrings("/Users/x/.cache/dirsized/sock", p.socket);
    try testing.expectEqualStrings("/Users/x/.cache/dirsized/table", p.snapshot);
    try testing.expectEqualStrings("/Users/x/.cache/dirsized/lock", p.lock);
}

test "Linux layout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try initFor(.linux, a, "/home/x", "/run/user/1000", "/xc");
    try expectPaths(p, "/xc/dirsized", "/run/user/1000/dirsized");
    try testing.expectEqualStrings("/run/user/1000/dirsized/sock", p.socket);
    try testing.expectEqualStrings("/xc/dirsized/table", p.snapshot);
    try testing.expectEqualStrings("/xc/dirsized/lock", p.lock);

    // No XDG_CACHE_HOME: home/.cache.
    const q = try initFor(.linux, a, "/home/x", "/run/user/1000", null);
    try expectPaths(q, "/home/x/.cache/dirsized", "/run/user/1000/dirsized");

    // XDG_RUNTIME_DIR unset or empty: the cache folder is used.
    for ([_]?[]const u8{ null, "" }) |rt| {
        const r = try initFor(.linux, a, "/home/x", rt, null);
        try expectPaths(r, "/home/x/.cache/dirsized", "/home/x/.cache/dirsized");
        try testing.expectEqualStrings("/home/x/.cache/dirsized/sock", r.socket);
    }
    // Empty or relative XDG_CACHE_HOME is ignored.
    const s = try initFor(.linux, a, "/home/x", null, "");
    try testing.expectEqualStrings("/home/x/.cache/dirsized", s.cache_dir);
    const t = try initFor(.linux, a, "/home/x", null, "rel");
    try testing.expectEqualStrings("/home/x/.cache/dirsized", t.cache_dir);
}

test "trailing slash in home" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try initFor(.macos, arena.allocator(), "/Users/x/", null, null);
    try testing.expectEqualStrings("/Users/x/.cache/dirsized/sock", p.socket);
}

test "socketPath matches Paths.init on this platform" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = try Paths.init(arena.allocator(), "/h", "/rt", "/xc");
    const s = try socketPath(gpa, "/h", "/rt", "/xc");
    defer gpa.free(s);
    try testing.expectEqualStrings(p.socket, s);
}

test "SocketPathTooLong" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "/run/u/dirsized/sock" is 20 bytes; build a runtime dir that gives exactly the limit.
    const mk = struct {
        fn dir(al: Allocator, total: usize) ![]u8 {
            // total = len(dir) + len("/dirsized/sock") (14)
            const n = total - 14;
            const d = try al.alloc(u8, n);
            @memset(d, 'a');
            d[0] = '/';
            return d;
        }
    };
    // Linux: limit 108 bytes including NUL, so 107 fits and 108 does not.
    _ = try initFor(.linux, a, "/h", try mk.dir(a, 107), null);
    try testing.expectError(error.SocketPathTooLong, initFor(.linux, a, "/h", try mk.dir(a, 108), null));
    // macOS: 104, so 103 fits, 104 does not (home based).
    // "<home>/.cache/dirsized/sock" = len(home) + 21.
    const h103 = try a.alloc(u8, 103 - 21);
    @memset(h103, 'b');
    h103[0] = '/';
    _ = try initFor(.macos, a, h103, null, null);
    const h104 = try a.alloc(u8, 104 - 21);
    @memset(h104, 'b');
    h104[0] = '/';
    try testing.expectError(error.SocketPathTooLong, initFor(.macos, a, h104, null, null));
}

fn modeOf(dir: std.Io.Dir, sub: []const u8) !u32 {
    const st = try dir.statFile(testing.io, sub, .{});
    return @as(u32, @intCast(st.permissions.toMode())) & 0o777;
}

test "ensureDirs creates parents, is idempotent, fixes the mode" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pb);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const home = try a.dupe(u8, pb[0..n]);
    const p = try layoutFor(.macos, a, home, null, null);
    try ensureDirs(&p);
    try ensureDirs(&p); // EEXIST is success

    const sd = try a.dupeZ(u8, p.socket_dir);
    try testing.expectEqual(@as(u32, 0o700), try modeOf(tmp.dir, ".cache/dirsized"));

    // An existing socket folder with a loose mode is tightened.
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(sd, 0o755));
    try ensureDirs(&p);
    try testing.expectEqual(@as(u32, 0o700), try modeOf(tmp.dir, ".cache/dirsized"));
}

test "ensureDirs: Linux layout with a runtime dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pb);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = pb[0..n];
    const p = try layoutFor(.linux, a, root, root, null);
    try ensureDirs(&p);
    try testing.expectEqual(@as(u32, 0o700), try modeOf(tmp.dir, "dirsized"));
    try testing.expectEqual(@as(u32, 0o700), try modeOf(tmp.dir, ".cache/dirsized"));
}
