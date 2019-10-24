const std = @import("std");
const expect = std.testing.expect;
const zuma = @import("../../zap.zig").zuma;
const zync = @import("../../zap.zig").zync;

pub fn transmute(comptime To: type, from: var) To {
    var input = from;
    var output: To = undefined;
    const bytes = comptime std.math.min(@sizeOf(@typeOf(from)), @sizeOf(To));
    @memcpy(@ptrCast([*]u8, &output), @ptrCast([*]const u8, &input), bytes);
    return output;
}

/// Constant representing assumed page size
pub const page_size = std.mem.page_size;

/// Dynamic, true system page size
var cached_page_size = zync.Lazy(zuma.backend.getPageSize).new();
pub fn getPageSize() usize {
    return cached_page_size.get() orelse page_size;
}

/// Get the systems huge page size if huge pages are supported, else null
var cached_huge_page_size = zync.Lazy(zuma.backend.getHugePageSize).new();
pub fn getHugePageSize() ?usize {
    return cached_huge_page_size.get();
}

test "getPageSize, getHugePageSize" {
    const size = getPageSize();
    expect(size >= page_size);
    expect(size == getPageSize());

    const huge_size = getHugePageSize();
    if (huge_size) |huge_page_size| {
        expect(huge_page_size >= 1 * 1024 * 1024);
        expect(huge_page_size > size);
    }
    expect(huge_size orelse 0 == getHugePageSize() orelse 0);
}

pub const NumaMemoryError = NumaError || error{InvalidAddress};

pub fn getNodeForMemory(ptr: usize) NumaMemoryError!usize {
    return zuma.backend.getNodeForMemory(ptr);
}

pub const NumaError = error{
    InvalidNode,
    InvalidResourceAccess,
};

pub fn getAvailableMemory(numa_node: ?usize) NumaError!usize {
    return zuma.backend.getAvailableMemory(nuam_node);
}

pub const PAGE_HUGE = 1 << 0;
pub const PAGE_EXEC = 1 << 1;
pub const PAGE_READ = 1 << 2;
pub const PAGE_WRITE = 1 << 3;
pub const PAGE_COMMIT = 1 << 4;
pub const PAGE_DECOMMIT = 1 << 5;

pub const MemoryError = std.os.UnexpectedError || NumaMemoryError || error{
    OutOfMemory,
    InvalidMemory,
    InvalidFlags,
};

pub fn map(address: ?[*]u8, bytes: usize, flags: u32, node: ?usize) MemoryError![]align(page_size) u8 {
    return zuma.backend.map(address, bytes, flags, node);
}

pub fn unmap(memory: []u8, node: ?usize) void {
    return zuma.backend.unmap(memory, node);
}

pub fn modify(memory: []u8, flags: u32, node: ?usize) MemoryError!void {
    return zuma.backend.modify(memory, flags, node);
}

test "Virtual memory" {
    for ([_]?usize{ null, 0 }) |node| {
        const memory = try map(null, page_size, PAGE_READ | PAGE_WRITE, node);
        defer unmap(memory, node);
        try modify(memory, PAGE_COMMIT | PAGE_READ | PAGE_WRITE, node);
        @ptrCast(*volatile u8, memory.ptr).* = 69;
        expect(memory[0] == 69);
        try modify(memory, PAGE_DECOMMIT, node);
    }
}
