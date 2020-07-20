const std = @import("std");
const sync = @import("./src/sync.zig");
const Allocator = std.mem.Allocator;

pub const allocator = &allocator_state;
var allocator_state = Allocator{
    .reallocFn = realloc,
    .shrinkFn = shrink,
};

var lock = sync.thread.Lock.init();
var arena: std.heap.ArenaAllocator = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;

pub fn initCapacity(max_memory: usize) !void {
    const memory = try std.heap.page_allocator.alloc(u8, max_memory);
    fba = @TypeOf(fba).init(memory);
    arena = @TypeOf(arena).init(&fba.allocator);
}

fn realloc(self: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
    lock.acquire();
    defer lock.release();
    return arena.allocator.reallocFn(&arena.allocator, old_mem, old_align, new_size, new_align);
}

fn shrink(self: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
    lock.acquire();
    defer lock.release();
    return arena.allocator.shrinkFn(&arena.allocator, old_mem, old_align, new_size, new_align);
}