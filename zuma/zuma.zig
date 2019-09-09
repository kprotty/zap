
const memory = @import("src/mem.zig");
const allocator = @import("src/allocator.zig");

test "zuma" {
    _ = memory;
    _ = allocator;
}

pub const mem = struct {
    pub usingnamespace memory;
    pub usingnamespace allocator;
};