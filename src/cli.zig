//! Argument parsing, output formats and exit codes.
//!
//! Size and list queries go through one function, `answer`, with two back ends: the daemon
//! (one connection, all paths pipelined) and `--scan` (reads the disk, only when no daemon
//! runs). Everything after `answer` is shared.

const std = @import("std");
const Allocator = std.mem.Allocator;
const libc = std.c;
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const ignore = @import("ignore.zig");
const paths = @import("paths.zig");
const proto = @import("proto.zig");
const scan = @import("scan.zig");
const scanner = @import("scanner.zig");
const server = @import("server.zig");
const Table = @import("table.zig").Table;

const version = "dirsized " ++ daemon.version;

const help_text =
    \\dirsized: the size of every folder
    \\
    \\Usage:
    \\  dirsized [OPTIONS] [PATH...]   size of each PATH (default ".")
    \\  dirsized -l [OPTIONS] [PATH]   child folders of PATH, largest first
    \\  dirsized status [--json]       state of the daemon, as key: value lines
    \\  dirsized check [PATH]          check the config file; tell if PATH is counted
    \\  dirsized daemon                run the daemon in the foreground
    \\
    \\Options:
    \\  -l          list the child folders of PATH (at most one PATH)
    \\  -n N        keep only the first N records (after sorting, with -l)
    \\  -h          sizes as K, M, G, T (1024-based, like ls -h)
    \\  -0          end each record with NUL instead of newline
    \\  --json      one JSON array of {"path","bytes","state"}; bytes are never -h
    \\  --scan      if no daemon runs: read the disk now
    \\  -?, --help  this text
    \\  --version   print the version
    \\  --          end of options (a PATH may start with "-")
    \\
    \\Output: BYTES<TAB>STATE<TAB>PATH, one line per record. BYTES is the sum of the
    \\file lengths below the folder (like ls -l). Symlinks and other volumes are skipped.
    \\STATE: ok, scanning, partial, stale, excluded, none (not a folder).
    \\Paths are absolute and real. In JSON, bytes that are not UTF-8 appear as \u00XX.
    \\Use -0 for lossless paths.
    \\
    \\The first word that is not an option may name a command. A folder called
    \\status, check or daemon is written ./status.
    \\
    \\The daemon keeps all sizes in memory and follows the disk. Its config file is
    \\~/.config/dirsized/config.toml (see "check").
    \\
    \\Exit: 0 all ok; 1 a path is missing, not a folder, excluded or outside the roots;
    \\2 bad usage or config (also internal errors); 3 daemon not running;
    \\4 a value is not final (scanning, partial, stale). If several apply: 2, 3, 1, 4.
    \\
    \\Examples:
    \\  dirsized -lh ~/prog              what is big under ~/prog?
    \\  dirsized status                  is the daemon done scanning?
    \\  dirsized -ln 5 -0 .              the 5 largest child folders, NUL-separated
    \\  dirsized check ~/prog/app        is this folder counted, and why?
    \\
;

const Command = enum { size, status, check, daemon };
const Action = enum { run, help, version };

pub const Options = struct {
    action: Action = .run,
    command: Command = .size,
    list: bool = false,
    human: bool = false,
    json: bool = false,
    nul: bool = false,
    scan: bool = false,
    limit: ?usize = null,
    paths: []const []const u8 = &.{},
};

/// The one-line reason for a usage error; the text lives in the struct itself.
pub const Usage = struct {
    buf: [160]u8 = undefined,
    msg: []const u8 = "",

    fn set(self: *Usage, comptime fmt: []const u8, args: anytype) error{Usage} {
        self.msg = std.fmt.bufPrint(&self.buf, fmt, args) catch &self.buf;
        return error.Usage;
    }
};

