//! The daemon's socket server and the small blocking client that `cli.zig` uses
//! (DESIGN.md section 11, ARCHITECTURE.md "server.zig").
//!
//! The server owns no thread and never blocks: the daemon puts `fillPoll`'s descriptors into its
//! one `poll()` call and passes the result back to `service`. Per client there is one fixed
//! input buffer and one growable output list that is reused, so a warm request allocates
//! nothing. A request is answered in the same wake-up that read it (read, handle, write); only
//! what the socket does not take stays buffered and waits for POLLOUT.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const c = std.c;
const proto = @import("proto.zig");

pub const max_clients = 32;
/// A client that does not read gets its answers buffered up to this size, then it is closed.
pub const max_output = 16 << 20;
/// Above this much unread output the server stops reading the client's next request.
const pause_input = 1 << 20;
/// How often (2 ms apart) the client retries a refused connect before it says "no daemon".
const refused_retries = 3;
/// Written output is dropped from the front of a client's buffer once this much is behind.
const compact_min = 64 << 10;
/// After `accept` fails for lack of descriptors the listen socket is left alone this long.
const accept_pause_ns = 1 * 1_000_000_000;
/// An idle output buffer bigger than this is freed (a `list` of a huge folder is rare).
const keep_capacity = 1 << 20;

extern "c" fn getpeereid(fd: c.fd_t, uid: *c.uid_t, gid: *c.gid_t) c_int;

/// Same layout as Linux `struct ucred`.
const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

/// The user id at the other end of a connected unix socket. Null means "cannot tell": the
/// caller treats that as a refusal.
fn peerUid(fd: c.fd_t) ?c.uid_t {
    switch (builtin.os.tag) {
        .macos => {
            var uid: c.uid_t = undefined;
            var gid: c.gid_t = undefined;
            return if (getpeereid(fd, &uid, &gid) == 0) uid else null;
        },
        .linux => {
            var cred: Ucred = undefined;
            var len: c.socklen_t = @sizeOf(Ucred);
            if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) != 0) return null;
            return cred.uid;
        },
        else => return null,
    }
}

pub fn setNonBlockingCloexec(fd: c.fd_t) error{Socket}!void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.Socket;
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0) return error.Socket;
    if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.Socket;
}

fn sockAddr(path: []const u8) error{PathTooLong}!c.sockaddr.un {
    var a: c.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&a), 0);
    a.family = c.AF.UNIX;
    if (path.len >= a.path.len) return error.PathTooLong;
    @memcpy(a.path[0..path.len], path);
    return a;
}

const Client = struct {
    fd: c.fd_t,
    in: [proto.max_request]u8 = undefined,
    in_len: usize = 0,
    out: std.ArrayList(u8) = .empty,
    /// Bytes of `out` that the socket already took.
    out_pos: usize = 0,
    /// No more input is read; the client is closed once its output is written.
    closing: bool = false,
    /// `Server.now` when the client last sent something (or connected).
    last_input: i64 = 0,

    fn pending(cl: *const Client) usize {
        return cl.out.items.len - cl.out_pos;
    }
};

