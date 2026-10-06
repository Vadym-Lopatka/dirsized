//! macOS change watcher: FSEvents with folder-level events, one stream per device.

const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const watch = @import("watch.zig");
const Change = watch.Change;
const StartResult = watch.StartResult;

// Hand-written because std.c has none of this. Header paths are relative to the SDK's
// usr/include or the framework's Headers; line numbers are from the macOS 27 SDK.
const CFTypeRef = *anyopaque;
const CFIndex = isize;
const StreamRef = *anyopaque;
const EventId = u64;

/// FSEvents/FSEvents.h:717. Without kFSEventStreamCreateFlagUseCFTypes `paths` is a
/// `char **`, one C string per event.
const Callback = *const fn (stream: ?*const anyopaque, info: ?*anyopaque, n: usize, paths: ?*anyopaque, flags: [*]const u32, ids: [*]const EventId) callconv(.c) void;

const StreamContext = extern struct { // FSEvents.h, FSEventStreamContext
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
};

const UuidBytes = extern struct { bytes: [16]u8 }; // CFUUID.h, CFUUIDBytes

extern "c" fn FSEventStreamCreate(allocator: ?*anyopaque, callback: Callback, context: *const StreamContext, paths: CFTypeRef, since: EventId, latency: f64, flags: u32) ?StreamRef;
extern "c" fn FSEventStreamSetDispatchQueue(stream: StreamRef, queue: *anyopaque) void;
extern "c" fn FSEventStreamStart(stream: StreamRef) u8; // Boolean
extern "c" fn FSEventStreamFlushSync(stream: StreamRef) void;
extern "c" fn FSEventStreamStop(stream: StreamRef) void;
extern "c" fn FSEventStreamInvalidate(stream: StreamRef) void;
extern "c" fn FSEventStreamRelease(stream: StreamRef) void;
extern "c" fn FSEventsGetCurrentEventId() EventId;
extern "c" fn FSEventsCopyUUIDForDevice(dev: c.dev_t) ?CFTypeRef;
extern "c" fn CFUUIDGetUUIDBytes(uuid: CFTypeRef) UuidBytes;
extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFStringCreateWithCString(allocator: ?*anyopaque, c_str: [*:0]const u8, encoding: u32) ?CFTypeRef;
extern "c" fn CFArrayCreate(allocator: ?*anyopaque, values: [*]const ?*const anyopaque, n: CFIndex, callbacks: *const anyopaque) ?CFTypeRef;
extern "c" const kCFTypeArrayCallBacks: u8; // only its address is used

// dispatch/queue.h
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_sync_f(queue: *anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_release(object: *anyopaque) void;

// os/lock.h: a lock is one u32, zero when free.
const UnfairLock = extern struct { opaque_: u32 = 0 };
extern "c" fn os_unfair_lock_lock(lock: *UnfairLock) void;
extern "c" fn os_unfair_lock_unlock(lock: *UnfairLock) void;

const kCFStringEncodingUTF8 = 0x08000100; // CFString.h
const kFSEventStreamEventIdSinceNow: EventId = 0xFFFFFFFFFFFFFFFF; // FSEvents.h:582
const kFSEventStreamCreateFlagWatchRoot = 0x4; // FSEvents.h:255

const flag_must_scan = 0x1; // FSEvents.h:398
const flag_user_dropped = 0x2;
const flag_kernel_dropped = 0x4;
const flag_ids_wrapped = 0x8;
const flag_history_done = 0x10;
const flag_root_changed = 0x20;
const flag_mount = 0x40;
const flag_unmount = 0x80;
const subtree_flags = flag_must_scan | flag_user_dropped | flag_kernel_dropped | flag_root_changed | flag_mount | flag_unmount;

/// Seconds FSEvents waits after the first event of a burst before it delivers the burst.
/// NoDefer is not set: it delivers the first event at once and the rest of the burst one
/// latency later, which is two wakeups for one burst (measured).
const latency = 0.3;

// Records in the buffer between the dispatch thread and the owner:
// tag u8, stream index u32, event id u64, path length u32, path bytes. Little endian.
const Tag = enum(u8) { change, subtree, history_done, wrapped, dropped };
const record_header = 17;

/// The callback and `drain` share this. It lives on the heap because the Watcher is
/// returned by value, and a callback may run while `start` is still setting up streams.
const Shared = struct {
    lock: UnfairLock = .{},
    /// Written by the callback, swapped out by `drain`.
    buf: std.ArrayList(u8) = .empty,
    /// The buffer could not grow: records are lost, so `drain` reports `.everything`.
    lost: bool = false,
    gpa: Allocator,
    wake_fd: c.fd_t,
};

/// One FSEvents stream: all roots on one device. Heap allocated: the callback gets its address.
const Stream = struct {
    shared: *Shared,
    index: u32,
    ref: ?StreamRef = null,
    dev: c.dev_t,
    /// Null when FSEvents has no history for the device; then nothing is saved for it.
    uuid: ?[16]u8,
    // Owner thread only from here.
    /// `drain` has handed out the HistoryDone marker (always true for a fresh start).
    history_done: bool,
    /// Highest id handed out by `drain`. Replayed ids arrive out of order, hence the maximum.
    max_id: EventId,
    /// The id saved by `saveState`: where a later start resumes.
    cp_id: EventId,
};

fn callback(_: ?*const anyopaque, info: ?*anyopaque, n: usize, paths: ?*anyopaque, flags: [*]const u32, ids: [*]const EventId) callconv(.c) void {
    const stream: *Stream = @ptrCast(@alignCast(info.?));
    const sh = stream.shared;
    const event_paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths.?));
    os_unfair_lock_lock(&sh.lock);
    for (0..n) |i| {
        const f = flags[i];
        if (f & flag_history_done != 0) {
            append(sh, .history_done, stream.index, ids[i], "");
            continue;
        }
        if (f & flag_ids_wrapped != 0) append(sh, .wrapped, stream.index, ids[i], "");
        // The event's path may lie above every root; only "everything" is then right.
        if (f & (flag_user_dropped | flag_kernel_dropped) != 0) append(sh, .dropped, stream.index, ids[i], "");
        append(sh, if (f & subtree_flags != 0) .subtree else .change, stream.index, ids[i], folderPath(std.mem.span(event_paths[i])));
    }
    const added = sh.buf.items.len != 0 or sh.lost;
    os_unfair_lock_unlock(&sh.lock);
    if (!added) return;
    // A full pipe already holds a wakeup; any other error cannot be handled here.
    const byte = [1]u8{0};
    _ = c.write(sh.wake_fd, &byte, 1);
}

