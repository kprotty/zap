const std = @import("std");
const os = std.os;

const Loop = @import("src/s3.zig");
const net = Loop.net;

pub fn main() !void {
    try (try Loop.run(asyncMain, .{}));
}

fn asyncMain() anyerror!void {
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    const address = try net.Address.parseIp("127.0.0.1", 3000);
    try server.listen(address);

    std.debug.print("Listening on {}", .{ address });
}