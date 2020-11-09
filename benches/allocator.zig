const std = @import("std");

pub const Allocator = 
    if (std.builtin.link_libc) CAllocator
    else if (std.builtin.os.tag == .windows) WindowsAllocator
    else ThreadSafeAllocator;

const WindowsAllocator = struct {
    heap: std.heap.HeapAllocator,

    pub fn init(self: *@This()) !void {
        self.heap = std.heap.HeapAllocator.init();
    }

    pub fn deinit(self: *@This()) void {
        self.heap.deinit();
    }

    pub fn getAllocator(self: *@This()) *std.mem.Allocator {
        return &self.heap.allocator;
    }
};

const CAllocator = struct {
    pub fn init(self: *@This()) !void {}
    pub fn deinit(self: *@This()) void {}

    pub fn getAllocator(self: *@This()) *std.mem.Allocator {
        return std.heap.c_allocator;
    }
};

const ThreadSafeAllocator = struct {
    mutex: std.Mutex,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(self: *@This()) !void {
        self.mutex = std.Mutex{};
        self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        self.allocator = .{
            .allocFn = allocFn,
            .resizeFn = resizeFn,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    pub fn getAllocator(self: *@This()) *std.mem.Allocator {
        return &self.allocator;
    }

    fn allocFn(allocator: *std.mem.Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) std.mem.Allocator.Error![]u8 {
        const self = @fieldParentPtr(@This(), "allocator", allocator);

        const held = self.mutex.acquire();
        defer held.release();
        
        const arena = &self.arena.allocator;
        return arena.allocFn(arena, len, ptr_align, len_align, ret_addr);
    }

    fn resizeFn(allocator: *std.mem.Allocator, buf: []u8, old_align: u29, new_len: usize, len_align: u29, ret_addr: usize) std.mem.Allocator.Error!usize {
        const self = @fieldParentPtr(@This(), "allocator", allocator);

        const held = self.mutex.acquire();
        defer held.release();
        
        const arena = &self.arena.allocator;
        return arena.resizeFn(arena, buf, old_align, new_len, len_align, ret_addr);
    }
};