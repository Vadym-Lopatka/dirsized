//! Linux change watcher: one inotify fd, one watch per folder.
//!
//! The scanner's worker adds the watch before it opens a folder (`readOptions`, result in
//! `FolderRead.wd`). The owner binds `wd -> node` in `onApplied` (the scanner's `on_applied`
//! hook) and stores the wd in the table's aux array. `drain` turns events into `Change.node`.
//!
//! Owner-thread only. Ordering the daemon MUST keep:
//!   1. `scanner.pump(...)` (applies results, calls `onApplied`),
//!   2. `watcher.release(table)` right after EVERY pump, before anything else touches the table.
//!      A freed NodeId can be reused; `release` is what removes the map entries of freed nodes,
//!      so no entry ever points at a reused id. `drain` also expects `release` to be current.
//!   3. `watcher.drain(table, ctx)` when `pollFd()` is readable, and also once after each
//!      pump/release round (it is one non-blocking read when idle): `onApplied` can queue a
//!      re-read for a node whose watch was removed under it (see `WatchGone`).
//!   4. `watcher.quiet()` when the scanner is idle (optional; frees the `dead` bookkeeping).
//!
//! Moved folder A -> B keeps its inode, so its wd. B's read gets the same wd and rebinds it
//! (`bind`). If A's removal is applied first, `release` removes the kernel watch while B's
//! result (with that wd) is still in flight; the wd is then in `dead`, `bind` refuses it, and
//! B is re-read (which adds a fresh watch). If B's result is applied first, the map binds the
//! wd to B, and A's `Freed` entry is skipped because the map no longer binds it to A.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const watch = @import("watch.zig");
const scan = @import("scan.zig");
const table_mod = @import("table.zig");
const Table = table_mod.Table;
const NodeId = table_mod.NodeId;
const Change = watch.Change;
const StartResult = watch.StartResult;

const IN = linux.IN;
const none = table_mod.none;
const read_buf_size = 64 * 1024;
/// The largest event: header, a 255-byte name, and its NUL. A read that leaves less room than
/// this may have left events in the queue.
const max_event_size = @sizeOf(linux.inotify_event) + 256;
/// `dead` is bookkeeping for a rare race; if `quiet` is never called it must not grow forever.
const dead_cap = 1 << 16;
/// Same for `unbound`: past this a full re-read is cheaper than remembering.
const unbound_cap = 1 << 16;

pub const BindError = error{
    OutOfMemory,
    /// The kernel watch was removed by `release` after the read that returned this wd started.
    WatchGone,
};

