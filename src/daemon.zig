//! The daemon (ARCHITECTURE.md "daemon.zig", DESIGN.md sections 6, 7, 11, 13).
//!
//! One thread owns the table and runs one `poll()` loop over: the wake pipe (scanner workers,
//! the watcher and the signal handler all write one byte to it), the watcher's own fd (Linux),
//! the listen socket and the clients. Nothing else touches the table.
//!
//! Two generations can exist. `live` is the one the scanner and the watcher maintain; `serving`
//! answers queries. They differ only while a new config is scanned: `serving` is then frozen and
//! its answers are `stale`. A table that is about to be thrown away is never kept alive by
//! anything: `scanner.discard()` and `watcher.stop()` come before the switch.
//!
//! Timers are armed only when there is something to wait for (a debounce, a snapshot of a
//! changed table, the verification), so an idle daemon sleeps in `poll` with no wake-ups.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const c = std.c;
const config = @import("config.zig");
const ignore = @import("ignore.zig");
const paths = @import("paths.zig");
const proto = @import("proto.zig");
const scan = @import("scan.zig");
const scanner_mod = @import("scanner.zig");
const server_mod = @import("server.zig");
const snapshot_mod = @import("snapshot.zig");
const table_mod = @import("table.zig");
const watch = @import("watch.zig");

const Table = table_mod.Table;
const NodeId = table_mod.NodeId;
const Scanner = scanner_mod.Scanner;
const Server = server_mod.Server;
const Watcher = watch.Watcher;

pub const version = "0.1.1";

const is_linux = builtin.os.tag == .linux;

const ns_per_s: i64 = 1_000_000_000;
/// Events of one folder are collected this long before it is read (DESIGN.md section 6).
const debounce_ns = 1 * ns_per_s;
/// A folder that keeps changing is read at most this often.
const backoff_max_ns = 30 * ns_per_s;
/// The slow-folder rule (see `Slow`).
const slow_min_ns = 50 * (ns_per_s / 1000);
const slow_factor = 20;
const slow_max_ns = 10 * 60 * ns_per_s;
const config_check_ns = 1 * ns_per_s;
/// A config file modified more recently than this may still be being written (an editor truncates,
/// then writes): it is not read yet.
const config_settle_ns = 200 * (ns_per_s / 1000);
const save_every_ns = 5 * 60 * ns_per_s;
const verify_every_ns = 7 * 24 * 60 * 60 * ns_per_s;
/// After a drain that found events the watcher fd is not polled for this long, so the kernel
/// merges a write storm into one wakeup (a plain `dd` of small blocks costs a core without it).
const watch_hold_ns = 100 * (ns_per_s / 1000);
/// After an allocation failure in the loop: try again later instead of spinning.
const retry_ns = 1 * ns_per_s;
/// While a generation has no working watcher, starting it is tried again this often.
const watch_retry_ns = 60 * ns_per_s;
const max_denied_listed = 100;

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("dirsized: " ++ fmt ++ "\n", args);
}

fn nowNs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * ns_per_s + ts.nsec;
}

// ---------------------------------------------------------------- pure decisions

/// What a query found. The tests drive `decide` with these, the daemon fills them from the table.
pub const Lookup = union(enum) {
    /// No root contains the path.
    outside,
    node: table_mod.State,
    /// Inside a root but without a node: excluded, not read yet, a file, or not there.
    missing: struct { excluded: bool, ancestor: table_mod.State },
};

/// The answer rules of ARCHITECTURE.md: `stale` turns only `ok` into `stale`; a value that is
/// still being read or is incomplete says so, whatever its age.
pub fn decide(l: Lookup, stale: bool) proto.State {
    return switch (l) {
        .outside => .none,
        .node => |s| switch (s) {
            .ok => if (stale) .stale else .ok,
            .scanning => .scanning,
            .partial => .partial,
        },
        .missing => |m| if (m.excluded) .excluded else if (m.ancestor == .scanning) .scanning else .none,
    };
}

/// Per-folder back-off for folders that keep changing: a small direct-mapped array, so its
/// memory does not depend on the table. A folder read again within twice its interval doubles
/// the interval (1 s up to 30 s); after a calm period it starts at 1 s again. A slot that is
/// taken by another folder is overwritten, which only forgets the back-off.
const Backoff = struct {
    const slots = 256;

    ids: [slots]NodeId = @splat(table_mod.none),
    last: [slots]i64 = @splat(0),
    interval: [slots]i64 = @splat(debounce_ns),

    fn slot(id: NodeId) usize {
        return (id *% 2654435761) >> 24; // the top 8 bits of a multiplicative hash
    }

    /// Null: read `id` now (this is recorded). Otherwise the time from which it may be read.
    fn admit(b: *Backoff, id: NodeId, now: i64) ?i64 {
        const i = slot(id);
        if (b.ids[i] == id) {
            const since = now - b.last[i];
            if (since < b.interval[i]) return b.last[i] + b.interval[i];
            b.interval[i] = if (since < 2 * b.interval[i]) @min(2 * b.interval[i], backoff_max_ns) else debounce_ns;
        } else {
            b.ids[i] = id;
            b.interval[i] = debounce_ns;
        }
        b.last[i] = now;
        return null;
    }

    fn reset(b: *Backoff) void {
        b.* = .{};
    }
};

/// A folder with a million files takes seconds of kernel time to read, and the kernel locks it
/// meanwhile. If it also changes often (a build's `target/debug/deps`), reading it again at the
/// debounce rate would burn a core and slow the build. So after a read that took T, the next
/// read of that folder must not start before 20 x T (at most 10 minutes) after the first one
/// ended. Only folders with T >= 50 ms get an entry; the array is fixed, and when it is full the
/// entry that expires first is replaced. The first read of a folder is never delayed: this
/// applies to the dirty list only, not to the initial scan or the verification.
const Slow = struct {
    const slots = 64;

    ids: [slots]NodeId = @splat(table_mod.none),
    /// Names the folder behind `ids[i]`: parent and name offset. A freed and reused id differs.
    ident: [slots]u64 = @splat(0),
    until: [slots]i64 = @splat(0),

    fn identOf(t: *const Table, id: NodeId) u64 {
        const nodes = t.image().nodes;
        if (id >= nodes.len) return 0;
        const n = nodes[id];
        return @as(u64, n.parent) << 32 | (n.name & ((1 << 29) - 1));
    }

    fn find(s: *const Slow, t: *const Table, id: NodeId) ?usize {
        const ident = identOf(t, id);
        for (s.ids, 0..) |x, i| if (x == id and s.ident[i] == ident) return i;
        return null;
    }

    /// A read of `id` took `took_ns` and has just ended at `now`.
    fn record(s: *Slow, t: *const Table, id: NodeId, took_ns: u64, now: i64) void {
        if (took_ns < slow_min_ns) {
            if (s.find(t, id)) |i| s.ids[i] = table_mod.none; // fast again
            return;
        }
        const wait: i64 = @intCast(@min(took_ns *| slow_factor, slow_max_ns));
        var at: usize = 0;
        if (s.find(t, id)) |i| {
            at = i;
        } else {
            // A free slot or an expired one first, else the entry that expires soonest.
            for (s.ids, 0..) |x, i| {
                if (x == table_mod.none or s.until[i] <= now) {
                    at = i;
                    break;
                }
                if (s.until[i] < s.until[at]) at = i;
            }
        }
        s.ids[at] = id;
        s.ident[at] = identOf(t, id);
        s.until[at] = now + wait;
    }

    /// Null: `id` may be read now. Otherwise the time from which it may be.
    /// An expired entry stays until `record` needs its slot.
    fn notBefore(s: *const Slow, t: *const Table, id: NodeId, now: i64) ?i64 {
        const i = s.find(t, id) orelse return null;
        return if (s.until[i] > now) s.until[i] else null;
    }

    fn reset(s: *Slow) void {
        s.* = .{};
    }
};

/// Both rules must agree, so the later time wins. A folder that the slow rule holds back is not
/// offered to the back-off, which would count it as read.
fn admitBoth(slow: *const Slow, backoff: *Backoff, t: *const Table, id: NodeId, now: i64) ?i64 {
    return slow.notBefore(t, id, now) orelse backoff.admit(id, now);
}

// ---------------------------------------------------------------- status