pub const Server = struct {
    gpa: Allocator,
    /// -1 when the server has no listen socket (tests hand it connected sockets).
    listen_fd: c.fd_t = -1,
    clients: std.ArrayList(*Client) = .empty,
    /// How many clients the last `fillPoll` listed; `service` maps descriptors to clients by index.
    polled: usize = 0,
    /// The caller's clock (any monotonic nanoseconds), as of the last `fillPoll` / `service`.
    now: i64 = 0,
    /// Set when `accept` ran out of descriptors: the listen socket stays out of the poll set until
    /// then (it would stay readable and spin the loop). The caller must wake up at this time.
    accept_resume: ?i64 = null,
    /// The socket file to remove on `deinit`; empty when the server did not create one.
    path_buf: [108]u8 = undefined,
    path_len: usize = 0,

    /// The caller holds the daemon lock, so a socket file that is still there is stale: it is
    /// replaced. Errors name the step that failed.
    pub fn listen(gpa: Allocator, path: []const u8) !Server {
        const addr = try sockAddr(path);
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = c.close(fd);
        try setNonBlockingCloexec(fd);
        var z: [108]u8 = undefined;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        _ = c.unlink(@ptrCast(&z));
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.Bind;
        errdefer _ = c.unlink(@ptrCast(&z));
        _ = c.chmod(@ptrCast(&z), 0o600); // the folder is 0700 already; this is a second lock
        if (c.listen(fd, 128) != 0) return error.Listen;
        var s: Server = .{ .gpa = gpa, .listen_fd = fd };
        try s.clients.ensureTotalCapacity(gpa, max_clients);
        @memcpy(s.path_buf[0..path.len], path);
        s.path_len = path.len;
        return s;
    }

    /// Closes every client and the listen socket and removes the socket file.
    pub fn deinit(s: *Server) void {
        for (s.clients.items) |cl| s.destroy(cl);
        s.clients.deinit(s.gpa);
        if (s.listen_fd >= 0) _ = c.close(s.listen_fd);
        s.removeSocketFile();
        s.* = undefined;
    }

    /// Early in a shutdown, so that a new client sees "no daemon" while the rest is torn down.
    pub fn removeSocketFile(s: *Server) void {
        if (s.path_len == 0) return;
        s.path_buf[s.path_len] = 0;
        _ = c.unlink(@ptrCast(&s.path_buf));
        s.path_len = 0;
    }

    /// Takes over a connected socket. The peer must already be checked.
    pub fn adopt(s: *Server, fd: c.fd_t) !void {
        errdefer _ = c.close(fd);
        try setNonBlockingCloexec(fd);
        if (s.clients.items.len == max_clients) return error.TooManyClients;
        const cl = try s.gpa.create(Client);
        cl.* = .{ .fd = fd, .last_input = s.now };
        s.clients.appendAssumeCapacity(cl);
    }

    fn destroy(s: *Server, cl: *Client) void {
        _ = c.close(cl.fd);
        cl.out.deinit(s.gpa);
        s.gpa.destroy(cl);
    }

    /// Room needed in the `fds` of `fillPoll`.
    pub const max_fds = 1 + max_clients;

    /// Writes the listen socket and every client into `fds` (`max_fds` entries) and returns how
    /// many it used. A client with unread output waits for POLLOUT, and one with a lot of it is
    /// not read from until it catches up.
    pub fn fillPoll(s: *Server, fds: []c.pollfd, now: i64) usize {
        s.now = now;
        const paused = if (s.accept_resume) |t| now < t else false;
        if (!paused) s.accept_resume = null;
        fds[0] = .{ .fd = if (paused) -1 else s.listen_fd, .events = c.POLL.IN, .revents = 0 };
        for (s.clients.items, 1..) |cl, i| {
            var ev: i16 = 0;
            if (!cl.closing and cl.pending() < pause_input) ev |= c.POLL.IN;
            if (cl.pending() > 0) ev |= c.POLL.OUT;
            fds[i] = .{ .fd = cl.fd, .events = ev, .revents = 0 };
        }
        s.polled = s.clients.items.len;
        return 1 + s.polled;
    }

    /// Handles what `poll` reported for the descriptors that `fillPoll` listed. `ctx.handle(req,
    /// out)` answers one request; if it fails, that client is closed.
    pub fn service(s: *Server, fds: []const c.pollfd, now: i64, ctx: anytype) void {
        s.now = now;
        var i = s.polled;
        while (i > 0) {
            i -= 1;
            const cl = s.clients.items[i];
            if (s.serviceClient(cl, fds[1 + i].revents, ctx)) continue;
            s.destroy(cl);
            _ = s.clients.swapRemove(i);
        }
        // After the loop: a client that is closed to make room must not shift the indexes above.
        if (fds[0].revents & c.POLL.IN != 0) s.acceptAll();
    }

    fn acceptAll(s: *Server) void {
        const me = c.getuid();
        while (true) {
            const fd = c.accept(s.listen_fd, null, null);
            if (fd < 0) {
                // EAGAIN: done. Out of descriptors: the connection stays queued and the socket
                // stays readable, so look away for a while. Anything else is not worth a retry loop.
                switch (c.errno(fd)) {
                    .MFILE, .NFILE => s.accept_resume = s.now + accept_pause_ns,
                    else => {},
                }
                return;
            }
            if (peerUid(fd) != me) {
                _ = c.close(fd);
                continue;
            }
            if (s.clients.items.len == max_clients) s.evictOldest();
            s.adopt(fd) catch {}; // too many clients or no memory: the client sees a close
        }
    }

    /// Frees one slot: the client that has been silent longest, idle or stuck on unread output
    /// alike (a client that does not read is not read from, so its clock stops). Done only when
    /// a new client would be refused, so a long-lived connection (the Emacs client) is never
    /// closed while slots are free.
    fn evictOldest(s: *Server) void {
        var oldest: usize = 0;
        for (s.clients.items, 0..) |cl, i| {
            if (cl.last_input < s.clients.items[oldest].last_input) oldest = i;
        }
        s.destroy(s.clients.items[oldest]);
        _ = s.clients.swapRemove(oldest);
    }

    /// False when the client must be closed.
    fn serviceClient(s: *Server, cl: *Client, revents: i16, ctx: anytype) bool {
        if (revents & c.POLL.NVAL != 0) return false;
        if (!cl.closing and cl.pending() < pause_input and revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) {
            const n = c.read(cl.fd, cl.in[cl.in_len..].ptr, cl.in.len - cl.in_len);
            if (n < 0) {
                switch (c.errno(n)) {
                    .AGAIN, .INTR => {},
                    else => return false,
                }
            } else if (n == 0) {
                cl.closing = true; // the client is done sending; it may still be reading
            } else {
                cl.in_len += @intCast(n);
                cl.last_input = s.now;
                if (!s.processFrames(cl, ctx)) return false;
            }
        }
        if (cl.pending() > 0 and !flush(cl, s.gpa)) return false;
        return !(cl.closing and cl.pending() == 0);
    }

    fn processFrames(s: *Server, cl: *Client, ctx: anytype) bool {
        var aw: Writer.Allocating = .fromArrayList(s.gpa, &cl.out);
        defer cl.out = aw.toArrayList();
        var start: usize = 0;
        while (!cl.closing) {
            const f = proto.nextFrame(cl.in[start..cl.in_len]) orelse break;
            if (proto.parseRequest(f.frame)) |req| {
                ctx.handle(req, &aw.writer) catch return false;
                // Per request: one read can hold hundreds of `list` requests, each with a big answer.
                if (aw.writer.end - cl.out_pos > max_output) return false;
            } else |_| {
                proto.writeError(&aw.writer, .bad_request, "expected: size PATH, list PATH or status") catch return false;
            }
            start += f.consumed;
        }
        std.mem.copyForwards(u8, cl.in[0 .. cl.in_len - start], cl.in[start..cl.in_len]);
        cl.in_len -= start;
        if (!cl.closing and cl.in_len == cl.in.len) {
            // A full buffer with no NUL in it: the request is longer than any path can be.
            proto.writeError(&aw.writer, .too_long, "request too long") catch return false;
            cl.closing = true;
        }
        // `end` counts the old bytes too: the writer was built on the list.
        return aw.writer.end - cl.out_pos <= max_output;
    }
};

