// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const builtin = std.builtin;

const Log2Int = std.math.Log2Int;
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

/// Hints to the CPU that the caller is free to schedule any other work internally.
/// This generally means that the current CPU core has the option to switch "hardware threads".
pub fn spinLoopHint() callconv(.Inline) void {
    // TODO: ARM Thumb v7 supports "yield"
    asm volatile (switch (builtin.arch) {
            .i386, .x86_64 => "pause",
            .aarch64 => "yield",
            else => "",
        });
}

/// Atomic memory orderings are used to bound internal transformations done by
/// both the compiler and the hardware when it comes to reordering memory instructions.
///
/// The current set of atomic memory orderings are based on LLVM/C11's atomic memory model.
/// https://llvm.org/docs/Atomics.html
/// https://en.cppreference.com/w/cpp/atomic/memory_order
pub const Ordering = enum {
    Unordered,
    Relaxed,
    Consume,
    Acquire,
    Release,
    AcqRel,
    SeqCst,

    fn toBuiltin(comptime self: Ordering) AtomicOrder {
        return switch (self) {
            .Unordered => .Unordered,
            .Relaxed => .Monotonic,
            .Consume => .Acquire, // TODO: relaxed + compilerFence(.acquire) ?
            .Acquire => .Acquire,
            .Release => .Release,
            .AcqRel => .AcqRel,
            .SeqCst => .SeqCst,
        };
    }
};

/// Introduce a lexical compiler and hardware reodering restriction using the given atomic memory ordering.
pub fn fence(comptime ordering: Ordering) callconv(.Inline) void {
    @fence(comptime ordering.toBuiltin());
}

/// Introduce a lexical compiler only reordering restriction using the given atomic memory ordering.
pub fn compilerFence(comptime ordering: Ordering) callconv(.Inline) void {
    switch (ordering) {
        .Unordered => @compileError("Unordered memory ordering can only be on atomic variables"),
        .Relaxed => @compileError("Relaxed memory ordering can only be on atomic variables"),
        .Consume => @compileError("Consume memory ordering can only be on atomic variables"),
        else => asm volatile (""
            :
            :
            : "memory"
        ),
    }
}

pub fn load(
    ptr: anytype,
    comptime ordering: Ordering,
) callconv(.Inline) @TypeOf(ptr.*) {
    return @atomicLoad(@TypeOf(ptr.*), ptr, comptime ordering.toBuiltin());
}

pub fn store(
    ptr: anytype,
    value: @TypeOf(ptr.*),
    comptime ordering: Ordering,
) callconv(.Inline) void {
    return @atomicStore(@TypeOf(ptr.*), ptr, value, comptime ordering.toBuiltin());
}

pub fn swap(
    ptr: anytype,
    value: @TypeOf(ptr.*),
    comptime ordering: Ordering,
) callconv(.Inline) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Xchg, value, ordering);
}

pub fn fetchAdd(
    ptr: anytype,
    value: @TypeOf(ptr.*),
    comptime ordering: Ordering,
) callconv(.Inline) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Add, value, ordering);
}

pub fn fetchSub(
    ptr: anytype,
    value: @TypeOf(ptr.*),
    comptime ordering: Ordering,
) callconv(.Inline) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Sub, value, ordering);
}

pub fn fetchAnd(
    ptr: anytype,
    value: @TypeOf(ptr.*),
    comptime ordering: Ordering,
) callconv(.Inline) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .And, value, ordering);
}

pub fn fetchOr(
    ptr: anytype,
    value: @TypeOf(ptr.*),
    comptime ordering: Ordering,
) callconv(.Inline) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Or, value, ordering);
}

pub fn fetchXor(
    ptr: anytype,
    value: @TypeOf(ptr.*),
    comptime ordering: Ordering,
) callconv(.Inline) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Xor, value, ordering);
}

fn atomicRmw(
    comptime T: type,
    ptr: *T,
    comptime op: AtomicRmwOp,
    value: T,
    comptime ordering: Ordering,
) callconv(.Inline) T {
    return @atomicRmw(T, ptr, op, value, comptime ordering.toBuiltin());
}

pub fn compareAndSwap(
    ptr: anytype,
    cmp: @TypeOf(ptr.*),
    xchg: @TypeOf(ptr.*),
    comptime success: Ordering,
    comptime failure: Ordering,
) callconv(.Inline) ?@TypeOf(ptr.*) {
    return @cmpxchgStrong(
        @TypeOf(ptr.*),
        ptr,
        cmp,
        xchg,
        comptime success.toBuiltin(),
        comptime failure.toBuiltin(),
    );
}

pub fn tryCompareAndSwap(
    ptr: anytype,
    cmp: @TypeOf(ptr.*),
    xchg: @TypeOf(ptr.*),
    comptime success: Ordering,
    comptime failure: Ordering,
) callconv(.Inline) ?@TypeOf(ptr.*) {
    return @cmpxchgWeak(
        @TypeOf(ptr.*),
        ptr,
        cmp,
        xchg,
        comptime success.toBuiltin(),
        comptime failure.toBuiltin(),
    );
}