/// Events carry a trailing slash for a folder; roots and `Change.path` have none.
fn folderPath(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') end -= 1;
    return p[0..end];
}

/// Caller holds the lock. A failed allocation is remembered, not returned: the callback has no caller to tell.
fn append(sh: *Shared, tag: Tag, stream: u32, id: EventId, path: []const u8) void {
    sh.buf.ensureUnusedCapacity(sh.gpa, record_header + path.len) catch {
        sh.lost = true;
        return;
    };
    var header: [record_header]u8 = undefined;
    header[0] = @intFromEnum(tag);
    std.mem.writeInt(u32, header[1..5], stream, .little);
    std.mem.writeInt(u64, header[5..13], id, .little);
    std.mem.writeInt(u32, header[13..17], @intCast(path.len), .little);
    sh.buf.appendSliceAssumeCapacity(&header);
    sh.buf.appendSliceAssumeCapacity(path);
}

fn noop(_: ?*anyopaque) callconv(.c) void {}

// Blob written by `saveState`: "dsw1", entry count u32, then per device UUID[16] and id u64.
// Keyed by UUID, so the order of devices does not matter.
const blob_magic = "dsw1";
const blob_entry = 24;

pub const Watcher = struct {
    gpa: Allocator,
    shared: *Shared,
    queue: *anyopaque,
    streams: std.ArrayList(*Stream) = .empty,
    /// Records taken from `shared.buf`; `scratch_pos` is the first one not yet handed out.
    scratch: std.ArrayList(u8) = .empty,
    scratch_pos: usize = 0,
    /// `.everything` is owed to the owner (records were lost).
    owe_everything: bool = false,

    pub const StartError = error{ InvalidPath, RootNotFound, StreamFailed } || Allocator.Error;

    pub fn init(gpa: Allocator, wake_fd: c.fd_t) !Watcher {
        const shared = try gpa.create(Shared);
        errdefer gpa.destroy(shared);
        shared.* = .{ .gpa = gpa, .wake_fd = wake_fd };
        // Serial: callbacks of all streams run one at a time.
        const queue = dispatch_queue_create("dirsized.watch", null) orelse return error.OutOfMemory;
        return .{ .gpa = gpa, .shared = shared, .queue = queue };
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        self.streams.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        // No stream is left, so the queue is idle.
        dispatch_release(self.queue);
        self.shared.buf.deinit(self.gpa);
        self.gpa.destroy(self.shared);
        self.* = undefined;
    }

    /// Roots are real absolute paths. They are grouped by device; a device gets one plain
    /// `FSEventStreamCreate` stream with absolute paths, not a device-relative one: on macOS 27
    /// `FSEventStreamCreateRelativeToDevice` takes ONE path only (a second path makes `Start`
    /// fail), and on a mounted disk image a stream with a sub-folder path delivered no events.
    pub fn start(self: *Watcher, roots: []const []const u8, saved: ?[]const u8) StartError!StartResult {
        if (self.streams.items.len != 0) self.stop();
        errdefer self.stop();

        // One stream per device; `members[i]` are the roots of `self.streams.items[i]`.
        var members: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        defer {
            for (members.items) |*m| m.deinit(self.gpa);
            members.deinit(self.gpa);
        }
        for (roots) |root| {
            const z = try self.gpa.dupeZ(u8, root);
            defer self.gpa.free(z);
            var st: c.Stat = undefined;
            if (c.fstatat(c.AT.FDCWD, z, &st, 0) != 0) return error.RootNotFound;
            const idx = for (self.streams.items, 0..) |s, i| {
                if (s.dev == st.dev) break i;
            } else blk: {
                const s = try self.gpa.create(Stream);
                errdefer self.gpa.destroy(s);
                s.* = .{
                    .shared = self.shared,
                    .index = @intCast(self.streams.items.len),
                    .dev = st.dev,
                    .uuid = copyUuid(st.dev),
                    .history_done = true,
                    .max_id = 0,
                    .cp_id = 0,
                };
                try self.streams.append(self.gpa, s);
                errdefer _ = self.streams.pop();
                try members.append(self.gpa, .empty);
                break :blk self.streams.items.len - 1;
            };
            try members.items[idx].append(self.gpa, root);
        }

        // Taken before any stream exists: a change after this point is delivered.
        const now_id = FSEventsGetCurrentEventId();
        const resume_ids = if (saved) |blob| self.resumeIds(blob, now_id) else null;
        for (self.streams.items) |s| {
            if (resume_ids) |ids| {
                s.cp_id = ids[s.index];
                s.history_done = false;
            } else s.cp_id = now_id;
            s.max_id = s.cp_id;
        }
        for (self.streams.items, members.items) |s, m| {
            const paths = try makePathArray(self.gpa, m.items);
            defer CFRelease(paths);
            const ctx: StreamContext = .{ .info = s };
            const since = if (resume_ids != null) s.cp_id else kFSEventStreamEventIdSinceNow;
            s.ref = FSEventStreamCreate(null, callback, &ctx, paths, since, latency, kFSEventStreamCreateFlagWatchRoot) orelse return error.StreamFailed;
            FSEventStreamSetDispatchQueue(s.ref.?, self.queue);
            if (FSEventStreamStart(s.ref.?) == 0) return error.StreamFailed;
        }
        return if (resume_ids != null) .resumed else .fresh;
    }

    /// The saved id of every stream, in stream order, or null unless the blob is valid, has a
    /// matching UUID for every stream and no id above `now_id` (the ids wrapped since).
    /// Allocation-free: at most `max_streams` devices.
    fn resumeIds(self: *const Watcher, blob: []const u8, now_id: EventId) ?[max_streams]EventId {
        if (self.streams.items.len == 0 or self.streams.items.len > max_streams) return null;
        if (blob.len < 8 or !std.mem.eql(u8, blob[0..4], blob_magic)) return null;
        const count = std.mem.readInt(u32, blob[4..8], .little);
        if (blob.len - 8 != @as(u64, count) * blob_entry) return null;
        var ids: [max_streams]EventId = undefined;
        for (self.streams.items) |s| {
            const uuid = s.uuid orelse return null;
            ids[s.index] = for (0..count) |i| {
                const e = blob[8 + i * blob_entry ..][0..blob_entry];
                if (std.mem.eql(u8, e[0..16], &uuid)) break std.mem.readInt(u64, e[16..24], .little);
            } else return null;
            if (ids[s.index] > now_id) return null;
        }
        return ids;
    }

    /// Stops and releases all streams. After this no callback runs and none will touch freed memory.
    pub fn stop(self: *Watcher) void {
        for (self.streams.items) |s| {
            const ref = s.ref orelse continue;
            FSEventStreamStop(ref);
            FSEventStreamInvalidate(ref);
            FSEventStreamRelease(ref);
            s.ref = null;
        }
        // A callback that was already queued may still be running or waiting. This block
        // runs behind it on the serial queue; after it returns the Streams can be freed.
        if (self.streams.items.len != 0) dispatch_sync_f(self.queue, null, noop);
        for (self.streams.items) |s| self.gpa.destroy(s);
        self.streams.clearRetainingCapacity();
        os_unfair_lock_lock(&self.shared.lock);
        self.shared.buf.clearRetainingCapacity();
        self.shared.lost = false;
        os_unfair_lock_unlock(&self.shared.lock);
        self.scratch.clearRetainingCapacity();
        self.scratch_pos = 0;
        self.owe_everything = false;
    }

    /// macOS has no fd to poll: the callback writes to `wake_fd`.
    pub fn pollFd(self: *const Watcher) c.fd_t {
        _ = self;
        return -1;
    }

    /// Owner thread. Hands out every buffered change in arrival order. If `onChange` fails,
    /// that change and the ones after it stay buffered for the next call.
    pub fn drain(self: *Watcher, ctx: anytype) !void {
        const sh = self.shared;
        if (self.scratch_pos == self.scratch.items.len) {
            self.scratch.clearRetainingCapacity();
            self.scratch_pos = 0;
            os_unfair_lock_lock(&sh.lock);
            std.mem.swap(std.ArrayList(u8), &self.scratch, &sh.buf);
            if (sh.lost) self.owe_everything = true;
            sh.lost = false;
            os_unfair_lock_unlock(&sh.lock);
        } else {
            // Left over from a failed call: keep it in front, append what is new. Rare, so it copies.
            self.scratch.replaceRangeAssumeCapacity(0, self.scratch_pos, &.{});
            self.scratch_pos = 0;
            os_unfair_lock_lock(&sh.lock);
            defer os_unfair_lock_unlock(&sh.lock);
            try self.scratch.appendSlice(self.gpa, sh.buf.items);
            sh.buf.clearRetainingCapacity();
            if (sh.lost) self.owe_everything = true;
            sh.lost = false;
        }
        if (self.owe_everything) {
            try ctx.onChange(Change.everything);
            self.owe_everything = false;
        }
        while (self.scratch_pos < self.scratch.items.len) {
            const rest = self.scratch.items[self.scratch_pos..];
            const tag: Tag = @enumFromInt(rest[0]);
            const index = std.mem.readInt(u32, rest[1..5], .little);
            const id = std.mem.readInt(u64, rest[5..13], .little);
            const len = std.mem.readInt(u32, rest[13..17], .little);
            const path = rest[record_header..][0..len];
            switch (tag) {
                .change, .subtree => try ctx.onChange(Change{ .path = .{ .path = path, .subtree = tag == .subtree } }),
                .wrapped, .dropped => try ctx.onChange(Change.everything),
                .history_done => {},
            }
            self.scratch_pos += record_header + len;
            const s = self.streams.items[index];
            switch (tag) {
                .history_done => s.history_done = true,
                // Ids start again: what was recorded before is meaningless.
                .wrapped => {
                    s.max_id = id;
                    s.cp_id = id;
                },
                .change, .subtree, .dropped => s.max_id = @max(s.max_id, id),
            }
        }
    }

    pub fn caughtUp(self: *const Watcher) bool {
        for (self.streams.items) |s| if (!s.history_done) return false;
        return true;
    }

    /// Everything handed out so far is in the table. A stream that is still replaying keeps
    /// its old id: the replay is not complete until its HistoryDone.
    ///
    /// A quiet disk moves no id, so a restart would replay everything since the last event.
    /// Instead the current id is taken, the streams are flushed (every event up to that id is
    /// then in the buffer) and the id is used if the buffer is empty: nothing at or below it is
    /// undelivered.
    pub fn checkpoint(self: *Watcher) void {
        var replaying = false;
        for (self.streams.items) |s| {
            if (s.history_done) s.cp_id = @max(s.cp_id, s.max_id) else replaying = true;
        }
        if (replaying or self.scratch_pos != self.scratch.items.len) return;
        const now_id = FSEventsGetCurrentEventId();
        for (self.streams.items) |s| if (s.ref) |ref| FSEventStreamFlushSync(ref);
        os_unfair_lock_lock(&self.shared.lock);
        defer os_unfair_lock_unlock(&self.shared.lock);
        if (self.shared.buf.items.len != 0 or self.shared.lost) return;
        for (self.streams.items) |s| s.cp_id = @max(s.cp_id, now_id);
    }

    pub fn saveState(self: *const Watcher, out: *std.ArrayList(u8), gpa: Allocator) !void {
        var count: u32 = 0;
        for (self.streams.items) |s| count += @intFromBool(s.uuid != null);
        try out.ensureUnusedCapacity(gpa, 8 + @as(usize, count) * blob_entry);
        out.appendSliceAssumeCapacity(blob_magic);
        out.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToLittle(u32, count)));
        for (self.streams.items) |s| {
            const uuid = s.uuid orelse continue;
            out.appendSliceAssumeCapacity(&uuid);
            out.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToLittle(u64, s.cp_id)));
        }
    }
};