pub const StatusInfo = struct {
    pid: i32,
    state: proto.State,
    folders: usize,
    memory: usize,
    /// Resident memory of the whole process, as the OS counts it.
    rss: usize,
    queued: usize,
    /// Folders whose next read is held back by the slow-folder rule.
    slow: usize,
    events: u64,
    snapshot_age: ?u64,
    verify_age: ?u64,
    roots: []const table_mod.Root,
    /// Linux only: inotify watches in use and the user's limit.
    watches: ?usize = null,
    watch_limit: ?usize = null,
    /// The watcher could not start (an error name); sizes change only by the periodic verification.
    watch_error: ?[]const u8 = null,
    config_error: ?[]const u8,
    /// Unreadable folders, each followed by a NUL.
    denied: []const u8,
};

/// The keys in the order of the contract.
pub fn writeStatus(w: *Writer, s: StatusInfo) Writer.Error!void {
    var b: [24]u8 = undefined;
    try proto.writeKeyValue(w, "proto", std.fmt.bufPrint(&b, "{d}", .{proto.version}) catch unreachable);
    try proto.writeKeyValue(w, "version", version);
    try kvInt(w, "pid", s.pid);
    try proto.writeKeyValue(w, "state", @tagName(s.state));
    try kvInt(w, "folders", s.folders);
    try kvInt(w, "memory", s.memory);
    try kvInt(w, "rss", s.rss);
    try kvInt(w, "queued", s.queued);
    try kvInt(w, "slow", s.slow);
    try kvInt(w, "events", s.events);
    try kvAge(w, "snapshot_age", s.snapshot_age);
    try kvAge(w, "verify_age", s.verify_age);
    for (s.roots) |r| try proto.writeKeyValue(w, "root", r.path);
    if (s.watches) |n| try kvInt(w, "watches", n);
    if (s.watch_limit) |n| try kvInt(w, "watch_limit", n);
    if (s.watch_error) |e| try proto.writeKeyValue(w, "watch_error", e);
    if (s.config_error) |e| try proto.writeKeyValue(w, "config_error", e);
    var rest = s.denied;
    while (std.mem.indexOfScalar(u8, rest, 0)) |end| {
        try proto.writeKeyValue(w, "denied", rest[0..end]);
        rest = rest[end + 1 ..];
    }
    try proto.writeEnd(w);
}

fn kvInt(w: *Writer, key: []const u8, n: anytype) Writer.Error!void {
    var b: [24]u8 = undefined;
    try proto.writeKeyValue(w, key, std.fmt.bufPrint(&b, "{d}", .{n}) catch unreachable);
}

fn kvAge(w: *Writer, key: []const u8, age: ?u64) Writer.Error!void {
    if (age) |a| try kvInt(w, key, a) else try proto.writeKeyValue(w, key, "-");
}

/// Resident memory of this process in bytes; 0 when the OS does not say.
fn residentBytes() usize {
    switch (builtin.os.tag) {
        .macos => {
            // struct rusage_info_v0 (sys/resource.h): a uuid, then u64 counters; the 7th is
            // ri_resident_size.
            const RusageV0 = extern struct { uuid: [16]u8, ri: [10]u64 };
            var ru: RusageV0 = undefined;
            if (proc_pid_rusage(c.getpid(), 0, &ru) != 0) return 0; // RUSAGE_INFO_V0
            return @intCast(ru.ri[6]);
        },
        .linux => {
            // /proc/self/statm: size resident shared ... in pages.
            const fd = c.open("/proc/self/statm", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
            if (fd < 0) return 0;
            defer _ = c.close(fd);
            var buf: [128]u8 = undefined;
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) return 0;
            var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], ' ');
            _ = it.next() orelse return 0;
            const pages = std.fmt.parseInt(usize, std.mem.trim(u8, it.next() orelse return 0, "\n"), 10) catch return 0;
            return pages * std.heap.pageSize();
        },
        else => return 0,
    }
}

extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;

// ---------------------------------------------------------------- generations and config

/// What a config file says, after validation.
const Spec = struct {
    roots: [][]u8,
    rules: ignore.Rules,
    hash: u64,

    fn deinit(s: *Spec, gpa: Allocator) void {
        for (s.roots) |r| gpa.free(r);
        gpa.free(s.roots);
        s.rules.deinit(gpa);
    }
};

fn specHash(roots: []const []const u8, patterns: []const []const u8) u64 {
    var h: std.hash.Wyhash = .init(0);
    for (roots) |r| {
        h.update(std.mem.asBytes(&@as(u64, r.len)));
        h.update(r);
    }
    h.update("\x00exclude\x00");
    for (patterns) |p| {
        h.update(std.mem.asBytes(&@as(u64, p.len)));
        h.update(p);
    }
    return h.final();
}

fn rootIgnoreCase(r: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{r}, 0) catch return false;
    return scan.ignoreCase(z);
}

/// What the snapshot stores as its config hash: the spec hash plus each root's letter case, so a
/// snapshot made on a case-sensitive volume is not used on another kind.
fn snapshotHash(config_hash: u64, ignore_case: []const bool) u64 {
    var h: std.hash.Wyhash = .init(config_hash);
    h.update(std.mem.sliceAsBytes(ignore_case));
    return h.final();
}

/// A table with the rules and roots it was built from.
const Generation = struct {
    table: Table,
    rules: ignore.Rules,
    roots: [][]u8,
    /// One per root, same order as `table.roots()`.
    ignore_case: []bool,
    hash: u64,

    /// Takes over `spec` and `loaded` (a table from the snapshot) in every case.
    fn create(gpa: Allocator, spec: Spec, loaded: ?Table) !*Generation {
        const g = gpa.create(Generation) catch |e| {
            var s = spec;
            s.deinit(gpa);
            if (loaded) |t| {
                var tt = t;
                tt.deinit();
            }
            return e;
        };
        g.* = .{ .table = loaded orelse Table.init(gpa), .rules = spec.rules, .roots = spec.roots, .ignore_case = &.{}, .hash = spec.hash };
        errdefer g.destroy(gpa);
        if (loaded == null) {
            for (g.roots) |r| _ = try g.table.addRoot(r);
        }
        g.ignore_case = try gpa.alloc(bool, g.roots.len);
        for (g.roots, g.ignore_case) |r, *ic| ic.* = rootIgnoreCase(r);
        return g;
    }

    fn destroy(g: *Generation, gpa: Allocator) void {
        g.table.deinit();
        g.rules.deinit(gpa);
        for (g.roots) |r| gpa.free(r);
        gpa.free(g.roots);
        gpa.free(g.ignore_case);
        gpa.destroy(g);
    }

    /// Is `path` (no node, deepest existing ancestor `id`) inside an excluded folder?
    fn excludes(g: *const Generation, id: NodeId, path: []const u8) bool {
        if (g.rules.patterns.len == 0) return false;
        var top = id;
        while (g.table.parentOf(top) != table_mod.none) top = g.table.parentOf(top);
        const root = g.table.name(top);
        if (path.len < root.len) return false;
        const rel = std.mem.trimStart(u8, path[root.len..], "/");
        var ic = false;
        for (g.table.roots(), 0..) |r, i| {
            if (r.node == top) ic = g.ignore_case[i];
        }
        return g.rules.explain(rel, ic).excluded;
    }

    fn lookup(g: *const Generation, path: []const u8) struct { l: Lookup, id: NodeId } {
        const d = g.table.lookupDeepest(path) orelse return .{ .l = .outside, .id = table_mod.none };
        if (d.exact) return .{ .l = .{ .node = g.table.state(d.id) }, .id = d.id };
        return .{
            .l = .{ .missing = .{ .excluded = g.excludes(d.id, path), .ancestor = g.table.state(d.id) } },
            .id = table_mod.none,
        };
    }
};

/// Cheap change detector for the config file: a rewrite changes at least one of these.
const Stamp = struct {
    exists: bool = false,
    mtime_ns: i96 = 0,
    size: u64 = 0,
    inode: u64 = 0,

    fn of(io: std.Io, path: []const u8) Stamp {
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{};
        return .{ .exists = true, .mtime_ns = st.mtime.nanoseconds, .size = st.size, .inode = @intCast(st.inode) };
    }

    /// Old enough to be read. An mtime in the future (clock skew) counts as old, or the file
    /// would never be read.
    fn settled(s: Stamp, real_now_ns: i96) bool {
        if (!s.exists) return true;
        const age = real_now_ns - s.mtime_ns;
        return age < 0 or age >= config_settle_ns;
    }
};