/// `args` excludes argv[0]. `--help` and `--version` stop parsing at once, so they win over
/// anything after them. Paths are returned as given; the default "." is added by the caller.
pub fn parse(arena: Allocator, args: []const []const u8, usage: *Usage) error{ Usage, OutOfMemory }!Options {
    var o: Options = .{};
    var words: std.ArrayList([]const u8) = .empty;
    var options_done = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (options_done or a.len < 2 or a[0] != '-') {
            try words.append(arena, a);
        } else if (std.mem.eql(u8, a, "--")) {
            options_done = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            if (std.mem.eql(u8, a, "--scan")) o.scan = true //
            else if (std.mem.eql(u8, a, "--json")) o.json = true //
            else if (std.mem.eql(u8, a, "--help")) return .{ .action = .help } //
            else if (std.mem.eql(u8, a, "--version")) return .{ .action = .version } //
            else return usage.set("unknown option {s}", .{a});
        } else {
            var j: usize = 1;
            while (j < a.len) : (j += 1) switch (a[j]) {
                'l' => o.list = true,
                'h' => o.human = true,
                '0' => o.nul = true,
                '?' => return .{ .action = .help },
                'n' => {
                    // `-n5`, `-hn5` and `-n 5` all work, as in ordinary tools.
                    const value = if (j + 1 < a.len) a[j + 1 ..] else if (i + 1 < args.len) blk: {
                        i += 1;
                        break :blk args[i];
                    } else return usage.set("option -n needs a number", .{});
                    o.limit = std.fmt.parseInt(usize, value, 10) catch
                        return usage.set("option -n needs a whole number, got \"{s}\"", .{value});
                    break;
                },
                else => return usage.set("unknown option -{c}", .{a[j]}),
            };
        }
    }

    var rest = words.items;
    if (rest.len > 0) for ([_]Command{ .status, .check, .daemon }) |c| {
        if (std.mem.eql(u8, rest[0], @tagName(c))) {
            o.command = c;
            rest = rest[1..];
            break;
        }
    };
    if (o.command != .size) {
        const json_ok = o.command == .status;
        if (o.list or o.human or (o.json and !json_ok) or o.nul or o.limit != null)
            return usage.set("{t} takes no output options", .{o.command});
        if (rest.len > @as(usize, if (o.command == .check) 1 else 0))
            return usage.set("{t} takes {s}", .{ o.command, if (o.command == .check) "at most one PATH" else "no PATH" });
    }
    if (o.json and o.nul) return usage.set("--json and -0 cannot be used together", .{});
    if (o.list and rest.len > 1) return usage.set("-l takes at most one PATH", .{});
    o.paths = rest;
    return o;
}

// ---- records and output ----------------------------------------------------------------

pub const State = proto.State;

pub const Record = struct { path: []const u8, bytes: u64, state: State };

/// What a back end returns. `asked` holds the state of every PATH the user named, whether
/// or not its record is shown: `-l` shows children, but the exit code depends on the folder
/// itself, and `-n` must not hide an unfinished value.
const Answer = struct { records: []Record, asked: []const State };

/// Largest first; equal sizes by path bytes, so the order never depends on the disk.
fn bySize(_: void, a: Record, b: Record) bool {
    if (a.bytes != b.bytes) return a.bytes > b.bytes;
    return std.mem.lessThan(u8, a.path, b.path);
}

/// `-l` sorts. `-n` then keeps the first N: after sorting with -l, in the order given without.
fn shape(records: []Record, list: bool, limit: ?usize) []Record {
    if (list) std.mem.sort(Record, records, {}, bySize);
    return records[0..@min(limit orelse records.len, records.len)];
}

/// 2 and 3 never reach here: they stop the run before any output. Then 1 beats 4 beats 0,
/// so a script that sees 4 knows every path exists.
fn exitCode(asked: []const State) u8 {
    var code: u8 = 0;
    for (asked) |s| switch (s) {
        .none, .excluded => return 1,
        .scanning, .partial, .stale => code = 4,
        .ok => {},
    };
    return code;
}

/// Like `ls -h` of GNU coreutils: 1024-based, rounded up, one decimal below 10.
fn humanSize(buf: *[8]u8, n: u64) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
    const units = "KMGTPE";
    var unit: u7 = 10;
    var u: usize = 0;
    while (true) : ({
        unit += 10;
        u += 1;
    }) {
        const div = @as(u128, 1) << unit;
        const tenths: u128 = (@as(u128, n) * 10 + div - 1) / div;
        if (tenths < 100) return std.fmt.bufPrint(buf, "{d}.{d}{c}", .{ tenths / 10, tenths % 10, units[u] }) catch unreachable;
        const whole = (tenths + 9) / 10;
        if (whole < 1024 or u == units.len - 1)
            return std.fmt.bufPrint(buf, "{d}{c}", .{ whole, units[u] }) catch unreachable;
    }
}

/// JSON allows any code point but needs `"`, `\` and controls escaped. A byte that is not
/// part of valid UTF-8 becomes `\u00XX`, so the output is always valid JSON (a real U+00XX
/// looks the same; use -0 when exact bytes matter).
fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const len: usize = std.unicode.utf8ByteSequenceLength(b) catch 0;
        if (len > 1 and i + len <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..len])) {
            try w.writeAll(s[i..][0..len]);
            i += len;
            continue;
        }
        i += 1;
        if (b == '"' or b == '\\') try w.writeAll(&.{ '\\', b }) //
        else if (b < 0x20 or b >= 0x7f) try w.print("\\u{x:0>4}", .{b}) //
        else try w.writeByte(b);
    }
    try w.writeByte('"');
}

fn writeRecords(w: *std.Io.Writer, records: []const Record, o: Options) std.Io.Writer.Error!void {
    if (o.json) try w.writeByte('[');
    for (records, 0..) |r, i| {
        var hb: [8]u8 = undefined;
        if (o.json) {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"path\":");
            try writeJsonString(w, r.path);
            try w.print(",\"bytes\":{d},\"state\":\"{t}\"}}", .{ r.bytes, r.state });
        } else {
            if (o.human) try w.writeAll(humanSize(&hb, r.bytes)) else try w.print("{d}", .{r.bytes});
            try w.print("\t{t}\t{s}", .{ r.state, r.path });
            try w.writeByte(if (o.nul) 0 else '\n');
        }
    }
    if (o.json) try w.writeAll("]\n");
}