/// More devices than this in one start is not resumed (a start still works).
const max_streams = 16;

fn copyUuid(dev: c.dev_t) ?[16]u8 {
    const ref = FSEventsCopyUUIDForDevice(dev) orelse return null;
    defer CFRelease(ref);
    return CFUUIDGetUUIDBytes(ref).bytes;
}

/// A CFArray of CFStrings for FSEventStreamCreate. Paths must be UTF-8; APFS and HFS+ names are.
fn makePathArray(gpa: Allocator, paths: []const []const u8) Watcher.StartError!CFTypeRef {
    const strings = try gpa.alloc(?*const anyopaque, paths.len);
    defer gpa.free(strings);
    var made: usize = 0;
    defer for (strings[0..made]) |s| CFRelease(@constCast(s.?));
    for (paths) |p| {
        const z = try gpa.dupeZ(u8, p);
        defer gpa.free(z);
        strings[made] = CFStringCreateWithCString(null, z, kCFStringEncodingUTF8) orelse return error.InvalidPath;
        made += 1;
    }
    // The array retains its strings, so they are released above.
    return CFArrayCreate(null, strings.ptr, @intCast(paths.len), &kCFTypeArrayCallBacks) orelse error.OutOfMemory;
}

// Tests need the real file system and a running fseventsd.