/// Writes as much as the socket takes. False on an error that ends the connection.
fn flush(cl: *Client, gpa: Allocator) bool {
    while (cl.pending() > 0) {
        const n = c.write(cl.fd, cl.out.items[cl.out_pos..].ptr, cl.pending());
        if (n < 0) switch (c.errno(n)) {
            .INTR => continue,
            .AGAIN => {
                // Without this the cap bounds the unread bytes, not the memory: a client that
                // reads steadily never drains the buffer, and the written head would pile up.
                if (cl.out_pos >= compact_min or cl.out_pos >= cl.pending()) {
                    const rest = cl.pending();
                    std.mem.copyForwards(u8, cl.out.items[0..rest], cl.out.items[cl.out_pos..]);
                    cl.out.items.len = rest;
                    cl.out_pos = 0;
                }
                return true;
            },
            else => return false,
        };
        cl.out_pos += @intCast(n);
    }
    cl.out.clearRetainingCapacity();
    cl.out_pos = 0;
    if (cl.out.capacity > keep_capacity) cl.out.shrinkAndFree(gpa, 0);
    return true;
}

// ---------------------------------------------------------------- blocking client

pub const ConnectError = error{ NoDaemon, PathTooLong, Socket };

/// A connected socket. `exchange` makes it non-blocking and times out on no progress.
pub fn connect(path: []const u8) ConnectError!c.fd_t {
    const addr = try sockAddr(path);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    var refused: u32 = 0;
    while (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) {
        switch (c.errno(-1)) {
            .INTR => continue,
            .NOENT => return error.NoDaemon,
            // The file is there: a busy daemon with a full backlog refuses too, so look again
            // briefly. A stale file (a crash) costs a few ms more than no file.
            .CONNREFUSED => {
                refused += 1;
                if (refused > refused_retries) return error.NoDaemon;
                const nap: c.timespec = .{ .sec = 0, .nsec = 2_000_000 };
                _ = c.nanosleep(&nap, null);
            },
            else => return error.Socket,
        }
    }
    return fd;
}