// ---- environment, config, back ends -----------------------------------------------------

const Env = struct {
    gpa: Allocator,
    arena: Allocator, // freed at exit: records, paths and the config text live here
    io: std.Io,
    home: []const u8,
    xdg_runtime: ?[]const u8 = null,
    xdg_cache: ?[]const u8 = null,
};

/// A message was already printed; the exit code is 2. Or the daemon is missing: exit code 3.
const Stop = error{ Reported, NoDaemon } || Allocator.Error || std.Io.Writer.Error;

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("dirsized: " ++ fmt ++ "\n", args);
}

const Loaded = struct { path: []const u8, found: bool, cfg: config.Config };

/// A missing file is not an error: the defaults apply.
fn loadConfig(env: Env) Stop!Loaded {
    if (env.home.len == 0) {
        say("HOME is not set, cannot find the config file", .{});
        return error.Reported;
    }
    const path = try config.defaultPath(env.arena, env.home);
    var found = true;
    const text = std.Io.Dir.cwd().readFileAlloc(env.io, path, env.arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => blk: {
            found = false;
            break :blk "";
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            say("cannot read {s}: {t}", .{ path, e });
            return error.Reported;
        },
    };
    var diag: config.Diag = .{};
    const cfg = config.Config.parse(env.gpa, text, &diag) catch |e| switch (e) {
        error.BadConfig => return badConfig(path, diag),
        else => |oom| return oom,
    };
    return .{ .path = path, .found = found, .cfg = cfg };
}

fn badConfig(path: []const u8, diag: config.Diag) error{Reported} {
    if (diag.line > 0)
        std.debug.print("{s}:{d}: {s}\n", .{ path, diag.line, diag.message })
    else
        std.debug.print("{s}: {s}\n", .{ path, diag.message });
    return error.Reported;
}

fn compileRules(env: Env, l: Loaded) Stop!ignore.Rules {
    var diag: config.Diag = .{};
    return config.compileRules(env.gpa, &l.cfg, &diag) catch |e| switch (e) {
        error.BadConfig => badConfig(l.path, diag),
        else => |oom| oom,
    };
}

fn realPath(arena: Allocator, path: [:0]const u8) Allocator.Error!?[:0]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.c.realpath(path, &buf) orelse return null;
    return try arena.dupeZ(u8, std.mem.span(p));
}

fn isFolder(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// The only place that knows where answers come from.
fn answer(env: Env, o: Options) Stop!Answer {
    return daemonAnswer(env, o) catch |e| switch (e) {
        error.NoDaemon => if (o.scan) scanAnswer(env, o) else noDaemon(),
        else => e,
    };
}

fn noDaemon() error{NoDaemon} {
    say("daemon is not running (use --scan to read the disk directly)", .{});
    return error.NoDaemon;
}

/// Error.NoDaemon is silent here: the caller decides whether that is fatal.
fn connectDaemon(env: Env) Stop!libc.fd_t {
    if (env.home.len == 0) {
        say("HOME is not set, cannot find the daemon socket", .{});
        return error.Reported;
    }
    const path = paths.socketPath(env.arena, env.home, env.xdg_runtime, env.xdg_cache) catch return error.OutOfMemory;
    return server.connect(path) catch |e| switch (e) {
        error.NoDaemon => error.NoDaemon,
        error.PathTooLong => {
            say("the socket path {s} is too long", .{path});
            return error.Reported;
        },
        error.Socket => {
            say("cannot connect to {s}", .{path});
            return error.Reported;
        },
    };
}

/// One request and its answer, as the client sees a failure. A message was printed.
fn exchangeFailed(e: server.ExchangeError) Stop {
    switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ConnectionClosed => say("the daemon closed the connection", .{}),
        error.Socket => say("cannot talk to the daemon", .{}),
    }
    return error.Reported;
}

/// A reply that is not what was asked for. A message was printed.
fn badReply(frame: []const u8, r: error{BadReply}!proto.Reply) error{Reported} {
    if (r) |reply| switch (reply) {
        .err => |er| say("the daemon refused the request: {s}: {s}", .{ er.code, er.message }),
        else => say("unexpected answer from the daemon", .{}),
    } else |_| say("unreadable answer from the daemon ({d} bytes)", .{frame.len});
    return error.Reported;
}

