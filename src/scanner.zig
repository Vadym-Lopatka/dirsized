//! Worker pool and owner-side apply loop.
//!
//! N workers each read one folder at a time (`scan.readFolder`, blocking and syscall-heavy).
//! The owner thread, the caller of `scanSubtree`, is the only one that touches the table: it
//! dispatches pending folders, applies the results, and pushes the new children.
//!
//! The table is the frontier. The owner keeps a stack of pending node ids (4 bytes each) and
//! builds a path only when a job is handed out, so memory does not grow with the number of
//! waiting folders. A node that is pending but on no stack (after an error) is picked up again
//! by the next `scanSubtree` call, which finds pending nodes from the table itself.
//!
//! Synchronisation: one mutex guards the two job lists and `quit`. Every change to them happens
//! under the mutex, every wait re-tests its predicate under the mutex, and every change is
//! followed by a signal, so a wake-up cannot be lost. Everything else is owner-only.
//!
//! Two ways to drive it. `scanSubtree` blocks on the condition variable until a subtree is done
//! (CLI scan mode). The daemon instead calls `enqueue` and `pump` from its poll loop: `pump`
//! never blocks, and a worker writes one byte to the wake fd after each result, so the loop wakes
//! when there is something to apply. `recheck` bits are cleared at dispatch (`takeRecheck`), not
//! at apply, so a change that arrives while a read is in flight sets the bit again and the folder
//! is read once more (the lost-update rule, ARCHITECTURE.md).
//!
//! Termination invariant: a pending node below the scan root is in exactly one of these places:
//! on `stack`, in a job in flight (submitted, result not applied yet), or - only after an error -
//! nowhere (it stays pending in the table). `in_flight` counts the second kind. `dispatch` runs
//! before every check, and it leaves `stack` non-empty only when `in_flight` is at its cap (or
//! after an error), so `in_flight == 0` after `dispatch` means the stack is empty and no result
//! is outstanding. That is the only exit of `scanSubtree`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scan = @import("scan.zig");
const table_mod = @import("table.zig");
const Table = table_mod.Table;
const NodeId = table_mod.NodeId;
const Rules = @import("ignore.zig").Rules;
const builtin = @import("builtin");

/// `Transient`: a read failed for a reason that may pass (out of descriptors or memory).
pub const Error = Allocator.Error || error{ TableFull, NameTooLong, Transient };

/// More workers than this only add kernel lock contention: measured on a 14-core M-series, 4
/// beat 8 by 25-35 % on a warm 26k-folder / 1.5M-file tree and a 52k-folder tree.
const max_default_threads = 4;

/// Runs on the owner thread right after a folder was read and applied, as a value or as
/// denied. The Linux daemon binds `read.wd` to the node here. `changed` tells if the table
/// now differs.
pub const Hook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, table: *Table, id: NodeId, read: *const scan.FolderRead, changed: bool) void,
};

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

extern "c" fn setiopolicy_np(iotype: c_int, scope: c_int, policy: c_int) c_int;

/// Switches the I/O priority of the calling thread. Best effort: a failure changes nothing.
fn setIoPriority(low: bool) void {
    switch (builtin.os.tag) {
        // IOPOL_TYPE_DISK = 0, IOPOL_SCOPE_THREAD = 1, IOPOL_THROTTLE = 3, IOPOL_DEFAULT = 0.
        .macos => _ = setiopolicy_np(0, 1, if (low) 3 else 0),
        // IOPRIO_WHO_PROCESS = 1 with who 0 is the calling thread; class idle = 3, none = 0.
        .linux => _ = std.os.linux.syscall3(.ioprio_set, 1, 0, if (low) 3 << 13 else 0),
        else => {},
    }
}

pub fn defaultThreads() u32 {
    const cpus = std.Thread.getCpuCount() catch 1;
    return @intCast(std.math.clamp(cpus, 1, max_default_threads));
}

/// A folder read and its result in one pooled object: the path goes to a worker, the filled
/// `read` (or the error) comes back. Warm jobs do not allocate.
const Job = struct {
    next: ?*Job = null,
    /// Absolute path, NUL-terminated for `readFolder`.
    path: std.ArrayList(u8) = .empty,
    /// Worker scratch: root-relative path of one child, for `Rules.match`.
    rel: std.ArrayList(u8) = .empty,
    /// Length of the root's path inside `path`; what follows is the path below the root.
    root_len: usize = 0,
    /// The root node this folder belongs to.
    root: NodeId = table_mod.none,
    rules: *const Rules = undefined,
    ignore_case: bool = false,
    read_opts: scan.ReadOptions = .{},
    read: scan.FolderRead = .{},
    result: (scan.ReadError || Allocator.Error)!void = {},
    /// Wall time of `scan.readFolder` for this job (the kernel's time for a huge folder).
    read_ns: u64 = 0,

    fn pathZ(job: *const Job) [:0]const u8 {
        return job.path.items[0 .. job.path.items.len - 1 :0];
    }

    fn deinit(job: *Job, gpa: Allocator) void {
        job.path.deinit(gpa);
        job.rel.deinit(gpa);
        job.read.deinit(gpa);
        gpa.destroy(job);
    }

    /// Owner side: fills in the path of `id`.
    fn prepare(job: *Job, table: *const Table, id: NodeId, gpa: Allocator) Allocator.Error!void {
        job.path.clearRetainingCapacity();
        try table.pathOf(id, &job.path, gpa);
        try job.path.append(gpa, 0);
        var top = id;
        while (table.parentOf(top) != table_mod.none) top = table.parentOf(top);
        job.root_len = table.name(top).len;
        job.root = top;
    }

    /// Worker side. A folder is excluded when its root-relative path matches; the root itself
    /// is never a child, so it is never tested. Names are compacted in place.
    fn filter(job: *Job, gpa: Allocator) Allocator.Error!void {
        if (job.rules.patterns.len == 0) return;
        const dir = std.mem.trimStart(u8, job.path.items[job.root_len .. job.path.items.len - 1], "/");
        const names = &job.read.names;
        var it = job.read.iterator();
        var w: usize = 0;
        var kept: u32 = 0;
        while (it.next()) |name| {
            job.rel.clearRetainingCapacity();
            if (dir.len != 0) {
                try job.rel.appendSlice(gpa, dir);
                try job.rel.append(gpa, '/');
            }
            try job.rel.appendSlice(gpa, name);
            if (job.rules.match(job.rel.items, job.ignore_case).excluded) continue;
            // The write position never passes the read position, so nothing unread is clobbered.
            std.mem.copyForwards(u8, names.items[w..][0..name.len], name);
            names.items[w + name.len] = 0;
            w += name.len + 1;
            kept += 1;
        }
        names.items.len = w;
        job.read.count = kept;
    }

    fn run(job: *Job, gpa: Allocator) void {
        const t0 = monotonicNs();
        job.result = scan.readFolder(gpa, job.pathZ(), job.read_opts, &job.read);
        job.read_ns = monotonicNs() -| t0;
        // After an error `read` is empty; there is nothing to filter.
        if (job.result) |_| job.result = job.filter(gpa) else |_| {}
    }
};

/// Intrusive stack of jobs. Order does not matter for either list.
const Lifo = struct {
    head: ?*Job = null,

    fn push(l: *Lifo, job: *Job) void {
        job.next = l.head;
        l.head = job;
    }

    fn pop(l: *Lifo) ?*Job {
        const job = l.head orelse return null;
        l.head = job.next;
        return job;
    }
};

