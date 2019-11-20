const std = @import("std");
const builtin = @import("builtin");

/// The assumed cache-line of the current system.
/// On modern intel architectures, spatial prefetcher
/// works with pairs of cache lines hence the doubled value.
/// NOTE: Changing this value means re-organizing all other structures!
pub const CACHE_LINE = switch (builtin.arch) {
    .x86_64 => 128,
    else => 64,
};

pub const BitSet = struct {
    const Word = usize;
    const MAX = @typeInfo(Word).Int.bits;
    const Index = @Type(builtin.TypeInfo{
        .Int = builtin.TypeInfo.Int{
            .is_signed = false,
            .bits = @ctz(usize, MAX),
        },
    });

    bitmask: Word,

    pub fn init(size: usize) BitSet {
        return BitSet {
            .bitmask = switch (std.math.min(size, MAX)) {
                MAX => ~@as(Word, 0),
                else => |s| (@as(Word, 1) << @truncate(Index, s)) - 1,
            },
        };
    }

    pub fn set(self: *BitSet, index: usize) void {
        const mask = @as(Word, 1) << @truncate(Index, index);
        _ = @atomicRmw(Word, &self.bitmask, .Or, mask, .Release);
    }

    pub fn get(self: *BitSet) ?Index {
        var mask = @atomicLoad(Word, &self.bitmask, .Monotonic);
        while (mask != 0) {
            const index = @truncate(Index, @ctz(Word, ~mask));
            const updated = mask | (@as(Word, 1) << index);
            mask = @cmpxchgWeak(Word, &self.bitmask, mask, updated, .Acquire, .Monotonic)
                orelse return index;
        }
        return null;
    }
};