/// The PATHs go out as pipelined requests and the answers come back in order. A PATH that has
/// no real path cannot exist, so it is answered here and never sent.
fn daemonAnswer(env: Env, o: Options) Stop!Answer {
    const fd = try connectDaemon(env);
    defer _ = libc.close(fd);
    const given: []const []const u8 = if (o.paths.len == 0) &.{"."} else o.paths;
    const verb: proto.Verb = if (o.list) .list else .size;

    var reals: std.ArrayList([]const u8) = .empty;
    var sent: std.ArrayList(bool) = .empty;
    var requests: std.Io.Writer.Allocating = .init(env.arena);
    var n_sent: usize = 0;
    for (given) |given_path| {
        const arg = try env.arena.dupeZ(u8, given_path);
        const resolved = try realPath(env.arena, arg);
        try reals.append(env.arena, resolved orelse arg);
        try sent.append(env.arena, resolved != null);
        if (resolved) |real| {
            try proto.writeRequest(&requests.writer, verb, real);
            n_sent += 1;
        }
    }
    var reply: std.ArrayList(u8) = .empty;
    server.exchange(env.arena, fd, requests.written(), n_sent, &reply) catch |e| return exchangeFailed(e);

    var records: std.ArrayList(Record) = .empty;
    var asked: std.ArrayList(State) = .empty;
    var rest: []const u8 = reply.items;
    for (reals.items, sent.items) |real, was_sent| {
        if (!was_sent) {
            try records.append(env.arena, .{ .path = real, .bytes = 0, .state = .none });
            try asked.append(env.arena, .none);
            continue;
        }
        var first = true;
        while (true) {
            const f = proto.nextFrame(rest) orelse return badReply("", error.BadReply);
            rest = rest[f.consumed..];
            const parsed = proto.parseReply(verb, f.frame);
            const r = parsed catch return badReply(f.frame, parsed);
            switch (r) {
                .end => break,
                .record => |rec| {
                    const state = rec.state;
                    if (!o.list) {
                        try records.append(env.arena, .{ .path = real, .bytes = rec.bytes, .state = state });
                        try asked.append(env.arena, state);
                    } else if (first) {
                        // The "." record: the folder itself. When it has no node the user needs
                        // to see why, so it is shown as a record of its own.
                        try asked.append(env.arena, state);
                        if (state == .none or state == .excluded)
                            try records.append(env.arena, .{ .path = real, .bytes = rec.bytes, .state = state });
                    } else {
                        try records.append(env.arena, .{
                            .path = try std.fs.path.join(env.arena, &.{ real, rec.name }),
                            .bytes = rec.bytes,
                            .state = state,
                        });
                    }
                    first = false;
                },
                else => return badReply(f.frame, parsed),
            }
        }
    }
    return .{ .records = records.items, .asked = asked.items };
}

fn scanAnswer(env: Env, o: Options) Stop!Answer {
    var loaded = try loadConfig(env);
    defer loaded.cfg.deinit();
    var rules = try compileRules(env, loaded);
    defer rules.deinit(env.gpa);
    var pool = scanner.Scanner.init(env.gpa, env.io, scanner.defaultThreads()) catch |e| {
        say("cannot start scan threads: {t}", .{e});
        return error.Reported;
    };
    defer pool.deinit();

    var records: std.ArrayList(Record) = .empty;
    var asked: std.ArrayList(State) = .empty;
    const given: []const []const u8 = if (o.paths.len == 0) &.{"."} else o.paths;
    for (given) |given_path| {
        const arg = try env.arena.dupeZ(u8, given_path);
        // A missing path keeps its spelling: there is no real path to show.
        const resolved = try realPath(env.arena, arg);
        const real = resolved orelse arg;
        if (resolved == null or !isFolder(env.io, real)) {
            try records.append(env.arena, .{ .path = real, .bytes = 0, .state = .none });
            try asked.append(env.arena, .none);
            continue;
        }
        var table = Table.init(env.gpa);
        defer table.deinit();
        const fail = error.Reported;
        const root = table.addRoot(real) catch |e| {
            say("{s}: {t}", .{ real, e });
            return fail;
        };
        pool.case_by_root = &.{scan.ignoreCase(real)};
        pool.scanSubtree(&table, &rules, root) catch |e| {
            say("scan of {s} failed: {t}", .{ real, e });
            return fail;
        };
        try asked.append(env.arena, stateOf(table.state(root)));
        if (!o.list) {
            try records.append(env.arena, .{ .path = real, .bytes = table.total(root), .state = asked.getLast() });
            continue;
        }
        var it = table.children(root);
        while (it.next()) |child| try records.append(env.arena, .{
            .path = try std.fs.path.join(env.arena, &.{ real, table.name(child) }),
            .bytes = table.total(child),
            .state = stateOf(table.state(child)),
        });
    }
    return .{ .records = records.items, .asked = asked.items };
}

fn stateOf(s: @import("table.zig").State) State {
    return switch (s) {
        inline else => |t| @field(State, @tagName(t)),
    };
}

// ---- status -----------------------------------------------------------------------------

