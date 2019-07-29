const std = @import("std");

const Output = std.io.OutStream(anyerror);
fn output(self: *Output, bytes: []const u8) anyerror!void {
    if (bytes.len == 0) return error.No;
    std.debug.warn("{}", bytes);
}

pub fn main() !void {
    var o = Output { .writeFn = output };
    var a = std.heap.LoggingAllocator.init(std.debug.global_allocator, &o);

    const p = try exampleCall(&a.allocator, testFunc, u32(5));//try async<&a.allocator> testFunc();
    const t = try std.Thread.spawn(p, exampleThread);
    t.wait();
}

fn exampleCall(a: *std.mem.Allocator, comptime f: var, args: ...) !promise->@typeOf(f).ReturnType {
    return try async<a> f(args);
}

fn exampleThread(p: promise->void) void {
    resume p;
}

async fn testFunc(x: u32) void {
    const message = "some data";
    var buffer: [4096]u8 = undefined;
    std.mem.copy(u8, buffer[0..message.len], message);

    std.debug.warn("Its currently: \t0x{x}->0x{x} ", @ptrToInt(@handle()), @ptrToInt(&buffer[0]));
    std.debug.warn("{}\n", buffer[0..message.len]);
    suspend;

    std.debug.warn("Its now: \t0x{x}->0x{x} ", @ptrToInt(@handle()), @ptrToInt(&buffer[0]));
    std.debug.warn("{}\n", buffer[0..message.len]);
}