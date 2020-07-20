const std = @import("std");
const zap = @import("zap");

const Lock = struct {
    mutex: std.Mutex = std.Mutex.init(),

    fn acquire(self: *Lock) void {
        _ = self.mutex.acquire();
    }

    fn release(self: *Lock) void {
        const held = std.Mutex.Held{ .mutex = &self.mutex };
        held.release();
    }
};

const Link = zap.Link;
const Builder = zap.Builder;
const Runnable = zap.Runnable;

var fba: std.heap.FixedBufferAllocator = undefined;
var arena: std.heap.ArenaAllocator = undefined;
var allocator: *std.mem.Allocator = undefined;
var allocator_lock = Lock{};

const N = 1 * 1000 * 1000;

pub fn main() !void {
    const heap = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
    const buffer = try heap.alloc(u8, 200 * 1024 * 1024);
    defer heap.free(buffer);
    fba = std.heap.FixedBufferAllocator.init(buffer);
    arena = std.heap.ArenaAllocator.init(&fba.allocator);
    allocator = &arena.allocator;

    const array = try heap.alloc(u32, N);
    defer heap.free(array);

    var rng: u32 = @truncate(u32, @ptrToInt(array.ptr) * 31);
    for (array) |*item| {
        const value = blk: {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            break :blk rng;
        };
        item.* = value;
    }

    var caller = Qsort.Caller{.result = null, .root = null};
    var qsort = Qsort.init(&caller, array, 0, @intCast(isize, array.len - 1));
    var builder = Builder{};

    std.debug.assert(!isSorted(array));
    try builder.run(&qsort.runnable);

    try caller.result.?;
    std.debug.assert(isSorted(array));
}

fn isSorted(array: []const u32) bool {
    var highest: u32 = 0;
    for (array) |item| {
        if (item < highest)
            return false;
        highest = std.math.max(item, highest);
    }
    return true;
}

const Qsort = struct {
    runnable: Runnable,
    state: State,

    const Caller = struct {
        result: ?std.mem.Allocator.Error!void,
        root: ?*Qsort,
    };

    const State = union(enum) {
        entry: struct {
            array: []u32,
            low: isize,
            high: isize,
            caller: *Caller,
        },
        partitioned: struct {
            leafs: [*]Qsort,
            lhs: Caller,
            rhs: Caller,
            caller: *Caller,
            completed: usize,
        },
        exit: void,
    };

    fn init(caller: *Caller, array: []u32, low: isize, high: isize) Qsort {
        return Qsort{
            .runnable = Runnable.init(.High, Qsort.run),
            .state = .{.entry = .{
                .array = array,
                .low = low,
                .high = high,
                .caller = caller,
            }},
        };
    }

    fn run(
        noalias runnable: *Runnable,
        noalias context: Runnable.Context,
    ) callconv(.C) ?*Runnable {
        const self = @fieldParentPtr(Qsort, "runnable", runnable);

        switch (self.state) {
            .entry => |*state| {
                const low = state.low;
                const high = state.high;
                const array = state.array;
                const caller = state.caller;
            
                const leafs = blk: {
                    allocator_lock.acquire();
                    defer allocator_lock.release();
                    break :blk allocator.alloc(Qsort, 2) catch |err| {
                        return self.complete(caller, err);
                    };
                };

                var i = low;
                var j = high;
                const middle = @divFloor(high - low, 2) + low;
                const pivot = array[@intCast(usize, middle)];
                while (i <= j) {
                    while (array[@intCast(usize, i)] < pivot)
                        i += 1;
                    while (array[@intCast(usize, j)] > pivot)
                        j -= 1;
                    if (i <= j) {
                        std.mem.swap(u32, &array[@intCast(usize, i)], &array[@intCast(usize, j)]);
                        i += 1;
                        j -= 1;
                    }
                }

                self.state = .{.partitioned = .{
                    .leafs = leafs.ptr,
                    .lhs = .{
                        .result = null,
                        .root = self,
                    },
                    .rhs = .{
                        .result = null,
                        .root = self,
                    },
                    .caller = caller,
                    .completed = 0,
                }};

                var batch = Link.Queue{};
                if (low < j) {
                    leafs[0] = Qsort.init(&self.state.partitioned.lhs, array, low, j);
                    batch.push(.Front, leafs[0].runnable.getLink());
                } else {
                    self.state.partitioned.lhs.result = {};
                    self.state.partitioned.completed += 1;
                }
                if (i < high) {
                    leafs[1] = Qsort.init(&self.state.partitioned.rhs, array, i, high);
                    batch.push(.Front, leafs[1].runnable.getLink());
                } else {
                    self.state.partitioned.rhs.result = {};
                    self.state.partitioned.completed += 1;
                }

                const next = batch.pop() orelse return &self.runnable;
                context.schedule(.Local, batch);
                return Runnable.fromLink(next);
            },
            .partitioned => |*state| {
                const completed = @atomicLoad(usize, &state.completed, .Acquire);
                std.debug.assert(completed == 2);
                
                {
                    allocator_lock.acquire();
                    defer allocator_lock.release();
                    allocator.free(state.leafs[0..2]);
                }

                return self.complete(state.caller, blk: {
                    const lhs = state.lhs.result.?;
                    const rhs = state.rhs.result.?;
                    _ = lhs catch |err| break :blk err;
                    _ = rhs catch |err| break :blk err;
                    break :blk {};
                });
            },
            .exit => unreachable,
        }
    }

    fn complete(
        noalias self: *Qsort,
        noalias caller: *Caller,
        result: std.mem.Allocator.Error!void,
    ) ?*Runnable {
        self.state = .{.exit = {}};
        caller.result = result;

        if (caller.root) |root| {
            const completed = @atomicRmw(usize, &root.state.partitioned.completed, .Add, 1, .Release);
            std.debug.assert(completed < 2);
            if (completed == 1)
                return &root.runnable;
        }

        return null;
    }
};