const testing = std.testing;
const io = testing.io;

const Collector = struct {
    const Item = struct { path: []u8, subtree: bool };
    items: std.ArrayList(Item) = .empty,
    everything: u32 = 0,
    /// Test hook: fail this many onChange calls first.
    fail: u32 = 0,

    fn onChange(col: *Collector, ch: Change) !void {
        if (col.fail > 0) {
            col.fail -= 1;
            return error.Injected;
        }
        switch (ch) {
            .path => |p| try col.items.append(testing.allocator, .{ .path = try testing.allocator.dupe(u8, p.path), .subtree = p.subtree }),
            .everything => col.everything += 1,
            .node => unreachable,
        }
    }

    fn deinit(col: *Collector) void {
        col.clear();
        col.items.deinit(testing.allocator);
    }

    fn clear(col: *Collector) void {
        for (col.items.items) |i| testing.allocator.free(i.path);
        col.items.clearRetainingCapacity();
    }

    fn has(col: *const Collector, path: []const u8) bool {
        for (col.items.items) |i| if (std.mem.eql(u8, i.path, path)) return true;
        return false;
    }
};

fn nowMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// A watcher with a pipe for the wake byte; the read end is non-blocking.
const Rig = struct {
    pipe: [2]c.fd_t,
    w: Watcher,

    fn init() !Rig {
        var p: [2]c.fd_t = undefined;
        try testing.expectEqual(0, c.pipe(&p));
        for (p) |fd| {
            const fl = c.fcntl(fd, c.F.GETFL);
            _ = c.fcntl(fd, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        }
        return .{ .pipe = p, .w = try Watcher.init(testing.allocator, p[1]) };
    }

    fn deinit(r: *Rig) void {
        r.w.deinit();
        _ = c.close(r.pipe[0]);
        _ = c.close(r.pipe[1]);
    }

    /// Waits on the wake pipe and drains until `done` is true or `timeout_ms` has passed.
    fn waitUntil(r: *Rig, col: *Collector, timeout_ms: i64, comptime done: fn (*Rig, *Collector) bool) !bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            try r.w.drain(col);
            if (done(r, col)) return true;
            const left = deadline - nowMs();
            if (left <= 0) return false;
            var fds = [1]c.pollfd{.{ .fd = r.pipe[0], .events = c.POLL.IN, .revents = 0 }};
            _ = c.poll(&fds, 1, @intCast(@min(left, 100)));
            var sink: [64]u8 = undefined;
            while (c.read(r.pipe[0], &sink, sink.len) > 0) {}
        }
    }

    /// Drains for `ms` regardless of what arrives.
    fn settle(r: *Rig, col: *Collector, ms: i64) !void {
        _ = try r.waitUntil(col, ms, never);
    }
};

