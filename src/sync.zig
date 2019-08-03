const std = @import("std");
const builtin = @import("builtin");

pub inline fn cpuRelax() void {
    switch (builtin.arch) {
        .x86_64, .i386 => asm volatile("pause" ::: "memory"),
        else => {}
    }
}

pub fn LazyInit(comptime T: type, comptime initialize: fn() T) type {
    return struct {
        const Uninitialized = 0;
        const Initializing = 1;
        const Initialized = 2;

        state: u8,
        value: T,

        pub fn new() @This() {
            return @This() {
                .state = Uninitialized,
                .value = undefined, 
            };
        }

        pub fn get(self: *@This()) *T {
            if (@cmpxchgWeak(u8, &self.state, Uninitialized, Initializing, .Acquire, .Acquire)) |_| {
                while (@atomicLoad(u8, &self.state, .Unordered) != Initialized)
                    cpuRelax();
                return &self.value;
            }

            self.value = initialize();
            // TODO replace with atomicStore (https://github.com/ziglang/zig/issues/2995)
            @ptrCast(*volatile u8, &self.state).* = Initialized;
            return &self.value;
        }
    };
}

test "lazy init" {
    const Lazy = struct {
        var num_called: usize = 0;
        var value = LazyInit(u32, init_value).new();

        fn init_value() u32 {
            _ = @atomicRmw(usize, &num_called, .Add, 1, .Monotonic);
            return 42;
        }
    };

    std.debug.assert(@atomicLoad(usize, &Lazy.num_called, .Unordered) == 0);
    std.debug.assert(Lazy.value.get().* == u8(42));
    std.debug.assert(@atomicLoad(usize, &Lazy.num_called, .Unordered) == 1);
}