pub const Watcher = struct {
    gpa: Allocator,
    fd: i32 = -1,
    map: std.AutoHashMapUnmanaged(i32, NodeId) = .empty,
    /// Watches that `release` removed; their IN_IGNORED is on its way. See `bind`.
    dead: std.AutoHashMapUnmanaged(i32, void) = .empty,
    /// Watches that had an event before they were bound: a worker added the watch and the
    /// folder changed before the owner applied the read. `bind` asks for a re-read of them.
    unbound: std.AutoHashMapUnmanaged(i32, void) = .empty,
    /// Nodes that must be reported by the next `drain` (bind hit a dead wd or an unbound event).
    redo: std.ArrayList(NodeId) = .empty,
    owe_everything: bool = false,
    /// The last `drain` filled its read buffer: the queue was long, and more may be waiting.
    saturated: bool = false,

    pub fn init(gpa: Allocator, _: std.c.fd_t) !Watcher {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        self.map.deinit(self.gpa);
        self.dead.deinit(self.gpa);
        self.unbound.deinit(self.gpa);
        self.redo.deinit(self.gpa);
        self.* = undefined;
    }

    /// Always `.fresh`. `roots` are watched by the scanner's first read, like every folder.
    pub fn start(self: *Watcher, roots: []const []const u8, saved: ?[]const u8) !StartResult {
        _ = .{ roots, saved };
        self.stop();
        const r = linux.inotify_init1(IN.NONBLOCK | IN.CLOEXEC);
        switch (linux.errno(r)) {
            .SUCCESS => self.fd = @intCast(r),
            .MFILE, .NFILE => return error.SystemResources,
            .NOMEM => return error.OutOfMemory,
            else => return error.Unexpected,
        }
        return .fresh;
    }

    /// Closes the fd (the kernel drops every watch) and clears the map. The caller's table
    /// still holds the old wds in aux: `start` is for a fresh table.
    pub fn stop(self: *Watcher) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1;
        self.map.clearRetainingCapacity();
        self.dead.clearRetainingCapacity();
        self.unbound.clearRetainingCapacity();
        self.redo.clearRetainingCapacity();
        self.owe_everything = false;
    }

    pub fn pollFd(self: *const Watcher) std.c.fd_t {
        return self.fd;
    }

    pub fn caughtUp(self: *const Watcher) bool {
        _ = self;
        return true;
    }

    pub fn checkpoint(self: *Watcher) void {
        _ = self;
    }

    pub fn saveState(self: *const Watcher, out: *std.ArrayList(u8), gpa: Allocator) !void {
        _ = .{ self, out, gpa };
    }

    // ---- Linux-only: scanner side --------------------------------------------------------

    /// For `Scanner.read_opts`.
    pub fn readOptions(self: *const Watcher) scan.ReadOptions {
        return .{ .inotify_fd = self.fd };
    }

    /// Binds `wd` to `id`. A wd bound to another id is rebound (a moved folder keeps its wd).
    /// An event that arrived for the wd before this call was dropped, so the folder is read again.
    pub fn bind(self: *Watcher, wd: i32, id: NodeId) BindError!void {
        if (self.dead.contains(wd)) return error.WatchGone;
        if (self.unbound.remove(wd)) try self.redo.append(self.gpa, id);
        try self.map.put(self.gpa, wd, id);
    }

    /// Body of the scanner's `on_applied` hook.
    pub fn onApplied(self: *Watcher, table: *Table, id: NodeId, read: *const scan.FolderRead) void {
        if (read.watch_failed) return self.watchFailed(table, id, -1);
        if (read.wd < 0) return;
        const wd = read.wd;
        const old = table.getAux(id);
        self.bind(wd, id) catch |err| switch (err) {
            error.OutOfMemory => return self.watchFailed(table, id, wd),
            error.WatchGone => {
                self.dropOld(id, old, wd);
                if (table.aux_on) table.setAux(id, none);
                // On OOM the redo is lost; ask for a full re-read instead.
                self.redo.append(self.gpa, id) catch {
                    self.owe_everything = true;
                };
                return;
            },
        };
        self.dropOld(id, old, wd);
        if (table.aux_on) table.setAux(id, @intCast(wd));
    }

    fn watchFailed(self: *Watcher, table: *Table, id: NodeId, wd: i32) void {
        if (wd >= 0 and self.fd >= 0) _ = linux.inotify_rm_watch(self.fd, wd); // not bound: would leak
        _ = table.applyDenied(id) catch false;
    }

    /// The node had another wd before: it is stale. Drop it unless it is bound elsewhere.
    fn dropOld(self: *Watcher, id: NodeId, old: u32, new: i32) void {
        if (old == none or old == new) return;
        const o: i32 = @intCast(old);
        if (self.map.get(o)) |b| if (b == id) self.unwatch(o);
    }

    /// Removes the map entry and the kernel watch.
    fn unwatch(self: *Watcher, wd: i32) void {
        _ = self.map.remove(wd);
        if (self.fd < 0) return;
        if (linux.errno(linux.inotify_rm_watch(self.fd, wd)) == .SUCCESS) {
            if (self.dead.count() >= dead_cap) self.dead.clearRetainingCapacity();
            self.dead.put(self.gpa, wd, {}) catch {};
        }
    }

    /// Drains `table.freed`. Call right after every scanner pump (see the file header).
    pub fn release(self: *Watcher, table: *Table) void {
        for (table.freed.items) |f| {
            const wd: i32 = @intCast(f.aux);
            if (self.map.get(wd)) |bound| {
                if (bound == f.id) self.unwatch(wd);
            }
        }
        table.freed.clearRetainingCapacity();
    }

    /// No scanner result is in flight: no stale or unbound wd can arrive any more.
    pub fn quiet(self: *Watcher) void {
        self.dead.clearRetainingCapacity();
        self.unbound.clearRetainingCapacity();
    }

    // ---- counters ------------------------------------------------------------------------

    pub fn watchCount(self: *const Watcher) usize {
        return self.map.count();
    }

    pub fn watchLimit() ?usize {
        const r = linux.openat(linux.AT.FDCWD, "/proc/sys/fs/inotify/max_user_watches", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(r) != .SUCCESS) return null;
        const fd: i32 = @intCast(r);
        defer _ = linux.close(fd);
        var buf: [32]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return null;
        return std.fmt.parseInt(usize, std.mem.trim(u8, buf[0..n], " \n\r\t"), 10) catch null;
    }

    // ---- events --------------------------------------------------------------------------

    /// Reads all queued events and calls `try ctx.onChange(Change)`. Linux-only signature: it
    /// needs the table (to clear aux on IN_IGNORED and to skip freed nodes). If `onChange`
    /// fails, the rest is still decoded (bookkeeping), the first error is returned, and the next
    /// call reports `.everything` first.
    pub fn drain(self: *Watcher, table: *Table, ctx: anytype) !void {
        var sink: Sink(@TypeOf(ctx)) = .{ .ctx = ctx };
        if (self.owe_everything) {
            self.owe_everything = false;
            sink.emit(.everything);
        }
        for (self.redo.items) |id| {
            if (table.parentOf(id) != table_mod.free_mark) sink.emit(.{ .node = id });
        }
        self.redo.clearRetainingCapacity();
        self.saturated = false;
        if (self.fd >= 0) {
            var buf: [read_buf_size]u8 align(@alignOf(linux.inotify_event)) = undefined;
            var last_wd: i32 = -1;
            while (true) {
                const n = linux.read(self.fd, &buf, buf.len);
                switch (linux.errno(n)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    .AGAIN => break,
                    else => {
                        sink.err = sink.err orelse error.ReadFailed;
                        break;
                    },
                }
                if (n == 0) break;
                if (buf.len - n < max_event_size) self.saturated = true;
                self.decode(table, buf[0..n], &sink, &last_wd);
            }
        }
        if (sink.err) |e| {
            self.owe_everything = true;
            return e;
        }
    }

    /// Remembers a wd that has no node yet. When the set is full, or cannot grow, a full re-read
    /// is owed instead.
    fn noteUnbound(self: *Watcher, wd: i32) void {
        if (self.unbound.count() >= unbound_cap) {
            self.unbound.clearRetainingCapacity();
            self.owe_everything = true;
        }
        self.unbound.put(self.gpa, wd, {}) catch {
            self.owe_everything = true;
        };
    }

    /// Decodes a buffer of `inotify_event` records.
    fn decode(self: *Watcher, table: *Table, bytes: []const u8, sink: anytype, last_wd: *i32) void {
        const hdr = @sizeOf(linux.inotify_event);
        var off: usize = 0;
        while (off + hdr <= bytes.len) {
            const wd = std.mem.readInt(i32, bytes[off..][0..4], .little);
            const mask = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
            const len = std.mem.readInt(u32, bytes[off + 12 ..][0..4], .little);
            off += hdr + len;

            if (mask & IN.Q_OVERFLOW != 0) {
                sink.emit(.everything);
                last_wd.* = -1;
                continue;
            }
            if (mask & IN.IGNORED != 0) {
                last_wd.* = -1;
                // The kernel dropped the watch. Unbind; the read adds it again if the folder lives.
                if (self.map.fetchRemove(wd)) |kv| {
                    if (table.aux_on and table.getAux(kv.value) == @as(u32, @intCast(wd))) table.setAux(kv.value, none);
                    sink.emit(.{ .node = kv.value });
                }
                continue;
            }
            const id = self.map.get(wd) orelse {
                self.noteUnbound(wd);
                continue;
            };
            if (wd == last_wd.*) continue; // coalesce a run of events of one folder
            last_wd.* = wd;
            sink.emit(.{ .node = id });
        }
    }
};

