# Zig 0.16.0 notes for dirsized

Verified with `/opt/homebrew/bin/zig` 0.16.0 on macOS 27 arm64. `STD` = `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std` (`zig env`, `.std_dir`).
"Ran" = compiled and executed with `zig run -lc x.zig` or `zig test x.zig` (macOS links libSystem implicitly; `-lc` is harmless).
Anything not run is marked UNVERIFIED. The std source is the authority, not memory.

## 0. What moved (quick map)

| Old (<=0.14) | 0.16 |
|---|---|
| `std.io.*`, `std.fs.cwd()`, `std.fs.File/Dir` | `std.Io`: `std.Io.File`, `std.Io.Dir.cwd()`, `std.Io.Writer/Reader`; every file/dir/sleep/clock op takes an `io: std.Io` |
| `std.Thread.Mutex/Condition/Semaphore/ResetEvent/WaitGroup/Pool` | removed. `std.Io.Mutex`, `std.Io.Condition`, `std.Io.Semaphore`, `std.Io.Event` (take `io`). `std.Thread.spawn/join/getCpuCount` remain |
| `std.process.argsAlloc/getEnvVarOwned`, `std.posix.getenv`, `std.os.argv` | removed. `main(init: std.process.Init)` gives args + env |
| `std.time.milliTimestamp/Instant/Timer/sleep` | removed. `std.Io.Timestamp.now(io, .awake)`, `io.sleep(d, clock)` |
| `std.net`, `std.posix.socket/open/close/write/fstatat/getenv/realpath` | removed (`std.Io.net`; use `std.c.*` for raw calls). `std.posix.read/openat/errno/E/O/AT/S/Stat` remain |
| `std.GeneralPurposeAllocator` | `std.heap.DebugAllocator` |
| `std.fmt.format`, `usingnamespace`, `async`/`await` keywords | gone (`w.print(...)`, no replacement, `std.Io.async`) |
| `std.ArrayList` managed | `std.ArrayList(T)` is unmanaged. Old one: `std.array_list.Managed(T)` |
| `std.mem.tokenize` | `std.mem.tokenizeScalar/Sequence/Any`. `std.mem.indexOf` and `std.mem.find` both exist |

Probed with `@hasDecl` (ran).

## 1. main, allocator, args, env, exit code, leak checking

Source: `STD/start.zig` (`callMain`, `wrapMain`, `use_debug_allocator`), `STD/process.zig` (`Init`), `STD/process/Args.zig`, `STD/process/Environ.zig`.

