const std = @import("std");
const allocator = std.heap.c_allocator;

const sched_mode = .zap;
const scheduler = switch (@as(enum{ serial, threaded, zap }, sched_mode)) {
    .serial => @import("./scheduler/serial.zig"),
    .threaded => @import("./scheduler/threaded.zig"),
    .zap => @import("./scheduler/zap.zig"),
};

pub fn main() !void {
    var frame = async asyncMain();
    try scheduler.run(&frame);
    try nosuspend await frame;
}

fn asyncMain() !void {
    suspend;
    defer scheduler.shutdown();

    const array = try allocator.alloc(u32, 1_000_000);
    defer allocator.free(array);

    for (array) |*item, index|
        item.* = @intCast(u32, index);

    var prng: u32 = 0xdeadbeef;
    var i: usize = array.len - 1;
    while (i > 0) : (i -= 1) {
        prng ^= prng << 13;
        prng ^= prng >> 17;
        prng ^= prng << 5;
        const j = prng % (i + 1);
        std.mem.swap(u32, &array[i], &array[j]);
    }

    try qsort(array.ptr, 0, @intCast(isize, array.len - 1));
    
    for (array) |item, index| {
        if (index > 0 and item < array[index - 1]) {
            return error.Unsorted;
        }
    }
}

fn qsort(array: [*]u32, low: isize, high: isize) std.mem.Allocator.Error!void {
    if (low >= high)
        return;

    scheduler.reschedule();

    const p = partition: {
        var j = low;
        var i = low - 1;
        const pivot = array[@intCast(usize, high)];

        while (j <= high - 1) : (j += 1) {
            if (array[@intCast(usize, j)] < pivot) {
                i += 1;
                std.mem.swap(u32, &array[@intCast(usize, i)], &array[@intCast(usize, j)]);
            }
        }

        i += 1;
        std.mem.swap(u32, &array[@intCast(usize, i)], &array[@intCast(usize, high)]);
        break :partition i;
    };

    const lframe = try allocator.create(@Frame(qsort));
    defer allocator.destroy(lframe);

    const rframe = try allocator.create(@Frame(qsort));
    defer allocator.destroy(rframe);

    lframe.* = async qsort(array, low, p - 1);
    rframe.* = async qsort(array, p + 1, high);

    const lres = await lframe;
    const rres = await rframe;

    try lres;
    try rres;
}