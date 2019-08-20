const std = @import("std");
const builtin = @import("builtin");
const thread = @import("thread.zig");
const scheduler = @import("scheduler.zig");

pub fn AtomicStack(comptime Node: type, comptime Field: []const u8) type {
    const field_type = @typeInfo(@typeInfo(@typeOf(@field(Node(undefined), Field))).Optional.child).Pointer;
    comptime std.debug.assert(field_type.size == .One and field_type.child == Node);

    return struct {
        top: ?*Node,
        count: usize,

        pub fn init(self: *@This()) void {
            self.count = 0;
            self.top = null;
        }

        pub fn size(self: *@This()) usize {
            return @atomicLoad(usize, &self.count, .Acquire);
        }
        
        pub fn put(self: *@This(), node: *Node) void {
            _ = @atomicRmw(usize, &self.count, .Add, 1, .Release);
            @field(node, Field) = @atomicLoad(?*Node, &self.top, .Monotonic);
            while (@cmpxchgWeak(?*Node, &self.top, @field(node, Field), node, .Release, .Monotonic)) |new_top|
                @field(node, Field) = new_top;
        }

        pub fn get(self: *@This()) ?*Node {
            var top = @atomicLoad(?*Node, &self.top, .Monotonic) orelse return null;
            while (@cmpxchgWeak(?*Node, &self.top, top, @field(top, Field), .Acquire, .Monotonic)) |new_top|
                top = new_top orelse return null;
            _ = @atomicRmw(usize, &self.count, .Sub, 1, .Release);
        }
    };
}

pub const Mutex = struct {
    const UNLOCKED  = 0;
    const LOCKED    = 1;
    const SLEEPING  = 2;

    const SPIN_YIELD    = 30;
    const ACTIVE_SPIN   = 4;
    const PASSIVE_SPIN  = 1;

    futex: Futex,

    pub fn init(self: *@This()) void {
        self.futex.init(UNLOCKED);
    }

    pub fn acquire(self: *@This()) void {
        var wait = @atomicRmw(u32, &self.futex.value, .Xchg, LOCKED, .Acquire);
        const spin_for = if (scheduler.system.isUniCore()) 0 else ACTIVE_SPIN;
        if (wait == UNLOCKED) return;
        var i: usize = undefined;

        while (true) {
            if (self.spin(wait, spin_for, SPIN_YIELD, thread.yieldCpu)) return;
            if (self.spin(wait, PASSIVE_SPIN, 0, thread.yield)) return;
            if (@atomicRmw(u32, &self.futex.value, .Xchg, SLEEPING, .Acquire) == UNLOCKED) return;
            wait = SLEEPING;
            self.futex.wait(SLEEPING, null);
        }
    }

    pub fn release(self: *@This()) void {
        switch (@atomicRmw(u32, &self.futex.value, .Xchg, UNLOCKED, .Release)) {
            UNLOCKED => @panic("Invalid mutex state"),
            SLEEPING => self.futex.wake(false),
            else => {}
        }
    }

    fn spin(self: *@This(), exchange: u32, spin_count: usize, comptime spin_yield: usize, yield: fn()void) bool {
        while (spin_count > 0) : (spin_count -= 1) {
            _ = @cmpxchgWeak(&self.futex.value, UNLOCKED, exchange, .Acquire, .Monotonic) orelse return true;
            for ([_]usize{0} ** spin_yield) |_| _ = yield();
        }
        return false;
    }
};

pub const Futex = switch (builtin.os) {
    .windows => WaitAddress,
    .linux => if (builtin.link_libc) PthreadCond else LinuxFutex,
    else => PthreadCond,
};

const WaitAddress = struct {
    const windows = std.os.windows;
    pub const Value = usize;

    value: Value,

    extern "Synchronization" stdcallcc fn WakeByAddressSingle(Address: windows.PVOID) void;
    extern "Synchronization" stdcallcc fn WakeByAddressAll(Address: windows.PVOID) void;
    extern "Synchronization" stdcallcc fn WaitOnAddress(
        Address: windows.PVOID,
        CompareAddress: windows.PVOID,
        AddressSize: windows.SIZE_T,
        dwMilliseconds: windows.DWORD,
    ) windows.BOOL;

    pub fn init(self: *@This(), value: Value) void {
        self.value = value;
    }

    pub fn wake(self: *@This(), everyone: bool) void {
        const address = @ptrCast(windows.PVOID, &self.value);
        if (everyone) WakeByAddressAll(address) else WakeByAddressSingle(address);
    }

    pub fn wait(self: *@This(), expect: Value, timeout_ms: ?usize) void {
        var expected = expect;
        _ = WaitOnAddress(
            @ptrCast(windows.PVOID, &self.value),
            @ptrCast(windows.PVOID, &expected),
            @sizeOf(@typeOf(self.value)),
            timeout_ms orelse windows.INFINITE,
        );
    }
};

const LinuxFutex = struct {
    const linux = std.os.linux;
    pub const Value = i32;

    value: Value,

    pub fn init(self: *@This(), value: Value) void {
        self.value = value;
    }

    pub fn wake(self: *@This(), everyone: bool) void {
        const OP = linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG;
        _ = linux.futex_wake(&self.value, OP, self.value);
    }

    pub fn wait(self: *@This(), expect: Value, timeout_ms: ?usize) void {
        const OP = linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG;
        var timeout = timespec {
            .tv_sec = 0,
            .tv_nsec = (timeout_ms orelse 0) * 1000000,
        };
        _ = linux.futex_wait(&self.value, OP, value, if (timeout_ms == null) null else &timeout);
    }
};

const PthreadCond = struct {

};