fn realNs() i96 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    return @as(i96, ts.sec) * ns_per_s + ts.nsec;
}

// ---------------------------------------------------------------- signals

var signal_pipe: std.atomic.Value(c.fd_t) = .init(-1);
var signal_count: std.atomic.Value(u32) = .init(0);

fn onSignal(_: c.SIG) callconv(.c) void {
    // A second signal means the first shutdown is stuck (a hung file system): leave at once.
    if (signal_count.fetchAdd(1, .monotonic) >= 1) c._exit(1);
    const byte = [1]u8{2};
    _ = c.write(signal_pipe.load(.monotonic), &byte, 1);
}

fn installSignals(wake_w: c.fd_t) void {
    signal_pipe.store(wake_w, .monotonic);
    var act: c.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
    _ = c.sigaction(c.SIG.TERM, &act, null);
    _ = c.sigaction(c.SIG.INT, &act, null);
    _ = c.sigaction(c.SIG.HUP, &act, null); // a closed terminal or session: stop cleanly too
    var ign: c.Sigaction = .{ .handler = .{ .handler = c.SIG.IGN }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
    _ = c.sigaction(c.SIG.PIPE, &ign, null);
}

// ---------------------------------------------------------------- the daemon

/// What the loaded snapshot says besides the table.
const Boot = struct {
    watch_state: ?[]u8,
    verified_unix: i64,
    saved_unix: i64,
};

const Daemon = struct {
    gpa: Allocator,
    io: std.Io,
    home: []const u8,
    config_path: []const u8,
    scanner: Scanner,
    watcher: Watcher,
    server: Server,
    snapshot: snapshot_mod.Snapshot,
    wake_r: c.fd_t,
    wake_w: c.fd_t,

    live: *Generation,
    serving: *Generation,
    /// The watcher is running for `live`. When it could not start, events are missing and the
    /// verification scan is the safety net.
    watching: bool = false,
    /// Why the watcher could not start (an error name), for `status`; null while it runs.
    watch_error: ?[]const u8 = null,
    watch_retry_at: ?i64 = null,
    /// `live` came from a snapshot that is not confirmed yet.
    live_stale: bool = false,

    /// Folders flagged `recheck` that wait for the debounce. Deduplicated by the flag itself.
    dirty: std.ArrayList(NodeId) = .empty,
    backoff: Backoff = .{},
    slow: Slow = .{},
    flush_at: ?i64 = null,
    retry_at: ?i64 = null,
    /// The watcher fd is left out of the poll set until then (`watch_hold_ns`).
    watch_hold: i64 = 0,
    /// A flagged folder may be on no stack (allocation failure); repaired when the scanner is idle.
    recover: bool = false,
    /// `markAll` or `markSubtree` ran out of memory half way, so some folders are unflagged and
    /// `recoverLost` cannot find them: the next recovery flags every folder again.
    remark: bool = false,
    /// Reusable list for subtree walks.
    walk: std.ArrayList(NodeId) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    now: i64 = 0,
    started: i64 = 0,
    /// Every folder is being read for the first time in this run (no snapshot, or a snapshot
    /// with no event history to resume from). Its end counts as a verification and is saved.
    initial_scan: bool = false,
    save_after_scan: bool = false,
    needs_shrink: bool = false,
    verifying: bool = false,
    last_verify: ?i64 = null,
    /// When the snapshot on disk was written (its age is shown by `status`).
    last_save: ?i64 = null,
    /// The next periodic save; moved after every try, so a failing disk is not retried each tick.
    save_at: i64 = 0,
    /// From a snapshot loaded by `initDaemon`, consumed by `start`.
    boot: ?Boot = null,
    /// Counts reads that changed the table; `saved_changed` is its value at the last save.
    changed: u64 = 0,
    saved_changed: u64 = 0,
    events: u64 = 0,

    config_stamp: Stamp = .{},
    next_config_check: i64 = 0,
    config_error: ?[]u8 = null,

    // ---- start and stop

    fn start(d: *Daemon) void {
        d.started = nowNs();
        d.now = d.started;
        d.next_config_check = d.now + config_check_ns;
        d.save_at = d.now + save_every_ns;
        d.scanner.on_applied = .{ .ctx = d, .func = onApplied };
        const boot = d.boot;
        d.boot = null;
        d.startLive(boot);
        d.tick(); // hands the roots to the scanner; nothing else would wake the loop
    }

    fn deinit(d: *Daemon) void {
        d.scanner.deinit();
        d.watcher.deinit();
        if (d.serving != d.live) d.serving.destroy(d.gpa);
        d.live.destroy(d.gpa);
        d.server.deinit();
        d.dirty.deinit(d.gpa);
        d.walk.deinit(d.gpa);
        d.scratch.deinit(d.gpa);
        if (d.config_error) |e| d.gpa.free(e);
        if (d.boot) |b| if (b.watch_state) |w| d.gpa.free(w);
        _ = c.close(d.wake_r);
        _ = c.close(d.wake_w);
    }

    /// Runs on the owner thread after each applied read.
    fn onApplied(ctx: *anyopaque, table: *Table, id: NodeId, read: *const scan.FolderRead, changed: bool) void {
        const d: *Daemon = @ptrCast(@alignCast(ctx));
        // Only a real change earns a snapshot: re-reading unchanged folders (the daemon's own
        // snapshot write is an event in ~/.cache) must not schedule the next save.
        if (changed) d.changed += 1;
        d.slow.record(table, id, d.scanner.last_read_ns, nowNs());
        // Binds the watch the worker added to the node.
        if (is_linux) d.watcher.onApplied(table, id, read);
    }

    /// Makes `live` the generation the scanner and watcher work on. The watcher starts before
    /// any folder is read (DESIGN.md section 6), so nothing that changes in between is missed.
    fn startLive(d: *Daemon, boot: ?Boot) void {
        const g = d.live;
        d.dirty.clearRetainingCapacity();
        d.backoff.reset();
        d.slow.reset();
        d.flush_at = null;
        d.verifying = false;
        d.scanner.setLowPriority(false);
        d.scanner.case_by_root = g.ignore_case;
        d.needs_shrink = true;
        d.live_stale = boot != null;
        d.last_verify = null;
        // The aux array holds the watch numbers; a loaded table has none (it is not in the image).
        if (is_linux) g.table.enableAux() catch log("out of memory: watches cannot be tracked", .{});

        const result = d.startWatching(if (boot) |b| b.watch_state else null);
        // Workers add the inotify watch before they read, so the fd must exist before the first read.
        if (is_linux) d.scanner.read_opts = d.watcher.readOptions();
        if (boot) |b| {
            if (b.watch_state) |w| d.gpa.free(w);
            d.setTimesFromSnapshot(b);
            // `.fresh` after a snapshot: the values are believed current but every folder is owed a
            // read, at low priority (nobody waits for it: answers are `stale` meanwhile).
            // `.resumed`: only the events since the checkpoint, and folders that were flagged at save time.
            d.initial_scan = result == .fresh;
            if (result == .fresh) {
                d.verifying = true;
                d.scanner.setLowPriority(true);
                d.markAll();
            } else {
                d.recoverLost();
                d.recheckDenied();
            }
        } else {
            d.initial_scan = true;
            for (g.table.roots()) |r| d.scanner.enqueue(r.node) catch {
                d.recover = true;
            };
        }
        d.changed += 1;
    }

    /// Converts the wall-clock times of the snapshot to the monotonic clock. A time in the future
    /// (the clock went back) or never verified means the verification is due now.
    fn setTimesFromSnapshot(d: *Daemon, b: Boot) void {
        const wall = snapshot_mod.unixNow();
        if (b.saved_unix > 0) d.last_save = d.now - @max(wall - b.saved_unix, 0) * ns_per_s;
        const due = d.now - verify_every_ns;
        d.last_verify = if (b.verified_unix > 0 and b.verified_unix <= wall)
            @max(d.now - (wall - b.verified_unix) * ns_per_s, due)
        else
            due;
    }

    /// Wall-clock seconds of the last completed verification, 0 = never.
    fn verifiedUnix(d: *const Daemon) i64 {
        const lv = d.last_verify orelse return 0;
        return snapshot_mod.unixNow() - @divTrunc(@max(d.now - lv, 0), ns_per_s);
    }

    fn startWatching(d: *Daemon, saved: ?[]const u8) watch.StartResult {
        d.watching = false;
        d.watch_error = null;
        d.watch_retry_at = null;
        const result = d.watcher.start(d.live.roots, saved) catch |e| {
            log("cannot watch for changes ({t}); trying again every 60 s", .{e});
            d.watch_error = @errorName(e);
            d.watch_retry_at = d.now + watch_retry_ns;
            return .fresh;
        };
        d.watching = true;
        return result;
    }

    /// Without a watcher no event arrives and sizes would stay as they were until the weekly
    /// verification. When it starts at last, every folder is owed a read, as after `.fresh`.
    fn retryWatch(d: *Daemon) void {
        // The Linux workers read `read_opts` (the inotify fd) while they run.
        if (!d.scanner.isIdle()) {
            d.watch_retry_at = d.now + retry_ns;
            return;
        }
        _ = d.watcher.start(d.live.roots, null) catch |e| {
            d.watch_error = @errorName(e);
            d.watch_retry_at = d.now + watch_retry_ns;
            return;
        };
        log("watching for changes now", .{});
        d.watching = true;
        d.watch_error = null;
        d.watch_retry_at = null;
        if (is_linux) d.scanner.read_opts = d.watcher.readOptions();
        // A scan that is under way anyway (new config) reads everything at normal priority.
        if (!d.initial_scan) {
            d.verifying = true;
            d.scanner.setLowPriority(true);
        }
        d.markAll();
        d.pump();
    }

    /// Replaces the fresh table of `live` by the snapshot's, when there is a usable one.
    fn loadSnapshot(d: *Daemon) void {
        const g = d.live;
        if (g.roots.len == 0) return;
        const t0 = nowNs();
        const l = d.snapshot.load(d.gpa, snapshotHash(g.hash, g.ignore_case), g.roots) orelse return;
        g.table.deinit();
        g.table = l.table;
        d.boot = .{ .watch_state = l.watch_state, .verified_unix = l.verified_unix, .saved_unix = l.saved_unix };
        log("loaded {d} folders from the snapshot in {d} ms", .{ g.table.count(), @divTrunc(nowNs() - t0, 1_000_000) });
    }

    // ---- config

    const SpecResult = union(enum) { ok: Spec, bad: []u8 };

    /// Reads and checks the config file. `bad` holds the message (allocated with `gpa`).
    fn readSpec(d: *Daemon) Allocator.Error!SpecResult {
        const gpa = d.gpa;
        const cfg_path = d.config_path;
        const text = std.Io.Dir.cwd().readFileAlloc(d.io, cfg_path, gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => try gpa.dupe(u8, ""),
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .bad = try std.fmt.allocPrint(gpa, "cannot read {s}: {t}", .{ cfg_path, e }) },
        };
        defer gpa.free(text);
        var diag: config.Diag = .{};
        var cfg = config.Config.parse(gpa, text, &diag) catch |e| switch (e) {
            error.BadConfig => return .{ .bad = try badMessage(gpa, cfg_path, diag) },
            else => |oom| return oom,
        };
        defer cfg.deinit();
        var rules = config.compileRules(gpa, &cfg, &diag) catch |e| switch (e) {
            error.BadConfig => return .{ .bad = try badMessage(gpa, cfg_path, diag) },
            else => |oom| return oom,
        };
        const roots = config.resolveRoots(gpa, &cfg, d.home, &diag) catch |e| {
            rules.deinit(gpa);
            switch (e) {
                error.BadConfig => return .{ .bad = try badMessage(gpa, cfg_path, diag) },
                else => |oom| return oom,
            }
        };
        return .{ .ok = .{ .roots = roots, .rules = rules, .hash = specHash(roots, cfg.exclude) } };
    }

    fn badMessage(gpa: Allocator, path: []const u8, diag: config.Diag) Allocator.Error![]u8 {
        if (diag.line > 0) return std.fmt.allocPrint(gpa, "{s}:{d}: {s}", .{ path, diag.line, diag.message });
        return std.fmt.allocPrint(gpa, "{s}: {s}", .{ path, diag.message });
    }

    fn setConfigError(d: *Daemon, msg: ?[]u8) void {
        if (d.config_error) |old| d.gpa.free(old);
        d.config_error = msg;
    }

    /// Called from `tick`, at most once per second: has the config file changed? A bad file
    /// changes nothing but `config_error`; a good one with other content starts a new generation.
    /// A file that is being written is not read: its stamp must be old enough before the read
    /// and the same after it. Otherwise the next check tries again (an editor that truncates and
    /// then writes would give an empty config, a rescan, and another rescan).
    /// While `config_error` is set the file is read again even when it did not change: a root
    /// that did not exist (a disk not mounted yet) may exist now.
    fn reloadConfigIfChanged(d: *Daemon) void {
        if (d.now < d.next_config_check) return;
        d.next_config_check = d.now + config_check_ns;
        const stamp = Stamp.of(d.io, d.config_path);
        if (d.config_error == null and std.meta.eql(stamp, d.config_stamp)) return;
        if (!stamp.settled(realNs())) return;
        const spec = d.readSpec() catch {
            log("out of memory while reading the config; will try again", .{});
            return;
        };
        if (!std.meta.eql(Stamp.of(d.io, d.config_path), stamp)) {
            switch (spec) {
                .bad => |msg| d.gpa.free(msg),
                .ok => |s| {
                    var sp = s;
                    sp.deinit(d.gpa);
                },
            }
            return;
        }
        const old_stamp = d.config_stamp;
        d.config_stamp = stamp;
        switch (spec) {
            .bad => |msg| {
                if (d.config_error) |old| if (std.mem.eql(u8, old, msg)) {
                    d.gpa.free(msg); // the same problem again: nothing new to say
                    return;
                };
                log("config error, keeping the previous config: {s}", .{msg});
                d.setConfigError(msg);
            },
            .ok => |s| {
                d.setConfigError(null);
                if (s.hash == d.live.hash) {
                    var sp = s;
                    sp.deinit(d.gpa);
                    return;
                }
                d.switchGeneration(s) catch |e| {
                    log("cannot start the new config ({t}); keeping the previous one", .{e});
                    d.config_stamp = old_stamp;
                };
            },
        }
    }

    /// Builds the new generation first (the only step that can fail), then switches. The old
    /// live generation keeps serving, frozen, until the new one is complete. A generation that
    /// was live but never served (a second config change during the first scan) is dropped.
    fn switchGeneration(d: *Daemon, spec: Spec) !void {
        const g = try Generation.create(d.gpa, spec, null);
        d.scanner.discard();
        d.watcher.stop();
        if (d.serving != d.live) d.live.destroy(d.gpa);
        d.live = g;
        log("config changed: scanning {d} root(s)", .{g.roots.len});
        d.startLive(null);
        d.tick();
    }

    // ---- the loop

    fn run(d: *Daemon) void {
        var fds: [2 + Server.max_fds]c.pollfd = undefined;
        while (signal_count.load(.monotonic) == 0) {
            const n = d.server.fillPoll(fds[2..], d.now);
            fds[0] = .{ .fd = d.wake_r, .events = c.POLL.IN, .revents = 0 };
            fds[1] = .{ .fd = if (d.now < d.watch_hold) -1 else d.watcher.pollFd(), .events = c.POLL.IN, .revents = 0 };
            const rc = c.poll(&fds, @intCast(2 + n), d.pollTimeout());
            d.now = nowNs();
            if (rc < 0) {
                if (c.errno(rc) != .INTR) log("poll failed: {t}", .{c.errno(rc)});
                continue;
            }
            // Queries first: their latency must not depend on what else woke us.
            if (rc > 0) d.server.service(fds[2 .. 2 + n], d.now, d);
            // Busy clients must not starve the timers: poll only reports 0 when nothing else is ready.
            if (rc == 0 or fds[0].revents != 0 or fds[1].revents != 0 or d.timerDue()) {
                if (fds[0].revents != 0) d.drainWakePipe();
                d.tick();
            }
        }
    }

    fn wake(d: *const Daemon) void {
        _ = c.write(d.wake_w, &[1]u8{1}, 1); // a full pipe already means "wake up"
    }

    fn drainWakePipe(d: *Daemon) void {
        var buf: [256]u8 = undefined;
        while (c.read(d.wake_r, &buf, buf.len) == buf.len) {}
    }

    /// When the earliest armed timer is due, or null for none.
    fn nextDeadline(d: *const Daemon) ?i64 {
        var next: ?i64 = null;
        const arm = struct {
            fn at(n: *?i64, t: i64) void {
                n.* = if (n.*) |x| @min(x, t) else t;
            }
        }.at;
        if (d.dirty.items.len > 0) if (d.flush_at) |t| arm(&next, t);
        if (d.retry_at) |t| arm(&next, t);
        if (d.changed != d.saved_changed) arm(&next, d.save_at);
        if (d.verifyDue()) |t| arm(&next, t);
        if (d.watch_retry_at) |t| arm(&next, t);
        if (d.config_error != null) arm(&next, d.next_config_check);
        if (d.now < d.watch_hold) arm(&next, d.watch_hold);
        if (d.server.accept_resume) |t| arm(&next, t);
        return next;
    }

    /// A timer has passed its deadline as of `now` (the clock read of this loop turn).
    fn timerDue(d: *const Daemon) bool {
        const at = d.nextDeadline() orelse return false;
        return at <= d.now;
    }

    /// Milliseconds until the next armed timer, or -1 for none.
    fn pollTimeout(d: *const Daemon) c_int {
        const at = d.nextDeadline() orelse return -1;
        const ms = @divTrunc(@max(at - d.now, 0) + 999_999, 1_000_000);
        return @intCast(@min(ms, std.math.maxInt(c_int)));
    }

    fn verifyDue(d: *const Daemon) ?i64 {
        if (d.verifying or d.serving != d.live) return null;
        return (d.last_verify orelse return null) + verify_every_ns;
    }

    /// Everything that follows from "something may have happened": events, results, timers.
    fn tick(d: *Daemon) void {
        d.now = nowNs();
        if (d.retry_at) |t| if (d.now >= t) {
            d.retry_at = null;
        };
        d.drainChanges();
        if (d.flush_at) |t| if (d.now >= t) d.flushDirty();
        d.pump();
        d.quiescent();
        d.timers();
    }

    /// Linux needs the table: it clears watch numbers on `IN_IGNORED` and skips freed nodes.
    fn drainChanges(d: *Daemon) void {
        const events = d.events;
        const r = if (is_linux) d.watcher.drain(&d.live.table, d) else d.watcher.drain(d);
        if (is_linux and d.events != events and !d.watcher.saturated) d.watch_hold = d.now + watch_hold_ns;
        r catch |e| {
            log("cannot read change events: {t}", .{e});
            d.retry_at = d.now + retry_ns;
        };
    }

    fn pump(d: *Daemon) void {
        // After an error, wait: a folder that fails every time (a name the table cannot hold)
        // would otherwise be read again at once, forever.
        if (d.retry_at) |t| if (d.now < t) return;
        d.scanner.pump(&d.live.table, &d.live.rules) catch |e| {
            log("scan problem ({t}); will retry", .{e});
            d.recover = true;
            d.retry_at = d.now + retry_ns;
        };
        d.afterPump();
    }

    /// Linux: `release` right after EVERY pump (it removes the watches of freed nodes before a
    /// node id can be reused), then `drain`: a result applied just now can owe a re-read.
    fn afterPump(d: *Daemon) void {
        if (!is_linux) return;
        d.watcher.release(&d.live.table);
        d.drainChanges();
    }

    /// What may only happen when the scanner has nothing left. Dirty folders do not hold back
    /// the first part: a folder that changes all the time waits up to 30 s in `dirty`, and the
    /// new config must not wait for it.
    fn quiescent(d: *Daemon) void {
        if (!d.scanner.isIdle()) return;
        if (d.recover and d.dirty.items.len == 0) {
            d.recover = false;
            if (d.remark) {
                d.remark = false;
                d.markAll(); // flags and queues everything; sets `remark` again if it fails
            } else d.recoverLost();
            d.pump();
            if (!d.scanner.isIdle()) return;
        }
        if (d.serving != d.live) {
            d.serving.destroy(d.gpa);
            d.serving = d.live;
            log("new config is ready", .{});
        }
        if (is_linux) d.watcher.quiet();
        if (d.initial_scan) {
            d.initial_scan = false;
            d.last_verify = d.now; // a complete scan is a verification
            d.save_after_scan = true; // so a crash soon after does not lose the scan
        }
        if (d.verifying) {
            d.verifying = false;
            d.scanner.setLowPriority(false);
            d.last_verify = d.now;
            d.save_after_scan = true; // `verified_unix` on disk must move, or every restart verifies again
            log("verification scan finished", .{});
        }
        if (d.live_stale and d.watcher.caughtUp()) d.live_stale = false;
        if (d.dirty.items.len == 0) {
            d.watcher.checkpoint();
            if (d.needs_shrink) {
                d.live.table.shrinkToFit();
                d.needs_shrink = false;
            }
        }
        if (d.save_after_scan) {
            d.save_after_scan = false;
            d.save(false);
        }
    }

    fn timers(d: *Daemon) void {
        d.reloadConfigIfChanged();
        if (d.watch_retry_at) |t| if (d.now >= t) d.retryWatch();
        if (d.changed != d.saved_changed and d.now >= d.save_at) d.save(false);
        if (d.verifyDue()) |t| if (d.now >= t) {
            log("starting the verification scan", .{});
            d.verifying = true;
            d.scanner.setLowPriority(true);
            d.markAll();
            d.pump();
        };
    }

    /// Any moment between pumps is consistent (only this thread touches the table). The watcher
    /// blob is the last checkpoint, never newer than the table.
    fn save(d: *Daemon, announce: bool) void {
        d.save_at = d.now + save_every_ns;
        if (d.live.roots.len == 0) return; // a bad config: nothing worth keeping
        const t0 = nowNs();
        const size = d.snapshot.save(.{
            .gpa = d.gpa,
            .table = &d.live.table,
            .watcher = &d.watcher,
            .config_hash = snapshotHash(d.live.hash, d.live.ignore_case),
            .verified_unix = d.verifiedUnix(),
        }) orelse return; // logged; the old file stays and the next try is in 5 minutes
        d.saved_changed = d.changed;
        d.last_save = d.now;
        if (announce) log("saved the snapshot: {d} folders, {d} bytes, {d} ms", .{ d.live.table.count(), size, @divTrunc(nowNs() - t0, 1_000_000) });
    }

    // ---- changes

    /// Called by the watcher for each change (never fails: an allocation problem sets `recover`).
    pub fn onChange(d: *Daemon, ch: watch.Change) !void {
        d.events += 1;
        const t = &d.live.table;
        switch (ch) {
            .everything => for (t.roots()) |r| d.markSubtree(r.node),
            .node => |id| d.markOne(id),
            .path => |p| {
                const dp = t.lookupDeepest(p.path) orelse {
                    // Above the roots (`/`, `/Users`): a subtree change there reaches the roots below it.
                    if (p.subtree) for (t.roots()) |r| if (config.isInside(r.path, p.path)) d.markSubtree(r.node);
                    return;
                };
                // An excluded folder has no node; the deepest node is then its parent.
                if (!dp.exact and d.live.excludes(dp.id, p.path)) return;
                // A path without a node is new: its parent finds it when it is read.
                if (p.subtree and dp.exact) d.markSubtree(dp.id) else d.markOne(dp.id);
            },
        }
    }

    fn markOne(d: *Daemon, id: NodeId) void {
        if (!d.live.table.markRecheck(id)) return;
        d.dirty.append(d.gpa, id) catch {
            d.recover = true;
            return;
        };
        // A folder that waits for a back-off must not hold up a new one.
        const due = if (d.live_stale) d.now else d.now + debounce_ns;
        d.flush_at = if (d.flush_at) |f| @min(f, due) else due;
    }

    fn markSubtree(d: *Daemon, top: NodeId) void {
        const t = &d.live.table;
        d.walk.clearRetainingCapacity();
        d.walk.append(d.gpa, top) catch {
            d.recover = true;
            d.remark = true;
            return;
        };
        while (d.walk.pop()) |n| {
            d.markOne(n);
            var it = t.children(n);
            while (it.next()) |ch| d.walk.append(d.gpa, ch) catch {
                // The rest of this subtree is not flagged: a full re-mark is owed.
                d.recover = true;
                d.remark = true;
                return;
            };
        }
    }

    /// Hands the dirty folders to the scanner, except those that are backing off.
    fn flushDirty(d: *Daemon) void {
        const t = &d.live.table;
        var keep: usize = 0;
        var earliest: ?i64 = null;
        for (d.dirty.items) |id| {
            if (!t.needsRead(id)) continue; // read meanwhile, or gone
            if (!d.live_stale) if (admitBoth(&d.slow, &d.backoff, t, id, d.now)) |at| {
                d.dirty.items[keep] = id;
                keep += 1;
                earliest = if (earliest) |e| @min(e, at) else at;
                continue;
            };
            d.scanner.enqueue(id) catch {
                d.recover = true;
            };
        }
        d.dirty.items.len = keep;
        d.flush_at = earliest;
    }

    /// Flags and queues every folder of `live`.
    fn markAll(d: *Daemon) void {
        const t = &d.live.table;
        const nodes = t.image().nodes;
        for (nodes, 0..) |n, i| {
            if (n.parent == table_mod.free_mark) continue;
            const id: NodeId = @intCast(i);
            _ = t.markRecheck(id);
            d.scanner.enqueue(id) catch {
                d.recover = true;
                d.remark = true;
                return;
            };
        }
    }

    /// A folder denied before the stop may be readable now (a new permission), and no event says
    /// so. Flags it like an event does; if it still fails, it stays denied.
    fn recheckDenied(d: *Daemon) void {
        var q: struct {
            d: *Daemon,
            fn visit(self: *@This(), id: NodeId) bool {
                self.d.markOne(id);
                return true;
            }
        } = .{ .d = d };
        d.walkDenied(d.live, &q);
    }

    /// After an allocation failure a flagged folder can be on no stack: queue every folder that
    /// still owes a read.
    fn recoverLost(d: *Daemon) void {
        const t = &d.live.table;
        for (t.image().nodes, 0..) |n, i| {
            if (n.parent == table_mod.free_mark) continue;
            const id: NodeId = @intCast(i);
            if (!t.needsRead(id)) continue;
            d.scanner.enqueue(id) catch {
                d.recover = true;
                return;
            };
        }
    }

    // ---- queries

    fn isStale(d: *const Daemon) bool {
        return d.serving != d.live or d.live_stale;
    }

    /// Called by the server for each request. The `size` path is a table lookup and one write.
    pub fn handle(d: *Daemon, req: proto.Request, out: *Writer) Writer.Error!void {
        // Reading the file and switching generations can take long: not in a query.
        if (d.now >= d.next_config_check) d.wake();
        const g = d.serving;
        const stale = d.isStale();
        switch (req.verb) {
            .size => {
                const r = g.lookup(req.path);
                const bytes = if (r.id != table_mod.none) g.table.total(r.id) else 0;
                try proto.writeRecord(out, bytes, decide(r.l, stale), req.path);
                try proto.writeEnd(out);
            },
            .list => {
                const r = g.lookup(req.path);
                const bytes = if (r.id != table_mod.none) g.table.total(r.id) else 0;
                try proto.writeRecord(out, bytes, decide(r.l, stale), ".");
                if (r.id != table_mod.none) {
                    var it = g.table.children(r.id);
                    while (it.next()) |ch| {
                        try proto.writeRecord(out, g.table.total(ch), decide(.{ .node = g.table.state(ch) }, stale), g.table.name(ch));
                    }
                }
                try proto.writeEnd(out);
            },
            .status => try d.status(out),
        }
    }

    fn status(d: *Daemon, out: *Writer) Writer.Error!void {
        const g = d.serving;
        var worst: table_mod.State = .ok;
        for (g.table.roots()) |r| switch (g.table.state(r.node)) {
            .scanning => worst = .scanning,
            .partial => if (worst == .ok) {
                worst = .partial;
            },
            .ok => {},
        };
        // A bad config (or none that works, so no roots) is not "ok", whatever the table says.
        if (d.config_error != null and worst == .ok) worst = .partial;
        d.scratch.clearRetainingCapacity();
        d.collectDenied(g);
        try writeStatus(out, .{
            .pid = c.getpid(),
            .state = decide(.{ .node = worst }, d.isStale()),
            .folders = g.table.count(),
            .memory = g.table.memoryBytes(),
            .rss = residentBytes(),
            .queued = d.scanner.stack.items.len + d.scanner.in_flight + d.dirty.items.len,
            .slow = d.slowCount(),
            .events = d.events,
            .snapshot_age = ageOf(d.now, d.last_save),
            .verify_age = ageOf(d.now, d.last_verify),
            .roots = g.table.roots(),
            .watches = if (is_linux) d.watcher.watchCount() else null,
            .watch_limit = if (is_linux) Watcher.watchLimit() else null,
            .watch_error = d.watch_error,
            .config_error = d.config_error,
            .denied = d.scratch.items,
        });
    }

    /// Dirty folders that the slow-folder rule holds back right now.
    fn slowCount(d: *const Daemon) usize {
        const t = &d.live.table;
        var n: usize = 0;
        for (d.dirty.items) |id| {
            if (t.needsRead(id) and d.slow.notBefore(t, id, d.now) != null) n += 1;
        }
        return n;
    }

    /// Fills `scratch` with the paths of folders that could not be read, each followed by NUL.
    fn collectDenied(d: *Daemon, g: *const Generation) void {
        var lister: struct {
            d: *Daemon,
            g: *const Generation,
            listed: usize = 0,
            fn visit(self: *@This(), id: NodeId) bool {
                self.g.table.pathOf(id, &self.d.scratch, self.d.gpa) catch return false;
                self.d.scratch.append(self.d.gpa, 0) catch return false;
                self.listed += 1;
                return self.listed < max_denied_listed;
            }
        } = .{ .d = d, .g = g };
        d.walkDenied(g, &lister);
    }

    /// Calls `ctx.visit(id)` for each denied folder until it returns false. Uses `d.walk`, so
    /// `visit` must not. The walk descends only where the O(1) `state` says something is wrong,
    /// so the cost follows the denied folders, not the table.
    fn walkDenied(d: *Daemon, g: *const Generation, ctx: anytype) void {
        d.walk.clearRetainingCapacity();
        for (g.table.roots()) |r| d.walk.append(d.gpa, r.node) catch return;
        while (d.walk.pop()) |n| {
            if (g.table.isDenied(n) and !ctx.visit(n)) return;
            var it = g.table.children(n);
            while (it.next()) |ch| {
                if (g.table.state(ch) != .ok) d.walk.append(d.gpa, ch) catch return;
            }
        }
    }
};

