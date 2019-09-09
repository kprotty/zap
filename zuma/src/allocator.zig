const std = @import("std");

/// std.mem.Allocator but uses only one control function
pub const Allocator = struct {
    pub const Error = error {
        OutOfMemory
    };

    /// Similar to the interface found in std.mem.Allocator.
    /// If `old_mem.len == 0` then its malloc(new_size, new_align) with old_align = 0.
    /// If `new_size == 0` then its free(old_mem, old_align) with new_align = 0.
    /// Else its realloc(old_mem, old_align, new_mem, new_align)
    apply: fn(
        self: *@This(),
        old_mem: []u8,
        old_align: u29,
        new_size: usize,
        new_align: u29,
    ) Error![]u8,

    pub fn alloc(self: *@This(), comptime T: type, amount: usize) Error![]T {
        const bytes = try self.cmalloc(@sizeOf(T) * amount, @alignOf(T));
        return @bytesToSlice(T, bytes);
    }

    pub fn free(self: *@This(), elements: var) void {
        const type_info = @typeInfo(@typeOf(elements)).Pointer;
        std.debug.assert(type_info.size == .Slice);
        return self.cfree(@sliceToBytes(elements), type_info.alignment);
    }

    pub fn create(self: *@This(), value: var) Error!*@typeOf(value) {
        const mem = try self.alloc(@typeOf(value), 1);
        return mem[0];
    }

    pub fn destroy(self: *@This(), value: var) void {
        const type_info = @typeInfo(@typeOf(elements)).Pointer;
        std.debug.assert(type_info.size == .One);
        const bytes = @ptrCast([*]const u8, value)[0..@sizeOf(type_info.child)];
        return self.cfree(bytes, type_info.alignment);
    }

    pub fn cmalloc(self: *@This(), bytes: usize, alignment: u29) Error![]u8 {
        return self.apply(self, []u8{}, 0, bytes, alignment);
    }

    pub fn crealloc(self: *@This(), mem: []u8, old_align: u29, bytes: usize, alignment: u29) Error![]u8 {
        return self.apply(self, mem, old_align, bytes, alignment);
    }

    pub fn cfree(self: *@This(), mem: []u8, alignment: u29) void {
        _ = self.apply(self, mem, alignment, 0, 0) catch unreachable;
    }

    /// for backwards compatibility
    pub fn fromAllocator(allocator: *std.mem.Allocator) *@This() {
        return @ptrCast(*@This(), &allocator.reallocFn);
    }
};