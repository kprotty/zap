const std = @import("std");
const zap = @import("zap");

const Task = zap.runtime.Task;
const allocator = std.heap.page_allocator;

const num_tasks = 100_000;

pub fn main() !void {
    try (try Task.runAsync(.{}, asyncMain, .{}));
}

fn asyncMain() !void {
    const frames = try allocator.alloc(@Frame(pingPong), num_tasks);
    defer allocator.free(frames);

    var counter: usize = num_tasks;
    for (frames) |*frame| 
        frame.* = async pingPong(&counter);
    for (frames) |*frame|
        await frame;

    const count = @atomicLoad(usize, &counter, .Monotonic);
    if (count != 0)
        std.debug.panic("bad counter", .{});
}

fn pingPong(counter: *usize) void {
    Task.runConcurrentlyAsync();

    const Channel = Oneshot(void);
    const item = {};

    const Pong = struct {
        c1: Channel = Channel{},
        c2: Channel = Channel{},

        fn run(self: *@This()) void {
            Task.runConcurrentlyAsync();
            self.c1.send(item);
            std.debug.assert(self.c2.recv() == item);
        }
    };

    var pong = Pong{};
    var frame = async pong.run();
    std.debug.assert(pong.c1.recv() == item);
    pong.c2.send(item);
    await frame;

    _ = @atomicRmw(usize, counter, .Sub, 1, .Monotonic);
}

fn Oneshot(comptime T: type) type {
    return struct {
        waiter: ?*Waiter = null,

        const Self = @This();
        const Waiter = struct {
            item: T = undefined,
            task: Task,
        };

        fn send(self: *Self, item: T) void {
            var waiter = Waiter{
                .task = Task.initAsync(@frame()),
                .item = item,
            };

            suspend {
                if (@atomicRmw(?*Waiter, &self.waiter, .Xchg, &waiter, .AcqRel)) |receiver| {
                    receiver.item = waiter.item;
                    var batch = Task.Batch.from(&receiver.task);
                    batch.push(&waiter.task);
                    batch.schedule(.{ .use_next = true, .use_lifo = true });
                }
            }
        }

        fn recv(self: *Self) T {
            var waiter = Waiter{ .task = Task.initAsync(@frame()) };

            suspend {
                if (@atomicRmw(?*Waiter, &self.waiter, .Xchg, &waiter, .AcqRel)) |sender| {
                    waiter.item = sender.item;
                    var batch = Task.Batch.from(&waiter.task);
                    batch.push(&sender.task);
                    batch.schedule(.{ .use_next = true, .use_lifo = true });
                }
            }

            return waiter.item;
        }
    };
}
