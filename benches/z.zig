pub const std = @import("std");
pub const zap = @import("zap");

pub const Task = zap.runtime.Task;
pub const Allocator = std.mem.Allocator;

pub fn spawn(comptime func: anytype, args: anytype) void {
    const Args = @TypeOf(args);
    const Decorator = struct {
        fn run(alloc: *Allocator, fn_args: Args) void {
            Task.runConcurrentlyAsync();
            const result = @call(.{}, func, fn_args);
            suspend alloc.destroy(@frame());
        }
    };

    const allocator = getAllocator();
    const frame = allocator.create(@Frame(Decorator.run)) catch @panic("error.OutOfMemory");
    frame.* = async Decorator.run(allocator, args);
}

pub const WaitGroup = struct {
    counter: usize,
    state: usize,

    pub fn init(count: usize) WaitGroup {
        return WaitGroup{
            .counter = count,
            .state = 0,
        };
    }

    pub fn wait(self: *WaitGroup) void {
        var task = Task.initAsync(@frame());
        suspend {
            if (@atomicRmw(usize, &self.state, .Xchg, @ptrToInt(&task), .AcqRel) == 1)
                task.schedule();
        }
    }

    pub fn done(self: *WaitGroup) void {
        if (@atomicRmw(usize, &self.counter, .Sub, 1, .Monotonic) != 1)
            return;
        if (@intToPtr(?*Task, @atomicRmw(usize, &self.state, .Xchg, 1, .Acquire))) |waiter|
            waiter.schedule();
    }
};

var has_global_heap = false;
var global_heap: Heap = undefined;
var global_heap_mutex = std.Mutex{};

pub fn getAllocator() *Allocator {
    if (@atomicLoad(bool, &has_global_heap, .Acquire))
        return global_heap.getAllocator();
    return getAllocatorSlow();
}

fn getAllocatorSlow() *Allocator {
    @setCold(true);

    const held = global_heap_mutex.acquire();
    defer held.release();

    if (!@atomicLoad(bool, &has_global_heap, .Monotonic)) {
        global_heap.init();
        @atomicStore(bool, &has_global_heap, true, .Release);
    }

    return global_heap.getAllocator();
}

const Heap = 
    if (std.builtin.link_libc) CHeap
    else if (std.builtin.os.tag == .windows) WindowsHeap
    else ThreadSafeHeap;

const WindowsHeap = struct {
    heap: std.heap.HeapAllocator,

    pub fn init(self: *@This()) void {
        self.heap = std.heap.HeapAllocator.init();
    }

    pub fn deinit(self: *@This()) void {
        self.heap.deinit();
    }

    pub fn getAllocator(self: *@This()) *Allocator {
        return &self.heap.allocator;
    }
};

const CHeap = struct {
    pub fn init(self: *@This()) void {}
    pub fn deinit(self: *@This()) void {}

    pub fn getAllocator(self: *@This()) *Allocator {
        return std.heap.c_allocator;
    }
};

const ThreadSafeHeap = struct {
    mutex: std.Mutex,
    arena: std.heap.ArenaAllocator,
    allocator: Allocator,

    pub fn init(self: *@This()) void {
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

    pub fn getAllocator(self: *@This()) *Allocator {
        return &self.allocator;
    }

    fn allocFn(allocator: *Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) Allocator.Error![]u8 {
        const self = @fieldParentPtr(@This(), "allocator", allocator);

        const held = self.mutex.acquire();
        defer held.release();
        
        const arena = &self.arena.allocator;
        return arena.allocFn(arena, len, ptr_align, len_align, ret_addr);
    }

    fn resizeFn(allocator: *Allocator, buf: []u8, old_align: u29, new_len: usize, len_align: u29, ret_addr: usize) Allocator.Error!usize {
        const self = @fieldParentPtr(@This(), "allocator", allocator);

        const held = self.mutex.acquire();
        defer held.release();
        
        const arena = &self.arena.allocator;
        return arena.resizeFn(arena, buf, old_align, new_len, len_align, ret_addr);
    }
};