Allowed `main` forms: `fn main() void|!void|u8|!u8|noreturn`, `fn main(init: std.process.Init.Minimal)`, `fn main(init: std.process.Init)`. An error returned from `main` prints `error: X` plus a trace and exits 1. A returned `u8` is the exit code.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;             // thread-safe; Debug: DebugAllocator with leak report at exit
    const arena = init.arena.allocator(); // freed at exit
    const io = init.io;               // std.Io.Threaded instance, needed for files/mutex/clock
    const argv = try init.minimal.args.toSlice(arena); // []const [:0]const u8, argv[0] INCLUDED
    var it = try init.minimal.args.iterateAllocator(gpa); // alternative; skip() drops argv[0]
    defer it.deinit();
    const home = init.environ_map.get("HOME") orelse "";   // ?[]const u8; map owned by Init
    _ = .{ argv, io, home };
    return 7;                         // exit code (u8). Early exit anywhere: std.process.exit(2)
}
```
Ran: args, HOME, exit code 7 (`echo $?`).

- Allocator in `init.gpa`: Debug = `DebugAllocator` (leaks printed as `error(DebugAllocator): memory address ... leaked`, exit code unchanged). ReleaseSafe/Fast with libc linked = `std.heap.c_allocator`, no leak check (ran: no report in `-OReleaseSafe`).
- Without `Init` (e.g. `pub fn main() u8`) you have no allocator and no `io`. Explicit leak-checked allocator:
```zig
var da: std.heap.DebugAllocator(.{}) = .init;
defer if (da.deinit() == .leak) std.process.exit(3);   // ran: exit 3 on leak
const gpa = da.allocator();
```
- Io without Init: `var t = std.Io.Threaded.init_single_threaded; const io = t.io();` (ran; single-threaded Io, no concurrency, fine for files/clock). Tests use `std.testing.io`.
- Env without a map: `std.process.Environ.getPosix(init.minimal.environ, "HOME")` returns `?[:0]const u8` (ran).
- `std.process.exit(code: u8) noreturn`, `std.process.fatal(fmt, args) noreturn` (prints, exit 1).

## 2. stdout/stderr, one buffered writer

Source: `STD/Io/File.zig` (`stdout()`, `stderr()`, `writer(file, io, buf)`), `STD/Io/Writer.zig` (`print`, `writeAll`, `writeByte`, `flush`).

```zig
var buf: [64 * 1024]u8 = undefined;
var fw = std.Io.File.stdout().writer(io, &buf);
const w = &fw.interface;                 // *std.Io.Writer: pass this around, not fw
try w.print("{d}\t{s}\t{x}\t{t}\n", .{ 42, "ok", 255, std.Io.File.Kind.directory }); // {t} = tag/error name
try w.writeAll("raw\x00bytes\n");        // bytes verbatim, NUL included
try w.writeByte(0);                      // -0 output terminator
try w.print("{s}\n", .{name});           // {s} on []const u8 writes raw bytes (no UTF-8 check, newline ok)
try w.flush();                           // exactly once at the end; not auto-flushed
```
Ran, verified with `xxd`: NUL bytes and `\n` inside names pass through unchanged.
- `std.debug.print(fmt, args)` writes unbuffered to stderr, needs no `io`. Fine for fatal messages and tests.
- Format specifiers: `{d}` ints, `{s}` bytes, `{x}` hex, `{t}` enum/error name, `{f}` calls a type's `format(self, w: *Io.Writer)`, `{any}` debug dump, `{?s}` optional string.
- Into memory: `var aw: std.Io.Writer.Allocating = .init(gpa); defer aw.deinit(); try aw.writer.print(...)`; `aw.written()`; fixed buffer: `std.Io.Writer.fixed(&buf)`. (decls exist: ran `@hasDecl`; usage UNVERIFIED.)
- `std.fmt.bufPrint(&buf, fmt, args) ![]u8`, `bufPrintZ`, `allocPrint(gpa, ...)` exist (ran bufPrintZ).

## 3. ArrayList, hash maps, arena

Source: `STD/array_list.zig`, `STD/hash_map.zig`, `STD/heap/arena_allocator.zig`.

```zig
var l: std.ArrayList(u8) = .empty;            // unmanaged: no allocator stored
defer l.deinit(gpa);
try l.append(gpa, 'a');
try l.appendSlice(gpa, "bc");
try l.print(gpa, "{d}", .{12});               // ArrayList(u8).print
try l.ensureTotalCapacity(gpa, 64);
l.appendAssumeCapacity('x');
const last: ?u8 = l.pop();                    // returns ?T now (null when empty)
l.clearRetainingCapacity();                   // keeps capacity
const bytes = l.items;                        // []u8 view
const owned = try l.toOwnedSlice(gpa);        // caller frees with gpa.free
```
Ran (`zig test`, `std.testing.allocator`). `std.ArrayListUnmanaged` is a deprecated alias of `std.ArrayList`. `std.array_list.Managed(T)` = old API with `.init(gpa)`, `append(x)` (ran).

```zig
var m: std.AutoHashMapUnmanaged(u32, u32) = .empty;
defer m.deinit(gpa);
try m.put(gpa, 1, 10);
const gop = try m.getOrPut(gpa, 2);
if (!gop.found_existing) gop.value_ptr.* = 0;
gop.value_ptr.* += 5;
_ = m.get(1);          // ?V
_ = m.remove(1);       // bool
_ = m.count();         // u32
var it = m.iterator(); while (it.next()) |e| _ = .{ e.key_ptr.*, e.value_ptr.* };
var sm: std.StringHashMapUnmanaged(u8) = .empty;   // keys are NOT copied
const h = std.hash.Wyhash.hash(0, bytes);          // u64
```
Ran. `std.AutoHashMap` (managed, stores allocator) still exists. Custom keys: `std.HashMapUnmanaged(K, V, Context, 80)` with `Context{ hash, eql }`; use `getOrPutAdapted` to look up by a different key type without allocating (UNVERIFIED, signature read in `hash_map.zig`).

```zig
var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();
const a = arena.allocator();
_ = arena.reset(.retain_capacity);
```
Ran.

## 4. Threads and sync

Source: `STD/Thread.zig` (spawn/join/getCpuCount), `STD/Io.zig` (`Mutex` ~l.1587, `Condition` ~l.1653, `Event`, futex), `STD/Io/Semaphore.zig`, `STD/atomic.zig`.

- `std.Thread.spawn(.{}, fn, .{args}) !Thread`, `t.join()`, `std.Thread.getCpuCount() !usize`, `std.Thread.yield()`: NO `Io` needed. Ran.
- `std.Thread.Mutex`, `Condition`, `Semaphore`, `ResetEvent`, `WaitGroup`, `Pool` are REMOVED (`@hasDecl` false).
- `std.Io.Mutex`, `std.Io.Condition` (`.init` consts) take an `Io` on every call. Use the `Uncancelable` variants; the plain ones return `error.Canceled` which only occurs if something cancels you.
- `std.atomic.Value(T)`: `.init(x)`, `.load(.acquire)`, `.store(v, .release)`, `.fetchAdd(1, .monotonic)`, `.cmpxchgStrong`. No `Io`. Ran.

Simplest correct choice for a blocking thread pool that does not use async I/O: plain `std.Thread` workers plus `std.Io.Mutex`/`std.Io.Condition`, with the process `io` (`init.io`, in tests `std.testing.io`) stored in the shared struct. The `Io` is only used as a futex provider there. Ran with 8 threads, 1000 jobs, in Debug and ReleaseSafe:

```zig
const Queue = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayList(u32) = .empty,
    done: bool = false,
    sum: std.atomic.Value(u64) = .init(0),

    fn worker(q: *Queue) void {
        while (true) {
            q.mutex.lockUncancelable(q.io);
            while (q.items.items.len == 0 and !q.done) q.cond.waitUncancelable(q.io, &q.mutex);
            const item = q.items.pop() orelse { q.mutex.unlock(q.io); return; };
            q.mutex.unlock(q.io);
            _ = q.sum.fetchAdd(item, .monotonic);
        }
    }
};
// producer: lock; append(gpa, x); unlock; q.cond.signal(q.io);
// shutdown: lock; q.done = true; unlock; q.cond.broadcast(q.io); for (ts) |t| t.join();
const n = @min(try std.Thread.getCpuCount(), 4);
for (ts) |*t| t.* = try std.Thread.spawn(.{}, Queue.worker, .{&q});
```
- A mutex+condvar pair pairs with ONE `Io` value; pass the same one everywhere. `Io.Threaded.global_single_threaded` is documented "does not support concurrency": do not use it as the futex for real threads.
- For a wake pipe or a poll loop use libc: `std.c.pipe`, `std.c.kevent`, `std.c.kqueue` exist (ran `@hasDecl`; calls UNVERIFIED).

## 5. Raw OS access (macOS hot paths)

Source: `STD/c.zig` (`pub const O/AT/S/Stat/E`, `pub extern "c" fn ...`, `private` block near the end), `STD/c/darwin.zig` (`E`), `STD/posix.zig`.

What std has (ran): `std.c.open(path: [*:0]const u8, flags: O, ...) c_int`, `openat`, `close`, `read`, `write`, `fstat`, `fstatat(dirfd, [*:0]path, *Stat, flags: u32)`, `fdopendir`, `readdir(*DIR) ?*dirent`, `closedir`, `realpath(noalias path, noalias out: [*]u8) ?[*:0]u8`, `sysconf`, `fcntl`, `getcwd`, `pipe`, `socket`, `kevent`, `kqueue`, `poll`, `fsync`, `rename`, `unlink`, `mkdir`.
`std.posix` keeps only `read`, `openat`/`openatZ`, `errno`, `E`, `O`, `AT`, `S`, `Stat`, `unexpectedErrno` (no `open`/`close`/`fstatat`/`getenv`/`socket`).

NOT in std (must be declared by hand): `getattrlistbulk`, `fsctl`, `ffsctl`, `setiopolicy_np`. Declare `extern "c"` in the file that uses them (all platform code lives in `scan_darwin.zig`/`watch_darwin.zig`):
```zig
extern "c" fn getattrlistbulk(dirfd: c_int, alist: *const AttrList, buf: [*]align(8) u8, size: usize, options: u64) c_int; // sys/unistd.h:188
extern "c" fn fsctl(path: [*:0]const u8, request: c_ulong, data: ?*anyopaque, options: c_uint) c_int;                       // unistd.h:785
extern "c" fn setiopolicy_np(iotype: c_int, scope: c_int, policy: c_int) c_int;                                               // UNVERIFIED (not compiled; check <sys/resource.h>)
```
`fsctl` linked and ran (bogus request returned -1, errno NOTTY). `std.c.realpath` ran: `/tmp` -> `/private/tmp`.

Flags and errno (ran):
- `std.c.O` on macOS is a packed struct of bools, NOT integer constants: `.{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }`. Same field names as POSIX, upper case.
- `std.c.AT.SYMLINK_NOFOLLOW` (0x20), `std.c.AT.FDCWD` (-2) are integer constants. `std.c.S.IFMT/IFDIR/IFREG/IFLNK` integer constants; `st.mode & std.c.S.IFMT == std.c.S.IFDIR`.
- errno: `std.c.errno(rc)` (also `std.posix.errno(rc)`) returns `std.c.E` when `rc == -1`, else `.SUCCESS`. Switch on `.NOENT, .ACCES, .PERM, .NOTDIR, .LOOP`. ENOTSUP is spelled `.OPNOTSUPP` (same number 45) on macOS: `.NOTSUP` does not exist. Print with `{t}`.
- Open a directory with O_DIRECTORY|O_NOFOLLOW on a symlink fails with `NOTDIR` (ran), not `LOOP`. Treat both as `NotDir`.
- `fdopendir(fd)` takes ownership of the fd; `closedir` closes it. Ran readdir + `fstatat(fd, name, &st, AT.SYMLINK_NOFOLLOW)` fallback: counted file bytes via `st.size`, dirs via `st.mode`.
- `dirent.name` is `[1024]u8`: `const name: [*:0]const u8 = @ptrCast(&ent.name);`.

### getattrlistbulk (ran; reads one folder; this is the required call)

Header facts (SDK `$(xcrun --show-sdk-path)/usr/include`, here `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`):
`sys/attr.h`: `struct attrlist` l.81-89 (24 bytes), `ATTR_BIT_MAP_COUNT 5` l.91, `attribute_set_t` l.93-99 (20 bytes), `attrreference_t` l.104-107, `FSOPT_NOFOLLOW` l.46, `FSOPT_PACK_INVAL_ATTRS` l.50 (the reader does not use it), `FSOPT_RETURN_REALDEV` l.54, `ATTR_CMN_NAME` l.409, `ATTR_CMN_DEVID` l.410, `ATTR_CMN_OBJTYPE` l.412, `ATTR_CMN_ERROR` l.449, `ATTR_CMN_RETURNED_ATTRS` l.456, `ATTR_DIR_MOUNTSTATUS` l.527, `DIR_MNTSTATUS_MNTPOINT` l.533, `ATTR_FILE_DATALENGTH` l.546. `sys/vnode.h`: `VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO` = 0..7, l.83-87. `sys/unistd.h:188`: prototype.
None of these constants is in `std.c` or `std.posix`: declare all by hand.

Record format, observed (hexdump, 3 entries) and matching `man getattrlistbulk`:
`u32 record_length` | `attribute_set_t returned` (20 bytes) | then ONLY the fields whose bit is set in `returned`, in this order: `ATTR_CMN_ERROR` (u32, comes first, right after the returned set), `ATTR_CMN_NAME` (`attrreference_t`: `i32 dataoffset` relative to the address of the reference itself, `u32 length` including the NUL), `ATTR_CMN_DEVID` (u32), `ATTR_CMN_OBJTYPE` (u32 vnode type), directory group (`ATTR_DIR_MOUNTSTATUS` u32), file group (`ATTR_FILE_DATALENGTH`, off_t 8 bytes, 4-byte aligned in the record: read unaligned). The name string bytes follow the fixed fields and the record is padded; always advance by `record_length`.
- Directory records have NO file-group field: always test `returned.file & ATTR_FILE_DATALENGTH` (a draft that read it unconditionally went out of bounds). The reader does not pass `FSOPT_PACK_INVAL_ATTRS`, so a record holds only the fields that its returned set announces.
- Symlinks (`VLNK`, type 5) report a `DATALENGTH` (the target length): skip by type, never add it.
- The buffer must be 4-byte aligned at least; use `align(8)`. Loop: call returns entry count, `0` at end, `-1` + errno on error (`OPNOTSUPP` -> fall back).
- DESIGN TRAP (ran): `ATTR_CMN_DEVID` does NOT detect mount points. For every entry in `/System/Volumes` it returned the PARENT folder's device (same value for the mount points `VM`, `Data`, `Hardware`), with or without `FSOPT_RETURN_REALDEV` (with it, a different but still constant value). Use `ATTR_DIR_MOUNTSTATUS` instead: bit `DIR_MNTSTATUS_MNTPOINT` (1) is set exactly for `/System/Volumes/{VM,Data,Hardware,Update,Preboot,xarts,iSCPreboot}` and `/dev`, clear for ordinary dirs (ran on `/` and `/System/Volumes`). Zero extra syscalls.

```zig
const std = @import("std");
const c = std.c;

