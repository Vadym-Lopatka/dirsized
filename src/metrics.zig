//! The optional metrics log (DESIGN.md section 13.6). Off unless the config says `metrics = true`.
//!
//! One JSON object per line, appended to `<cache>/metrics.log`. Once a minute the daemon writes a
//! `sample` line (CPU, memory, requests, loop times, scan work) and after it the slowest requests
//! and folder reads of that minute. Nothing leaves the computer.
//!
//! Everything here has a fixed size: a request costs two clock reads and a few additions, and no
//! allocation. At 4 MiB the file is renamed to `metrics.log.1`, so at most 8 MiB stay on disk.
//! Every duration is in nanoseconds and every size in bytes; the key says so (`_ns`), or is a count.

const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;
const c = std.c;
const proto = @import("proto.zig");

const ns_per_s = std.time.ns_per_s;
pub const interval_ns: i64 = 60 * ns_per_s;
const max_file: u64 = 4 << 20;
/// A path of PATH_MAX bytes where every byte needs six (`\u00XX`), plus the other keys.
const max_line = 6 * std.fs.max_path_bytes + 512;

/// Durations in power-of-two buckets: bucket i holds the values with i significant bits. A
/// quantile is the upper bound of its bucket, so it can be up to 2 x too high. The maximum is exact.
pub const Hist = struct {
    buckets: [65]u32 = @splat(0),
    count: u64 = 0,
    max: u64 = 0,

    pub fn add(h: *Hist, ns: u64) void {
        h.buckets[64 - @as(usize, @clz(ns))] +|= 1;
        h.count += 1;
        h.max = @max(h.max, ns);
    }

    /// The duration that `permille` of the entries do not exceed; 0 when there are none.
    pub fn quantile(h: *const Hist, permille: u64) u64 {
        const want = @max((h.count * permille + 999) / 1000, 1);
        var seen: u64 = 0;
        for (h.buckets, 0..) |n, i| {
            seen += n;
            if (seen >= want) return if (i >= 64) h.max else @min(h.max, (@as(u64, 1) << @intCast(i)) - 1);
        }
        return 0;
    }
};

/// The slowest few of a window with their paths, slowest first.
pub const Top = struct {
    pub const n = 3;

    pub const Entry = struct {
        ns: u64 = 0,
        bytes: u64 = 0,
        verb: []const u8 = "",
        len: usize = 0,
        buf: [std.fs.max_path_bytes]u8 = undefined,

        pub fn path(e: *const Entry) []const u8 {
            return e.buf[0..e.len];
        }
    };

    e: [n]Entry = @splat(.{}),

    /// Would `ns` be kept? The caller can then skip the work of finding the path.
    pub fn takes(t: *const Top, ns: u64) bool {
        return ns > t.e[n - 1].ns;
    }

    pub fn put(t: *Top, ns: u64, verb: []const u8, bytes: u64, path: []const u8) void {
        if (!t.takes(ns)) return;
        var i: usize = n - 1;
        while (i > 0 and t.e[i - 1].ns < ns) : (i -= 1) {
            const from = &t.e[i - 1];
            set(&t.e[i], from.ns, from.verb, from.bytes, from.path());
        }
        set(&t.e[i], ns, verb, bytes, path);
    }

    /// Copies the path bytes only, not the whole buffer: this runs for requests.
    fn set(e: *Entry, ns: u64, verb: []const u8, bytes: u64, path: []const u8) void {
        e.ns = ns;
        e.bytes = bytes;
        e.verb = verb;
        e.len = @min(path.len, e.buf.len);
        @memcpy(e.buf[0..e.len], path[0..e.len]);
    }
};

/// What the daemon knows at the moment of a sample.
pub const Gauges = struct {
    uptime_ns: i64,
    state: proto.State,
    watching: bool,
    config_ok: bool,
    folders: usize,
    table_bytes: usize,
    rss: usize,
    queued: usize,
    clients: usize,
    /// Change events since the daemon started; the sample shows the difference.
    events: u64,
};