fn Sink(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        err: ?anyerror = null,

        fn emit(self: *@This(), c: Change) void {
            if (self.err != null) return;
            self.ctx.onChange(c) catch |e| {
                self.err = e;
            };
        }
    };
}

// ---- tests -----------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;
const tio = testing.io;
const Scanner = @import("scanner.zig").Scanner;
const Rules = @import("ignore.zig").Rules;

fn ok(r: usize) !void {
    try testing.expectEqual(.SUCCESS, linux.errno(r));
}

fn nowNs() i96 {
    return std.Io.Clock.Timestamp.now(tio, .awake).raw.nanoseconds;
}

const Pipe = struct {
    rd: i32,
    wr: i32,

    fn init() !Pipe {
        var fds: [2]i32 = undefined;
        try ok(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
        return .{ .rd = fds[0], .wr = fds[1] };
    }

    fn deinit(p: Pipe) void {
        _ = linux.close(p.rd);
        _ = linux.close(p.wr);
    }

    fn waitAndDrain(p: Pipe) !void {
        var pfd = [1]linux.pollfd{.{ .fd = p.rd, .events = linux.POLL.IN, .revents = 0 }};
        if (linux.poll(&pfd, 1, 10_000) == 0) return error.WakeTimeout;
        var buf: [256]u8 = undefined;
        while (linux.errno(linux.read(p.rd, &buf, buf.len)) == .SUCCESS) {}
    }
};

/// Everything the daemon does on Linux, in test form.
const Rig = struct {
    t: Table,
    sc: Scanner,
    w: Watcher,
    pipe: Pipe,
    rules: Rules,
    changes: std.ArrayList(Change) = .empty,
    auto: bool = true, // onChange: markRecheck + enqueue

    fn init(self: *Rig, threads: u32) !void {
        self.pipe = try Pipe.init();
        errdefer self.pipe.deinit();
        var bad: ?u32 = null;
        self.rules = try Rules.compile(ta, &.{}, &bad);
        errdefer self.rules.deinit(ta);
        self.t = Table.init(ta);
        errdefer self.t.deinit();
        try self.t.enableAux();
        self.w = try Watcher.init(ta, self.pipe.wr);
        errdefer self.w.deinit();
        _ = try self.w.start(&.{}, null);
        self.sc = try Scanner.init(ta, tio, threads);
        errdefer self.sc.deinit();
        self.sc.setWakeFd(self.pipe.wr);
        self.sc.read_opts = self.w.readOptions();
        self.sc.on_applied = .{ .ctx = self, .func = onApplied };
        self.changes = .empty;
        self.auto = true;
    }

    fn deinit(self: *Rig) void {
        self.changes.deinit(ta);
        self.sc.deinit();
        self.w.deinit();
        self.t.deinit();
        self.rules.deinit(ta);
        self.pipe.deinit();
    }

    fn onApplied(ctx: *anyopaque, table: *Table, id: NodeId, read: *const scan.FolderRead, _: bool) void {
        const self: *Rig = @ptrCast(@alignCast(ctx));
        self.w.onApplied(table, id, read);
    }

    pub fn onChange(self: *Rig, c: Change) !void {
        try self.changes.append(ta, c);
        if (!self.auto) return;
        switch (c) {
            .node => |id| if (self.t.markRecheck(id)) try self.sc.enqueue(id),
            .everything => {
                for (self.t.roots()) |r| if (self.t.markRecheck(r.node)) try self.sc.enqueue(r.node);
            },
            .path => unreachable,
        }
    }

    fn pump(self: *Rig) !void {
        try self.sc.pump(&self.t, &self.rules);
        self.w.release(&self.t);
    }

    fn pumpUntilIdle(self: *Rig) !void {
        try self.pump();
        while (!self.sc.isIdle()) {
            try self.pipe.waitAndDrain();
            try self.pump();
        }
    }

    fn drain(self: *Rig) !void {
        try self.w.drain(&self.t, self);
    }

    /// Drain + pump until a drain yields nothing and the scanner is idle.
    fn settle(self: *Rig) !void {
        var rounds: usize = 0;
        while (rounds < 100) : (rounds += 1) {
            const before = self.changes.items.len;
            try self.drain();
            try self.pumpUntilIdle();
            if (self.changes.items.len == before and self.sc.isIdle()) {
                self.w.quiet();
                return;
            }
        }
        return error.DidNotSettle;
    }

    fn scanRoot(self: *Rig, path: []const u8) !NodeId {
        const root = try self.t.addRoot(path);
        try self.sc.enqueue(root);
        try self.pumpUntilIdle();
        return root;
    }

    fn sawNode(self: *const Rig, id: NodeId) bool {
        for (self.changes.items) |c| switch (c) {
            .node => |n| if (n == id) return true,
            else => {},
        };
        return false;
    }
};

const Tmp = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init(self: *Tmp) !void {
        self.tmp = testing.tmpDir(.{ .iterate = true });
        self.len = try self.tmp.dir.realPath(tio, &self.buf);
        try self.tmp.dir.createDirPath(tio, "root");
        try self.tmp.dir.createDirPath(tio, "out");
    }

    fn deinit(self: *Tmp) void {
        self.tmp.cleanup();
    }

    fn base(self: *const Tmp) []const u8 {
        return self.buf[0..self.len];
    }

    fn abs(self: *const Tmp, out: []u8, rel: []const u8) []const u8 {
        return std.fmt.bufPrint(out, "{s}/{s}", .{ self.base(), rel }) catch unreachable;
    }

    fn dir(self: *Tmp, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(tio, rel);
    }

    fn file(self: *Tmp, rel: []const u8, size: usize) !void {
        const data = try ta.alloc(u8, size);
        defer ta.free(data);
        @memset(data, 'x');
        try self.tmp.dir.writeFile(tio, .{ .sub_path = rel, .data = data });
    }

    fn append(self: *Tmp, rel: []const u8, size: usize) !void {
        var pa: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&pa, "{s}/{s}", .{ self.base(), rel });
        const r = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, 0);
        try ok(r);
        const fd: i32 = @intCast(r);
        defer _ = linux.close(fd);
        const data = try ta.alloc(u8, size);
        defer ta.free(data);
        @memset(data, 'y');
        try ok(linux.write(fd, data.ptr, data.len));
    }

    fn truncate(self: *Tmp, rel: []const u8, size: i64) !void {
        var pa: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&pa, "{s}/{s}", .{ self.base(), rel });
        const r = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        try ok(r);
        const fd: i32 = @intCast(r);
        defer _ = linux.close(fd);
        try ok(linux.ftruncate(fd, size));
    }

    fn rm(self: *Tmp, rel: []const u8) !void {
        try self.tmp.dir.deleteFile(tio, rel);
    }

    fn rmTree(self: *Tmp, rel: []const u8) !void {
        try self.tmp.dir.deleteTree(tio, rel);
    }

    fn mv(self: *Tmp, from: []const u8, to: []const u8) !void {
        var a: [std.fs.max_path_bytes]u8 = undefined;
        var b: [std.fs.max_path_bytes]u8 = undefined;
        try std.Io.Dir.renameAbsolute(self.abs(&a, from), self.abs(&b, to), tio);
    }
};

