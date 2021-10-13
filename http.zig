const std = @import("std");
const os = std.os;

const Loop = @import("src/s3.zig");
const net = Loop.net;

pub fn main() !void {
    try (try Loop.run(asyncMain, .{}));
}

fn asyncMain() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());

    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    const address = try net.Address.parseIp("127.0.0.1", 3000);
    try server.listen(address);

    std.debug.print("Listening on {}\n", .{ address });
    while (true) {
        std.debug.print("waiting for conn..\n", .{});
        
        const conn = try server.accept();
        std.debug.print("Got conn {}\n", .{conn});
    }
}