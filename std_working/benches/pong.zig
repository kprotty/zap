const Z = @import("./z.zig");

const num_tasks = 100_000;

pub fn main() !void {
    try Z.Task.runAsync(.{}, asyncMain, .{});
}

fn asyncMain() void {
    var wg = Z.WaitGroup.init(num_tasks);

    var i: usize = num_tasks;
    while (i > 0) : (i -= 1)
        Z.spawn(pingPong, .{&wg});

    wg.wait();
}

fn pingPong(wg: *Z.WaitGroup) void {
    defer wg.done();

    const Channel = Oneshot(void);
    const item = {};

    const Pong = struct {
        c1: Channel = Channel{},
        c2: Channel = Channel{},

        fn run(self: *@This()) void {
            self.c1.send(item);
            _ = self.c2.recv();
        }
    };

    var pong = Pong{};
    Z.spawn(Pong.run, .{&pong});
    
    _ = pong.c1.recv();
    pong.c2.send(item);
}

fn Oneshot(comptime T: type) type {
    return struct {
        waiter: ?*Waiter = null,

        const Self = @This();
        const Waiter = struct {
            item: T = undefined,
            task: Z.Task,
        };

        fn send(self: *Self, item: T) void {
            var waiter = Waiter{
                .task = Z.Task.initAsync(@frame()),
                .item = item,
            };

            suspend {
                if (@atomicRmw(?*Waiter, &self.waiter, .Xchg, &waiter, .AcqRel)) |receiver| {
                    receiver.item = waiter.item;
                    var batch = Z.Task.Batch.from(&receiver.task);
                    batch.push(&waiter.task);
                    batch.schedule(.{ .use_next = true, .use_lifo = true });
                }
            }
        }

        fn recv(self: *Self) T {
            var waiter = Waiter{
                .task = Z.Task.initAsync(@frame()),
            };

            suspend {
                if (@atomicRmw(?*Waiter, &self.waiter, .Xchg, &waiter, .AcqRel)) |sender| {
                    waiter.item = sender.item;
                    var batch = Z.Task.Batch.from(&waiter.task);
                    batch.push(&sender.task);
                    batch.schedule(.{ .use_next = true, .use_lifo = true });
                }
            }

            return waiter.item;
        }
    };
}