const RefTotals = struct { total: u64 = 0, folders: usize = 0 };

/// Independent answer with std's directory iterator.
fn refWalk(path: []const u8) !RefTotals {
    var dir = try std.Io.Dir.openDirAbsolute(tio, path, .{ .iterate = true });
    defer dir.close(tio);
    var r: RefTotals = .{ .folders = 1 };
    var it = dir.iterate();
    while (try it.next(tio)) |e| {
        const st = dir.statFile(tio, e.name, .{ .follow_symlinks = false }) catch continue;
        switch (st.kind) {
            .file => r.total += st.size,
            .directory => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const sub = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, e.name });
                const c = try refWalk(sub);
                r.total += c.total;
                r.folders += c.folders;
            },
            else => {},
        }
    }
    return r;
}

/// Every table folder matches the disk and is bound.
fn checkNode(rig: *Rig, id: NodeId, path: []const u8, live: *usize) !void {
    const ref = try refWalk(path);
    try testing.expectEqual(ref.total, rig.t.total(id));
    try testing.expectEqual(table_mod.State.ok, rig.t.state(id));
    const wd = rig.t.getAux(id);
    try testing.expect(wd != none);
    try testing.expectEqual(id, rig.w.map.get(@intCast(wd)).?);
    live.* += 1;
    var it = rig.t.children(id);
    while (it.next()) |c| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, rig.t.name(c) });
        try checkNode(rig, c, sub, live);
    }
}

