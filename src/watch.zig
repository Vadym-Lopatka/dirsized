//! Change types shared by the platform watchers, and the platform selection.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Same type as `table.NodeId`; table.zig is not imported here on purpose.
pub const NodeId = u32;

pub const Change = union(enum) {
    /// macOS: absolute folder path, no trailing slash. `subtree`: re-read everything below it.
    path: struct { path: []const u8, subtree: bool },
    /// Linux: the folder of that watch.
    node: NodeId,
    /// Queue overflow or wrapped event ids: re-read every root.
    everything,
};

pub const StartResult = enum {
    /// Every change since the saved state will be delivered, then `caughtUp()` turns true.
    resumed,
    /// Only changes from now on; the caller must read every folder.
    fresh,
};

pub const Watcher = switch (builtin.os.tag) {
    .macos => @import("watch_darwin.zig").Watcher,
    .linux => @import("watch_linux.zig").Watcher,
    else => Stub,
};

/// Other systems watch nothing: a start is always fresh and the owner reads every folder.
const Stub = struct {
    pub fn init(gpa: Allocator, wake_fd: std.c.fd_t) !Stub {
        _ = .{ gpa, wake_fd };
        return .{};
    }

    pub fn deinit(self: *Stub) void {
        _ = self;
    }

    pub fn start(self: *Stub, roots: []const []const u8, saved: ?[]const u8) !StartResult {
        _ = .{ self, roots, saved };
        return .fresh;
    }

    pub fn stop(self: *Stub) void {
        _ = self;
    }

    pub fn pollFd(self: *const Stub) std.c.fd_t {
        _ = self;
        return -1;
    }

    pub fn drain(self: *Stub, ctx: anytype) !void {
        _ = .{ self, ctx };
    }

    pub fn caughtUp(self: *const Stub) bool {
        _ = self;
        return true;
    }

    pub fn checkpoint(self: *Stub) void {
        _ = self;
    }

    pub fn saveState(self: *const Stub, out: *std.ArrayList(u8), gpa: Allocator) !void {
        _ = .{ self, out, gpa };
    }
};

test "the selected Watcher has the contract's methods" {
    inline for (.{ "init", "deinit", "start", "stop", "pollFd", "drain", "caughtUp", "checkpoint", "saveState" }) |name| {
        try std.testing.expect(@hasDecl(Watcher, name));
    }
}