const AttrList = extern struct { // sys/attr.h:81-89
    bitmapcount: u16 = 5, // ATTR_BIT_MAP_COUNT, attr.h:91
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};
const AttributeSet = extern struct { common: u32, vol: u32, dir: u32, file: u32, fork: u32 }; // attr.h:93-99
comptime {
    std.debug.assert(@sizeOf(AttrList) == 24 and @sizeOf(AttributeSet) == 20);
}
// sys/unistd.h:188; returns entry count, 0 at end, -1 + errno on error
extern "c" fn getattrlistbulk(dirfd: c_int, alist: *const AttrList, buf: [*]align(8) u8, size: usize, options: u64) c_int;

const FSOPT_NOFOLLOW = 0x1; // attr.h:46
const CMN_NAME = 0x1; // attr.h:409
const CMN_DEVID = 0x2; // :410
const CMN_OBJTYPE = 0x8; // :412
const CMN_ERROR = 0x20000000; // :449
const CMN_RETURNED_ATTRS = 0x80000000; // :456
const DIR_MOUNTSTATUS = 0x4; // :527 (flag MNTPOINT = 1, :533)
const FILE_DATALENGTH = 0x200; // :546
const VREG = 1; // sys/vnode.h:85 (VDIR=2, VLNK=5)
const VDIR = 2;

