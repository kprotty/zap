const builtin = @import("builtin");

pub const sync = struct {
    pub const atomic = @import("./sync/atomic.zig");
    pub const wait_address = @import("./sync/wait_address.zig");
};