/// Processor time and peak memory of the whole process, worker threads included.
const Cpu = struct {
    user_ns: u64 = 0,
    sys_ns: u64 = 0,
    rss_max: u64 = 0,

    fn now() Cpu {
        var ru: c.rusage = undefined;
        if (c.getrusage(c.rusage.SELF, &ru) != 0) return .{};
        // ru_maxrss is in bytes on macOS and in kilobytes on Linux.
        const unit: u64 = if (builtin.os.tag == .macos) 1 else 1024;
        return .{ .user_ns = tvNs(ru.utime), .sys_ns = tvNs(ru.stime), .rss_max = @as(u64, @intCast(@max(ru.maxrss, 0))) * unit };
    }

    fn tvNs(t: c.timeval) u64 {
        return @as(u64, @intCast(t.sec)) * ns_per_s + @as(u64, @intCast(t.usec)) * 1000;
    }
};

/// What is counted between two samples.
const Window = struct {
    wakeups: u64 = 0,
    busy_ns: u64 = 0,
    loop_max_ns: u64 = 0,
    /// Indexed by `proto.Verb`.
    verbs: [3]u64 = @splat(0),
    out_bytes: u64 = 0,
    req: Hist = .{},
    slow_req: Top = .{},
    reads: u64 = 0,
    read_ns: u64 = 0,
    slow_read: Top = .{},
};

