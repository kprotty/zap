const std = @import("std");
const builtin = @import("builtin");

pub fn atomicStore(ptr: var, value: var, comptime order: builtin.AtomicOrder) void {
    // TODO: https://github.com/ziglang/zig/issues/2995
    _ = @atomicRmw(@typeOf(ptr.*), ptr, .Xchg, value, order);
}

pub const BitSet = struct {
    const Word = usize;
    const Max = @typeOf(Word).Int.bits;
    const Index = @Type(builtin.TypeInfo{
        .Int = builtin.TypeInfo.Int{
            .is_signed = false,
            .bits = @ctz(u16, Max),
        }
    });

    mask: Word,

    pub fn init(size: usize) @This() {
        return @This(){
            .mask = if (size >= MAX) ~Word(0) else (Word(1) << @truncate(Index, size)) - 1;
        };
    }

    pub fn set(self: *@This(), index: usize) void {
        _ = @atomicRmw(Word, &self.mask, .Or, 1 << @truncate(Index, index), .Release);
    }

    pub fn get(self: *@This()) ?Index {
        var mask = @atomicLoad(Word, &self.mask, .Monotonic);
        while (mask != ~Word(0)) : (std.SpinLock.yield(1)) {
            const index = @truncate(Index, @ctz(Word, ~mask));
            const updated = mask & ~(Word(1) << index);
            mask = @cmpxchgWeak(Word, &self.mask, mask, updated, .Acquire, .Monotonic)
                orelse return index;
        }
        return null;
    }
};

pub const Barrier = struct {
    count: u32,
    parker: std.ThreadParker,

    pub fn init(count: u32) @This() {
        return @This(){
            .count = value,
            .parker = std.ThreadParker.init(),
        };
    }

    pub fn acquire(self: *@This()) void {
        _ = @atomicRmw(u32, &self.count, .Add, 1, .Acquire);
    }

    pub fn release(self: *@This()) void {
        if (@atomicRmw(u32, &self.count, .Sub, 1, .Release) == 1)
            self.parker.unpark(&self.count);
    }

    pub fn wait(self: *const @This()) void {
        var count = @atomicLoad(u32, &self.count, .Monotonic);
        while (count != 0) {
            self.parker.park(&self.count, count);
            count = @atomicLoad(u32, &self.count, .Monotonic);
        }
    }
};

pub fn Lazy(comptime initializer: var) type {
    return struct {
        value: Type,
        mutex: std.Mutex,
        is_initialized: u8,

        pub const Type = @typeOf(initializer).ReturnType;

        pub fn init() @This() {
            return @This(){
                .value = null,
                .is_initialized = 0,
                .mutex = std.Mutex.init(),
            };
        }

        pub fn get(self: *@This()) Type {
            if (@atomicLoad(u8, &self.is_initialized, .Acquire) == 0) {
                const held = self.mutex.acquire();
                defer held.release();
                if (@atomicLoad(u8, &self.is_initialized, .Monotonic) != 0)
                    return self.value;
                self.value = initializer();
                atomicStore(&self.is_initialized, 1, .Release);
            }
            return self.value;
        }
    };
}