fn ageOf(now: i64, then: ?i64) ?u64 {
    const t = then orelse return null;
    return @intCast(@max(@divTrunc(now - t, ns_per_s), 0));
}

// ---------------------------------------------------------------- entry

fn takeLock(path: []const u8) !c.fd_t {
    var z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= z.len) return error.NameTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = c.open(@ptrCast(&z), .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.LockFile;
    if (c.flock(fd, c.LOCK.EX | c.LOCK.NB) != 0) {
        _ = c.close(fd);
        return if (c.errno(-1) == .AGAIN) error.AlreadyRunning else error.LockFile;
    }
    return fd;
}

/// Exit code: 0 after SIGTERM/SIGINT/SIGHUP, 2 when another daemon runs or the setup is wrong.
pub fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const home = init.environ_map.get("HOME") orelse "";
    if (home.len == 0) {
        log("HOME is not set", .{});
        return 2;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = paths.Paths.init(arena.allocator(), home, init.environ_map.get("XDG_RUNTIME_DIR"), init.environ_map.get("XDG_CACHE_HOME")) catch |e| {
        log("cannot decide where to put the socket: {t}", .{e});
        return 2;
    };
    paths.ensureDirs(&p) catch |e| {
        log("cannot create {s}: {t}", .{ p.cache_dir, e });
        return 2;
    };
    const config_path = config.defaultPath(arena.allocator(), home) catch |e| {
        log("cannot decide where the config is: {t}", .{e});
        return 2;
    };
    const lock_fd = takeLock(p.lock) catch |e| switch (e) {
        error.AlreadyRunning => {
            log("another daemon is running", .{});
            return 2;
        },
        else => {
            log("cannot lock {s}: {t}", .{ p.lock, e });
            return 2;
        },
    };
    defer _ = c.close(lock_fd);

    var d: Daemon = undefined;
    initDaemon(&d, gpa, init.io, home, &p, config_path) catch |e| {
        log("cannot start: {t}", .{e});
        return 2;
    };
    installSignals(d.wake_w);
    d.start();
    log("running, pid {d}, socket {s}", .{ c.getpid(), p.socket });
    d.run();
    log("stopping", .{});
    d.server.removeSocketFile(); // clients see "no daemon" while the rest is torn down
    // Also without a change: the watcher checkpoint may have moved.
    if (d.changed != d.saved_changed or !d.initial_scan) d.save(true);
    d.deinit();
    return 0;
}