fn never(_: *Rig, _: *Collector) bool {
    return false;
}

fn caught(r: *Rig, _: *Collector) bool {
    return r.w.caughtUp();
}

const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{ .iterate = true }) };
        f.len = try f.tmp.dir.realPath(io, &f.buf);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }

    fn path(f: *const Fixture) []const u8 {
        return f.buf[0..f.len];
    }

    /// Absolute path of `rel` inside the fixture, owned by the caller.
    fn abs(f: *const Fixture, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ f.path(), rel });
    }

    fn touch(f: *Fixture, rel: []const u8) !void {
        try f.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = "x" });
    }
};

/// Fails the test unless the path arrives within `timeout_ms`.
fn expectChange(r: *Rig, col: *Collector, path: []const u8) !void {
    const Wait = struct {
        var want: []const u8 = "";
        fn done(_: *Rig, cc: *Collector) bool {
            return cc.has(want);
        }
    };
    Wait.want = path;
    if (!try r.waitUntil(col, 5000, Wait.done)) {
        std.debug.print("no change for {s}; got {d} others:\n", .{ path, col.items.items.len });
        for (col.items.items) |i| std.debug.print("  {s}\n", .{i.path});
        return error.TestExpectedChange;
    }
}

test "a file in a sub-folder gives a change for that folder, in about the latency" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();

    const roots = [_][]const u8{f.path()};
    try testing.expectEqual(StartResult.fresh, try r.w.start(&roots, null));
    try testing.expect(r.w.caughtUp());
    try f.tmp.dir.createDir(io, "sub", .default_dir);
    try r.settle(&col, 800); // the folder's own event
    col.clear();

    const t0 = nowMs();
    try f.touch("sub/file");
    const sub = try f.abs("sub");
    defer testing.allocator.free(sub);
    try expectChange(&r, &col, sub);
    const delay = nowMs() - t0;
    try testing.expect(delay < 2000);
    for (col.items.items) |i| try testing.expect(!i.subtree);
}

