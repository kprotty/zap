// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

pub const CACHE_ALIGN = switch (std.builtin.arch) {
    .arm, .armeb, .mips, .mipsel, .mips64, .mips64el, .riscv64 => 32,
    .aarch64, .wasm32, .wasm64, .i386, .x86_64 => 64,
    .powerpc64 => 128,
    .s390x => 256,
    else => @alignOf(usize), 
};

pub fn spinLoopHint() void {
    switch (std.builtin.arch) {
        .i386, .x86_64 => asm volatile("pause" ::: "memory"),
        .arm, .aarch64 => asm volatile("yield" ::: "memory"),
        else => {},
    }
}

pub const Ordering = enum {
    unordered,
    relaxed,
    acquire,
    release,
    consume,
    acq_rel,
    seq_cst,

    pub fn toBuiltin(self: Ordering) std.builtin.AtomicOrder {
        return switch (self) {
            .unordered => .Unordered,
            .relaxed => .Monotonic,
            .acquire => .Acquire,
            .release => .Release,
            .consume => .Acquire,
            .acq_rel => .AcqRel,
            .seq_cst => .SeqCst,
        };
    }

    pub fn isEqualOrStricterThan(self: Ordering, compare: Ordering) bool {
        return switch (compare) {
            .unordered => true,
            .relaxed => switch (self) {
                .unordered => false,
                else => true,
            },
            .consume => switch (self) {
                .unordered, .relaxed => false,
                else => true,
            },
            .acquire => switch (self) {
                .acquire, .release, .acq_rel, .seq_cst => true,
                else => false,
            },
            .release => switch (self) {
                .acquire, .release, .acq_rel, .seq_cst => true,
                else => false,
            },
            .acq_rel => switch (self) {
                .acq_rel, .seq_cst => true,
                else => false,
            },
            .seq_cst => switch (self) {
                .seq_cst => true,
                else => false,
            },
        };
    }

    fn getRmw(comptime self: Ordering) Ordering {
        return switch (self) {
            .unordered => @compileError("rmw ops need synchronization, hence need more than unordered"),
            .consume => @compileError("rmw ops may store, hence need more than consume"),
            else => self,
        };
    }

    fn getRmwLoad(comptime self: Ordering) Ordering {
        return switch (self.getRmw()) {
            .unordered, .consume => unreachable,
            .relaxed, .release => .relaxed,
            .acquire, .acq_rel => .acquire,
            .seq_cst => .seq_cst,
        };
    }

    fn getRmwStore(comptime self: Ordering) Ordering {
        return switch (self.getRmw()) {
            .unordered, .consume => unreachable,
            .relaxed, .acquire => .relaxed,
            .release, .acq_rel => .release,
            .seq_cst => .seq_cst,
        };
    }
};

pub inline fn fence(comptime ordering: Ordering) void {
    if (!comptime ordering.isEqualOrStricterThan(.acquire))
        @compileError("fence() memory ordering must be equal or as strict as `acquire`");
    @fence(comptime ordering.toBuiltin());
}

pub inline fn compilerFence(comptime ordering: Ordering) void {
    if (!comptime ordering.isEqualOrStricterThan(.acquire))
        @compileError("fence() memory ordering must be equal or as strict as `acquire`");
    asm volatile("" ::: "memory");
}

fn ValueOf(comptime ptr: anytype) type {
    return std.meta.Child(ptr);
}

pub inline fn load(
    ptr: anytype,
    comptime ordering: Ordering,
) ValueOf(@TypeOf(ptr)) {
    switch (ordering) {
        .release, .acq_rel => {
            @compileError("atomic load memory ordering cannot be release");
        },
        .consume => {
            const value = @atomicLoad(ValueOf(@TypeOf(ptr)), ptr, .Monotonic);
            compilerFence(.acquire);
            return value;
        },
        else => return @atomicLoad(
            ValueOf(@TypeOf(ptr)),
            ptr,
            comptime ordering.toBuiltin(),
        ),
    }
}

pub inline fn store(
    ptr: anytype,
    value: ValueOf(@TypeOf(ptr)),
    comptime ordering: Ordering,
) void {
    switch (ordering) {
        .acquire, .acq_rel, .consume => {
            @compileError("atomic store memory ordering cannot be acquire/consume");
        },
        else => return @atomicStore(
            ValueOf(@TypeOf(ptr)),
            ptr,
            value,
            comptime ordering.toBuiltin(),
        ),
    }
}