/// Keys whose values are text, never numbers, even when they look like one (a folder "123").
fn statusKeyIsText(key: []const u8) bool {
    for ([_][]const u8{ "version", "state", "root", "denied", "config_error", "watch_error" }) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

fn isNumber(v: []const u8) bool {
    if (v.len == 0 or v.len > 18 or (v.len > 1 and v[0] == '0')) return false;
    for (v) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

const Pair = struct { key: []const u8, value: []const u8 };

/// `key: value` lines, in the daemon's order.
fn writeStatusText(w: *std.Io.Writer, pairs: []const Pair) std.Io.Writer.Error!void {
    for (pairs) |p| try w.print("{s}: {s}\n", .{ p.key, p.value });
}

/// One object. A key that repeats (`root`, `denied`) becomes an array; `root` and `denied` are
/// arrays even when they occur once, so a reader sees one type. Numbers are numbers, `-` is null.
fn writeStatusJson(w: *std.Io.Writer, pairs: []const Pair) std.Io.Writer.Error!void {
    try w.writeByte('{');
    var first_key = true;
    for (pairs, 0..) |p, i| {
        const seen_before = for (pairs[0..i]) |q| {
            if (std.mem.eql(u8, q.key, p.key)) break true;
        } else false;
        if (seen_before) continue;
        var n: usize = 0;
        for (pairs[i..]) |q| n += @intFromBool(std.mem.eql(u8, q.key, p.key));
        const array = n > 1 or std.mem.eql(u8, p.key, "root") or std.mem.eql(u8, p.key, "denied");
        if (!first_key) try w.writeByte(',');
        first_key = false;
        try writeJsonString(w, p.key);
        try w.writeByte(':');
        if (array) try w.writeByte('[');
        var shown: usize = 0;
        for (pairs[i..]) |q| {
            if (!std.mem.eql(u8, q.key, p.key)) continue;
            if (shown > 0) try w.writeByte(',');
            shown += 1;
            if (statusKeyIsText(q.key)) try writeJsonString(w, q.value) //
            else if (isNumber(q.value)) try w.writeAll(q.value) //
            else if (std.mem.eql(u8, q.value, "-")) try w.writeAll("null") //
            else try writeJsonString(w, q.value);
        }
        if (array) try w.writeByte(']');
    }
    try w.writeAll("}\n");
}

fn statusCommand(env: Env, o: Options, w: *std.Io.Writer) Stop!void {
    const fd = connectDaemon(env) catch |e| return if (e == error.NoDaemon) noDaemon() else e;
    defer _ = libc.close(fd);
    var requests: std.Io.Writer.Allocating = .init(env.arena);
    try proto.writeRequest(&requests.writer, .status, "");
    var reply: std.ArrayList(u8) = .empty;
    server.exchange(env.arena, fd, requests.written(), 1, &reply) catch |e| return exchangeFailed(e);
    var pairs: std.ArrayList(Pair) = .empty;
    var rest: []const u8 = reply.items;
    while (true) {
        const f = proto.nextFrame(rest) orelse return badReply("", error.BadReply);
        rest = rest[f.consumed..];
        const parsed = proto.parseReply(.status, f.frame);
        const r = parsed catch return badReply(f.frame, parsed);
        switch (r) {
            .end => break,
            .pair => |p| try pairs.append(env.arena, .{ .key = p.key, .value = p.value }),
            else => return badReply(f.frame, parsed),
        }
    }
    if (o.json) try writeStatusJson(w, pairs.items) else try writeStatusText(w, pairs.items);
}

// ---- check ------------------------------------------------------------------------------

fn containingRoot(roots: []const []const u8, path: []const u8) ?[]const u8 {
    for (roots) |r| {
        if (std.mem.eql(u8, path, r) or config.isInside(path, r)) return r;
    }
    return null;
}

fn check(env: Env, o: Options, w: *std.Io.Writer) Stop!u8 {
    var loaded = try loadConfig(env);
    defer loaded.cfg.deinit();
    var rules = try compileRules(env, loaded);
    defer rules.deinit(env.gpa);
    var diag: config.Diag = .{};
    const roots = config.resolveRoots(env.gpa, &loaded.cfg, env.home, &diag) catch |e| switch (e) {
        error.BadConfig => return badConfig(loaded.path, diag),
        else => |oom| return oom,
    };
    try w.print("ok{s}{s}{s}\n", if (loaded.found) .{ "", "", "" } else .{ " (no config file at ", loaded.path, "; defaults apply)" });
    for (roots) |r| try w.print("root\t{s}\n", .{r});
    try w.print("rules\t{d}\n", .{loaded.cfg.exclude.len});
    if (o.paths.len == 0) return 0;

    const arg = try env.arena.dupeZ(u8, o.paths[0]);
    const path = try realPath(env.arena, arg) orelse {
        try w.print("none\t{s}\tdoes not exist\n", .{arg});
        return 1;
    };
    const root = containingRoot(roots, path) orelse {
        try w.print("outside\t{s}\tno root contains it\n", .{path});
        return 1;
    };
    const rel = std.mem.trimStart(u8, path[root.len..], "/");
    const m = rules.explain(rel, scan.ignoreCase(path));
    const text = if (m.rule) |i| loaded.cfg.exclude[i] else "";
    const line = if (m.rule) |i| loaded.cfg.exclude_lines[i] else 0;
    if (m.excluded) {
        try w.print("excluded\t{s}\trule \"{s}\" (line {d})\n", .{ path, text, line });
        return 1;
    }
    try w.print("counted\t{s}\troot {s}", .{ path, root });
    if (m.rule != null) try w.print(", kept by rule \"{s}\" (line {d})", .{ text, line });
    try w.writeByte('\n');
    return 0;
}

// ---- entry ------------------------------------------------------------------------------

pub fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var usage: Usage = .{};
    const o = parse(arena, argv[1..], &usage) catch |e| switch (e) {
        error.Usage => {
            say("{s}\nTry 'dirsized --help'.", .{usage.msg});
            return 2;
        },
        error.OutOfMemory => return e,
    };

    if (o.action == .run and o.command == .daemon) return daemon.run(init);

    var buf: [64 * 1024]u8 = undefined;
    // Streaming, not positional: stdout may be a file shared with stderr or opened with `>>`,
    // and positional writes would overwrite from offset 0.
    var fw = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const env: Env = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = init.io,
        .home = init.environ_map.get("HOME") orelse "",
        .xdg_runtime = init.environ_map.get("XDG_RUNTIME_DIR"),
        .xdg_cache = init.environ_map.get("XDG_CACHE_HOME"),
    };
    var code: u8 = 0;
    const outcome = dispatch(env, o, &fw.interface, &code);
    if (outcome) |_| {} else |e| switch (e) {
        error.Reported => return 2,
        error.NoDaemon => return 3,
        error.OutOfMemory => {
            say("out of memory", .{});
            return 2;
        },
        // A reader that closes the pipe early (`| head -1`) is normal, not an error.
        error.WriteFailed => {
            const werr = fw.err orelse error.WriteFailed;
            if (werr == error.BrokenPipe) return code;
            say("cannot write output: {t}", .{werr});
            return 2;
        },
    }
    return code;
}