fn emptySpec(gpa: Allocator) !Spec {
    var bad: ?u32 = null;
    return .{ .roots = try gpa.alloc([]u8, 0), .rules = try ignore.Rules.compile(gpa, &.{}, &bad), .hash = 0 };
}

/// Sets up everything that can fail. The first generation comes from the config; a bad config
/// file gives an empty generation and `config_error`, so the daemon runs and a later fix is
/// picked up like any other change.
fn initDaemon(d: *Daemon, gpa: Allocator, io: std.Io, home: []const u8, p: *const paths.Paths, config_path: []const u8) !void {
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.Pipe;
    errdefer {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
    }
    try server_mod.setNonBlockingCloexec(pipe_fds[0]);
    try server_mod.setNonBlockingCloexec(pipe_fds[1]);

    var srv = try Server.listen(gpa, p.socket);
    errdefer srv.deinit();
    var sc = try Scanner.init(gpa, io, scanner_mod.defaultThreads());
    errdefer sc.deinit();
    sc.setWakeFd(pipe_fds[1]);
    var wt = try Watcher.init(gpa, pipe_fds[1]);
    errdefer wt.deinit();

    d.* = .{
        .gpa = gpa,
        .io = io,
        .home = home,
        .config_path = config_path,
        .scanner = sc,
        .watcher = wt,
        .server = srv,
        .snapshot = .{ .path = p.snapshot },
        .wake_r = pipe_fds[0],
        .wake_w = pipe_fds[1],
        .live = undefined,
        .serving = undefined,
    };
    d.config_stamp = Stamp.of(d.io, d.config_path);
    const spec: Spec = switch (try d.readSpec()) {
        .ok => |s| s,
        .bad => |msg| blk: {
            log("config error: {s}", .{msg});
            d.config_error = msg;
            break :blk try emptySpec(gpa);
        },
    };
    d.live = try Generation.create(gpa, spec, null);
    d.serving = d.live;
    d.loadSnapshot();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "decide: the answer-state rules" {
    const S = table_mod.State;
    try testing.expectEqual(proto.State.none, decide(.outside, false));
    try testing.expectEqual(proto.State.none, decide(.outside, true));
    try testing.expectEqual(proto.State.ok, decide(.{ .node = S.ok }, false));
    try testing.expectEqual(proto.State.stale, decide(.{ .node = S.ok }, true));
    try testing.expectEqual(proto.State.scanning, decide(.{ .node = S.scanning }, true));
    try testing.expectEqual(proto.State.partial, decide(.{ .node = S.partial }, true));
    try testing.expectEqual(proto.State.excluded, decide(.{ .missing = .{ .excluded = true, .ancestor = S.scanning } }, false));
    try testing.expectEqual(proto.State.scanning, decide(.{ .missing = .{ .excluded = false, .ancestor = S.scanning } }, false));
    try testing.expectEqual(proto.State.none, decide(.{ .missing = .{ .excluded = false, .ancestor = S.ok } }, false));
    try testing.expectEqual(proto.State.none, decide(.{ .missing = .{ .excluded = false, .ancestor = S.partial } }, true));
}

test "backoff: a busy folder waits 1, 2, 4 ... 30 s; a calm one starts over" {
    var b: Backoff = .{};
    var now: i64 = 100 * ns_per_s;
    // First flush at once.
    try testing.expectEqual(@as(?i64, null), b.admit(7, now));
    var at = now;
    // Offer the folder every second for a few minutes; record when it is let through.
    var gaps: [8]i64 = undefined;
    var n: usize = 0;
    var t: i64 = 1;
    while (t <= 200 and n < gaps.len) : (t += 1) {
        const tt = now + t * ns_per_s;
        if (b.admit(7, tt) == null) {
            gaps[n] = @divTrunc(tt - at, ns_per_s);
            n += 1;
            at = tt;
        }
    }
    try testing.expectEqualSlices(i64, &.{ 1, 2, 4, 8, 16, 30, 30, 30 }, &gaps);
    // Left alone for much longer than twice the interval, it is let through at the 1 s level again.
    now = at + 200 * ns_per_s;
    try testing.expectEqual(@as(?i64, null), b.admit(7, now));
    try testing.expectEqual(@as(?i64, now + debounce_ns), b.admit(7, now + ns_per_s / 2));
    try testing.expectEqual(@as(?i64, null), b.admit(7, now + ns_per_s));
}

test "backoff: the time returned is when the folder may go" {
    var b: Backoff = .{};
    const t0: i64 = 5 * ns_per_s;
    try testing.expectEqual(@as(?i64, null), b.admit(3, t0));
    try testing.expectEqual(@as(?i64, null), b.admit(3, t0 + ns_per_s)); // within 2 x 1 s: interval 2 s
    try testing.expectEqual(@as(?i64, t0 + 3 * ns_per_s), b.admit(3, t0 + 2 * ns_per_s));
}

test "backoff: a slot shared by two folders forgets, never grows" {
    var b: Backoff = .{};
    // Two ids with the same slot.
    var other: NodeId = 8;
    while (Backoff.slot(other) != Backoff.slot(7)) other += 1;
    try testing.expectEqual(@as(?i64, null), b.admit(7, 0));
    try testing.expectEqual(@as(?i64, null), b.admit(other, ns_per_s / 10)); // takes the slot over
    try testing.expectEqual(@as(?i64, null), b.admit(7, ns_per_s / 5)); // forgotten: let through
}

test "status: exact keys and order" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    const roots = [_]table_mod.Root{ .{ .path = "/a", .node = 0 }, .{ .path = "/b c", .node = 1 } };
    try writeStatus(&w, .{
        .pid = 42,
        .state = .scanning,
        .folders = 10,
        .memory = 4096,
        .rss = 8192,
        .queued = 3,
        .slow = 2,
        .events = 7,
        .snapshot_age = null,
        .verify_age = 12,
        .roots = &roots,
        .watch_error = "SystemResources",
        .config_error = "x:1: bad",
        .denied = "/a/d1\x00/a/d2\x00",
    });
    const want = "proto\t1\x00" ++ "version\t" ++ version ++ "\x00" ++ "pid\t42\x00" ++ "state\tscanning\x00" ++
        "folders\t10\x00" ++ "memory\t4096\x00" ++ "rss\t8192\x00" ++ "queued\t3\x00" ++ "slow\t2\x00" ++ "events\t7\x00" ++
        "snapshot_age\t-\x00" ++ "verify_age\t12\x00" ++ "root\t/a\x00" ++ "root\t/b c\x00" ++
        "watch_error\tSystemResources\x00" ++ "config_error\tx:1: bad\x00" ++ "denied\t/a/d1\x00" ++ "denied\t/a/d2\x00" ++ "\x00";
    try testing.expectEqualStrings(want, w.buffered());
}

