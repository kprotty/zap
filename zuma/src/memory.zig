const std = @import("std");
const expect = std.testing.expect;
const zuma = @import("../../zap.zig").zuma;
const zync = @import("../../zap.zig").zync;

pub fn ptrCast(comptime To: type, from: var) To {
    return @ptrCast(To, @alignCast(@alignOf(To), from));
}

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
pub inline fn getPageSize() usize {
    return cached_page_size.get() orelse page_size;
}

/// Get the systems huge page size if huge pages are supported, else null
var cached_huge_page_size = zync.Lazy(zuma.backend.getHugePageSize).new();
pub inline fn getHugePageSize() ?usize {
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

pub const PAGE_HUGE     = 1 << 0;
pub const PAGE_EXEC     = 1 << 1;
pub const PAGE_READ     = 1 << 2;
pub const PAGE_WRITE    = 1 << 3;
pub const PAGE_COMMIT   = 1 << 4;
pub const PAGE_DECOMMIT = 1 << 5;

pub const MapError = error {
    // TODO
};

pub fn map(handle: ?zio.Handle, address: ?*align(page_size) const u8, bytes: usize, flags: u32, node: ?usize) MapError![]align(page_size) u8 {
    return backend.map(handle, address, bytes, flags);
}

pub fn unmap(memory: []align(page_size) u8, node: ?usize) void {
    return backend.unmap(memory);
}

pub const ModifyError = error {
    // TODO
};

pub fn modify(memory: []align(page_size) u8, flags: u32, node: ?usize) ModifyError!void {
    return backend.modify(memory, flags);
}