fn dispatch(env: Env, o: Options, w: *std.Io.Writer, code: *u8) Stop!void {
    switch (o.action) {
        .help, .version => {
            try w.writeAll(if (o.action == .help) help_text else version ++ "\n");
            return w.flush();
        },
        .run => {},
    }
    switch (o.command) {
        .size => {
            const ans = try answer(env, o);
            code.* = exitCode(ans.asked);
            try writeRecords(w, shape(ans.records, o.list, o.limit), o);
        },
        .status => try statusCommand(env, o, w),
        .daemon => unreachable, // `run` hands it to daemon.run before it gets here
        .check => code.* = try check(env, o, w),
    }
    try w.flush();
}

// ---- tests ------------------------------------------------------------------------------

test "parse: valid command lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const P = []const []const u8;
    const cases = [_]struct { args: P, expect: Options }{
        .{ .args = &.{}, .expect = .{} },
        .{ .args = &.{ "a", "b" }, .expect = .{ .paths = &.{ "a", "b" } } },
        .{ .args = &.{ "-l", "a" }, .expect = .{ .list = true, .paths = &.{"a"} } },
        .{ .args = &.{ "--scan", "-lh", "a" }, .expect = .{ .scan = true, .list = true, .human = true, .paths = &.{"a"} } },
        .{ .args = &.{ "a", "-h", "b" }, .expect = .{ .human = true, .paths = &.{ "a", "b" } } },
        .{ .args = &.{ "-hn5", "a" }, .expect = .{ .human = true, .limit = 5, .paths = &.{"a"} } },
        .{ .args = &.{ "-n", "5" }, .expect = .{ .limit = 5 } },
        .{ .args = &.{"-n0"}, .expect = .{ .limit = 0 } },
        .{ .args = &.{ "-ln", "3", "-0" }, .expect = .{ .list = true, .limit = 3, .nul = true } },
        .{ .args = &.{ "--json", "a" }, .expect = .{ .json = true, .paths = &.{"a"} } },
        .{ .args = &.{ "--", "-l", "-x" }, .expect = .{ .paths = &.{ "-l", "-x" } } },
        .{ .args = &.{"-"}, .expect = .{ .paths = &.{"-"} } },
        .{ .args = &.{ "-l", "--", "-x" }, .expect = .{ .list = true, .paths = &.{"-x"} } },
        .{ .args = &.{"status"}, .expect = .{ .command = .status } },
        .{ .args = &.{ "status", "--json" }, .expect = .{ .command = .status, .json = true } },
        .{ .args = &.{"daemon"}, .expect = .{ .command = .daemon } },
        .{ .args = &.{"check"}, .expect = .{ .command = .check } },
        .{ .args = &.{ "--scan", "check", "a" }, .expect = .{ .command = .check, .scan = true, .paths = &.{"a"} } },
        .{ .args = &.{ "./status", "check" }, .expect = .{ .paths = &.{ "./status", "check" } } },
        .{ .args = &.{ "a", "status" }, .expect = .{ .paths = &.{ "a", "status" } } },
        .{ .args = &.{"--help"}, .expect = .{ .action = .help } },
        .{ .args = &.{"-?"}, .expect = .{ .action = .help } },
        .{ .args = &.{ "--help", "--bogus" }, .expect = .{ .action = .help } },
        .{ .args = &.{"--version"}, .expect = .{ .action = .version } },
    };
    for (cases) |c| {
        var usage: Usage = .{};
        const got = try parse(arena.allocator(), c.args, &usage);
        errdefer std.debug.print("args: {any}\n", .{c.args});
        try std.testing.expectEqual(c.expect.action, got.action);
        try std.testing.expectEqual(c.expect.command, got.command);
        try std.testing.expectEqual(c.expect.list, got.list);
        try std.testing.expectEqual(c.expect.human, got.human);
        try std.testing.expectEqual(c.expect.json, got.json);
        try std.testing.expectEqual(c.expect.nul, got.nul);
        try std.testing.expectEqual(c.expect.scan, got.scan);
        try std.testing.expectEqual(c.expect.limit, got.limit);
        try std.testing.expectEqual(c.expect.paths.len, got.paths.len);
        for (c.expect.paths, got.paths) |e, g| try std.testing.expectEqualStrings(e, g);
    }
}

