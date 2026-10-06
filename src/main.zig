const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    return cli.run(init);
}

test {
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("ignore.zig");
    _ = @import("table.zig");
    _ = @import("scan.zig");
    _ = @import("scanner.zig");
    _ = @import("proto.zig");
    _ = @import("paths.zig");
    _ = @import("watch.zig");
    _ = @import("server.zig");
    _ = @import("daemon.zig");
    _ = @import("snapshot.zig");
}