pub const UpdateOp = enum {
    swap,
    add,
    sub,
    @"and",
    @"or",
    nand,
    xor,
    min,
    max,

    pub fn toBuiltin(self: UpdateOp) std.builtin.AtomicRmwOp {
        return switch (self) {
            .swap => .Xchg,
            .add => .Add,
            .sub => .Sub,
            .@"and" => .And,
            .@"or" => .Or,
            .nand => .Nand,
            .xor => .Xor,
            .min => .Min,
            .max => .Max,
        };
    }
};

pub inline fn update(
    ptr: anytype,
    comptime operation: UpdateOp,
    value: ValueOf(@TypeOf(ptr)),
    comptime ordering: Ordering,
) ValueOf(@TypeOf(ptr)) {
    return @atomicRmw(
        ValueOf(@TypeOf(ptr)),
        ptr,
        comptime operation.toBuiltin(),
        value,
        comptime ordering.getRmw().toBuiltin(),
    );
}

pub const Strength = enum {
    weak,
    strong,
};

pub inline fn compareAndSwap(
    comptime strength: Strength,
    ptr: anytype,
    compare_with: ValueOf(@TypeOf(ptr)),
    exchange_with: ValueOf(@TypeOf(ptr)),
    comptime on_success: Ordering,
    comptime on_failure: Ordering,
) ?ValueOf(@TypeOf(ptr)) {
    return switch (strength) {
        .weak => @cmpxchgWeak(
            ValueOf(@TypeOf(ptr)),
            ptr,
            compare_with,
            exchange_with,
            comptime on_success.toBuiltin(),
            comptime on_failure.toBuiltin(),
        ),
        .strong => @cmpxchgStrong(
            ValueOf(@TypeOf(ptr)),
            ptr,
            compare_with,
            exchange_with,
            comptime on_success.toBuiltin(),
            comptime on_failure.toBuiltin(),
        ),
    };
}

pub const BitwiseOp = enum {
    get,
    set,
    reset,
    toggle,
};

pub fn bitwise(
    ptr: anytype,
    comptime operation: BitwiseOp,
    bit: std.math.Log2Int(ValueOf(@TypeOf(ptr))),
    comptime ordering: Ordering,
) u1 {
    const Value = ValueOf(@TypeOf(ptr));
    const mask = @as(Value, 1) << bit;
    const isX86 = switch (std.builtin.arch) {
        .i386, .x86_64 => true,
        else => false,
    };

    comptime var byte_size = std.math.floorPowerOfTwo(u16, std.meta.bitCount(Value)) / 8;

    if (!isX86 or (byte_size > @sizeOf(usize)) or (byte_size == 1)) {
        const value = switch (operation) {
            .get => load(ptr, comptime ordering.getRmwLoad()),
            .set => update(ptr, .@"or", mask, ordering),
            .reset => update(ptr, .@"and", ~mask, ordering),
            .toggle => update(ptr, .xor, mask, ordering),
        };
        return @boolToInt(value & mask != 0);
    }

    const inst: []const u8 = switch (operation) {
        .get => "bt",
        .set => "lock bts",
        .reset => "lock btr",
        .toggle => "lock btc",
    };

    // x86 address faults are by page: if at least one byte is valid, the operation succeeds.
    byte_size = comptime std.math.max(2, byte_size);
    const suffix: []const u8 = switch (byte_size) {
        2 => "w",
        4 => "l",
        8 => "q",
        else => unreachable,
    };

    const asm_ptr = ptr;
    const asm_bit = @as(std.meta.Int(false, byte_size * 8), bit);
    const asm_result = asm volatile(
        inst ++ suffix ++ " %[bit], %[ptr]"
        :   [result] "={@ccc}" (-> u8),
        :   [ptr] "*p" (asm_ptr),
            [bit] "X" (asm_bit),
        :   "cc", "memory"
    );

    {
        @setRuntimeSafety(false);
        if (asm_result > 1)
            unreachable;
        return @intCast(u1, asm_result);
    }
}
            