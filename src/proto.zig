//! Wire protocol of the daemon socket (DESIGN.md section 11). Pure: no I/O, no allocation.
//!
//! Every record ends with NUL, because a path may hold TAB, newline or space. NAME and PATH
//! are the last field of a record, so a TAB inside them is data: split on the first two TABs.

const std = @import("std");
const Writer = std.Io.Writer;

pub const version = 1;

/// PATH_MAX of the larger platform (Linux: 4096) plus room for the verb and the space.
pub const max_request = 4096 + 16;

pub const State = enum { ok, scanning, partial, stale, excluded, none };

pub const Verb = enum { size, list, status };

pub const Request = struct { verb: Verb, path: []const u8 };

pub const ErrorCode = enum {
    bad_request,
    too_long,

    pub fn text(c: ErrorCode) []const u8 {
        return switch (c) {
            .bad_request => "bad-request",
            .too_long => "too-long",
        };
    }
};

// ---------------------------------------------------------------- server side

/// One request, without its NUL. `status` takes no path. `size` and `list` need an absolute
/// path; one trailing `/` is dropped unless the path is `/`. The path points into `bytes`.
pub fn parseRequest(bytes: []const u8) error{BadRequest}!Request {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.BadRequest;
    if (std.mem.eql(u8, bytes, "status") or std.mem.eql(u8, bytes, "status ")) {
        return .{ .verb = .status, .path = "" };
    }
    const sp = std.mem.indexOfScalar(u8, bytes, ' ') orelse return error.BadRequest;
    const verb = std.meta.stringToEnum(Verb, bytes[0..sp]) orelse return error.BadRequest;
    if (verb == .status) return error.BadRequest; // `status` with an argument
    var path = bytes[sp + 1 ..];
    if (path.len == 0 or path[0] != '/') return error.BadRequest;
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    return .{ .verb = verb, .path = path };
}

/// The bytes up to the first NUL (not including it), or null if no complete request is
/// buffered yet. `consumed` includes the NUL.
pub fn nextFrame(buf: []const u8) ?struct { frame: []const u8, consumed: usize } {
    const i = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
    return .{ .frame = buf[0..i], .consumed = i + 1 };
}

pub fn writeRecord(w: *Writer, bytes: u64, state: State, name: []const u8) Writer.Error!void {
    try w.print("{d}\t{t}\t", .{ bytes, state });
    try w.writeAll(name);
    try w.writeByte(0);
}

/// The empty record that ends every answer.
pub fn writeEnd(w: *Writer) Writer.Error!void {
    try w.writeByte(0);
}

pub fn writeKeyValue(w: *Writer, key: []const u8, value: []const u8) Writer.Error!void {
    try w.writeAll(key);
    try w.writeByte('\t');
    try w.writeAll(value);
    try w.writeByte(0);
}

/// The error record and the end marker.
pub fn writeError(w: *Writer, code: ErrorCode, message: []const u8) Writer.Error!void {
    try w.writeAll("!\t");
    try w.writeAll(code.text());
    try w.writeByte('\t');
    try w.writeAll(message);
    try w.writeByte(0);
    try w.writeByte(0);
}

/// A request with its NUL. `status` ignores `path`.
pub fn writeRequest(w: *Writer, verb: Verb, path: []const u8) Writer.Error!void {
    if (verb == .status) return w.writeAll("status\x00");
    try w.print("{t} ", .{verb});
    try w.writeAll(path);
    try w.writeByte(0);
}

// ---------------------------------------------------------------- client side

pub const Reply = union(enum) {
    record: struct { bytes: u64, state: State, name: []const u8 },
    pair: struct { key: []const u8, value: []const u8 },
    err: struct { code: []const u8, message: []const u8 },
    end,
};

/// One frame of an answer, without its NUL. Zero-copy: strings point into `frame`.
/// An empty frame is `.end`; `!` TAB starts an error; `status` frames are pairs.
pub fn parseReply(kind: Verb, frame: []const u8) error{BadReply}!Reply {
    if (frame.len == 0) return .end;
    if (frame.len >= 2 and frame[0] == '!' and frame[1] == '\t') {
        const rest = frame[2..];
        const t = std.mem.indexOfScalar(u8, rest, '\t') orelse return error.BadReply;
        return .{ .err = .{ .code = rest[0..t], .message = rest[t + 1 ..] } };
    }
    if (kind == .status) {
        const t = std.mem.indexOfScalar(u8, frame, '\t') orelse return error.BadReply;
        return .{ .pair = .{ .key = frame[0..t], .value = frame[t + 1 ..] } };
    }
    const t1 = std.mem.indexOfScalar(u8, frame, '\t') orelse return error.BadReply;
    const t2 = std.mem.indexOfScalarPos(u8, frame, t1 + 1, '\t') orelse return error.BadReply;
    const bytes = parseU64(frame[0..t1]) orelse return error.BadReply;
    const state = std.meta.stringToEnum(State, frame[t1 + 1 .. t2]) orelse return error.BadReply;
    return .{ .record = .{ .bytes = bytes, .state = state, .name = frame[t2 + 1 ..] } };
}