/// State shared with the workers. Heap-allocated so the `Scanner` value can move.
const Shared = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Workers wait here for jobs (or `quit`).
    work: std.Io.Condition = .init,
    /// The owner waits here for results.
    done: std.Io.Condition = .init,
    jobs: Lifo = .{},
    results: Lifo = .{},
    quit: bool = false,
    /// Write end of the owner's wake pipe, -1 for none. Set by the owner, read by workers.
    wake_fd: std.atomic.Value(i32) = .init(-1),
    /// The owner asks workers to run at low I/O priority; each worker follows before its next job.
    low_priority: std.atomic.Value(bool) = .init(false),

    /// One byte per result. A full pipe (EAGAIN) is fine: the owner is already due to wake. An
    /// interrupted write is retried, or the byte of the only result could be lost.
    fn wake(sh: *Shared) void {
        const fd = sh.wake_fd.load(.acquire);
        if (fd < 0) return;
        const byte = [1]u8{1};
        while (true) {
            const rc = std.c.write(fd, &byte, 1);
            if (rc >= 0 or std.c.errno(rc) != .INTR) return;
        }
    }

    fn submit(sh: *Shared, job: *Job) void {
        sh.mutex.lockUncancelable(sh.io);
        sh.jobs.push(job);
        sh.mutex.unlock(sh.io);
        sh.work.signal(sh.io);
    }

    /// Moves every posted result to `into`. With `wait`, blocks until there is at least one.
    fn take(sh: *Shared, into: *Lifo, wait: bool) void {
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        while (sh.results.head == null) {
            if (!wait) return;
            sh.done.waitUncancelable(sh.io, &sh.mutex);
        }
        while (sh.results.pop()) |job| into.push(job);
    }

    fn stop(sh: *Shared) void {
        sh.mutex.lockUncancelable(sh.io);
        sh.quit = true;
        sh.mutex.unlock(sh.io);
        sh.work.broadcast(sh.io);
    }

    fn worker(sh: *Shared) void {
        var low = false; // this thread's current I/O priority
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        while (true) {
            if (sh.jobs.pop()) |job| {
                sh.mutex.unlock(sh.io);
                const want = sh.low_priority.load(.monotonic);
                if (want != low) {
                    setIoPriority(want);
                    low = want;
                }
                job.run(sh.gpa);
                sh.mutex.lockUncancelable(sh.io);
                sh.results.push(job);
                sh.done.signal(sh.io);
                // After the push, so a byte always means "a result is waiting"; outside the lock
                // so the syscall does not hold up the other workers.
                sh.mutex.unlock(sh.io);
                sh.wake();
                sh.mutex.lockUncancelable(sh.io);
            } else if (sh.quit) {
                return;
            } else {
                sh.work.waitUncancelable(sh.io, &sh.mutex);
            }
        }
    }
};