test "mkdir -p, rename of a folder, delete of a tree" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();
    const roots = [_][]const u8{f.path()};
    _ = try r.w.start(&roots, null);

    try f.tmp.dir.createDirPath(io, "a/b/c/d");
    try f.touch("a/b/c/d/leaf");
    for ([_][]const u8{ "a/b/c/d", "a/b/c" }) |rel| {
        const p = try f.abs(rel);
        defer testing.allocator.free(p);
        try expectChange(&r, &col, p);
    }
    try r.settle(&col, 500);
    col.clear();

    try f.tmp.dir.rename("a/b", f.tmp.dir, "a/b2", io);
    const parent = try f.abs("a");
    defer testing.allocator.free(parent);
    try expectChange(&r, &col, parent);
    try r.settle(&col, 500);
    col.clear();

    try f.tmp.dir.deleteTree(io, "a/b2");
    try expectChange(&r, &col, parent);
    for (col.items.items) |i| try testing.expect(i.path.len == 1 or i.path[i.path.len - 1] != '/');
}

test "resume replays what happened after the checkpoint, while running and while stopped" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();
    const roots = [_][]const u8{f.path()};
    try f.tmp.dir.createDir(io, "x", .default_dir);
    try f.tmp.dir.createDir(io, "y", .default_dir);
    try testing.expectEqual(StartResult.fresh, try r.w.start(&roots, null));

    try f.touch("x/before");
    const x = try f.abs("x");
    defer testing.allocator.free(x);
    const y = try f.abs("y");
    defer testing.allocator.free(y);
    try expectChange(&r, &col, x);
    r.w.checkpoint();
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(testing.allocator);
    try r.w.saveState(&blob, testing.allocator);
    try testing.expectEqual(8 + blob_entry, blob.items.len);
    col.clear();

    // A: after the checkpoint, while running. It is delivered now and replayed later.
    try f.touch("x/a");
    try expectChange(&r, &col, x);
    r.w.stop();
    col.clear();
    // B: while stopped. Give fseventsd time to log it.
    try f.touch("y/b");
    try r.settle(&col, 1000);

    try testing.expectEqual(StartResult.resumed, try r.w.start(&roots, blob.items));
    try testing.expect(!r.w.caughtUp() or col.items.items.len == 0);
    try expectChange(&r, &col, x);
    try expectChange(&r, &col, y);
    try testing.expect(try r.waitUntil(&col, 5000, caught));
    try testing.expect(r.w.caughtUp());

    // Live events after the replay still arrive.
    col.clear();
    try f.touch("y/live");
    try expectChange(&r, &col, y);
}

test "checkpoint does not move before the replay is done" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    const roots = [_][]const u8{f.path()};
    _ = try r.w.start(&roots, null);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(testing.allocator);
    try r.w.saveState(&blob, testing.allocator);
    r.w.stop();

    _ = try r.w.start(&roots, blob.items);
    const s = r.w.streams.items[0];
    const saved_id = s.cp_id;
    // Pretend a replayed event was handed out, but HistoryDone not yet.
    s.history_done = false;
    s.max_id = saved_id + 1000;
    r.w.checkpoint();
    try testing.expectEqual(saved_id, s.cp_id);
    s.history_done = true;
    r.w.checkpoint();
    try testing.expect(s.cp_id >= saved_id + 1000);
}