fn rd(comptime T: type, rec: []const u8, off: usize) T {
    return std.mem.readInt(T, rec[off..][0..@sizeOf(T)], .little);
}

/// Counts regular-file bytes and child dirs (not mount points) of one dir.
fn read(path: [*:0]const u8, dirs: *std.ArrayList(u8), gpa: std.mem.Allocator) !u64 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return switch (c.errno(fd)) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.NotFound,
        .NOTDIR, .LOOP => error.NotDir,
        else => error.Unexpected,
    };
    defer _ = c.close(fd);
    const al: AttrList = .{
        .commonattr = CMN_RETURNED_ATTRS | CMN_NAME | CMN_DEVID | CMN_OBJTYPE | CMN_ERROR,
        .dirattr = DIR_MOUNTSTATUS,
        .fileattr = FILE_DATALENGTH,
    };
    var buf: [64 * 1024]u8 align(8) = undefined;
    var own: u64 = 0;
    while (true) {
        const n = getattrlistbulk(fd, &al, &buf, buf.len, FSOPT_NOFOLLOW);
        if (n < 0) return switch (c.errno(n)) {
            .OPNOTSUPP => error.NotSupported, // caller falls back to readdir + fstatat
            .ACCES, .PERM => error.AccessDenied,
            else => error.Unexpected,
        };
        if (n == 0) return own;
        var off: usize = 0;
        for (0..@intCast(n)) |_| {
            const rec = buf[off..][0..rd(u32, &buf, off)];
            off += rec.len;
            var p: usize = 4; // skip the u32 record length
            const set: AttributeSet = .{ .common = rd(u32, rec, 4), .vol = rd(u32, rec, 8), .dir = rd(u32, rec, 12), .file = rd(u32, rec, 16), .fork = rd(u32, rec, 20) };
            p += 20;
            // Fields are packed in this order, each only if its bit is set in `set`.
            if (set.common & CMN_ERROR != 0) {
                const err = rd(u32, rec, p);
                p += 4;
                if (err != 0) continue; // the real reader (src/scan_darwin.zig) counts this in `entry_errors`, and the folder becomes `partial`
            }
            var name: []const u8 = "";
            if (set.common & CMN_NAME != 0) { // attrreference_t {i32 dataoffset, u32 length}
                const dataoffset = rd(i32, rec, p);
                const length = rd(u32, rec, p + 4);
                const start: usize = @intCast(@as(isize, @intCast(p)) + dataoffset); // relative to the reference itself
                name = rec[start..][0 .. length - 1]; // length counts the trailing NUL
                p += 8;
            }
            if (set.common & CMN_DEVID != 0) p += 4;
            const objtype = if (set.common & CMN_OBJTYPE != 0) rd(u32, rec, p) else 0;
            if (set.common & CMN_OBJTYPE != 0) p += 4;
            var mnt: u32 = 0;
            if (set.dir & DIR_MOUNTSTATUS != 0) { // directories only
                mnt = rd(u32, rec, p);
                p += 4;
            }
            if (objtype == VREG and set.file & FILE_DATALENGTH != 0) own += rd(u64, rec, p); // off_t, only 4-aligned: read unaligned
            if (objtype == VDIR and mnt & 1 == 0) {
                try dirs.appendSlice(gpa, name);
                try dirs.append(gpa, 0);
            }
        }
    }
}