pub const Metrics = struct {
    /// -1: off. Every counting function may be called anyway; the daemon checks `on` first
    /// only to save the clock reads.
    fd: c.fd_t = -1,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    file_size: u64 = 0,
    window_start: i64 = 0,
    /// The daemon's loop must wake up at this time while the metrics are on.
    sample_at: i64 = 0,
    cpu_last: Cpu = .{},
    events_last: u64 = 0,
    w: Window = .{},

    pub fn setPath(m: *Metrics, path: []const u8) error{NameTooLong}!void {
        if (path.len + 2 >= m.path_buf.len) return error.NameTooLong; // room for ".1" in `rotate`
        @memcpy(m.path_buf[0..path.len], path);
        m.path_buf[path.len] = 0;
        m.path_len = path.len;
    }

    pub fn on(m: *const Metrics) bool {
        return m.fd >= 0;
    }

    /// Opens the file and writes the `start` line. False: the file cannot be opened.
    pub fn enable(m: *Metrics, now: i64, version: []const u8, events: u64) bool {
        if (m.on()) return true;
        m.open();
        if (!m.on()) return false;
        m.w = .{};
        m.window_start = now;
        m.sample_at = now + interval_ns;
        m.cpu_last = .now();
        m.events_last = events;
        var buf: [256]u8 = undefined;
        var w: Writer = .fixed(&buf);
        writeStart(&w, unixNow(), version) catch return true;
        m.append(w.buffered());
        return true;
    }

    /// Writes the `stop` line and closes the file. The caller writes a last sample before, if it wants one.
    pub fn disable(m: *Metrics) void {
        if (!m.on()) return;
        var buf: [128]u8 = undefined;
        var w: Writer = .fixed(&buf);
        if (writeHead(&w, unixNow(), "stop")) |_| {
            if (w.writeAll("}\n")) |_| m.append(w.buffered()) else |_| {}
        } else |_| {}
        if (m.fd >= 0) _ = c.close(m.fd);
        m.fd = -1;
    }

    /// One answered request: the time inside the handler and the bytes of the answer.
    pub fn request(m: *Metrics, verb: proto.Verb, path: []const u8, ns: u64, bytes: u64) void {
        m.w.verbs[@intFromEnum(verb)] += 1;
        m.w.out_bytes += bytes;
        m.w.req.add(ns);
        m.w.slow_req.put(ns, @tagName(verb), bytes, path);
    }

    /// One folder read by a worker. True: it is one of the slowest, so `slowRead` wants its path.
    pub fn read(m: *Metrics, ns: u64) bool {
        m.w.reads += 1;
        m.w.read_ns += ns;
        return m.w.slow_read.takes(ns);
    }

    pub fn slowRead(m: *Metrics, ns: u64, path: []const u8) void {
        m.w.slow_read.put(ns, "", 0, path);
    }

    /// One turn of the daemon's loop took `ns` from the wake-up to the next `poll`. A query that
    /// arrives during a turn waits for its end, so the longest turn is the worst added latency.
    pub fn loopTurn(m: *Metrics, ns: u64) void {
        m.w.wakeups += 1;
        m.w.busy_ns += ns;
        m.w.loop_max_ns = @max(m.w.loop_max_ns, ns);
    }

    /// Writes the sample of the window that ends now, then its slowest requests and reads.
    pub fn sample(m: *Metrics, now: i64, g: Gauges) void {
        const cpu: Cpu = .now();
        const unix = unixNow();
        var buf: [max_line]u8 = undefined;
        var w: Writer = .fixed(&buf);
        if (writeSample(&w, unix, m, now, cpu, g)) |_| m.append(w.buffered()) else |_| {}
        for ([_]*const Top{ &m.w.slow_req, &m.w.slow_read }, [_][]const u8{ "request", "read" }) |top, ev| {
            for (&top.e) |*e| {
                if (e.ns == 0) break;
                w = .fixed(&buf);
                if (writeSlow(&w, unix, ev, e)) |_| m.append(w.buffered()) else |_| {}
            }
        }
        m.w = .{};
        m.window_start = now;
        m.sample_at = now + interval_ns;
        m.cpu_last = cpu;
        m.events_last = g.events;
    }

    fn pathZ(m: *const Metrics) [*:0]const u8 {
        return @ptrCast(&m.path_buf);
    }

    fn open(m: *Metrics) void {
        if (m.path_len == 0) return;
        const fd = c.open(m.pathZ(), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return;
        const end = c.lseek(fd, 0, c.SEEK.END);
        m.file_size = if (end > 0) @intCast(end) else 0;
        m.fd = fd;
    }

    /// `metrics.log` becomes `metrics.log.1` (the old `.1` is replaced) and a new file starts.
    /// The metrics never go off here and the size limit holds: if the rename or the new file
    /// fails, the open file is emptied and used again.
    fn rotate(m: *Metrics) void {
        var old: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(old[0..m.path_len], m.path_buf[0..m.path_len]);
        @memcpy(old[m.path_len..][0..3], ".1\x00");
        const full = m.fd;
        if (c.rename(m.pathZ(), @ptrCast(&old)) == 0) {
            m.fd = -1;
            m.open();
            if (m.on()) {
                _ = c.close(full);
                return;
            }
            m.fd = full;
        }
        _ = c.ftruncate(full, 0);
        m.file_size = 0;
    }

    /// One whole line per `write`. A full disk loses the line; the next one tries again.
    fn append(m: *Metrics, line: []const u8) void {
        if (!m.on()) return;
        if (m.file_size + line.len > max_file) {
            // The count is ours; the file is the truth (somebody may have emptied it).
            const end = c.lseek(m.fd, 0, c.SEEK.END);
            if (end >= 0) m.file_size = @intCast(end);
            if (m.file_size + line.len > max_file) m.rotate();
        }
        const n = c.write(m.fd, line.ptr, line.len);
        if (n > 0) m.file_size += @intCast(n);
    }
};

fn unixNow() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// `{"t":"2026-10-06T10:00:00Z","ev":"sample"`: the start of every line. The time is UTC.
fn writeHead(w: *Writer, unix: i64, ev: []const u8) Writer.Error!void {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{{\"t\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\",\"ev\":\"{s}\"", .{
        yd.year,              md.month.numeric(),      @as(u8, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        ev,
    });
}

fn writeStart(w: *Writer, unix: i64, version: []const u8) Writer.Error!void {
    try writeHead(w, unix, "start");
    try w.print(",\"version\":\"{s}\",\"pid\":{d},\"os\":\"{t}\",\"interval_s\":{d}}}\n", .{
        version, c.getpid(), builtin.os.tag, @divTrunc(interval_ns, ns_per_s),
    });
}

fn writeSample(w: *Writer, unix: i64, m: *const Metrics, now: i64, cpu: Cpu, g: Gauges) Writer.Error!void {
    const win = &m.w;
    const window: u64 = @intCast(@max(now - m.window_start, 1));
    const user = cpu.user_ns -| m.cpu_last.user_ns;
    const sys = cpu.sys_ns -| m.cpu_last.sys_ns;
    const pct = @as(f64, @floatFromInt(user + sys)) * 100 / @as(f64, @floatFromInt(window));
    try writeHead(w, unix, "sample");
    try w.print(",\"window_s\":{d},\"uptime_s\":{d},\"state\":\"{t}\",\"watching\":{},\"config_ok\":{}", .{
        (window + ns_per_s / 2) / ns_per_s, @divTrunc(@max(g.uptime_ns, 0), ns_per_s), g.state, g.watching, g.config_ok,
    });
    // One core that is busy all the time is 100.
    try w.print(",\"cpu_pct\":{d:.2},\"cpu_user_ns\":{d},\"cpu_sys_ns\":{d}", .{ pct, user, sys });
    try w.print(",\"rss\":{d},\"rss_max\":{d},\"table\":{d},\"folders\":{d}", .{ g.rss, cpu.rss_max, g.table_bytes, g.folders });
    try w.print(",\"requests\":{d},\"size\":{d},\"list\":{d},\"status\":{d}", .{
        win.req.count,
        win.verbs[@intFromEnum(proto.Verb.size)],
        win.verbs[@intFromEnum(proto.Verb.list)],
        win.verbs[@intFromEnum(proto.Verb.status)],
    });
    try w.print(",\"req_p50_ns\":{d},\"req_p99_ns\":{d},\"req_max_ns\":{d},\"out_bytes\":{d}", .{
        win.req.quantile(500), win.req.quantile(990), win.req.max, win.out_bytes,
    });
    try w.print(",\"events\":{d},\"reads\":{d},\"read_ns\":{d},\"read_max_ns\":{d},\"queued\":{d},\"clients\":{d}", .{
        g.events -| m.events_last, win.reads, win.read_ns, win.slow_read.e[0].ns, g.queued, g.clients,
    });
    try w.print(",\"wakeups\":{d},\"busy_ns\":{d},\"loop_max_ns\":{d}}}\n", .{ win.wakeups, win.busy_ns, win.loop_max_ns });
}

/// A `request` line has the verb and the size of the answer; a `read` line has only the time.
fn writeSlow(w: *Writer, unix: i64, ev: []const u8, e: *const Top.Entry) Writer.Error!void {
    try writeHead(w, unix, ev);
    try w.print(",\"ns\":{d}", .{e.ns});
    if (e.verb.len > 0) try w.print(",\"verb\":\"{s}\",\"out_bytes\":{d}", .{ e.verb, e.bytes });
    try w.writeAll(",\"path\":");
    try proto.writeJsonString(w, e.path());
    try w.writeAll("}\n");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "hist: quantiles are bucket bounds, never above the maximum" {
    var h: Hist = .{};
    try testing.expectEqual(@as(u64, 0), h.quantile(500));
    for (0..98) |_| h.add(1000); // 10 bits: the bucket ends at 1023
    h.add(5000);
    h.add(1_000_000);
    try testing.expectEqual(@as(u64, 1023), h.quantile(500));
    try testing.expectEqual(@as(u64, 8191), h.quantile(990));
    try testing.expectEqual(@as(u64, 1_000_000), h.quantile(1000));
    try testing.expectEqual(@as(u64, 1_000_000), h.max);
    var one: Hist = .{};
    one.add(700);
    try testing.expectEqual(@as(u64, 700), one.quantile(500));
    one.add(0);
    one.add(std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, 0), one.quantile(1));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), one.quantile(1000));
}

test "top: keeps the three slowest, slowest first" {
    var t: Top = .{};
    for ([_]u64{ 5, 9, 1, 7, 3, 9 }, [_][]const u8{ "/e", "/a", "/x", "/c", "/y", "/b" }) |ns, p| {
        if (t.takes(ns)) t.put(ns, "size", ns * 2, p);
    }
    try testing.expectEqualStrings("/a", t.e[0].path());
    try testing.expectEqualStrings("/b", t.e[1].path()); // a tie keeps the first one first
    try testing.expectEqualStrings("/c", t.e[2].path());
    try testing.expectEqual(@as(u64, 14), t.e[2].bytes);
    try testing.expect(!t.takes(7));
    try testing.expect(!(Top{}).takes(0));
}

test "head: the time is UTC in ISO 8601" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeHead(&w, 1_700_000_000, "x");
    try testing.expectEqualStrings("{\"t\":\"2023-11-14T22:13:20Z\",\"ev\":\"x\"", w.buffered());
    w = .fixed(&buf);
    try writeHead(&w, 951_868_799, "x"); // the last second of a 29 February
    try testing.expectEqualStrings("{\"t\":\"2000-02-29T23:59:59Z\",\"ev\":\"x\"", w.buffered());
}