test "checkpoint on a quiet disk moves the id; an undelivered event keeps it back" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();
    const roots = [_][]const u8{f.path()};
    try f.tmp.dir.createDir(io, "x", .default_dir);
    _ = try r.w.start(&roots, null);
    try r.settle(&col, 800);
    const s = r.w.streams.items[0];
    const start_id = s.cp_id;
    r.w.checkpoint();
    try testing.expect(s.cp_id > start_id);

    // The event is inside FSEvents' latency window: the checkpoint must not skip it. Save the
    // blob without draining and restart from it: the replay has to bring the event back.
    try f.touch("x/f");
    var nap = [1]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
    _ = c.poll(&nap, 1, 100); // long enough for fseventsd to number the event, short of the latency
    r.w.checkpoint();
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(testing.allocator);
    try r.w.saveState(&blob, testing.allocator);
    r.w.stop();
    col.clear();
    try testing.expectEqual(StartResult.resumed, try r.w.start(&roots, blob.items));
    const x = try f.abs("x");
    defer testing.allocator.free(x);
    try expectChange(&r, &col, x);
}

test "a corrupted blob, an empty blob or a blob of another device gives fresh" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    const roots = [_][]const u8{f.path()};
    _ = try r.w.start(&roots, null);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(testing.allocator);
    try r.w.saveState(&blob, testing.allocator);
    r.w.stop();

    // Another device: same layout, other UUID.
    var other = try blob.clone(testing.allocator);
    defer other.deinit(testing.allocator);
    other.items[8] ^= 0xff;
    var bad_magic = try blob.clone(testing.allocator);
    defer bad_magic.deinit(testing.allocator);
    bad_magic.items[0] = 'X';
    var bad_count = try blob.clone(testing.allocator);
    defer bad_count.deinit(testing.allocator);
    bad_count.items[4] = 200;
    const cases = [_][]const u8{ "", "dsw", "garbage garbage garbage garbage", blob.items[0 .. blob.items.len - 1], other.items, bad_magic.items, bad_count.items };
    for (cases) |bytes| {
        try testing.expectEqual(StartResult.fresh, try r.w.start(&roots, bytes));
        try testing.expect(r.w.caughtUp());
        r.w.stop();
    }
    // The untouched blob does resume.
    try testing.expectEqual(StartResult.resumed, try r.w.start(&roots, blob.items));
}

test "a saved id above the current one (ids wrapped) gives fresh" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    const roots = [_][]const u8{f.path()};
    _ = try r.w.start(&roots, null);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(testing.allocator);
    try r.w.saveState(&blob, testing.allocator);
    r.w.stop();
    try testing.expectEqual(StartResult.resumed, try r.w.start(&roots, blob.items));
    r.w.stop();
    std.mem.writeInt(u64, blob.items[blob.items.len - 8 ..][0..8], FSEventsGetCurrentEventId() + 1_000_000, .little);
    try testing.expectEqual(StartResult.fresh, try r.w.start(&roots, blob.items));
}

test "a wrapped event restarts the saved id" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();
    _ = try r.w.start(&.{f.path()}, null);
    const s = r.w.streams.items[0];
    s.cp_id = std.math.maxInt(u64) - 10;
    s.max_id = s.cp_id;
    os_unfair_lock_lock(&r.w.shared.lock);
    append(r.w.shared, .wrapped, 0, 5, "");
    os_unfair_lock_unlock(&r.w.shared.lock);
    try r.w.drain(&col);
    try testing.expectEqual(1, col.everything);
    try testing.expectEqual(5, s.cp_id);
}

test "a lost record with an empty buffer still wakes the owner" {
    var r = try Rig.init();
    defer r.deinit();
    var s: Stream = .{ .shared = r.w.shared, .index = 0, .dev = 0, .uuid = null, .history_done = true, .max_id = 0, .cp_id = 0 };
    r.w.shared.lost = true;
    var byte: [1]u8 = undefined;
    try testing.expect(c.read(r.pipe[0], &byte, 1) < 0);
    var path: [*:0]const u8 = "";
    const flags = [1]u32{0};
    const ids = [1]EventId{0};
    callback(null, &s, 0, @ptrCast(&path), &flags, &ids);
    try testing.expectEqual(1, c.read(r.pipe[0], &byte, 1));
    var col: Collector = .{};
    defer col.deinit();
    try r.w.drain(&col);
    try testing.expectEqual(1, col.everything);
}

test "dropped events give everything, also for a path above the roots" {
    var r = try Rig.init();
    defer r.deinit();
    var s: Stream = .{ .shared = r.w.shared, .index = 0, .dev = 0, .uuid = null, .history_done = true, .max_id = 0, .cp_id = 0 };
    try r.w.streams.append(testing.allocator, &s);
    defer r.w.streams.clearRetainingCapacity();
    var path: [*:0]const u8 = "/Users/";
    const flags = [1]u32{flag_must_scan | flag_user_dropped};
    const ids = [1]EventId{7};
    callback(null, &s, 1, @ptrCast(&path), &flags, &ids);
    var col: Collector = .{};
    defer col.deinit();
    try r.w.drain(&col);
    try testing.expectEqual(1, col.everything);
    try testing.expect(col.items.items[0].subtree);
    try testing.expectEqual(7, s.max_id);
}