test "read one folder" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "file5", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file3", .data = "123" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.symLink(io, "file5", "link", .{});
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pbuf);
    pbuf[n] = 0;
    var dirs: std.ArrayList(u8) = .empty;
    defer dirs.deinit(gpa);
    try std.testing.expectEqual(8, try read(pbuf[0..n :0], &dirs, gpa));
    try std.testing.expectEqualStrings("sub\x00", dirs.items);
    // A mount point is skipped: /System/Volumes/VM is one.
    dirs.clearRetainingCapacity();
    _ = try read("/System/Volumes", &dirs, gpa);
    try std.testing.expect(std.mem.indexOf(u8, dirs.items, "VM\x00") == null);
    try std.testing.expectError(error.NotFound, read("/nonexistent", &dirs, gpa));
}
```
Ran: `zig test gab.zig` (sum 8 for files of 5+3 bytes, symlink ignored, `sub` listed, mount point `VM` skipped, `/nonexistent` -> `NotFound`).

## 6. @cImport

`@cImport(@cInclude("unistd.h"))` still compiles and runs in 0.16.0 (ran, `zig build-exe -lc`). The supported route going forward is the build-system step `b.addTranslateC` (`STD/Build/Step/TranslateC.zig`). Whether `@cImport` is formally deprecated: UNVERIFIED (no warning seen).
Verified translate-c in a scratch build (`b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize, .link_libc = true })`, then `.imports = &.{.{ .name = "c", .module = t.createModule() }}` and `@import("c")`): `c.struct_attrlist` was 24 bytes, `c.ATTR_BIT_MAP_COUNT` and `c.ATTR_CMN_NAME` usable. It reads the SDK headers of the build host. Cross-target header resolution: UNVERIFIED.
Recommendation here: hand-written `extern` + `extern struct` (section 5). Only 3-4 functions and ~12 constants, no build dependency on SDK headers, works in cross builds. Use `comptime { assert(@sizeOf(...) == N) }` to guard the layouts.

## 7. Unit tests

Source: `STD/testing.zig`.
- `const testing = std.testing;` `testing.allocator` (DebugAllocator: leaks fail the test, "1 tests leaked memory", exit 1; ran). `testing.io` = `std.Io.Threaded` instance for Io calls.
- `try testing.expectEqual(expected, actual)`: expected FIRST. A literal expected coerces to the actual's type (`expectEqual(5, x_u32)` ran fine); for optionals use `@as(?u32, 3)` or `null` (ran). Also `expectEqualStrings(expected, actual)`, `expectEqualSlices(T, e, a)`, `expectError(error.X, expr)`, `expect(bool)`, `expectEqualDeep`.
- Temp dir (ran):
```zig
var tmp = testing.tmpDir(.{});          // creates .zig-cache/tmp/<random> relative to the test's cwd
defer tmp.cleanup();
const io = testing.io;
try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "12345" });
try tmp.dir.createDir(io, "d", .default_dir);
try tmp.dir.symLink(io, "f", "l", .{});              // (target, link_path)
var pb: [std.fs.max_path_bytes]u8 = undefined;
const n = try tmp.dir.realPath(io, &pb);             // usize; ABSOLUTE real path, no NUL
pb[n] = 0; const path: [:0]const u8 = pb[0..n :0];   // for C calls
```
  (`Dir.realPath(io, buf) !usize`, `Dir.realPathFileAlloc(io, sub, gpa) ![:0]u8`). `std.fs.max_path_bytes` still exists. The relative `.zig-cache/tmp` depends on cwd: `zig build test` runs tests with cwd = project root (ran: `tmpDir` works under `zig build test` and cleans up). `testing.tmpDir` is `comptime assert(builtin.is_test)`.
- Single file: `zig test src/ignore.zig` (pure modules). Anything calling `std.c.*` also works on macOS without `-lc` (libSystem implicit; ran); add `-lc` for Linux targets. Filter: `zig test x.zig --test-filter name`. A file reached only via `@import` inside a `test {}` block gets its tests run (`main.zig` does `_ = @import("cli.zig");`).
- `zig build test --summary all` shows counts. Failing/leaking tests give exit 1.

## 8. Build system (0.16)

Source: `lib/zig/init/build.zig` (template), `STD/Build.zig`, `STD/Build/Module.zig`.
`build.zig` as used in this repo (ran, all targets):
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});          // -Dtarget=
    const optimize = b.standardOptimizeOption(.{});       // -Doptimize=
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .macos) mod.linkFramework("CoreServices", .{});
    const exe = b.addExecutable(.{ .name = "dirsized", .root_module = mod });  // root_module form: target/optimize live on the module
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```
- `.root_source_file`, `.target`, `.optimize`, `.link_libc` are fields of `b.createModule(.{...})`; `addExecutable(.{ .name, .root_module })`. The old `b.addExecutable(.{ .root_source_file, .target })` form is gone.
- `mod.linkFramework("CoreServices", .{})` is guarded by the target OS, so the Linux binary has no framework (checked: `strings` finds no CoreServices; `file` says statically linked).
- `build.zig.zon` needs `.name = .dirsized` (enum literal), `.fingerprint = 0x...` (the compiler prints the right value if missing; it depends on the name: do not rename without regenerating), `.version`, `.minimum_zig_version`, `.dependencies = .{}`, `.paths`.
- Flags: `zig build [step] -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe` (`--release=safe` also exists), `--summary all`, `-p prefix`, `--verbose`, `-l` list steps, `zig build test -Dtarget=x86_64-linux-musl` cross-compiles the tests but cannot run them here.
- Linux musl + `link_libc = true` links zig's bundled musl statically; no extra flag is needed (`file`: "statically linked").
- Ran `zig build -Dtarget=...` on both Linux targets with `-Doptimize=ReleaseSafe`: green.