pub const Scanner = struct {
    gpa: Allocator,
    shared: *Shared,
    workers: []std.Thread,

    // Owner-only state from here on.
    stack: std.ArrayList(NodeId) = .empty,
    /// Subtree walk of `seed`; reused.
    walk: std.ArrayList(NodeId) = .empty,
    /// Child names of one result, as slices into the job; reused.
    names: std.ArrayList([]const u8) = .empty,
    /// Idle jobs. Capacity for all of them is reserved in `init`, so returning one cannot fail.
    idle: std.ArrayList(*Job) = .empty,
    /// Results taken from `shared` and not applied yet.
    ready: Lifo = .{},
    jobs_made: usize = 0,
    in_flight: usize = 0,
    /// First error of the current scan or pump. It stops dispatching and applying; the results
    /// still in flight are then drained and dropped (their folders are asked for again).
    failed: ?Error = null,
    /// Copied into each job at dispatch. The Linux daemon sets `inotify_fd` here.
    read_opts: scan.ReadOptions = .{},
    /// Roots can sit on volumes that differ in letter case. One entry per `table.roots()` entry,
    /// same order, borrowed. A root without an entry is case-sensitive.
    case_by_root: []const bool = &.{},
    on_applied: ?Hook = null,
    /// Wall time of the read whose result `on_applied` is being called for (the daemon's slow-folder rule).
    last_read_ns: u64 = 0,
    /// Reads handed to workers since init (a counter, for tests and the daemon's statistics).
    dispatched: u64 = 0,

    pub fn init(gpa: Allocator, io: std.Io, threads: u32) !Scanner {
        const n = @max(threads, 1);
        const shared = try gpa.create(Shared);
        errdefer gpa.destroy(shared);
        shared.* = .{ .gpa = gpa, .io = io };
        const workers = try gpa.alloc(std.Thread, n);
        errdefer gpa.free(workers);
        var idle: std.ArrayList(*Job) = .empty;
        try idle.ensureTotalCapacity(gpa, 2 * n);
        errdefer idle.deinit(gpa);

        var spawned: usize = 0;
        errdefer {
            shared.stop();
            for (workers[0..spawned]) |t| t.join();
        }
        while (spawned < n) {
            workers[spawned] = try std.Thread.spawn(.{}, Shared.worker, .{shared});
            spawned += 1;
        }
        return .{ .gpa = gpa, .shared = shared, .workers = workers, .idle = idle };
    }

    /// Waits for reads in flight (`discard`), then joins the workers.
    pub fn deinit(self: *Scanner) void {
        self.discard();
        std.debug.assert(self.in_flight == 0 and self.idle.items.len == self.jobs_made);
        self.shared.stop();
        for (self.workers) |t| t.join();
        for (self.idle.items) |job| job.deinit(self.gpa);
        self.idle.deinit(self.gpa);
        self.stack.deinit(self.gpa);
        self.walk.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.gpa.free(self.workers);
        self.gpa.destroy(self.shared);
        self.* = undefined;
    }

    /// Owner thread. Reads every pending folder at or below `id` (and the folders that reading
    /// creates) and applies the results, then returns. To have an existing folder read again,
    /// the caller first calls `table.markPending(id)`. On error the table is consistent, the
    /// unread folders are still pending, and the scanner can be used again.
    pub fn scanSubtree(self: *Scanner, table: *Table, rules: *const Rules, id: NodeId) Error!void {
        self.failed = null;
        try self.seed(table, id);
        while (true) {
            self.dispatch(table, rules);
            if (self.in_flight == 0) break;
            _ = self.applyOne(table, true);
        }
        return self.failed orelse {};
    }

    /// A worker writes one byte to `fd` after it posts a result. The daemon makes the pipe
    /// non-blocking and polls its read end. -1 turns it off.
    pub fn setWakeFd(self: *Scanner, fd: std.c.fd_t) void {
        self.shared.wake_fd.store(fd, .release);
    }

    /// Workers switch their I/O policy before the next job they start (not in the middle of one).
    pub fn setLowPriority(self: *Scanner, low: bool) void {
        self.shared.low_priority.store(low, .monotonic);
    }

    /// Owner thread. Asks for `id` to be read by the next `pump`. The caller has already set
    /// `pending` or `recheck`; `dispatch` skips an id that needs nothing by then. An id queued
    /// twice is read twice at worst (results are state-based, so that is harmless).
    pub fn enqueue(self: *Scanner, id: NodeId) Allocator.Error!void {
        try self.stack.append(self.gpa, id);
    }

    /// Owner thread, never blocks. Applies every result that is ready, then hands out more reads
    /// (new children of applied folders go to the stack directly). Returns the first error, and
    /// unlike `scanSubtree` it stays usable: `failed` is reset on entry, so the next `pump`
    /// carries on. Nothing is lost on an error: a dropped result's folder is flagged again
    /// (`requeue`) and goes back on the stack.
    pub fn pump(self: *Scanner, table: *Table, rules: *const Rules) Error!void {
        self.failed = null;
        while (self.applyOne(table, false)) {}
        self.dispatch(table, rules);
        return self.failed orelse {};
    }

    /// True when nothing is queued and no read is in flight (so no result can arrive).
    pub fn isIdle(self: *const Scanner) bool {
        return self.stack.items.len == 0 and self.in_flight == 0;
    }

    /// Blocks until every read in flight has finished, drops all results, clears the stack. For
    /// a table that is about to be thrown away (a new generation): the dropped folders are not
    /// flagged again. The scanner can be used afterwards.
    pub fn discard(self: *Scanner) void {
        while (self.in_flight > 0) {
            if (self.ready.head == null) self.shared.take(&self.ready, true);
            while (self.ready.pop()) |job| {
                self.in_flight -= 1;
                self.idle.appendAssumeCapacity(job);
            }
        }
        self.stack.clearRetainingCapacity();
        self.failed = null;
    }

    /// Replaces the stack with the pending nodes at or below `id`, shallowest on top: reading a
    /// folder first can remove a pending child, which saves reading it.
    fn seed(self: *Scanner, table: *const Table, id: NodeId) Allocator.Error!void {
        self.stack.clearRetainingCapacity();
        self.walk.clearRetainingCapacity();
        if (table.state(id) != .scanning) return;
        try self.walk.append(self.gpa, id);
        while (self.walk.pop()) |n| {
            if (table.isPending(n)) try self.stack.append(self.gpa, n);
            // `scanning` is O(1) and prunes every folder with nothing pending below.
            var it = table.children(n);
            while (it.next()) |c| if (table.state(c) == .scanning) try self.walk.append(self.gpa, c);
        }
        std.mem.reverse(NodeId, self.stack.items);
    }

    /// Hands folders that need a read (`pending` or `recheck`) to the workers while there is room:
    /// at most 2 x threads in flight, so a worker that finishes finds the next job waiting. Skips
    /// ids that need nothing any more (read already, or removed). The `recheck` bit is cleared
    /// here, before the read starts, so a change during the read is not lost. On an error the
    /// id goes back on the stack: it was popped and not submitted, and must not fall out.
    fn dispatch(self: *Scanner, table: *Table, rules: *const Rules) void {
        while (self.failed == null and self.in_flight < 2 * self.workers.len) {
            const id = self.stack.pop() orelse return;
            if (!table.needsRead(id)) continue;
            const job = self.idle.pop() orelse (self.newJob() catch |err| {
                self.stack.appendAssumeCapacity(id);
                self.failed = err;
                return;
            });
            job.prepare(table, id, self.gpa) catch |err| {
                self.idle.appendAssumeCapacity(job);
                self.stack.appendAssumeCapacity(id);
                self.failed = err;
                return;
            };
            job.rules = rules;
            job.ignore_case = self.caseOf(table, job.root);
            job.read_opts = self.read_opts;
            table.takeRecheck(id);
            self.in_flight += 1;
            self.dispatched += 1;
            self.shared.submit(job);
        }
    }

    fn caseOf(self: *const Scanner, table: *const Table, root: NodeId) bool {
        for (table.roots(), 0..) |r, i| {
            if (r.node == root and i < self.case_by_root.len) return self.case_by_root[i];
        }
        return false;
    }

    fn newJob(self: *Scanner) Allocator.Error!*Job {
        const job = try self.gpa.create(Job);
        job.* = .{};
        self.jobs_made += 1;
        return job;
    }

    /// Applies one finished result. With `wait` it blocks until one arrives (there must be a
    /// job in flight); without, it returns false when none is ready.
    fn applyOne(self: *Scanner, table: *Table, wait: bool) bool {
        if (self.ready.head == null) {
            std.debug.assert(!wait or self.in_flight > 0);
            self.shared.take(&self.ready, wait);
        }
        const job = self.ready.pop() orelse return false;
        self.in_flight -= 1;
        // After an error the result is dropped, and its folder is flagged again.
        if (self.failed == null) {
            self.apply(table, job) catch |err| {
                self.failed = err;
                self.requeue(table, job);
            };
        } else self.requeue(table, job);
        self.idle.appendAssumeCapacity(job);
        return true;
    }

    /// A result that was not applied must not lose its folder. `pending` still owes the read; a
    /// `recheck` bit was cleared at dispatch, so it is set again (a node that is pending needs
    /// no extra bit). The id goes back on the stack when there is room; if there is none, the
    /// flag alone remains and the next `enqueue` or full re-read of that folder picks it up. A
    /// node that no longer exists needs nothing.
    fn requeue(self: *Scanner, table: *Table, job: *const Job) void {
        const id = table.lookup(job.pathZ()) orelse return;
        if (!table.isPending(id)) _ = table.markRecheck(id);
        self.stack.append(self.gpa, id) catch {};
    }

    fn apply(self: *Scanner, table: *Table, job: *const Job) Error!void {
        // The job knows a path, not a node: the node may be gone, or replaced, by now.
        const id = table.lookup(job.pathZ()) orelse return;
        job.result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Not the folder's fault: `failed` and `requeue` read it again.
            error.Transient => return error.Transient,
            // Denied, and also "unexpected" (a path beyond PATH_MAX, an odd file system):
            // `partial` tells the truth, a silent wrong value would not.
            error.AccessDenied, error.Unexpected => return self.denied(table, id, job),
            error.NotFound, error.NotDir => {
                const parent = table.parentOf(id);
                // A root that vanished stays in the table as unreadable rather than being removed.
                if (parent == table_mod.none) return self.denied(table, id, job);
                // The parent's read drops every gone child in one pass; removing them one by one
                // walks the sibling list each time. Reading the child again now would only fail
                // again: if it is back by then, the parent's read hands it out as pending.
                _ = table.markRecheck(parent);
                try self.stack.append(self.gpa, parent);
                return;
            },
        };
        // An entry that could not be inspected may be a folder: applying the list would drop its
        // node (and subtree) as "gone". Keep the last known value and children, say `partial`.
        self.last_read_ns = job.read_ns;
        if (job.read.entry_errors != 0) return self.denied(table, id, job);
        try self.names.ensureTotalCapacity(self.gpa, job.read.count);
        self.names.clearRetainingCapacity();
        var it = job.read.iterator();
        while (it.next()) |name| self.names.appendAssumeCapacity(name);
        // The new children are pending; the stack receives them directly.
        const changed = table.applyRead(id, job.read.own, self.names.items, &self.stack, self.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // These fail the same way on every try (a name the table cannot hold, a full table).
            // Requeueing would read the folder again every second and the scanner would never be
            // idle: mark it unreadable instead.
            error.NameTooLong, error.TableFull => return self.denied(table, id, job),
        };
        if (self.on_applied) |h| h.func(h.ctx, table, id, &job.read, changed);
    }

    /// Every denied path ends here. After a read that failed, `job.read` is empty (`wd` is -1), so
    /// the hook has nothing to bind; after one that was applied, the watch its read added is bound.
    fn denied(self: *Scanner, table: *Table, id: NodeId, job: *const Job) Error!void {
        const changed = try table.applyDenied(id);
        if (self.on_applied) |h| h.func(h.ctx, table, id, &job.read, changed);
    }
};

