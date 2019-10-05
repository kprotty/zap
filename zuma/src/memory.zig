const std = @import("std");
const zync = @import("../zap.zig").zync;

pub fn ptrCast(comptime To: type, from: var) To {
    return @ptrCast(To, @alignCast(@alignOf(To), from));
}

pub fn transmute(comptime To: type, from: var) To {
    var input = from;
    var output: To = undefined;
    const size = std.math.max(@sizeOf(To), @sizeOf(@typeOf(from)));
    const bytes = std.mem.alignForward(size, @alignOf(To));
    @memcpy(@ptrCast([*]u8, &output), @ptrCast([*]const u8, &input), bytes);
    return output;
}

/// Constant representing assumed page size
pub const page_size = std.mem.page_size;

/// Dynamic, true system page size
var cached_page_size = zync.Lazy(backend.pageSize).new();
pub inline fn pageSize() usize {
    return cached_page_size.get() orelse page_size;
}

/// Get the systems huge page size if huge pages are supported, else null
var cached_huge_page_size = zync.Lazy(backend.hugePageSize).new();
pub inline fn hugePageSize() ?usize {
    return cached_huge_page_size.get();
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