fn testGauges(events: u64) Gauges {
    return .{ .uptime_ns = 90 * ns_per_s, .state = .ok, .watching = true, .config_ok = true, .folders = 7, .table_bytes = 378, .rss = 1 << 20, .queued = 2, .clients = 1, .events = events };
}

test "the file: start, sample, slowest lines and stop are JSON lines; off writes nothing" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    var m: Metrics = .{};
    // Off: counting is harmless and nothing is written.
    m.request(.size, "/a", 10, 5);
    m.sample(0, testGauges(0));
    try m.setPath(try std.fmt.bufPrint(&path_buf, "{s}/metrics.log", .{dir}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "metrics.log", .{}));

    try testing.expect(m.enable(1000, "9.9.9", 40));
    try testing.expectEqual(@as(i64, 1000 + interval_ns), m.sample_at);
    m.request(.size, "/a", 800, 12);
    m.request(.list, "/odd \"\n\xff name", 90_000, 4096);
    m.request(.status, "", 3000, 300);
    try testing.expect(m.read(2_000_000));
    m.slowRead(2_000_000, "/big");
    m.loopTurn(50_000);
    m.loopTurn(20_000);
    const end = 1000 + 60 * ns_per_s;
    m.sample(end, testGauges(45));
    try testing.expectEqual(end + interval_ns, m.sample_at);
    try testing.expectEqual(@as(u64, 0), m.w.req.count); // a new window
    m.disable();
    try testing.expect(!m.on());

    const text = try tmp.dir.readFileAlloc(testing.io, "metrics.log", gpa, .limited(1 << 20));
    defer gpa.free(text);
    try testing.expectEqual(@as(u64, text.len), m.file_size);
    var evs: std.ArrayList(u8) = .empty;
    defer evs.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const v = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer v.deinit();
        const o = v.value.object;
        const ev = o.get("ev").?.string;
        try evs.appendSlice(gpa, ev);
        try evs.append(gpa, ' ');
        try testing.expectEqual(@as(usize, 20), o.get("t").?.string.len);
        if (std.mem.eql(u8, ev, "start")) try testing.expectEqualStrings("9.9.9", o.get("version").?.string);
        if (std.mem.eql(u8, ev, "sample")) {
            try testing.expectEqual(@as(i64, 60), o.get("window_s").?.integer);
            try testing.expectEqual(@as(i64, 90), o.get("uptime_s").?.integer);
            try testing.expectEqualStrings("ok", o.get("state").?.string);
            try testing.expectEqual(@as(i64, 3), o.get("requests").?.integer);
            try testing.expectEqual(@as(i64, 1), o.get("list").?.integer);
            try testing.expectEqual(@as(i64, 90_000), o.get("req_max_ns").?.integer);
            try testing.expectEqual(@as(i64, 4095), o.get("req_p50_ns").?.integer);
            try testing.expectEqual(@as(i64, 4408), o.get("out_bytes").?.integer);
            try testing.expectEqual(@as(i64, 5), o.get("events").?.integer);
            try testing.expectEqual(@as(i64, 1), o.get("reads").?.integer);
            try testing.expectEqual(@as(i64, 2_000_000), o.get("read_max_ns").?.integer);
            try testing.expectEqual(@as(i64, 2), o.get("wakeups").?.integer);
            try testing.expectEqual(@as(i64, 70_000), o.get("busy_ns").?.integer);
            try testing.expectEqual(@as(i64, 50_000), o.get("loop_max_ns").?.integer);
            try testing.expect(o.get("cpu_pct") != null and o.get("rss_max") != null);
        }
        if (std.mem.eql(u8, ev, "request") and o.get("ns").?.integer == 90_000) {
            try testing.expectEqualStrings("list", o.get("verb").?.string);
            try testing.expectEqualStrings("/odd \"\n\u{ff} name", o.get("path").?.string);
            try testing.expectEqual(@as(i64, 4096), o.get("out_bytes").?.integer);
        }
        if (std.mem.eql(u8, ev, "read")) try testing.expectEqualStrings("/big", o.get("path").?.string);
    }
    try testing.expectEqualStrings("start sample request request request read stop ", evs.items);
}

