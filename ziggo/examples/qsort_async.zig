const std = @import("std");
const zap = @import("zap");

const Lock = zap.sync.thread.Lock;

const N = 1 * 1000 * 1000;

// Uncomment to use std.event.Loop
pub const io_mode = .evented;
const use_event_loop = @hasDecl(@import("root"), "io_mode");

var fba: std.heap.FixedBufferAllocator = undefined;
var arena: std.heap.ArenaAllocator = undefined;
var allocator: *std.mem.Allocator = undefined;
var allocator_lock = Lock.init();

pub fn main() !void {
    const heap_allocator = 
        if (std.builtin.link_libc) std.heap.c_allocator
        else std.heap.page_allocator;

    const buffer = try heap_allocator.alloc(u8, 3 * 1024 * 1024 * 1024);
    defer heap_allocator.free(buffer);
    fba = std.heap.FixedBufferAllocator.init(buffer);
    arena = std.heap.ArenaAllocator.init(&fba.allocator);
    allocator = &arena.allocator;

    const array = try heap_allocator.alloc(u32, N);
    defer heap_allocator.free(array);

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

    std.debug.assert(!isSorted(array));
    if (use_event_loop) {
        try qsort(array, 0, @intCast(isize, array.len - 1));
    } else {
        const result = try zap.Task.run(.{}, qsort, .{array, 0, @intCast(isize, array.len - 1)});
        try result;
    }
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

fn qsort(array: []u32, low: isize, high: isize) std.mem.Allocator.Error!void {
    if (low >= high)
        return;

    if (use_event_loop) {
        std.event.Loop.startCpuBoundOperation();
    } else {
        const context = zap.Task.getContext() orelse unreachable;
        context.yield(.High);
    }

    var i = low;
    var j = high;
    const pivot = array[@intCast(usize, @divFloor(high - low, 2) + low)];
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

    var frame_l: *@Frame(qsort) = undefined;
    var frame_r: *@Frame(qsort) = undefined;
    {
        allocator_lock.acquire();
        defer allocator_lock.release();
        frame_l = try allocator.create(@Frame(qsort));
        errdefer allocator.destroy(frame_l);
        frame_r = try allocator.create(@Frame(qsort));
    }

    frame_l.* = async qsort(array, low, j);
    frame_r.* = async qsort(array, i, high);

    const res_l = await frame_l;
    const res_r = await frame_r;

    {
        allocator_lock.acquire();
        defer allocator_lock.release();
        allocator.destroy(frame_l);
        allocator.destroy(frame_r);
    }

    try res_l;
    try res_r;
}