// ---- tests -----------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;
const tio = testing.io;
const libc = std.c;
const State = table_mod.State;

const StatKind = struct { kind: enum { file, dir, other }, size: u64 };

/// lstat for the reference walk. Linux uses statx: `std.c.Stat` and `fstatat` are `void` there.
fn lstatKind(path: [*:0]const u8) ?StatKind {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &stx)) != .SUCCESS) return null;
        return switch (stx.mode & 0o170000) {
            0o100000 => .{ .kind = .file, .size = stx.size },
            0o040000 => .{ .kind = .dir, .size = 0 },
            else => .{ .kind = .other, .size = 0 },
        };
    }
    var st: libc.Stat = undefined;
    if (libc.fstatat(libc.AT.FDCWD, path, &st, libc.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return switch (st.mode & libc.S.IFMT) {
        libc.S.IFREG => .{ .kind = .file, .size = @intCast(st.size) },
        libc.S.IFDIR => .{ .kind = .dir, .size = 0 },
        else => .{ .kind = .other, .size = 0 },
    };
}

/// Independent reference: a plain recursive walk with libc `readdir` and `fstatat`, never
/// following symlinks, skipping what `skip` says (given the root-relative path).
const Ref = struct {
    name: []const u8,
    total: u64,
    kids: []Ref,

    fn count(r: Ref) usize {
        var n: usize = 1;
        for (r.kids) |k| n += k.count();
        return n;
    }
};

fn noSkip(_: []const u8) bool {
    return false;
}

fn refWalk(arena: Allocator, path: [:0]const u8, name: []const u8, rel: []const u8, skip: *const fn ([]const u8) bool) !Ref {
    var kids: std.ArrayList(Ref) = .empty;
    var total: u64 = 0;
    if (libc.opendir(path)) |dir| {
        defer _ = libc.closedir(dir);
        while (libc.readdir(dir)) |ent| {
            const nm = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
            const child = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ path, nm }, 0);
            const st = lstatKind(child) orelse continue;
            switch (st.kind) {
                .file => total += st.size,
                .dir => {
                    const crel = if (rel.len == 0) nm else try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, nm });
                    if (skip(crel)) continue;
                    const k = try refWalk(arena, child, try arena.dupe(u8, nm), crel, skip);
                    total += k.total;
                    try kids.append(arena, k);
                },
                else => {},
            }
        }
    }
    return .{ .name = name, .total = total, .kids = kids.items };
}

fn expectSame(t: *const Table, id: NodeId, ref: Ref, check_state: bool) !void {
    try testing.expectEqual(ref.total, t.total(id));
    if (check_state) try testing.expectEqual(State.ok, t.state(id));
    var n: usize = 0;
    var it = t.children(id);
    while (it.next()) |_| n += 1;
    try testing.expectEqual(ref.kids.len, n);
    for (ref.kids) |k| try expectSame(t, t.child(id, k.name) orelse return error.MissingNode, k, check_state);
}

/// A temp tree plus helpers to build and change it.
const Fixture = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,
    zeros: [4096]u8 = @splat(0),

    fn init(fx: *Fixture) !void {
        fx.tmp = testing.tmpDir(.{ .iterate = true });
        fx.len = try fx.tmp.dir.realPath(tio, &fx.buf);
        fx.buf[fx.len] = 0;
    }

    fn deinit(fx: *Fixture) void {
        fx.tmp.cleanup();
    }

    fn path(fx: *const Fixture) [:0]const u8 {
        return fx.buf[0..fx.len :0];
    }

    fn dir(fx: *Fixture, sub: []const u8) !void {
        try fx.tmp.dir.createDirPath(tio, sub);
    }

    fn file(fx: *Fixture, sub: []const u8, size: usize) !void {
        try fx.tmp.dir.writeFile(tio, .{ .sub_path = sub, .data = fx.zeros[0..size] });
    }

    fn reference(fx: *const Fixture, arena: Allocator, skip: *const fn ([]const u8) bool) !Ref {
        return refWalk(arena, fx.path(), "", "", skip);
    }
};

fn scanWith(t: *Table, sc: *Scanner, root: NodeId, patterns: []const []const u8) !void {
    var bad: ?u32 = null;
    var rules = try Rules.compile(ta, patterns, &bad);
    defer rules.deinit(ta);
    try sc.scanSubtree(t, &rules, root);
}

/// Scans a fresh table with `threads` workers and compares it with the reference.
fn scanAndCompare(fx: *const Fixture, threads: u32, patterns: []const []const u8, skip: *const fn ([]const u8) bool) !void {
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const ref = try fx.reference(arena.allocator(), skip);
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, threads);
    defer sc.deinit();
    try scanWith(&t, &sc, root, patterns);
    try expectSame(&t, root, ref, true);
    try testing.expectEqual(ref.count(), t.count());
}

test "hand-made tree, one worker" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("a/x");
    try fx.dir("b/y/z");
    try fx.dir("c");
    try fx.file("top", 3);
    try fx.file("a/f", 10);
    try fx.file("a/x/f", 5);
    try fx.file("b/y/z/f", 1000);
    try fx.tmp.dir.symLink(tio, "a", "link", .{});
    try scanAndCompare(&fx, 1, &.{}, noSkip);

    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 2);
    defer sc.deinit();
    try scanWith(&t, &sc, root, &.{});
    try testing.expectEqual(@as(u64, 1018), t.total(root));
    try testing.expectEqual(@as(usize, 7), t.count());
}

test "empty root" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try scanAndCompare(&fx, 4, &.{}, noSkip);
}

test "wide folder: 2000 child folders" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var name: [32]u8 = undefined;
    for (0..2000) |i| {
        try fx.dir(try std.fmt.bufPrint(&name, "d{d:0>5}", .{i}));
        try fx.file(try std.fmt.bufPrint(&name, "d{d:0>5}/f", .{i}), i % 3000);
    }
    try scanAndCompare(&fx, 8, &.{}, noSkip);
}

test "deep chain: depth 300" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const chain = "d/" ** 299 ++ "d";
    try fx.dir(chain);
    try fx.file(chain ++ "/f", 77);
    try fx.file("d/d/f", 5);
    try scanAndCompare(&fx, 4, &.{}, noSkip);
}

/// 3000 folders, 10000 files of random sizes, shaped by a seeded PRNG.
fn buildRandom(fx: *Fixture, arena: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.append(arena, "");
    for (0..3000) |i| {
        const parent = dirs.items[rnd.uintLessThan(usize, dirs.items.len)];
        const p = if (parent.len == 0)
            try std.fmt.allocPrint(arena, "n{d}", .{i})
        else
            try std.fmt.allocPrint(arena, "{s}/n{d}", .{ parent, i });
        try fx.dir(p);
        try dirs.append(arena, p);
    }
    for (0..10000) |i| {
        const parent = dirs.items[rnd.uintLessThan(usize, dirs.items.len)];
        var buf: [64]u8 = undefined;
        const p = if (parent.len == 0)
            try std.fmt.bufPrint(&buf, "f{d}", .{i})
        else
            try std.fmt.allocPrint(arena, "{s}/f{d}", .{ parent, i });
        try fx.file(p, rnd.uintLessThan(usize, 4097));
    }
}