test "stop then start with another root, and deinit without stop" {
    var f1 = try Fixture.init();
    defer f1.deinit();
    var f2 = try Fixture.init();
    defer f2.deinit();
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();
    try f1.tmp.dir.createDir(io, "s", .default_dir);
    try f2.tmp.dir.createDir(io, "s", .default_dir);
    const p1 = try f1.abs("s");
    defer testing.allocator.free(p1);
    const p2 = try f2.abs("s");
    defer testing.allocator.free(p2);

    _ = try r.w.start(&.{f1.path()}, null);
    try f1.touch("s/one");
    try expectChange(&r, &col, p1);
    r.w.stop();
    r.w.stop(); // twice is fine
    col.clear();

    _ = try r.w.start(&.{f2.path()}, null);
    try f1.touch("s/ignored"); // no longer watched
    try f2.touch("s/two");
    try expectChange(&r, &col, p2);
    try r.settle(&col, 600);
    try testing.expect(!col.has(p1));

    // A second Watcher dropped while running; the leak checker watches this one.
    var r2 = try Rig.init();
    _ = try r2.w.start(&.{f1.path()}, null);
    try f1.touch("s/three");
    r2.deinit();
    var r3 = try Rig.init();
    r3.deinit(); // never started
}

test "two roots on one device share one stream and both report" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();
    try f.tmp.dir.createDirPath(io, "one/s");
    try f.tmp.dir.createDirPath(io, "two/s");
    const one = try f.abs("one");
    defer testing.allocator.free(one);
    const two = try f.abs("two");
    defer testing.allocator.free(two);
    const one_s = try f.abs("one/s");
    defer testing.allocator.free(one_s);
    const two_s = try f.abs("two/s");
    defer testing.allocator.free(two_s);

    _ = try r.w.start(&.{ one, two }, null);
    try testing.expectEqual(1, r.w.streams.items.len);
    try f.touch("one/s/f");
    try f.touch("two/s/f");
    try expectChange(&r, &col, one_s);
    try expectChange(&r, &col, two_s);
}

test "a root that does not exist is an error and leaves a usable watcher" {
    var r = try Rig.init();
    defer r.deinit();
    try testing.expectError(error.RootNotFound, r.w.start(&.{"/no/such/folder/for/dirsized"}, null));
    try testing.expect(r.w.caughtUp());
}

test "drain keeps what onChange did not take" {
    var f = try Fixture.init();
    defer f.deinit();
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();
    try f.tmp.dir.createDir(io, "s", .default_dir);
    _ = try r.w.start(&.{f.path()}, null);
    try f.touch("s/f");
    // Wait until the callback has buffered something.
    var fds = [1]c.pollfd{.{ .fd = r.pipe[0], .events = c.POLL.IN, .revents = 0 }};
    try testing.expect(c.poll(&fds, 1, 5000) == 1);
    col.fail = 1;
    try testing.expectError(error.Injected, r.w.drain(&col));
    try testing.expectEqual(0, col.items.items.len);
    try r.w.drain(&col);
    try testing.expect(col.items.items.len > 0);
}

test "path form: no trailing slash, root path kept" {
    try testing.expectEqualStrings("/a/b", folderPath("/a/b/"));
    try testing.expectEqualStrings("/a/b", folderPath("/a/b"));
    try testing.expectEqualStrings("/", folderPath("/"));
}

test "the disk image case: a volume mounted under /Volumes (skipped when none is there)" {
    // Needs an APFS image named DSTEST attached with `hdiutil attach`.
    var dir = std.Io.Dir.openDirAbsolute(io, "/Volumes/DSTEST", .{}) catch return error.SkipZigTest;
    dir.close(io);
    var r = try Rig.init();
    defer r.deinit();
    var col: Collector = .{};
    defer col.deinit();
    _ = try r.w.start(&.{"/Volumes/DSTEST"}, null);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/Volumes/DSTEST/dirsized-test-file", .data = "x" });
    defer std.Io.Dir.deleteFileAbsolute(io, "/Volumes/DSTEST/dirsized-test-file") catch {};
    try expectChange(&r, &col, "/Volumes/DSTEST");

    // Resume on this volume: assert only that it does not crash.
    r.w.checkpoint();
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(testing.allocator);
    try r.w.saveState(&blob, testing.allocator);
    r.w.stop();
    col.clear();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/Volumes/DSTEST/dirsized-test-file2", .data = "y" });
    defer std.Io.Dir.deleteFileAbsolute(io, "/Volumes/DSTEST/dirsized-test-file2") catch {};
    _ = try r.w.start(&.{"/Volumes/DSTEST"}, blob.items);
    _ = try r.waitUntil(&col, 3000, caught);
}