pub const ExchangeError = error{ ConnectionClosed, Socket } || Allocator.Error;

/// Sends `requests` (any number of pipelined requests) and reads until `answers` answers are
/// complete: each answer ends with an empty frame. The raw bytes land in `reply`. Sending and
/// reading are interleaved with `poll`: the server stops reading a client that has a lot of
/// unread output, so writing everything first would deadlock on a long request list.
pub fn exchange(gpa: Allocator, fd: c.fd_t, requests: []const u8, answers: usize, reply: *std.ArrayList(u8)) ExchangeError!void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.Socket;
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0) return error.Socket;
    var sent: usize = 0;
    var seen: usize = 0;
    var pos: usize = 0;
    while (seen < answers) {
        var pfd = [1]c.pollfd{.{ .fd = fd, .events = @as(i16, c.POLL.IN) | (if (sent < requests.len) @as(i16, c.POLL.OUT) else 0), .revents = 0 }};
        const rc = c.poll(&pfd, 1, 30_000); // the old read timeout: no progress for 30 s is an error
        if (rc < 0) switch (c.errno(rc)) {
            .INTR => continue,
            else => return error.Socket,
        };
        if (rc == 0) return error.Socket;
        if (sent < requests.len and pfd[0].revents & c.POLL.OUT != 0) {
            const n = c.write(fd, requests[sent..].ptr, requests.len - sent);
            if (n < 0) switch (c.errno(n)) {
                .INTR, .AGAIN => {},
                .PIPE, .CONNRESET => return error.ConnectionClosed,
                else => return error.Socket,
            } else sent += @intCast(n);
        }
        if (pfd[0].revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) == 0) continue;
        try reply.ensureUnusedCapacity(gpa, 4096);
        const spare = reply.unusedCapacitySlice();
        const n = c.read(fd, spare.ptr, spare.len);
        if (n < 0) switch (c.errno(n)) {
            .INTR, .AGAIN => continue,
            .CONNRESET => return error.ConnectionClosed,
            else => return error.Socket,
        };
        if (n == 0) return error.ConnectionClosed;
        reply.items.len += @intCast(n);
        while (proto.nextFrame(reply.items[pos..])) |f| {
            pos += f.consumed;
            if (f.frame.len == 0) seen += 1;
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const EchoCtx = struct {
    handled: usize = 0,
    fail_on: ?[]const u8 = null,

    fn handle(self: *EchoCtx, req: proto.Request, out: *Writer) Writer.Error!void {
        self.handled += 1;
        if (self.fail_on) |p| if (std.mem.eql(u8, p, req.path)) return error.WriteFailed;
        try proto.writeRecord(out, req.path.len, .ok, req.path);
        try proto.writeEnd(out);
    }
};

fn nowNs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
}