test "status: optional keys are left out" {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeStatus(&w, .{ .pid = 1, .state = .ok, .folders = 0, .memory = 0, .rss = 0, .queued = 0, .slow = 0, .events = 0, .snapshot_age = 5, .verify_age = null, .roots = &.{}, .config_error = null, .denied = "" });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "config_error") == null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "watch_error") == null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "denied") == null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "snapshot_age\t5\x00verify_age\t-\x00") != null);
}

test "config stamp: a file written in the last 200 ms is not settled" {
    const t0: i96 = 1000 * ns_per_s;
    const s: Stamp = .{ .exists = true, .mtime_ns = t0, .size = 5, .inode = 9 };
    try testing.expect(!s.settled(t0));
    try testing.expect(!s.settled(t0 + config_settle_ns - 1));
    try testing.expect(s.settled(t0 + config_settle_ns));
    try testing.expect(s.settled(t0 - ns_per_s)); // mtime in the future: do not wait forever
    try testing.expect((Stamp{}).settled(t0)); // no file: nothing is being written
}

test "spec hash depends on roots and patterns, with boundaries" {
    const a = specHash(&.{"/a"}, &.{"x"});
    try testing.expectEqual(a, specHash(&.{"/a"}, &.{"x"}));
    try testing.expect(a != specHash(&.{"/b"}, &.{"x"}));
    try testing.expect(a != specHash(&.{"/a"}, &.{"y"}));
    try testing.expect(specHash(&.{ "/a", "/b" }, &.{}) != specHash(&.{"/a/b"}, &.{}));
    try testing.expect(specHash(&.{"/a"}, &.{ "x", "y" }) != specHash(&.{"/a"}, &.{"xy"}));
}

