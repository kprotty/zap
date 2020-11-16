const std = @import("std");
const Lock = @import("./lock.zig").Lock;
const Atomic = @import("../sync/sync.zig").core.atomic.Atomic;

const InnerHeap = 
    if (std.builtin.os.tag == .windows) WindowsHeap
    else if (std.builtin.link_libc) LibcHeap
    else ThreadSafeHeap;

var init_lock = Lock{};
var is_init = Atomic(bool).init(false);
var global_heap: InnerHeap = undefined;

pub fn getAllocator() *std.mem.Allocator {
    if (is_init.load(.seq_cst))
        return global_heap.getAllocator();

    init_lock.acquire();
    defer init_lock.release();

    if (!is_init.load(.seq_cst)) {
        global_heap.init();
        is_init.store(true, .seq_cst);
    }

    return global_heap.getAllocator();
}

const LibcHeap = struct {
    fn init(self: *LibcHeap) void {}

    fn getAllocator(self: *LibcHeap) *std.mem.Allocator {
        return std.heap.c_allocator;
    }
};

const WindowsHeap = struct {
    heap: std.heap.HeapAllocator,

    fn init(self: *WindowsHeap) void {
        self.heap = std.heap.HeapAllocator.init();
    }

    fn getAllocator(self: *WindowsHeap) *std.mem.Allocator {
        return &self.heap.allocator;
    }
};

const ThreadSafeHeap = struct {
    lock: Lock = Lock{},
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator = std.mem.Allocator{
        .allocFn = allocFn,
        .resizeFn = resizeFn,
    },

    fn init(self: *ThreadSafeHeap) void {
        self.* = ThreadSafeHeap{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    fn getAllocator(self: *ThreadSafeHeap) *std.mem.Allocator {
        return &self.allocator;
    }

    fn allocFn(allocator: *std.mem.Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) std.mem.Allocator.Error![]u8 {
        const self = @fieldParentPtr(ThreadSafeHeap, "allocator", allocator);
        self.lock.acquire();
        defer self.lock.release();
        return (self.arena.allocator.allocFn)(&self.arena.allocator, len, ptr_align, len_align, ret_addr);
    }

    fn resizeFn(allocator: *std.mem.Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) std.mem.Allocator.Error!usize {
        const self = @fieldParentPtr(ThreadSafeHeap, "allocator", allocator);
        self.lock.acquire();
        defer self.lock.release();
        return (self.arena.allocator.resizeFn)(&self.arena.allocator, buf, buf_align, new_len, len_align, ret_addr);
    }
};