test "random tree: threads 1, 2 and 8 agree with the reference" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    try buildRandom(&fx, arena.allocator(), 0x5eed);
    for ([_]u32{ 1, 2, 8 }) |threads| try scanAndCompare(&fx, threads, &.{}, noSkip);
}

test "random tree: 20 scans with 8 workers shake out races" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    try buildRandom(&fx, arena.allocator(), 42);
    const ref = try fx.reference(arena.allocator(), noSkip);
    // One scanner for all runs: also shows that it stays reusable.
    var sc = try Scanner.init(ta, tio, 8);
    defer sc.deinit();
    var bad: ?u32 = null;
    var rules = try Rules.compile(ta, &.{}, &bad);
    defer rules.deinit(ta);
    for (0..20) |_| {
        var t = Table.init(ta);
        defer t.deinit();
        const root = try t.addRoot(fx.path());
        try sc.scanSubtree(&t, &rules, root);
        try expectSame(&t, root, ref, true);
        try testing.expectEqual(ref.count(), t.count());
        try testing.expectEqual(@as(usize, 0), t.below.count());
    }
}

fn excludeSkip(rel: []const u8) bool {
    const base = rel[if (std.mem.lastIndexOfScalar(u8, rel, '/')) |s| s + 1 else 0..];
    if (std.mem.eql(u8, base, "node_modules")) return true;
    if (std.mem.eql(u8, rel, "b/build")) return true;
    return std.mem.endsWith(u8, base, ".cache") and !std.mem.eql(u8, base, "keep.cache");
}

test "exclude rules: name, anchored, negation" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("a/node_modules/x");
    try fx.dir("node_modules");
    try fx.dir("b/build/deep");
    try fx.dir("b/keep");
    try fx.dir("c/b/build");
    try fx.dir("d/x.cache/inner");
    try fx.dir("d/keep.cache");
    try fx.dir("e.cache");
    try fx.file("a/f", 1);
    try fx.file("a/node_modules/f", 100);
    try fx.file("a/node_modules/x/f", 100);
    try fx.file("node_modules/f", 1000);
    try fx.file("b/build/f", 10);
    try fx.file("b/build/deep/f", 10);
    try fx.file("b/keep/f", 7);
    try fx.file("c/b/build/f", 3);
    try fx.file("d/x.cache/f", 50);
    try fx.file("d/x.cache/inner/f", 50);
    try fx.file("d/keep.cache/f", 9);
    try fx.file("e.cache/f", 60);
    const patterns = [_][]const u8{ "node_modules/", "/b/build", "*.cache", "!keep.cache" };

    for ([_]u32{ 1, 8 }) |threads| {
        try scanAndCompare(&fx, threads, &patterns, excludeSkip);
    }

    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 3);
    defer sc.deinit();
    try scanWith(&t, &sc, root, &patterns);
    // a, b, b/keep, c, c/b, c/b/build, d, d/keep.cache and the root; nothing excluded has a node.
    try testing.expectEqual(@as(usize, 9), t.count());
    try testing.expectEqual(@as(u64, 1 + 7 + 3 + 9), t.total(root));
    const p = try std.fmt.allocPrint(ta, "{s}/a/node_modules", .{fx.path()});
    defer ta.free(p);
    try testing.expectEqual(@as(?NodeId, null), t.lookup(p));
    const b = t.child(root, "b").?;
    try testing.expectEqual(@as(?NodeId, null), t.child(b, "build"));
    try testing.expectEqual(@as(u64, 7), t.total(b));
}

fn chmod(fx: *const Fixture, sub: []const u8, mode: libc.mode_t) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ fx.path(), sub });
    try testing.expectEqual(@as(c_int, 0), libc.chmod(p, mode));
}

test "unreadable folder: ancestors are partial, siblings ok" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("top/mid/locked/inner");
    try fx.dir("top/mid/sibling");
    try fx.dir("other");
    try fx.file("top/mid/locked/f", 100);
    try fx.file("top/mid/locked/inner/f", 100);
    try fx.file("top/mid/sibling/f", 5);
    try fx.file("top/f", 1);
    try fx.file("other/f", 2);
    try chmod(&fx, "top/mid/locked", 0);
    defer chmod(&fx, "top/mid/locked", 0o755) catch {};

    for ([_]u32{ 1, 8 }) |threads| {
        var arena: std.heap.ArenaAllocator = .init(ta);
        defer arena.deinit();
        const ref = try fx.reference(arena.allocator(), noSkip);
        var t = Table.init(ta);
        defer t.deinit();
        const root = try t.addRoot(fx.path());
        var sc = try Scanner.init(ta, tio, threads);
        defer sc.deinit();
        try scanWith(&t, &sc, root, &.{});
        try expectSame(&t, root, ref, false);
        const top = t.child(root, "top").?;
        const mid = t.child(top, "mid").?;
        const locked = t.child(mid, "locked").?;
        try testing.expectEqual(State.partial, t.state(root));
        try testing.expectEqual(State.partial, t.state(top));
        try testing.expectEqual(State.partial, t.state(mid));
        try testing.expectEqual(State.partial, t.state(locked));
        try testing.expectEqual(State.ok, t.state(t.child(mid, "sibling").?));
        try testing.expectEqual(State.ok, t.state(t.child(root, "other").?));
        try testing.expectEqual(@as(u64, 0), t.total(locked));
        try testing.expectEqual(@as(usize, 0), t.below.get(root).?.pending);
    }
}

test "a path beyond PATH_MAX ends partial, not in a hang" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    // Each step is created through an open handle, so no single call sees a long path.
    var cur = fx.tmp.dir;
    // PATH_MAX is 1024 on macOS and 4096 on Linux.
    const depth: usize = if (builtin.os.tag == .linux) 25 else 7;
    for (0..depth) |i| {
        const name: [200]u8 = @splat('a' + @as(u8, @intCast(i)));
        const next = try cur.createDirPathOpen(tio, &name, .{});
        if (i != 0) cur.close(tio);
        cur = next;
        try next.writeFile(tio, .{ .sub_path = "f", .data = "x" });
    }
    cur.close(tio);

    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 4);
    defer sc.deinit();
    try scanWith(&t, &sc, root, &.{});
    try testing.expectEqual(State.partial, t.state(root));
    // Where it stops depends on the length of the temp path; it must stop before the bottom.
    try testing.expect(t.total(root) >= 1 and t.total(root) < depth);
    try testing.expect(t.count() < depth + 1);
}

test "a vanished or replaced root is partial, not removed" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("gone");
    var t = Table.init(ta);
    defer t.deinit();
    const gone = try std.fmt.allocPrint(ta, "{s}/gone", .{fx.path()});
    defer ta.free(gone);
    const missing = try std.fmt.allocPrint(ta, "{s}/missing", .{fx.path()});
    defer ta.free(missing);
    const r1 = try t.addRoot(gone);
    const r2 = try t.addRoot(missing);
    try fx.tmp.dir.deleteDir(tio, "gone");
    var sc = try Scanner.init(ta, tio, 2);
    defer sc.deinit();
    try scanWith(&t, &sc, r1, &.{});
    try scanWith(&t, &sc, r2, &.{});
    try testing.expectEqual(State.partial, t.state(r1));
    try testing.expectEqual(State.partial, t.state(r2));
    try testing.expectEqual(@as(usize, 2), t.count());
}