fn expectConsistent(rig: *Rig, root: NodeId, path: []const u8) !void {
    var live: usize = 0;
    try checkNode(rig, root, path, &live);
    try testing.expectEqual((try refWalk(path)).folders, live);
    try testing.expectEqual(live, rig.w.watchCount());
    var it = rig.w.map.iterator();
    while (it.next()) |e| {
        try testing.expect(rig.t.parentOf(e.value_ptr.*) != table_mod.free_mark);
        try testing.expectEqual(@as(u32, @intCast(e.key_ptr.*)), rig.t.getAux(e.value_ptr.*));
    }
}

test "scan binds every folder" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    try tmp.dir("root/a/b");
    try tmp.dir("root/c");
    try tmp.file("root/a/f", 10);
    var rig: Rig = undefined;
    try rig.init(3);
    defer rig.deinit();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const rp = tmp.abs(&pb, "root");
    const root = try rig.scanRoot(rp);
    try testing.expectEqual(@as(usize, 4), rig.w.watchCount());
    try expectConsistent(&rig, root, rp);
    try testing.expect(Watcher.watchLimit().? > 0);
}

test "a new file reports its folder; the reread matches" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    try tmp.dir("root/a/b");
    var rig: Rig = undefined;
    try rig.init(2);
    defer rig.deinit();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const rp = tmp.abs(&pb, "root");
    const root = try rig.scanRoot(rp);
    const b = rig.t.child(rig.t.child(root, "a").?, "b").?;
    rig.auto = false;
    try tmp.file("root/a/b/new", 123);
    try rig.drain();
    try testing.expectEqual(@as(usize, 1), rig.changes.items.len);
    try testing.expectEqual(Change{ .node = b }, rig.changes.items[0]);
    _ = rig.t.markRecheck(b);
    try rig.sc.enqueue(b);
    try rig.pumpUntilIdle();
    try testing.expectEqual(@as(u64, 123), rig.t.total(root));
    try expectConsistent(&rig, root, rp);
}