fn slowTable(gpa: Allocator, names: []const []const u8) !Table {
    var t = Table.init(gpa);
    errdefer t.deinit();
    var fresh: std.ArrayList(NodeId) = .empty;
    defer fresh.deinit(gpa);
    const r = try t.addRoot("/r");
    _ = try t.applyRead(r, 0, names, &fresh, gpa);
    return t;
}

test "slow rule: next read waits 20 x T after the previous one, capped at 10 minutes" {
    var t = try slowTable(testing.allocator, &.{ "big", "small" });
    defer t.deinit();
    const big = t.lookup("/r/big").?;
    const ms: i64 = ns_per_s / 1000;
    var s: Slow = .{};
    const t0: i64 = 1000 * ns_per_s;
    // Never read slowly: no entry, never delayed.
    try testing.expectEqual(@as(?i64, null), s.notBefore(&t, big, t0));
    // 49 ms is not slow; 50 ms is.
    s.record(&t, big, 49 * @as(u64, @intCast(ms)), t0);
    try testing.expectEqual(@as(?i64, null), s.notBefore(&t, big, t0));
    s.record(&t, big, 50 * @as(u64, @intCast(ms)), t0);
    try testing.expectEqual(@as(?i64, t0 + 1 * ns_per_s), s.notBefore(&t, big, t0 + 1));
    try testing.expectEqual(@as(?i64, null), s.notBefore(&t, big, t0 + 1 * ns_per_s)); // allowed again, entry expired
    // 3 s read: 60 s. 13 s read: 260 s. 40 s read: 800 s, capped to 600 s.
    s.record(&t, big, 3 * ns_per_s, t0);
    try testing.expectEqual(@as(?i64, t0 + 60 * ns_per_s), s.notBefore(&t, big, t0 + 5 * ns_per_s));
    s.record(&t, big, 13 * ns_per_s, t0);
    try testing.expectEqual(@as(?i64, t0 + 260 * ns_per_s), s.notBefore(&t, big, t0 + 5 * ns_per_s));
    s.record(&t, big, 40 * ns_per_s, t0);
    try testing.expectEqual(@as(?i64, t0 + 600 * ns_per_s), s.notBefore(&t, big, t0 + 5 * ns_per_s));
    // A fast read (the folder shrank) removes the delay.
    s.record(&t, big, ms, t0 + 100 * ns_per_s);
    try testing.expectEqual(@as(?i64, null), s.notBefore(&t, big, t0 + 101 * ns_per_s));
}

