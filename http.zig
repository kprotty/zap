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

    errdefer |err| {
        std.debug.warn("client {} got err {}\n", .{stream, err});
    }

    var offset: usize = 0;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const req_buf = buffer[0..offset];
        const clrf = "\r\n\r\n";

        if (std.mem.indexOf(u8, req_buf, clrf)) |req_end| {
            const request = req_buf[0..req_end + clrf.len];
            std.mem.copyBackwards(u8, &buffer, request);
            offset -= request.len;

            const resp = "HTTP/1.1 200 Ok\r\nContent-Length: 10\r\nContent-Type: text/plain; charset=utf8\r\n\r\nHelloWorld";
            try stream.writer().writeAll(resp);
            continue;
        }

        const read_buf = buffer[offset..];
        if (read_buf.len == 0)
            return error.RequestTooBig;

        const bytes = try stream.read(read_buf);
        offset += bytes;
        if (bytes == 0)
            return error.Eof;
    }
}