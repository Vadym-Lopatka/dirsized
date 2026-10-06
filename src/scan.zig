//! FolderRead type and `readFolder`; selects the platform reader.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// `Transient`: out of descriptors or memory. Reading again may work once the pressure is gone.
/// Every other error is permanent for the scanner: an I/O error that repeats must not keep the
/// daemon busy for ever.
pub const ReadError = error{ AccessDenied, NotFound, NotDir, Transient, Unexpected };

/// The one mapping from an errno (`std.c.E` or `std.os.linux.E`) to a `ReadError`.
pub fn mapErrno(e: anytype) ReadError {
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.NotFound,
        // O_NOFOLLOW on a symlink gives ELOOP, or ENOTDIR together with O_DIRECTORY.
        .NOTDIR, .LOOP => error.NotDir,
        .MFILE, .NFILE, .NOMEM => error.Transient,
        else => error.Unexpected,
    };
}

/// Result of reading one folder. Owned by one worker and reused across calls.
pub const FolderRead = struct {
    /// Sum of the logical lengths of the regular files directly inside.
    own: u64 = 0,
    /// Child folder names, each followed by a 0 byte (names never contain NUL).
    names: std.ArrayList(u8) = .empty,
    count: u32 = 0,
    /// Linux with `ReadOptions.inotify_fd`: the watch number of this folder, or -1.
    wd: i32 = -1,
    /// The watch could not be added (the user's watch limit); the folder was still read.
    watch_failed: bool = false,
    /// Entries that could not be inspected (not counting ones that vanished meanwhile). The
    /// owner must not trust the child list then: a failed entry may be a folder.
    entry_errors: u32 = 0,

    /// Keeps the capacity, so a warm reader does not allocate.
    pub fn reset(self: *FolderRead) void {
        self.own = 0;
        self.names.clearRetainingCapacity();
        self.count = 0;
        self.wd = -1;
        self.watch_failed = false;
        self.entry_errors = 0;
    }

    pub fn deinit(self: *FolderRead, gpa: Allocator) void {
        self.names.deinit(gpa);
        self.* = .{};
    }

    /// Wraps: sparse files can add up past 2^64. A wrong size is better than a crash.
    pub fn addFile(self: *FolderRead, size: u64) void {
        self.own +%= size;
    }

    pub fn addDir(self: *FolderRead, gpa: Allocator, name: []const u8) Allocator.Error!void {
        try self.names.ensureUnusedCapacity(gpa, name.len + 1);
        self.names.appendSliceAssumeCapacity(name);
        self.names.appendAssumeCapacity(0);
        self.count += 1;
    }

    pub fn iterator(self: *const FolderRead) NameIterator {
        return .{ .rest = self.names.items };
    }
};

pub const ReadOptions = struct {
    /// Linux: add an inotify watch on the folder before it is opened. -1 = no watch.
    inotify_fd: i32 = -1,
};

pub const NameIterator = struct {
    rest: []const u8,

    pub fn next(self: *NameIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.rest, 0).?;
        defer self.rest = self.rest[end + 1 ..];
        return self.rest[0..end];
    }
};

/// Folders can be case-insensitive per volume (APFS default), so ask the volume that holds
/// the path. Elsewhere the answer is always "case-sensitive".
extern "c" fn pathconf(path: [*:0]const u8, name: c_int) c_long;
pub fn ignoreCase(path: [:0]const u8) bool {
    if (builtin.os.tag != .macos) return false;
    const _PC_CASE_SENSITIVE = 11;
    return pathconf(path, _PC_CASE_SENSITIVE) == 0;
}

const impl = switch (builtin.os.tag) {
    .macos => @import("scan_darwin.zig"),
    .linux => @import("scan_linux.zig"),
    else => struct {
        fn readFolder(_: Allocator, _: [:0]const u8, _: ReadOptions, _: *FolderRead) (ReadError || Allocator.Error)!void {
            return error.Unexpected;
        }
    },
};

/// Reads ONE folder (not recursive). `out` is reset first and reused across calls. Symlinks,
/// special files and mount points are ignored, `dir_path` itself is never followed if it is a
/// symlink (`NotDir`). On error the contents of `out` are empty.
pub fn readFolder(gpa: Allocator, dir_path: [:0]const u8, opts: ReadOptions, out: *FolderRead) (ReadError || Allocator.Error)!void {
    out.reset();
    errdefer out.reset();
    return impl.readFolder(gpa, dir_path, opts, out);
}

test "FolderRead names round trip" {
    const gpa = std.testing.allocator;
    var r: FolderRead = .{};
    defer r.deinit(gpa);
    try r.names.appendSlice(gpa, "a b\x00x\ny\x00é\x00");
    r.count = 3;
    var it = r.iterator();
    try std.testing.expectEqualStrings("a b", it.next().?);
    try std.testing.expectEqualStrings("x\ny", it.next().?);
    try std.testing.expectEqualStrings("é", it.next().?);
    try std.testing.expectEqual(null, it.next());
    r.reset();
    it = r.iterator();
    try std.testing.expectEqual(null, it.next());
}

test "only resource pressure is transient" {
    const E = std.posix.E;
    try std.testing.expectEqual(error.Transient, mapErrno(E.MFILE));
    try std.testing.expectEqual(error.Transient, mapErrno(E.NFILE));
    try std.testing.expectEqual(error.Transient, mapErrno(E.NOMEM));
    try std.testing.expectEqual(error.Unexpected, mapErrno(E.IO));
    try std.testing.expectEqual(error.Unexpected, mapErrno(E.AGAIN));
    try std.testing.expectEqual(error.AccessDenied, mapErrno(E.ACCES));
    try std.testing.expectEqual(error.NotDir, mapErrno(E.LOOP));
    try std.testing.expectEqual(error.Unexpected, mapErrno(E.NAMETOOLONG));
}

test "sizes wrap instead of panicking" {
    var r: FolderRead = .{};
    r.addFile(1 << 63);
    r.addFile(1 << 63);
    r.addFile(5);
    try std.testing.expectEqual(5, r.own);
}

test {
    _ = impl;
}