/// One poll round, as the daemon's loop does it.
fn round(s: *Server, ctx: anytype) void {
    var fds: [Server.max_fds]c.pollfd = undefined;
    const n = s.fillPoll(&fds, nowNs());
    _ = c.poll(&fds, @intCast(n), 50);
    s.service(fds[0..n], nowNs(), ctx);
}

fn socketPair() ![2]c.fd_t {
    var sv: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &sv));
    return sv;
}

fn readSome(fd: c.fd_t, buf: []u8) []u8 {
    const n = c.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else buf[0..0];
}

test "framing: pipelined requests are answered in order, a bad one gets an error record" {
    const sv = try socketPair();
    defer _ = c.close(sv[1]);
    var s: Server = .{ .gpa = testing.allocator };
    try s.clients.ensureTotalCapacity(testing.allocator, max_clients);
    defer s.deinit();
    try s.adopt(sv[0]);
    var ctx: EchoCtx = .{};

    // A request split across two writes, then two more in one write, then garbage.
    _ = c.write(sv[1], "size /a", 7);
    round(&s, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx.handled);
    const rest = "\x00list /bc\x00bogus\x00size /d e\n\x00";
    _ = c.write(sv[1], rest.ptr, rest.len);
    round(&s, &ctx);
    try testing.expectEqual(@as(usize, 3), ctx.handled);

    var buf: [256]u8 = undefined;
    const got = readSome(sv[1], &buf);
    const want = "2\tok\t/a\x00\x00" ++ "3\tok\t/bc\x00\x00" ++
        "!\tbad-request\texpected: size PATH, list PATH or status\x00\x00" ++ "5\tok\t/d e\n\x00\x00";
    try testing.expectEqualStrings(want, got);
}

test "framing: a request that fills the buffer gets too-long and the connection is closed" {
    const sv = try socketPair();
    defer _ = c.close(sv[1]);
    var s: Server = .{ .gpa = testing.allocator };
    try s.clients.ensureTotalCapacity(testing.allocator, max_clients);
    defer s.deinit();
    try s.adopt(sv[0]);
    var ctx: EchoCtx = .{};

    var big: [proto.max_request]u8 = @splat('x');
    @memcpy(big[0..6], "size /");
    _ = c.write(sv[1], &big, big.len);
    var rounds: usize = 0;
    while (s.clients.items.len > 0 and rounds < 10) : (rounds += 1) round(&s, &ctx);
    try testing.expectEqual(@as(usize, 0), s.clients.items.len);
    try testing.expectEqual(@as(usize, 0), ctx.handled);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("!\ttoo-long\trequest too long\x00\x00", readSome(sv[1], &buf));
    try testing.expectEqual(@as(usize, 0), readSome(sv[1], &buf).len); // EOF
}

test "framing: a failing handler closes only that client" {
    const a = try socketPair();
    defer _ = c.close(a[1]);
    const b = try socketPair();
    defer _ = c.close(b[1]);
    var s: Server = .{ .gpa = testing.allocator };
    try s.clients.ensureTotalCapacity(testing.allocator, max_clients);
    defer s.deinit();
    try s.adopt(a[0]);
    try s.adopt(b[0]);
    var ctx: EchoCtx = .{ .fail_on = "/boom" };
    _ = c.write(a[1], "size /boom\x00", 11);
    _ = c.write(b[1], "size /ok\x00", 9);
    round(&s, &ctx);
    try testing.expectEqual(@as(usize, 1), s.clients.items.len);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("3\tok\t/ok\x00\x00", readSome(b[1], &buf));
}

