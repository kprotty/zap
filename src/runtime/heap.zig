const zap = @import("../zap.zig");
const target = zap.runtime.target;
const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const allocator: *Allocator = 
    if (target.has_libc)
        std.heap.c_allocator
    else if (target.is_windows)
        &(struct { var heap = std.heap.HeapAllocator.init(); }).heap.allocator
    else
        std.heap.page_allocator; // TODO: custom (basic) one for linux without libc