test "parse: usage errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { args: []const []const u8, msg: []const u8 }{
        .{ .args = &.{"-x"}, .msg = "unknown option -x" },
        .{ .args = &.{"-lx"}, .msg = "unknown option -x" },
        .{ .args = &.{"--nope"}, .msg = "unknown option --nope" },
        .{ .args = &.{"-n"}, .msg = "option -n needs a number" },
        .{ .args = &.{ "a", "-hn" }, .msg = "option -n needs a number" },
        .{ .args = &.{ "-n", "x" }, .msg = "option -n needs a whole number, got \"x\"" },
        .{ .args = &.{"-n-1"}, .msg = "option -n needs a whole number, got \"-1\"" },
        .{ .args = &.{ "-n", "" }, .msg = "option -n needs a whole number, got \"\"" },
        .{ .args = &.{ "-l", "a", "b" }, .msg = "-l takes at most one PATH" },
        .{ .args = &.{ "--json", "-0" }, .msg = "--json and -0 cannot be used together" },
        .{ .args = &.{ "status", "a" }, .msg = "status takes no PATH" },
        .{ .args = &.{ "daemon", "a" }, .msg = "daemon takes no PATH" },
        .{ .args = &.{ "check", "a", "b" }, .msg = "check takes at most one PATH" },
        .{ .args = &.{ "check", "-l" }, .msg = "check takes no output options" },
        .{ .args = &.{ "status", "-l" }, .msg = "status takes no output options" },
        .{ .args = &.{ "check", "--json" }, .msg = "check takes no output options" },
        .{ .args = &.{ "daemon", "-h" }, .msg = "daemon takes no output options" },
    };
    for (cases) |c| {
        var usage: Usage = .{};
        try std.testing.expectError(error.Usage, parse(arena.allocator(), c.args, &usage));
        try std.testing.expectEqualStrings(c.msg, usage.msg);
    }
}

test "humanSize matches gls -lh" {
    const cases = [_]struct { n: u64, s: []const u8 }{
        .{ .n = 0, .s = "0" },
        .{ .n = 1, .s = "1" },
        .{ .n = 1023, .s = "1023" },
        .{ .n = 1024, .s = "1.0K" },
        .{ .n = 1025, .s = "1.1K" },
        .{ .n = 1536, .s = "1.5K" },
        .{ .n = 9728, .s = "9.5K" },
        .{ .n = 9729, .s = "9.6K" },
        .{ .n = 10188, .s = "10K" },
        .{ .n = 10239, .s = "10K" },
        .{ .n = 10240, .s = "10K" },
        .{ .n = 10241, .s = "11K" },
        .{ .n = 1023488, .s = "1000K" },
        .{ .n = 1048064, .s = "1.0M" },
        .{ .n = 1048575, .s = "1.0M" },
        .{ .n = 1048576, .s = "1.0M" },
        .{ .n = 1048577, .s = "1.1M" },
        .{ .n = 1572864, .s = "1.5M" },
        .{ .n = 10484737, .s = "10M" },
        .{ .n = 1072693248, .s = "1023M" },
        .{ .n = 1610612736, .s = "1.5G" },
        .{ .n = 10737418240, .s = "10G" },
        .{ .n = 1099511627776, .s = "1.0T" },
        .{ .n = 1125899906842624, .s = "1.0P" },
        .{ .n = 1 << 60, .s = "1.0E" },
        .{ .n = std.math.maxInt(u64), .s = "16E" },
    };
    for (cases) |c| {
        var buf: [8]u8 = undefined;
        try std.testing.expectEqualStrings(c.s, humanSize(&buf, c.n));
    }
}

test "JSON string escaping" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "", .out = "\"\"" },
        .{ .in = "/a b/c", .out = "\"/a b/c\"" },
        .{ .in = "q\"b\\", .out = "\"q\\\"b\\\\\"" },
        .{ .in = "a\nb\tc\x00", .out = "\"a\\u000ab\\u0009c\\u0000\"" },
        .{ .in = "\x7f", .out = "\"\\u007f\"" },
        .{ .in = "é日🙂", .out = "\"é日🙂\"" },
        .{ .in = "\xe9", .out = "\"\\u00e9\"" },
        .{ .in = "a\xc3", .out = "\"a\\u00c3\"" },
        .{ .in = "\xe6\x97", .out = "\"\\u00e6\\u0097\"" },
        .{ .in = "\xed\xa0\x80", .out = "\"\\u00ed\\u00a0\\u0080\"" }, // surrogate half
        .{ .in = "\xc0\x80", .out = "\"\\u00c0\\u0080\"" }, // overlong NUL
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeJsonString(&w, c.in);
        try std.testing.expectEqualStrings(c.out, w.buffered());
    }
}