test "file and folder churn keeps totals, watches and map right" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    try tmp.dir("root/a/b");
    try tmp.dir("root/c/d");
    try tmp.dir("root/e");
    try tmp.file("root/a/f", 100);
    try tmp.file("root/c/g", 50);
    var rig: Rig = undefined;
    try rig.init(3);
    defer rig.deinit();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const rp = tmp.abs(&pb, "root");
    const root = try rig.scanRoot(rp);
    try expectConsistent(&rig, root, rp);

    const Op = enum { append, truncate, rm, mkdirs, rmtree, mv };
    const steps = [_]struct { op: Op, a: []const u8, b: []const u8 = "" }{
        .{ .op = .append, .a = "root/a/f" },
        .{ .op = .truncate, .a = "root/a/f" },
        .{ .op = .rm, .a = "root/c/g" },
        .{ .op = .mkdirs, .a = "root/e/x/y/z/w" },
        .{ .op = .rmtree, .a = "root/e/x/y" },
        .{ .op = .mv, .a = "root/a/b", .b = "root/a/b2" }, // same parent
        .{ .op = .mv, .a = "root/a/b2", .b = "root/e/b3" }, // other parent
        .{ .op = .mv, .a = "root/c/d", .b = "out/d" }, // out of the tree
        .{ .op = .mv, .a = "out/d", .b = "root/c/d" }, // and back
        .{ .op = .rmtree, .a = "root/a" },
    };
    for (steps) |s| {
        switch (s.op) {
            .append => try tmp.append(s.a, 4000),
            .truncate => try tmp.truncate(s.a, 7),
            .rm => try tmp.rm(s.a),
            .mkdirs => {
                try tmp.dir(s.a);
                try tmp.file("root/e/x/y/z/w/f", 77);
            },
            .rmtree => try tmp.rmTree(s.a),
            .mv => try tmp.mv(s.a, s.b),
        }
        try rig.settle();
        try expectConsistent(&rig, root, rp);
    }
}

test "folder move A -> B: B's read applied first or last, the watch survives" {
    inline for (.{ true, false }) |b_first| {
        var tmp: Tmp = undefined;
        try tmp.init();
        defer tmp.deinit();
        try tmp.dir("root/p/a/deep");
        try tmp.dir("root/q");
        try tmp.file("root/p/a/deep/f", 11);
        var rig: Rig = undefined;
        try rig.init(1);
        defer rig.deinit();
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const rp = tmp.abs(&pb, "root");
        const root = try rig.scanRoot(rp);
        const p = rig.t.child(root, "p").?;
        const q = rig.t.child(root, "q").?;
        try tmp.mv("root/p/a", "root/q/b");
        rig.auto = false;
        try rig.drain();
        // The events of both parents are in. Apply them in a chosen order.
        try testing.expect(rig.sawNode(p) and rig.sawNode(q));
        const order = if (b_first) [2]NodeId{ q, p } else [2]NodeId{ p, q };
        for (order) |id| {
            _ = rig.t.markRecheck(id);
            try rig.sc.enqueue(id);
            try rig.pumpUntilIdle();
        }
        rig.auto = true;
        try rig.settle();
        try expectConsistent(&rig, root, rp);
        try testing.expectEqual(@as(u64, 11), rig.t.total(q));
        // The moved folder still reports changes.
        try tmp.file("root/q/b/deep/g", 5);
        try rig.settle();
        try testing.expectEqual(@as(u64, 16), rig.t.total(root));
        try expectConsistent(&rig, root, rp);
    }
}

test "release keeps a wd that now belongs to another node (unit)" {
    var rig: Rig = undefined;
    try rig.init(1);
    defer rig.deinit();
    const a = try rig.t.addRoot("/x/a");
    const b = try rig.t.addRoot("/x/b");
    // A holds wd 7, B takes it over, then A is freed.
    try rig.w.bind(7, a);
    rig.t.setAux(a, 7);
    try rig.w.bind(7, b);
    rig.t.setAux(b, 7);
    try rig.t.freed.append(ta, .{ .id = a, .aux = 7 });
    rig.w.release(&rig.t);
    try testing.expectEqual(b, rig.w.map.get(7).?);
    try testing.expectEqual(@as(usize, 0), rig.t.freed.items.len);
    // The reverse: the freed entry of the current owner removes the binding.
    try rig.t.freed.append(ta, .{ .id = b, .aux = 7 });
    rig.w.release(&rig.t);
    try testing.expectEqual(@as(?NodeId, null), rig.w.map.get(7));
    // And a dead wd is refused by bind.
    try rig.w.bind(8, a);
    rig.w.unwatch(8);
    try rig.w.dead.put(ta, 8, {});
    try testing.expectError(error.WatchGone, rig.w.bind(8, b));
}

test "onApplied with a dead wd: no binding, the node is reported by the next drain" {
    var rig: Rig = undefined;
    try rig.init(1);
    defer rig.deinit();
    rig.auto = false;
    const a = try rig.t.addRoot("/x/a");
    try rig.w.dead.put(ta, 5, {});
    const read: scan.FolderRead = .{ .wd = 5 };
    rig.w.onApplied(&rig.t, a, &read);
    try testing.expectEqual(@as(usize, 0), rig.w.watchCount());
    try testing.expectEqual(none, rig.t.getAux(a));
    try rig.drain();
    try testing.expectEqual(@as(usize, 1), rig.changes.items.len);
    try testing.expectEqual(Change{ .node = a }, rig.changes.items[0]);
}

