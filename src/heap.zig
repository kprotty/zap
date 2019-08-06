const std = @import("std");

pub const Heap = struct {
    allocator: std.mem.Allocator,

    pub fn init(self: *Heap) void {
        self.allocator = std.debug.allocator.*; // TODO: mimalloc
    }
}