test "slow rule: a freed and reused id is not delayed; a full array replaces the entry that expires first" {
    var t = try slowTable(testing.allocator, &.{"big"});
    defer t.deinit();
    var s: Slow = .{};
    const big = t.lookup("/r/big").?;
    s.record(&t, big, ns_per_s, 0);
    try testing.expect(s.notBefore(&t, big, 1) != null);
    var fresh: std.ArrayList(NodeId) = .empty;
    defer fresh.deinit(testing.allocator);
    _ = try t.applyRead(t.lookup("/r").?, 0, &.{}, &fresh, testing.allocator); // big is gone
    _ = try t.applyRead(t.lookup("/r").?, 0, &.{"other"}, &fresh, testing.allocator); // its id is reused
    const other = t.lookup("/r/other").?;
    try testing.expectEqual(big, other);
    try testing.expectEqual(@as(?i64, null), s.notBefore(&t, other, 1));

    // Fixed size: more slow folders than slots keep the array at 64 entries; the ones that
    // expire last survive.
    var big_t = try slowTable(testing.allocator, &.{});
    defer big_t.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    var bufs: [70][4]u8 = undefined;
    for (&bufs, 0..) |*b, i| {
        b.* = .{ 'd', @intCast('a' + i / 26), @intCast('a' + i % 26), 0 };
        try names.append(testing.allocator, b[0..3]);
    }
    _ = try big_t.applyRead(big_t.lookup("/r").?, 0, names.items, &fresh, testing.allocator);
    var ids: [70]NodeId = undefined;
    for (names.items, 0..) |n, i| {
        var pbuf: [16]u8 = undefined;
        ids[i] = big_t.lookup(try std.fmt.bufPrint(&pbuf, "/r/{s}", .{n})).?;
        // Entry i expires at (i + 1) s.
        s.record(&big_t, ids[i], @intCast((i + 1) * 1000 * 1000 * 1000 / 20), 0);
    }
    var live: usize = 0;
    for (s.ids) |x| live += @intFromBool(x != table_mod.none);
    try testing.expectEqual(@as(usize, 64), live);
    // The last one, which expires latest, is held; the first ones were replaced.
    try testing.expect(s.notBefore(&big_t, ids[69], 0) != null);
    try testing.expectEqual(@as(?i64, null), s.notBefore(&big_t, ids[0], 0));
}

test "slow rule and back-off: the later of the two times wins" {
    var t = try slowTable(testing.allocator, &.{"big"});
    defer t.deinit();
    const big = t.lookup("/r/big").?;
    var s: Slow = .{};
    var b: Backoff = .{};
    const t0: i64 = 100 * ns_per_s;
    // First read at t0 (back-off records it), which took 2 s: slow until t0 + 2 + 40 s.
    try testing.expectEqual(@as(?i64, null), admitBoth(&s, &b, &t, big, t0));
    s.record(&t, big, 2 * ns_per_s, t0 + 2 * ns_per_s);
    // At t0 + 3 s the back-off alone would say "go" (it only asks 1-2 s); the slow rule says 42 s.
    try testing.expectEqual(@as(?i64, t0 + 42 * ns_per_s), admitBoth(&s, &b, &t, big, t0 + 3 * ns_per_s));
    // At t0 + 42 s the slow rule is satisfied and the back-off lets it through.
    try testing.expectEqual(@as(?i64, null), admitBoth(&s, &b, &t, big, t0 + 42 * ns_per_s));
    // Back-off the other way: a fast folder that keeps changing is held by the back-off only.
    var t2 = try slowTable(testing.allocator, &.{"x"});
    defer t2.deinit();
    const x = t2.lookup("/r/x").?;
    var s2: Slow = .{};
    var b2: Backoff = .{};
    try testing.expectEqual(@as(?i64, null), admitBoth(&s2, &b2, &t2, x, t0));
    try testing.expectEqual(@as(?i64, null), admitBoth(&s2, &b2, &t2, x, t0 + ns_per_s));
    try testing.expectEqual(@as(?i64, t0 + 3 * ns_per_s), admitBoth(&s2, &b2, &t2, x, t0 + 2 * ns_per_s));
}

test "recheckDenied: flags and queues the denied folders, nothing else" {
    const ta = testing.allocator;
    var t = try slowTable(ta, &.{ "a", "b" });
    const b = t.lookup("/r/b").?;
    var fresh: std.ArrayList(NodeId) = .empty;
    defer fresh.deinit(ta);
    _ = try t.applyRead(t.lookup("/r/a").?, 0, &.{}, &fresh, ta); // new folders start `pending`
    _ = try t.applyDenied(b);
    var g: Generation = undefined;
    g.table = t;
    defer g.table.deinit();
    var d: Daemon = undefined;
    d.gpa = ta;
    d.live = &g;
    d.walk = .empty;
    d.dirty = .empty;
    d.flush_at = null;
    d.live_stale = true;
    d.recover = false;
    d.now = 0;
    defer d.walk.deinit(ta);
    defer d.dirty.deinit(ta);

    d.recheckDenied();
    try testing.expectEqualSlices(NodeId, &.{b}, d.dirty.items);
    try testing.expect(g.table.needsRead(b));
    try testing.expect(!g.table.needsRead(g.table.lookup("/r/a").?));
    try testing.expect(!g.table.needsRead(g.table.lookup("/r").?));
    try testing.expect(g.table.isDenied(b)); // the flag goes only when a read succeeds
    try testing.expect(d.flush_at != null);
}