test "a folder that is read but denied is still bound, and follows chmod" {
    if (linux.getuid() == 0) return error.SkipZigTest; // root can inspect everything
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    try tmp.dir("root/d/sub");
    var rig: Rig = undefined;
    try rig.init(1);
    defer rig.deinit();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const rp = tmp.abs(&pb, "root");
    var da: [std.fs.max_path_bytes:0]u8 = undefined;
    const dp = try std.fmt.bufPrintZ(&da, "{s}/d", .{rp});
    try ok(linux.chmod(dp, 0o400)); // getdents works, statx of the entries does not
    defer _ = linux.chmod(dp, 0o755);
    const root = try rig.scanRoot(rp);
    const d = rig.t.child(root, "d").?;
    try testing.expectEqual(table_mod.State.partial, rig.t.state(d));
    try testing.expect(rig.t.getAux(d) != none);
    try testing.expectEqual(d, rig.w.map.get(@intCast(rig.t.getAux(d))).?);

    try ok(linux.chmod(dp, 0o755)); // the event of the folder's own watch brings the re-read
    try rig.settle();
    try testing.expectEqual(table_mod.State.ok, rig.t.state(root));
    try expectConsistent(&rig, root, rp);
}

test "a failed watch makes the folder partial" {
    var rig: Rig = undefined;
    try rig.init(1);
    defer rig.deinit();
    const r = try rig.t.addRoot("/x/a");
    try testing.expectEqual(table_mod.State.scanning, rig.t.state(r));
    const read: scan.FolderRead = .{ .watch_failed = true };
    rig.w.onApplied(&rig.t, r, &read);
    try testing.expectEqual(table_mod.State.partial, rig.t.state(r));
    try testing.expectEqual(@as(usize, 0), rig.w.watchCount());
}

const Collect = struct {
    list: std.ArrayList(Change) = .empty,
    pub fn onChange(self: *Collect, c: Change) !void {
        try self.list.append(ta, c);
    }
};

fn putEvent(out: *std.ArrayList(u8), wd: i32, mask: u32, name: []const u8) !void {
    const padded = std.mem.alignForward(usize, name.len, 4);
    var h: [16]u8 = undefined;
    std.mem.writeInt(i32, h[0..4], wd, .little);
    std.mem.writeInt(u32, h[4..8], mask, .little);
    std.mem.writeInt(u32, h[8..12], 0, .little);
    std.mem.writeInt(u32, h[12..16], @intCast(padded), .little);
    try out.appendSlice(ta, &h);
    try out.appendSlice(ta, name);
    try out.appendNTimes(ta, 0, padded - name.len);
}

test "decoder: overflow, ignored, unknown wd, coalescing" {
    var rig: Rig = undefined;
    try rig.init(1);
    defer rig.deinit();
    const a = try rig.t.addRoot("/x/a");
    const b = try rig.t.addRoot("/x/b");
    try rig.w.bind(1, a);
    rig.t.setAux(a, 1);
    try rig.w.bind(2, b);
    rig.t.setAux(b, 2);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(ta);
    try putEvent(&bytes, 1, IN.MODIFY, "f");
    try putEvent(&bytes, 1, IN.MODIFY, "f");
    try putEvent(&bytes, 1, IN.CLOSE_WRITE, "f");
    try putEvent(&bytes, 99, IN.CREATE, "zz"); // not bound yet: remembered
    try putEvent(&bytes, 2, IN.CREATE, "name");
    try putEvent(&bytes, -1, IN.Q_OVERFLOW, "");
    try putEvent(&bytes, 2, IN.DELETE_SELF, "");
    try putEvent(&bytes, 2, IN.IGNORED, "");
    try putEvent(&bytes, 2, IN.CREATE, "late"); // unbound now

    var col: Collect = .{};
    defer col.list.deinit(ta);
    var sink: Sink(*Collect) = .{ .ctx = &col };
    var last: i32 = -1;
    rig.w.decode(&rig.t, bytes.items, &sink, &last);
    const want = [_]Change{ .{ .node = a }, .{ .node = b }, .everything, .{ .node = b }, .{ .node = b } };
    try testing.expectEqual(want.len, col.list.items.len);
    for (want, col.list.items) |w, g| try testing.expectEqual(w, g);
    // IN_IGNORED unbound wd 2 and cleared the aux.
    try testing.expectEqual(@as(?NodeId, null), rig.w.map.get(2));
    try testing.expectEqual(none, rig.t.getAux(b));
    try testing.expectEqual(a, rig.w.map.get(1).?);
    try testing.expect(rig.w.unbound.contains(99));
    // The first bind owes one re-read; a later bind of the same wd (the next read) owes none.
    const owed = rig.w.redo.items.len;
    try rig.w.bind(99, a);
    try testing.expectEqual(owed + 1, rig.w.redo.items.len);
    try rig.w.bind(99, a);
    try testing.expectEqual(owed + 1, rig.w.redo.items.len);
}