test "framing: the client may close its sending side and still get the answer" {
    const sv = try socketPair();
    defer _ = c.close(sv[1]);
    var s: Server = .{ .gpa = testing.allocator };
    try s.clients.ensureTotalCapacity(testing.allocator, max_clients);
    defer s.deinit();
    try s.adopt(sv[0]);
    var ctx: EchoCtx = .{};
    _ = c.write(sv[1], "size /q\x00", 8);
    _ = c.shutdown(sv[1], 1); // SHUT_WR
    var rounds: usize = 0;
    while (s.clients.items.len > 0 and rounds < 10) : (rounds += 1) round(&s, &ctx);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("2\tok\t/q\x00\x00", readSome(sv[1], &buf));
}

test "exchange reads until the requested number of answers" {
    const sv = try socketPair();
    defer _ = c.close(sv[0]);
    defer _ = c.close(sv[1]);
    // The "server" answers before the client reads: socket buffers hold the small answer.
    const answer = "1\tok\t/a\x00\x00" ++ "!\ttoo-long\tx\x00\x00";
    _ = c.write(sv[1], answer.ptr, answer.len);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try exchange(testing.allocator, sv[0], "size /a\x00size /b\x00", 2, &reply);
    try testing.expectEqualStrings(answer, reply.items);
    // The other side hangs up before the second answer.
    _ = c.close(sv[1]);
    var r2: std.ArrayList(u8) = .empty;
    defer r2.deinit(testing.allocator);
    try testing.expectError(error.ConnectionClosed, exchange(testing.allocator, sv[0], "", 1, &r2));
}

test "listen, connect, serve one request, clean up the socket file" {
    // A short path: sun_path is 104 bytes on macOS and the test dir can be long.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/dsrv-{d}.sock", .{c.getpid()});
    var s = try Server.listen(testing.allocator, path);
    defer s.deinit();

    const fd = try connect(path);
    defer _ = c.close(fd);
    _ = c.write(fd, "size /zz\x00", 9);
    var ctx: EchoCtx = .{};
    round(&s, &ctx); // accepts
    round(&s, &ctx); // reads and answers
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try exchange(testing.allocator, fd, "", 1, &reply);
    try testing.expectEqualStrings("3\tok\t/zz\x00\x00", reply.items);

    s.removeSocketFile();
    try testing.expectError(error.NoDaemon, connect(path));
}

const BigCtx = struct {
    handled: usize = 0,

    fn handle(self: *BigCtx, req: proto.Request, out: *Writer) Writer.Error!void {
        self.handled += 1;
        _ = req;
        try out.splatByteAll('x', 1 << 20); // a 1 MiB answer per request
        try proto.writeEnd(out);
    }
};

test "a request that makes the answer too big closes the client at once, not after the batch" {
    const sv = try socketPair();
    defer _ = c.close(sv[1]);
    var s: Server = .{ .gpa = testing.allocator };
    try s.clients.ensureTotalCapacity(testing.allocator, max_clients);
    defer s.deinit();
    try s.adopt(sv[0]);
    var ctx: BigCtx = .{};
    // One read holds 455 tiny requests with 1 MiB answers. The handler must stop right at the cap,
    // inside the batch.
    var req: [4096]u8 = undefined;
    var len: usize = 0;
    while (len + 9 <= req.len) : (len += 9) @memcpy(req[len..][0..9], "size /ab\x00");
    var rounds: usize = 0;
    while (s.clients.items.len > 0 and rounds < 3000) : (rounds += 1) {
        _ = c.write(sv[1], &req, len);
        round(&s, &ctx);
    }
    try testing.expectEqual(@as(usize, 0), s.clients.items.len);
    // The cap is 16 MiB: the 17th answer crosses it. A check after the whole batch would run all 455.
    try testing.expect(ctx.handled <= 17);
}