/// Digits only: no sign, no underscore, no empty string.
fn parseU64(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "parseRequest: verbs" {
    const a = try parseRequest("size /a/b");
    try testing.expectEqual(Verb.size, a.verb);
    try testing.expectEqualStrings("/a/b", a.path);
    const b = try parseRequest("list /");
    try testing.expectEqual(Verb.list, b.verb);
    try testing.expectEqualStrings("/", b.path);
    try testing.expectEqual(Verb.status, (try parseRequest("status")).verb);
    try testing.expectEqual(Verb.status, (try parseRequest("status ")).verb);
}

test "parseRequest: trailing slash rule" {
    try testing.expectEqualStrings("/a", (try parseRequest("size /a/")).path);
    try testing.expectEqualStrings("/a/", (try parseRequest("size /a//")).path); // only ONE is stripped
    try testing.expectEqualStrings("/", (try parseRequest("size /")).path);
    try testing.expectEqualStrings("/", (try parseRequest("size //")).path);
}

test "parseRequest: odd bytes in the path are data" {
    const r = try parseRequest("size /a b\tc\nd\xff\xfe ");
    try testing.expectEqualStrings("/a b\tc\nd\xff\xfe ", r.path);
}

test "parseRequest: errors" {
    const bad = [_][]const u8{
        "",      "size",      "size ",        "size a",  "size ./a", "list",
        "list ", "status /a", "statusx",      "Size /a", "stat",     "size\t/a",
        "rm /a", " size /a",  "size /a\x00b",
    };
    for (bad) |b| try testing.expectError(error.BadRequest, parseRequest(b));
}

test "nextFrame: pipelined" {
    const buf = "size /a\x00list /b\x00stat";
    const f1 = nextFrame(buf).?;
    try testing.expectEqualStrings("size /a", f1.frame);
    try testing.expectEqual(@as(usize, 8), f1.consumed);
    const f2 = nextFrame(buf[f1.consumed..]).?;
    try testing.expectEqualStrings("list /b", f2.frame);
    try testing.expect(nextFrame(buf[f1.consumed + f2.consumed ..]) == null);
    try testing.expect(nextFrame("") == null);
    const e = nextFrame("\x00x").?; // empty frame
    try testing.expectEqual(@as(usize, 0), e.frame.len);
    try testing.expectEqual(@as(usize, 1), e.consumed);
}

test "writeRequest round trip" {
    var b: [128]u8 = undefined;
    var w = Writer.fixed(&b);
    try writeRequest(&w, .size, "/x y\t\n");
    try writeRequest(&w, .list, "/");
    try writeRequest(&w, .status, "ignored");
    var rest: []const u8 = w.buffered();
    const want = [_]Request{
        .{ .verb = .size, .path = "/x y\t\n" },
        .{ .verb = .list, .path = "/" },
        .{ .verb = .status, .path = "" },
    };
    for (want) |x| {
        const f = nextFrame(rest).?;
        const r = try parseRequest(f.frame);
        try testing.expectEqual(x.verb, r.verb);
        try testing.expectEqualStrings(x.path, r.path);
        rest = rest[f.consumed..];
    }
    try testing.expectEqual(@as(usize, 0), rest.len);
}

test "record round trip: every state, u64 max, odd names" {
    const names = [_][]const u8{ "a", ".", "with space", "tab\tin\tname", "new\nline", "\xff\xfe\x80", "/abs/p\tq", "" };
    var b: [1024]u8 = undefined;
    for (std.enums.values(State)) |st| {
        for (names, 0..) |n, i| {
            const bytes: u64 = if (i % 2 == 0) std.math.maxInt(u64) else i;
            var w = Writer.fixed(&b);
            try writeRecord(&w, bytes, st, n);
            const out = w.buffered();
            const f = nextFrame(out).?;
            try testing.expectEqual(out.len, f.consumed);
            const r = try parseReply(.list, f.frame);
            try testing.expectEqual(bytes, r.record.bytes);
            try testing.expectEqual(st, r.record.state);
            try testing.expectEqualStrings(n, r.record.name);
        }
    }
}

test "exact bytes of an answer" {
    var b: [64]u8 = undefined;
    var w = Writer.fixed(&b);
    try writeRecord(&w, 42, .partial, "/p");
    try writeEnd(&w);
    try testing.expectEqualStrings("42\tpartial\t/p\x00\x00", w.buffered());
}

test "list answer: records then end" {
    var b: [256]u8 = undefined;
    var w = Writer.fixed(&b);
    try writeRecord(&w, 10, .ok, ".");
    try writeRecord(&w, 4, .ok, "a\tb");
    try writeRecord(&w, 6, .scanning, "c");
    try writeEnd(&w);
    var rest: []const u8 = w.buffered();
    var n: usize = 0;
    while (nextFrame(rest)) |f| {
        rest = rest[f.consumed..];
        const r = try parseReply(.list, f.frame);
        if (r == .end) break;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 0), rest.len);
}