## 9. Other traps

- `usingnamespace` is a syntax error (ran). `async`/`await` are not keywords; the model is `std.Io.async(io, fn, args)` / `io.concurrent(...)`, `std.Io.Group`, `std.Io.Select`. Not needed here (UNVERIFIED usage).
- `packed struct` cannot contain arrays or pointers (compile error, ran). `packed struct(u3) { a: bool, b: bool, c: bool }` is fine and `@sizeOf` is 1; convert with `@bitCast` to `u3`, not `u8` (size mismatch error, ran). `extern struct` with `u64,u64,u32 x4` is exactly 32 bytes (ran with `comptime assert`).
- Sentinels: `[:0]const u8` coerces to `[]const u8`, not the reverse. Make one with `std.fmt.bufPrintZ(&buf, ...)`, `gpa.dupeZ(u8, s)`, or `buf[n] = 0; buf[0..n :0]`. `[*:0]const u8` for C calls; `std.mem.span(p)` converts back.
- `@fieldParentPtr` needs a known result type (`const p: *T = @fieldParentPtr("f", ptr);`). `@ptrCast`/`@alignCast` are result-typed: `@alignCast(@ptrCast(p))` into a typed var. `@intCast`, `@bitCast` likewise need a result type.
- File/Dir operations in std need `io` and return `Io.Cancelable`-extended error sets; for hot paths use `std.c` directly (no `io`).
- `std.process.Init` fields: `.minimal.args`, `.minimal.environ`, `.arena`, `.gpa`, `.io`, `.environ_map`, `.preopens`.
- Hash map and list APIs that allocate all take `gpa` as the first argument after `self` (`l.append(gpa, x)`, `m.put(gpa, k, v)`, `l.deinit(gpa)`). Forgetting `gpa` in `deinit` is a compile error.
- `std.testing.refAllDeclsRecursive` is gone; `std.testing.refAllDecls(@This())` remains. We use explicit `_ = @import(...)` in `main.zig`.
- `std.Io.Dir.cwd()` replaces `std.fs.cwd()`. `std.fs.max_path_bytes` still exists.
- Error sets: `error{...}` unions with `||` unchanged. `main` returning `!u8` is allowed. An inferred error set crossing threads: workers should return `void` and report via the queue.
- Tests that need `io`: use `testing.io`. Production code calling `Mutex.lock` must have an `Io` (see section 4).