test "the longest silent client is evicted, even one with unread output" {
    var s: Server = .{ .gpa = testing.allocator };
    try s.clients.ensureTotalCapacity(testing.allocator, max_clients);
    defer s.deinit();
    var peers: [max_clients]c.fd_t = undefined;
    for (&peers, 0..) |*p, i| {
        const sv = try socketPair();
        p.* = sv[1];
        s.now = @intCast(i); // client i was last heard at i ns
        try s.adopt(sv[0]);
    }
    defer for (peers) |p| {
        _ = c.close(p);
    };
    s.evictOldest();
    try testing.expectEqual(@as(usize, max_clients - 1), s.clients.items.len);
    for (s.clients.items) |cl| try testing.expect(cl.last_input != 0);
    // Unread output does not protect a client: the next oldest (client 1) goes.
    for (s.clients.items) |cl| try cl.out.append(testing.allocator, 'x');
    s.evictOldest();
    try testing.expectEqual(@as(usize, max_clients - 2), s.clients.items.len);
    for (s.clients.items) |cl| try testing.expect(cl.last_input > 1);
}

test "flush drops the written head when the socket stops taking data" {
    const sv = try socketPair();
    defer _ = c.close(sv[1]);
    var s: Server = .{ .gpa = testing.allocator };
    try s.clients.ensureTotalCapacity(testing.allocator, max_clients);
    defer s.deinit();
    try s.adopt(sv[0]);
    const cl = s.clients.items[0];
    try cl.out.appendNTimes(testing.allocator, 'x', 8 << 20);
    // A client that reads steadily but slower than the answers come: the written head must not pile up.
    var buf: [1 << 16]u8 = undefined;
    while (cl.pending() > 0) {
        try testing.expect(flush(cl, testing.allocator));
        try testing.expect(cl.out_pos < compact_min);
        if (cl.pending() > 0) _ = readSome(sv[1], &buf);
    }
}

test "accept pause keeps the listen socket out of the poll set" {
    var s: Server = .{ .gpa = testing.allocator, .listen_fd = 5 };
    var fds: [Server.max_fds]c.pollfd = undefined;
    s.accept_resume = 2000;
    _ = s.fillPoll(&fds, 1000);
    try testing.expectEqual(@as(c.fd_t, -1), fds[0].fd);
    _ = s.fillPoll(&fds, 2000);
    try testing.expectEqual(@as(c.fd_t, 5), fds[0].fd);
    try testing.expectEqual(@as(?i64, null), s.accept_resume);
    s.listen_fd = -1; // not a real descriptor: deinit must not close it
}

const PumpArgs = struct {
    s: *Server,
    ctx: *EchoCtx,
    stop: *std.atomic.Value(bool),
};

fn pumpThread(a: PumpArgs) void {
    while (!a.stop.load(.acquire)) round(a.s, a.ctx);
}

test "exchange: 50 000 pipelined requests with big answers do not deadlock" {
    const sv = try socketPair();
    defer _ = c.close(sv[0]);
    var s: Server = .{ .gpa = testing.allocator };
    try s.clients.ensureTotalCapacity(testing.allocator, max_clients);
    defer s.deinit();
    try s.adopt(sv[1]);
    var ctx: EchoCtx = .{};
    var stop: std.atomic.Value(bool) = .init(false);
    const th = try std.Thread.spawn(.{}, pumpThread, .{PumpArgs{ .s = &s, .ctx = &ctx, .stop = &stop }});

    const n = 50_000;
    var requests: std.Io.Writer.Allocating = .init(testing.allocator);
    defer requests.deinit();
    for (0..n) |i| {
        var pb: [96]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "/a/long/path/to/make/the/answers/big/{d:0>6}", .{i});
        try proto.writeRequest(&requests.writer, .size, p);
    }
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    const result = exchange(testing.allocator, sv[0], requests.written(), n, &reply);
    stop.store(true, .release);
    th.join();
    try result;
    var ends: usize = 0;
    var rest: []const u8 = reply.items;
    while (proto.nextFrame(rest)) |f| : (rest = rest[f.consumed..]) {
        if (f.frame.len == 0) ends += 1;
    }
    try testing.expectEqual(@as(usize, n), ends);
}
