const std = @import("std");
const os = std.os;

const Loop = @import("src/s3.zig");
const net = Loop.net;

pub fn main() !void {
    try (try Loop.run(runServer, .{}));
}

fn runServer() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = &gpa.allocator;

    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    const address = try net.Address.parseIp("127.0.0.1", 3000);
    try server.listen(address);

    std.debug.print("Listening on {}\n", .{ address });
    while (true) {
        const conn = try server.accept();
        errdefer conn.stream.close();

        const client = try allocator.create(@Frame(runClient));
        client.* = async runClient(conn.stream, allocator);
    }
}

fn runClient(stream: net.Stream, allocator: *std.mem.Allocator) anyerror!void {
    defer {
        stream.close();
        suspend { allocator.destroy(@frame()); }
    }

    std.debug.warn("handling {}\n", .{stream});
}