test "re-scan: markPending asks for a re-read" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("a/x");
    try fx.dir("b/y/z");
    try fx.dir("c");
    try fx.file("a/f", 10);
    try fx.file("a/x/f", 5);
    try fx.file("b/f", 20);
    try fx.file("b/y/z/f", 1);

    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 2);
    defer sc.deinit();
    try scanWith(&t, &sc, root, &.{});
    try expectSame(&t, root, try fx.reference(arena.allocator(), noSkip), true);

    // Nothing pending: a second call is a no-op.
    try scanWith(&t, &sc, root, &.{});
    try expectSame(&t, root, try fx.reference(arena.allocator(), noSkip), true);

    // Add a subtree, grow a file, delete a folder, move a subtree.
    try fx.dir("a/new/deeper");
    try fx.file("a/new/g", 100);
    try fx.file("a/new/deeper/h", 7);
    try fx.file("b/f", 2000);
    try fx.tmp.dir.deleteDir(tio, "c");
    try fx.tmp.dir.rename("b/y", fx.tmp.dir, "a/y", tio);
    const a = t.child(root, "a").?;
    const b = t.child(root, "b").?;
    try t.markPending(a);
    try t.markPending(b);
    try t.markPending(root);
    try testing.expectEqual(State.scanning, t.state(root));
    try scanWith(&t, &sc, root, &.{});
    try expectSame(&t, root, try fx.reference(arena.allocator(), noSkip), true);
    try testing.expectEqual(@as(?NodeId, null), t.child(root, "c"));

    // Asking below the root reads only that part.
    try fx.file("a/x/f2", 40);
    try t.markPending(t.child(a, "x").?);
    try scanWith(&t, &sc, a, &.{});
    try expectSame(&t, root, try fx.reference(arena.allocator(), noSkip), true);
}

test "re-scan: pending children of a folder that no longer lists them" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var name: [16]u8 = undefined;
    for (0..60) |i| {
        try fx.dir(try std.fmt.bufPrint(&name, "d{d}", .{i}));
        try fx.file(try std.fmt.bufPrint(&name, "d{d}/f", .{i}), i + 1);
    }
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 1);
    defer sc.deinit();
    try scanWith(&t, &sc, root, &.{});
    for (0..60) |i| try fx.tmp.dir.deleteTree(tio, try std.fmt.bufPrint(&name, "d{d}", .{i}));
    // The root is read first and drops all children while 58 of their ids are still on the stack.
    try t.markPending(root);
    var it = t.children(root);
    while (it.next()) |ch| try t.markPending(ch);
    try scanWith(&t, &sc, root, &.{});
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectEqual(@as(u64, 0), t.total(root));
    try testing.expectEqual(State.ok, t.state(root));
}

test "deinit right after init and after an unused scanner" {
    for ([_]u32{ 0, 1, 8 }) |threads| {
        var sc = try Scanner.init(ta, tio, threads);
        sc.deinit();
    }
}

/// Fails the n-th allocation. Thread-safe, unlike `std.testing.FailingAllocator`.
const FailAt = struct {
    fail_at: usize,
    seen: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *FailAt) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FailAt = @ptrCast(@alignCast(ctx));
        if (self.seen.fetchAdd(1, .monotonic) == self.fail_at) return null;
        return ta.rawAlloc(len, a, ra);
    }

    fn resize(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        return ta.rawResize(m, a, n, ra);
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *FailAt = @ptrCast(@alignCast(ctx));
        if (self.seen.fetchAdd(1, .monotonic) == self.fail_at) return null;
        return ta.rawRemap(m, a, n, ra);
    }

    fn free(_: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        ta.rawFree(m, a, ra);
    }
};

test "allocation failure anywhere: error or a correct table, workers drain, no leak" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("a/b/c");
    try fx.dir("d/e");
    try fx.dir("f");
    try fx.file("a/b/f", 4);
    try fx.file("d/e/f", 8);
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const ref = try fx.reference(arena.allocator(), noSkip);
    var bad: ?u32 = null;
    var rules = try Rules.compile(ta, &.{"zzz"}, &bad);
    defer rules.deinit(ta);

    var fail_at: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_at += 1) {
        var fa: FailAt = .{ .fail_at = fail_at };
        var t = Table.init(ta);
        defer t.deinit();
        const root = try t.addRoot(fx.path());
        var sc = Scanner.init(fa.allocator(), tio, 2) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            continue;
        };
        defer sc.deinit();
        var failed = false;
        sc.scanSubtree(&t, &rules, root) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failed = true;
            failures += 1;
            // The failed scan left a scanner that works: the same one finishes the job.
            fa.fail_at = std.math.maxInt(usize);
            try sc.scanSubtree(&t, &rules, root);
        };
        try expectSame(&t, root, ref, true);
        if (!failed and fa.seen.load(.monotonic) <= fail_at) break; // nothing was left to fail
    }
    try testing.expect(failures > 5);
}

// ---- pump-driven scanning (the daemon's way) -------------------------------------------

/// A non-blocking pipe as the daemon's wake pipe: the scanner writes `wr`, the test polls `rd`.
const Pipe = struct {
    rd: libc.fd_t,
    wr: libc.fd_t,

    fn init() !Pipe {
        var fds: [2]libc.fd_t = undefined;
        if (libc.pipe(&fds) != 0) return error.PipeFailed;
        const nb: c_int = @intCast(@as(u32, @bitCast(libc.O{ .NONBLOCK = true })));
        for (fds) |fd| _ = libc.fcntl(fd, libc.F.SETFL, nb);
        return .{ .rd = fds[0], .wr = fds[1] };
    }

    fn deinit(p: Pipe) void {
        _ = libc.close(p.rd);
        _ = libc.close(p.wr);
    }

    /// Waits for at least one byte (10 s at most), then empties the pipe.
    fn waitAndDrain(p: Pipe) !void {
        var pfd = [1]libc.pollfd{.{ .fd = p.rd, .events = libc.POLL.IN, .revents = 0 }};
        if (libc.poll(&pfd, 1, 10_000) <= 0) return error.WakeTimeout;
        var buf: [256]u8 = undefined;
        while (libc.read(p.rd, &buf, buf.len) > 0) {}
    }
};

fn pumpUntilIdle(sc: *Scanner, t: *Table, rules: *const Rules, pipe: Pipe) !void {
    try sc.pump(t, rules);
    while (!sc.isIdle()) {
        try pipe.waitAndDrain();
        try sc.pump(t, rules);
    }
}

fn noRules() !Rules {
    var bad: ?u32 = null;
    return Rules.compile(ta, &.{}, &bad);
}

test "pump with a wake pipe matches the reference" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    try buildRandom(&fx, arena.allocator(), 0xbeef);
    const ref = try fx.reference(arena.allocator(), noSkip);
    var rules = try noRules();
    defer rules.deinit(ta);
    const pipe = try Pipe.init();
    defer pipe.deinit();

    for ([_]u32{ 1, 4 }) |threads| {
        var t = Table.init(ta);
        defer t.deinit();
        const root = try t.addRoot(fx.path());
        var sc = try Scanner.init(ta, tio, threads);
        defer sc.deinit();
        sc.setWakeFd(pipe.wr);
        sc.setLowPriority(threads == 1); // only has to work; there is no portable way to observe it
        try testing.expect(sc.isIdle());
        try sc.enqueue(root);
        try testing.expect(!sc.isIdle());
        try pumpUntilIdle(&sc, &t, &rules, pipe);
        try expectSame(&t, root, ref, true);
        try testing.expectEqual(ref.count(), t.count());
        try testing.expectEqual(@as(u64, ref.count()), sc.dispatched);
        // Nothing queued: pump is a no-op and does not block.
        try sc.pump(&t, &rules);
        try testing.expect(sc.isIdle());
    }
}

