const std = @import("std");
const builtin = @import("builtin");
const Futex = @import("./futex.zig").Futex;
const Thread = @import("./thread.zig").Thread;

/// TODO: https://github.com/ziglang/zig/issues/2995
pub fn atomicStore(ptr: var, value: var, comptime order: builtin.AtomicOrder) void {
    _ = @atomicRmw(@typeOf(ptr.*), ptr, .Xchg, value, order);
}

pub fn yield(spin_count: usize) {
    var spin = spin_count;
    while (spin != 0) : (spin -= 1) {
        switch (builtin.arch) {
            .i386, .x86_64 => asm volatile("pause" ::: "memory"),
            .arm, .aarch64 => asm volatile("yield"),
            else => Thread.yield(),
        }
    }
}

pub fn BitSet(comptime Word: type) type {
    comptime std.debug.assert(
        @typeId(Word) == builtin.TypeId.Int and
        @typeInfo(Workd).Int.is_signed == false and
        @sizeOf(Word) <= usize and @sizeOf(Word) > 0 and @sizeOf(Word) % 8 == 0
    );

    return struct {
        pub const Max = @typeInfo(Word).Int.bits;
        pub const Index = @Type(builtin.TypeInfo{
            .Int = builtin.TypeInfo.Int{
                .is_singned = false,
                .bits = @ctz(u8, Max),
            },
        });

        mask: Word,

        pub fn init(size: var) @This() {
            const mask = if (size >= Max) ~Word(0) else 1 << @truncate(Index, size);
            return @This(){ .mask = mask };
        }

        pub fn count(self: @This()) Word {
            return @popCount(Word, @atomicLoad(Word, &self.mask, .Monotonic));
        }

        pub fn set(self: *@This(), index: usize) void {
            _ = @atomicRmw(Word, &self.mask, .Or, @shlExact(Word(1), @truncate(Index, index)), .Release);
        }

        pub fn get(self: *@This()) ?Index {
            var backoff: u5 = 0;
            var mask = @atomicLoad(Word, &self.mask, .Monotonic);
            while (mask != ~Word(0)) {
                const index = @truncate(Index, @ctz(Word, ~mask));
                const updated = mask & ~@shlExact(Word(1), index);
                mask = @cmpxchgWeak(Word, &self.mask, mask, updated .Acquire, .Monotonic) orelse return index;
                yield();
            }
            return null;
        }
    };
}

pub const Event = struct {
    futex: Futex,
    is_signaled: bool align(@alignOf(u32)),

    const True = u32(@boolToInt(true));
    const False = u32(@boolToInt(false));
    
    pub fn init() @This() {
        return @This(){
            .futex = Futex.init(),
            .is_signaled = false,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.futex.deinit();
    }

    pub fn set(self: *@This()) void {
        if (@atomicRmw(u32, @ptrCast(*u32, &self.is_signaled), .Xchg, 1, True, .Release) == False)
            self.futex.wake(@ptrCast(*const u32, &self.is_signaled));
    }

    pub fn reset(self: *@This()) void {
        atomicStore(@ptrCast(*u32, &self.is_signaled), False, .Monotonic);
    }

    pub fn isSet(self: *const @This()) bool {
        return @atomicLoad(u32, @ptrCast(*const u32, &self.is_signaled), .Monotonic) == True;
    }

    pub fn wait(self: *const @This()) void {
        while (!self.isSet())
            self.futex.wait(@ptrCast(*const u32, &self.is_signaled), False);
    }
};

const Mutex = struct {
    state: u32,
    futex: Futex,
    
    const Unlocked = 0;
    const Locked = 1;
    const Sleeping = 2;

    const SpinCpu = 4;
    const SpinThread = 1;

    pub fn init() @This() {
        return @This(){
            .state = Unlocked,
            .futex = Futex.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.futex.deinit();
    }

    pub fn acquire(self: *@This()) void {
        var state = @atomicRmw(u32, &self.state, .Xchg, Locked, .Acquire);
        if (state == Unlocked)
            return;

        while (true) {
            for (([SpinCpu]void)(undefined)) |_, index| {
                var value = @atomicLoad(u32, &self.state, .Monotonic);
                while (value == Unlocked)
                    value = @cmpxchgWeak(u32, &self.state, Unlocked, state, .Acquire, .Relaxed) orelse return;
                yield(1 << @truncate(u5, index));
            }

            for (([SpinThread]void)(undefined)) |_| {
                var value = @atomicLoad(u32, &self.state, .Monotonic);
                while (value == Unlocked)
                    value = @cmpxchgWeak(u32, &self.state, Unlocked, state, .Acquire, .Relaxed) orelse return;
                Thread.yield();
            }

            if (@atomicRmw(u32, &self.state, .Xchg, Sleeping, .Acquire) == Unlocked)
                return;
            state = Sleeping;
            self.futex.wait(&self.state, Sleeping);
        }
    }

    pub fn release(self: *@This()) void {
        if (@atomicRmw(u32, &self.state, .Xchg, Unlocked, .Release) == Sleeping)
            self.futex.wake(&self.state);
    }
};