test "records: output formats" {
    const recs = [_]Record{
        .{ .path = "/a\nb", .bytes = 1536, .state = .ok },
        .{ .path = "/c", .bytes = 0, .state = .none },
    };
    const cases = [_]struct { o: Options, out: []const u8 }{
        .{ .o = .{}, .out = "1536\tok\t/a\nb\n0\tnone\t/c\n" },
        .{ .o = .{ .human = true, .nul = true }, .out = "1.5K\tok\t/a\nb\x000\tnone\t/c\x00" },
        .{ .o = .{ .json = true, .human = true }, .out = "[{\"path\":\"/a\\u000ab\",\"bytes\":1536,\"state\":\"ok\"},{\"path\":\"/c\",\"bytes\":0,\"state\":\"none\"}]\n" },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeRecords(&w, &recs, c.o);
        try std.testing.expectEqualStrings(c.out, w.buffered());
    }
    var buf: [8]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeRecords(&w, &.{}, .{ .json = true });
    try std.testing.expectEqualStrings("[]\n", w.buffered());
}

test "records: sorting and -n" {
    var recs = [_]Record{
        .{ .path = "/p/b", .bytes = 5, .state = .ok },
        .{ .path = "/p/a", .bytes = 5, .state = .ok },
        .{ .path = "/p/c", .bytes = 9, .state = .ok },
        .{ .path = "/p/\xc3\xa9", .bytes = 1, .state = .ok },
        .{ .path = "/p/Z", .bytes = 1, .state = .ok },
    };
    // Without -l the order stays; -n keeps the first N.
    var kept = shape(&recs, false, 2);
    try std.testing.expectEqualStrings("/p/b", kept[0].path);
    try std.testing.expectEqual(2, kept.len);
    kept = shape(&recs, true, null);
    const want = [_][]const u8{ "/p/c", "/p/a", "/p/b", "/p/Z", "/p/\xc3\xa9" };
    for (want, kept) |e, g| try std.testing.expectEqualStrings(e, g.path);
    kept = shape(&recs, true, 2);
    try std.testing.expectEqual(2, kept.len);
    try std.testing.expectEqualStrings("/p/a", kept[1].path);
    try std.testing.expectEqual(0, shape(&recs, true, 0).len);
    try std.testing.expectEqual(5, shape(&recs, true, 99).len);
    try std.testing.expectEqual(0, shape(recs[0..0], true, 3).len);
}

test "exit code: 1 beats 4 beats 0" {
    try std.testing.expectEqual(0, exitCode(&.{}));
    try std.testing.expectEqual(0, exitCode(&.{ .ok, .ok }));
    try std.testing.expectEqual(4, exitCode(&.{ .ok, .scanning }));
    try std.testing.expectEqual(4, exitCode(&.{ .partial, .stale }));
    try std.testing.expectEqual(1, exitCode(&.{ .partial, .none }));
    try std.testing.expectEqual(1, exitCode(&.{ .none, .scanning }));
    try std.testing.expectEqual(1, exitCode(&.{ .excluded, .ok }));
}

test "status: text and JSON" {
    const pairs = [_]Pair{
        .{ .key = "proto", .value = "1" },
        .{ .key = "version", .value = "0.0.0" },
        .{ .key = "state", .value = "ok" },
        .{ .key = "snapshot_age", .value = "-" },
        .{ .key = "root", .value = "/123" },
        .{ .key = "denied", .value = "/a\"b" },
        .{ .key = "denied", .value = "/c" },
    };
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeStatusText(&w, &pairs);
    try std.testing.expectEqualStrings("proto: 1\nversion: 0.0.0\nstate: ok\nsnapshot_age: -\nroot: /123\ndenied: /a\"b\ndenied: /c\n", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try writeStatusJson(&w, &pairs);
    try std.testing.expectEqualStrings(
        "{\"proto\":1,\"version\":\"0.0.0\",\"state\":\"ok\",\"snapshot_age\":null,\"root\":[\"/123\"],\"denied\":[\"/a\\\"b\",\"/c\"]}\n",
        w.buffered(),
    );
}

test "check: which root contains a path (the root / contains all)" {
    try std.testing.expectEqualStrings("/", containingRoot(&.{"/"}, "/home/x").?);
    try std.testing.expectEqualStrings("/", containingRoot(&.{"/"}, "/").?);
    try std.testing.expectEqualStrings("/a", containingRoot(&.{ "/b", "/a" }, "/a/c").?);
    try std.testing.expectEqual(@as(?[]const u8, null), containingRoot(&.{"/a"}, "/ab"));
}