test "an event between the worker's add_watch and the owner's bind is not lost" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    try tmp.dir("root/a");
    var rig: Rig = undefined;
    try rig.init(1);
    defer rig.deinit();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const rp = tmp.abs(&pb, "root");
    const root = try rig.scanRoot(rp);

    try tmp.dir("root/n");
    rig.auto = false;
    try rig.drain(); // the root's CREATE event
    _ = rig.t.markRecheck(root);
    try rig.sc.enqueue(root);
    try rig.pump(); // dispatch the root
    try rig.pipe.waitAndDrain();
    try rig.pump(); // apply the root: n is pending and dispatched
    try rig.pipe.waitAndDrain(); // the worker has read n (watch added, result posted, not applied)
    try tmp.file("root/n/f", 500); // a change after the watch was added
    rig.auto = true;
    try rig.drain(); // the owner reads the inotify fd before it applies n's result
    try rig.settle();
    try rig.settle();
    try testing.expectEqual((try refWalk(rp)).total, rig.t.total(root));
}

test "a folder deleted behind our back: IGNORED rereads it and the node goes" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    try tmp.dir("root/a");
    try tmp.dir("root/b");
    var rig: Rig = undefined;
    try rig.init(2);
    defer rig.deinit();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const rp = tmp.abs(&pb, "root");
    const root = try rig.scanRoot(rp);
    try tmp.rmTree("root/a");
    try rig.settle();
    try expectConsistent(&rig, root, rp);
    try testing.expectEqual(@as(usize, 2), rig.w.watchCount());
}

test "a drain that fills the read buffer says so" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    var rig: Rig = undefined;
    try rig.init(1);
    defer rig.deinit();
    // A plain file stands in for the inotify fd: `drain` only reads it. Each event is 32 bytes.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(ta);
    for (0..read_buf_size / 32 + 10) |_| try putEvent(&bytes, 99, IN.CREATE, "0123456789abcdef");
    try tmp.tmp.dir.writeFile(tio, .{ .sub_path = "events", .data = bytes.items });
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pb, "{s}/events", .{tmp.base()});
    const fd = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(fd));
    _ = linux.close(rig.w.fd);
    rig.w.fd = @intCast(fd);
    rig.auto = false;
    try rig.drain();
    try testing.expect(rig.w.saturated);
    try rig.drain(); // at the end of the file
    try testing.expect(!rig.w.saturated);
}

test "drain failure: first error returned, everything owed next time" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    try tmp.dir("root/a");
    var rig: Rig = undefined;
    try rig.init(1);
    defer rig.deinit();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    _ = try rig.scanRoot(tmp.abs(&pb, "root"));
    try tmp.file("root/a/f", 1);
    const Bad = struct {
        pub fn onChange(_: *@This(), _: Change) !void {
            return error.Nope;
        }
    };
    var bad: Bad = .{};
    try testing.expectError(error.Nope, rig.w.drain(&rig.t, &bad));
    rig.auto = false;
    try rig.drain();
    try testing.expectEqual(Change.everything, rig.changes.items[0]);
}

test "5000 folders: one touch each, every folder is reported" {
    var tmp: Tmp = undefined;
    try tmp.init();
    defer tmp.deinit();
    var name: [64]u8 = undefined;
    const n = 5000;
    for (0..n) |i| {
        try tmp.dir(try std.fmt.bufPrint(&name, "root/g{d}/d{d:0>5}", .{ i % 50, i }));
    }
    var rig: Rig = undefined;
    try rig.init(4);
    defer rig.deinit();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const rp = tmp.abs(&pb, "root");
    const t0 = nowNs();
    _ = try rig.scanRoot(rp);
    const t1 = nowNs();
    try testing.expectEqual(@as(usize, n + 50 + 1), rig.w.watchCount());
    for (0..n) |i| {
        try tmp.file(try std.fmt.bufPrint(&name, "root/g{d}/d{d:0>5}/f", .{ i % 50, i }), 1);
    }
    const t2 = nowNs();
    rig.auto = false;
    try rig.drain();
    const t3 = nowNs();
    var seen: usize = 0;
    var it = rig.w.map.iterator();
    while (it.next()) |e| {
        if (rig.sawNode(e.value_ptr.*)) seen += 1;
    }
    try testing.expect(seen >= n);
    std.debug.print("5000 folders: scan {d} ms, touch {d} ms, drain {d} ms, {d} changes, {d} folders seen\n", .{
        @divTrunc(t1 - t0, 1_000_000), @divTrunc(t2 - t1, 1_000_000), @divTrunc(t3 - t2, 1_000_000), rig.changes.items.len, seen,
    });
}