test "the file is renamed at the size limit and a new one starts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var m: Metrics = .{};
    try m.setPath(try std.fmt.bufPrint(&path_buf, "{s}/metrics.log", .{dir}));
    try testing.expect(m.enable(0, "v", 0));
    const first = m.file_size;
    // A count that is too high is corrected from the file: no rename yet.
    m.file_size = max_file - 1;
    m.sample(1, testGauges(0));
    try testing.expect(m.file_size > first and m.file_size < 2048);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "metrics.log.1", .{}));
    // A file that is really full is renamed.
    try testing.expectEqual(@as(c_int, 0), c.ftruncate(m.fd, max_file - 1));
    m.file_size = max_file - 1;
    m.sample(2, testGauges(0));
    try testing.expect(m.file_size < 1024);
    try testing.expectEqual(max_file - 1, (try tmp.dir.statFile(testing.io, "metrics.log.1", .{})).size);
    // The rename cannot work (the target is a folder with something in it): the file is
    // emptied instead, so it stays below the limit and the metrics stay on.
    try tmp.dir.deleteFile(testing.io, "metrics.log.1");
    try tmp.dir.createDir(testing.io, "metrics.log.1", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "metrics.log.1/x", .data = "x" });
    try testing.expectEqual(@as(c_int, 0), c.ftruncate(m.fd, max_file - 1));
    m.file_size = max_file - 1;
    m.sample(3, testGauges(0));
    try testing.expect(m.on() and m.file_size < 1024);
    try testing.expectEqual(m.file_size, (try tmp.dir.statFile(testing.io, "metrics.log", .{})).size);
    m.disable();
    try tmp.dir.deleteFile(testing.io, "metrics.log.1/x");
    try tmp.dir.deleteDir(testing.io, "metrics.log.1");
    // A second start appends to the file that is there.
    try testing.expect(m.enable(0, "v", 0));
    try testing.expect(m.file_size > first);
    m.disable();
}