test "pump reads recheck folders and clears the bit at dispatch" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("a/x");
    try fx.dir("b");
    try fx.file("a/f", 10);
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    var rules = try noRules();
    defer rules.deinit(ta);
    const pipe = try Pipe.init();
    defer pipe.deinit();
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 2);
    defer sc.deinit();
    sc.setWakeFd(pipe.wr);
    try sc.enqueue(root);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    const a = t.child(root, "a").?;
    const first = sc.dispatched;

    try fx.file("a/f2", 100);
    try testing.expect(t.markRecheck(a));
    try testing.expectEqual(State.ok, t.state(root)); // owed, but not `scanning`
    try sc.enqueue(a);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    try testing.expectEqual(first + 1, sc.dispatched);
    try testing.expect(!t.needsRead(a));
    try expectSame(&t, root, try fx.reference(arena.allocator(), noSkip), true);

    // Not flagged, not read.
    try sc.enqueue(a);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    try testing.expectEqual(first + 1, sc.dispatched);
}

test "lost update: a recheck set while the read is in flight reads the folder again" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("a");
    try fx.file("a/f", 10);
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    var rules = try noRules();
    defer rules.deinit(ta);
    const pipe = try Pipe.init();
    defer pipe.deinit();
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 1);
    defer sc.deinit();
    sc.setWakeFd(pipe.wr);
    try sc.enqueue(root);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    const a = t.child(root, "a").?;
    const before = sc.dispatched;

    // Read 1 starts; its bit is gone. The event arrives while it runs: the bit is set again.
    try testing.expect(t.markRecheck(a));
    try sc.enqueue(a);
    try sc.pump(&t, &rules);
    try testing.expectEqual(before + 1, sc.dispatched);
    try testing.expect(!t.needsRead(a)); // dispatch took the bit
    try fx.file("a/g", 1000); // may or may not be seen by read 1
    try testing.expect(t.markRecheck(a));

    // Applying result 1 must not clear the new bit.
    while (sc.in_flight != 0) {
        try pipe.waitAndDrain();
        try sc.pump(&t, &rules);
    }
    try testing.expect(sc.isIdle());
    try testing.expect(t.needsRead(a));
    try testing.expectEqual(before + 1, sc.dispatched);

    // The caller (the daemon's debounce) enqueues it: read 2 sees the final disk state.
    try sc.enqueue(a);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    try testing.expectEqual(before + 2, sc.dispatched);
    try testing.expect(!t.needsRead(a));
    try expectSame(&t, root, try fx.reference(arena.allocator(), noSkip), true);
    try testing.expectEqual(@as(u64, 1010), t.total(root));
}

test "discard waits for reads in flight, drops results, and the scanner works again" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    try buildRandom(&fx, arena.allocator(), 7);
    const ref = try fx.reference(arena.allocator(), noSkip);
    var rules = try noRules();
    defer rules.deinit(ta);
    const pipe = try Pipe.init();
    defer pipe.deinit();
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 4);
    defer sc.deinit();
    sc.setWakeFd(pipe.wr);
    try sc.enqueue(root);
    try sc.pump(&t, &rules);
    for (0..3) |_| {
        try pipe.waitAndDrain();
        try sc.pump(&t, &rules);
    }
    try testing.expect(!sc.isIdle());
    sc.discard();
    try testing.expect(sc.isIdle());
    try testing.expectEqual(@as(usize, 0), sc.in_flight);
    try testing.expectEqual(sc.jobs_made, sc.idle.items.len);
    sc.discard(); // idle: nothing to do

    // The folders whose results were dropped are still pending; seeding finds them.
    try testing.expectEqual(State.scanning, t.state(root));
    try sc.seed(&t, root);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    try expectSame(&t, root, ref, true);
    try testing.expectEqual(ref.count(), t.count());
}

const HookCtx = struct {
    calls: usize = 0,
    kids: usize = 0,
    changed: usize = 0,
    saw_pending: bool = false,
    last_table: ?*Table = null,
};

fn countHook(ctx: *anyopaque, table: *Table, id: NodeId, read: *const scan.FolderRead, changed: bool) void {
    const c: *HookCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    c.changed += @intFromBool(changed);
    c.kids += read.count;
    // The apply is done when the hook runs: the folder is no longer pending itself.
    if (table.isPending(id)) c.saw_pending = true;
    c.last_table = table;
}

test "on_applied runs on the owner thread after each successful apply" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("a/x");
    try fx.dir("b/y/z");
    try fx.dir("locked/inner");
    try fx.file("a/f", 1);
    try chmod(&fx, "locked", 0);
    defer chmod(&fx, "locked", 0o755) catch {};
    var rules = try noRules();
    defer rules.deinit(ta);
    const pipe = try Pipe.init();
    defer pipe.deinit();
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 3);
    defer sc.deinit();
    sc.setWakeFd(pipe.wr);
    var ctx: HookCtx = .{};
    sc.on_applied = .{ .ctx = &ctx, .func = countHook };
    try sc.enqueue(root);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    // root, a, a/x, b, b/y, b/y/z were applied and `locked` was denied; `inner` never seen.
    try testing.expectEqual(@as(usize, 7), ctx.calls);
    try testing.expectEqual(@as(usize, 6), ctx.kids); // a, b, locked (root); x (a); y (b); z (y)
    try testing.expect(!ctx.saw_pending);
    try testing.expectEqual(@as(?*Table, &t), ctx.last_table);
    try testing.expectEqual(State.partial, t.state(root));

    // A recheck of one folder calls it once more.
    const a = t.child(root, "a").?;
    try testing.expect(t.markRecheck(a));
    try sc.enqueue(a);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    try testing.expectEqual(@as(usize, 8), ctx.calls);
    // Nothing changed on disk: the hook says so (the daemon saves a snapshot only for real changes).
    try testing.expectEqual(@as(usize, 7), ctx.changed);
    try fx.file("a/g", 5);
    try testing.expect(t.markRecheck(a));
    try sc.enqueue(a);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    try testing.expectEqual(@as(usize, 8), ctx.changed);
}