test "status round trip" {
    var b: [256]u8 = undefined;
    var w = Writer.fixed(&b);
    try writeKeyValue(&w, "proto", "1");
    try writeKeyValue(&w, "denied", "/a\tb\nc");
    try writeKeyValue(&w, "empty", "");
    try writeEnd(&w);
    var rest: []const u8 = w.buffered();
    const want = [_][2][]const u8{ .{ "proto", "1" }, .{ "denied", "/a\tb\nc" }, .{ "empty", "" } };
    for (want) |kv| {
        const f = nextFrame(rest).?;
        rest = rest[f.consumed..];
        const r = try parseReply(.status, f.frame);
        try testing.expectEqualStrings(kv[0], r.pair.key);
        try testing.expectEqualStrings(kv[1], r.pair.value);
    }
    const f = nextFrame(rest).?;
    try testing.expect((try parseReply(.status, f.frame)) == .end);
}

test "error round trip" {
    var b: [128]u8 = undefined;
    var w = Writer.fixed(&b);
    try writeError(&w, .bad_request, "path must be absolute");
    try testing.expectEqualStrings("!\tbad-request\tpath must be absolute\x00\x00", w.buffered());
    const f = nextFrame(w.buffered()).?;
    const r = try parseReply(.size, f.frame);
    try testing.expectEqualStrings("bad-request", r.err.code);
    try testing.expectEqualStrings("path must be absolute", r.err.message);
    const e = nextFrame(w.buffered()[f.consumed..]).?;
    try testing.expect((try parseReply(.size, e.frame)) == .end);

    w = Writer.fixed(&b);
    try writeError(&w, .too_long, "");
    try testing.expectEqualStrings("!\ttoo-long\t\x00\x00", w.buffered());
    // Errors also arrive for status.
    const r2 = try parseReply(.status, "!\ttoo-long\tx");
    try testing.expectEqualStrings("too-long", r2.err.code);
}

test "parseReply: malformed" {
    const bad_rec = [_][]const u8{
        "5",         "5\tok",                       "x\tok\tn",                    "\tok\tn",     "-1\tok\tn",
        "+1\tok\tn", "1_0\tok\tn",                  " 1\tok\tn",                   "5\tbogus\tn", "5\t\tn",
        "5\tOK\tn",  "18446744073709551616\tok\tn", "99999999999999999999\tok\tn", "!",           "!\tcode",
        "!x\ta\tb",
    };
    for (bad_rec) |f| try testing.expectError(error.BadReply, parseReply(.size, f));
    try testing.expectError(error.BadReply, parseReply(.status, "novalue"));
    try testing.expectError(error.BadReply, parseReply(.status, "!"));
}

test "parseReply: u64 max and the boundary" {
    const r = try parseReply(.size, "18446744073709551615\tok\t/");
    try testing.expectEqual(std.math.maxInt(u64), r.record.bytes);
    const z = try parseReply(.size, "0\tnone\t/q");
    try testing.expectEqual(@as(u64, 0), z.record.bytes);
    try testing.expectEqual(State.none, z.record.state);
    try testing.expectEqual(State.excluded, (try parseReply(.size, "1\texcluded\t/")).record.state);
}

test "parseReply: later TABs stay in the name" {
    const r = try parseReply(.list, "7\tok\t\t\t");
    try testing.expectEqualStrings("\t\t", r.record.name);
}

test "parseReply: empty frame is end for every kind" {
    for (std.enums.values(Verb)) |k| try testing.expect((try parseReply(k, "")) == .end);
}

test "max_request" {
    try testing.expectEqual(4112, max_request);
}