test "pump after an allocation failure carries on and loses no folder" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.dir("a/b/c");
    try fx.dir("d/e");
    try fx.dir("f");
    try fx.file("a/b/f", 4);
    try fx.file("d/e/f", 8);
    var arena: std.heap.ArenaAllocator = .init(ta);
    defer arena.deinit();
    const ref = try fx.reference(arena.allocator(), noSkip);
    var rules = try noRules();
    defer rules.deinit(ta);
    const pipe = try Pipe.init();
    defer pipe.deinit();

    var fail_at: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_at += 1) {
        var fa: FailAt = .{ .fail_at = fail_at };
        var t = Table.init(ta);
        defer t.deinit();
        const root = try t.addRoot(fx.path());
        var sc = Scanner.init(fa.allocator(), tio, 2) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            continue;
        };
        defer sc.deinit();
        sc.setWakeFd(pipe.wr);
        var failed = false;
        sc.enqueue(root) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failed = true;
            failures += 1;
            fa.fail_at = std.math.maxInt(usize);
            try sc.enqueue(root);
        };
        var rounds: usize = 0;
        while (rounds < 10_000) : (rounds += 1) {
            sc.pump(&t, &rules) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failed = true;
                failures += 1;
                fa.fail_at = std.math.maxInt(usize);
            };
            if (sc.isIdle()) break;
            if (sc.in_flight > 0) try pipe.waitAndDrain();
        } else return error.DidNotFinish;
        try expectSame(&t, root, ref, true);
        try testing.expectEqual(ref.count(), t.count());
        if (!failed and fa.seen.load(.monotonic) <= fail_at) break;
    }
    try testing.expect(failures > 5);
}

/// A job with a hand-made result for the folder `path`, as a worker would post it.
fn fakeJob(path: []const u8, names: []const u8, count: u32) !*Job {
    const job = try ta.create(Job);
    job.* = .{};
    try job.path.appendSlice(ta, path);
    try job.path.append(ta, 0);
    try job.read.names.appendSlice(ta, names);
    job.read.count = count;
    return job;
}

test "a result that can never be applied marks the folder denied, not pending" {
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot("/r");
    var sc = try Scanner.init(ta, tio, 1);
    defer sc.deinit();
    try testing.expectEqual(State.scanning, t.state(root));
    // A child name over 255 bytes: `applyRead` says NameTooLong on every try.
    const job = try fakeJob("/r", "n" ** 256 ++ "\x00", 1);
    defer job.deinit(ta);
    try sc.apply(&t, job);
    try testing.expectEqual(State.partial, t.state(root));
    try testing.expect(!t.isPending(root));
    try testing.expect(!t.needsRead(root));
    try testing.expect(t.isDenied(root));
}

test "a folder with a failed entry keeps its children and is partial" {
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot("/r");
    var fresh: std.ArrayList(NodeId) = .empty;
    defer fresh.deinit(ta);
    _ = try t.applyRead(root, 5, &.{"kid"}, &fresh, ta);
    const kid = t.child(root, "kid").?;
    _ = try t.applyRead(kid, 7, &.{}, &fresh, ta);
    try testing.expectEqual(State.ok, t.state(root));
    try testing.expectEqual(@as(u64, 12), t.total(root));
    var sc = try Scanner.init(ta, tio, 1);
    defer sc.deinit();
    // The re-read lists no folders, but one entry could not be inspected.
    const job = try fakeJob("/r", "", 0);
    defer job.deinit(ta);
    job.read.entry_errors = 1;
    try sc.apply(&t, job);
    try testing.expectEqual(kid, t.child(root, "kid").?);
    try testing.expectEqual(@as(u64, 12), t.total(root));
    try testing.expectEqual(State.partial, t.state(root));
    // Without the error the child is gone, as before.
    job.read.entry_errors = 0;
    try sc.apply(&t, job);
    try testing.expectEqual(@as(?NodeId, null), t.child(root, "kid"));
}

test "a transient read error is retried, not made permanent" {
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot("/r");
    var sc = try Scanner.init(ta, tio, 1);
    defer sc.deinit();
    const job = try fakeJob("/r", "", 0);
    job.result = error.Transient;
    sc.jobs_made = 1;
    sc.in_flight = 1;
    sc.ready.push(job);
    try testing.expect(sc.applyOne(&t, false));
    try testing.expectEqual(error.Transient, sc.failed.?);
    try testing.expect(!t.isDenied(root));
    try testing.expect(t.isPending(root));
    try testing.expectEqual(root, sc.stack.getLast());
}

test "a pending child that vanished asks for its parent once, and comes back if it returns" {
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot("/r");
    var sc = try Scanner.init(ta, tio, 1);
    defer sc.deinit();
    var read_root = try fakeJob("/r", "kid\x00", 1);
    defer read_root.deinit(ta);
    try sc.apply(&t, read_root);
    const kid = t.child(root, "kid").?;
    sc.stack.clearRetainingCapacity();

    var gone = try fakeJob("/r/kid", "", 0);
    defer gone.deinit(ta);
    gone.result = error.NotFound;
    try sc.apply(&t, gone);
    try testing.expectEqualSlices(NodeId, &.{root}, sc.stack.items);
    try testing.expect(t.needsRead(root));
    try testing.expect(t.isPending(kid));

    // The parent's read still lists the child: it is handed out again, once.
    sc.stack.clearRetainingCapacity();
    try sc.apply(&t, read_root);
    try testing.expectEqualSlices(NodeId, &.{kid}, sc.stack.items);

    // The parent's read does not list it: it is dropped and nothing is queued.
    sc.stack.clearRetainingCapacity();
    var read_empty = try fakeJob("/r", "", 0);
    defer read_empty.deinit(ta);
    try sc.apply(&t, read_empty);
    try testing.expectEqual(@as(?NodeId, null), t.child(root, "kid"));
    try testing.expectEqual(0, sc.stack.items.len);
}

test "every denied path tells the hook whether the table changed" {
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot("/r");
    var sc = try Scanner.init(ta, tio, 1);
    defer sc.deinit();
    var ctx: HookCtx = .{};
    sc.on_applied = .{ .ctx = &ctx, .func = countHook };
    var ok = try fakeJob("/r", "", 0);
    defer ok.deinit(ta);
    try sc.apply(&t, ok);
    try testing.expectEqual(1, ctx.changed); // pending -> ok

    var denied = try fakeJob("/r", "", 0);
    defer denied.deinit(ta);
    denied.result = error.AccessDenied;
    try sc.apply(&t, denied);
    try testing.expect(t.isDenied(root));
    try testing.expectEqual(2, ctx.changed); // readable -> denied
    try sc.apply(&t, denied);
    try testing.expectEqual(3, ctx.calls);
    try testing.expectEqual(2, ctx.changed); // already denied

    // A vanished root is denied in the same way.
    try sc.apply(&t, ok);
    denied.result = error.NotFound;
    try sc.apply(&t, denied);
    try testing.expectEqual(4, ctx.changed);
}

test "gone children are dropped by one read of their parent" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var name: [16]u8 = undefined;
    for (0..30) |i| try fx.dir(try std.fmt.bufPrint(&name, "d{d}", .{i}));
    var t = Table.init(ta);
    defer t.deinit();
    const root = try t.addRoot(fx.path());
    var sc = try Scanner.init(ta, tio, 2);
    defer sc.deinit();
    const pipe = try Pipe.init();
    defer pipe.deinit();
    sc.setWakeFd(pipe.wr);
    var rules = try noRules();
    defer rules.deinit(ta);
    try sc.enqueue(root);
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    try testing.expectEqual(31, t.count());

    // Only the children are flagged; the parent's new file shows that it was read too.
    for (0..30) |i| try fx.tmp.dir.deleteDir(tio, try std.fmt.bufPrint(&name, "d{d}", .{i}));
    try fx.file("f", 9);
    var it = t.children(root);
    while (it.next()) |ch| {
        _ = t.markRecheck(ch);
        try sc.enqueue(ch);
    }
    try pumpUntilIdle(&sc, &t, &rules, pipe);
    try testing.expectEqual(1, t.count());
    try testing.expectEqual(9, t.total(root));
}
