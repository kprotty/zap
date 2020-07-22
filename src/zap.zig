
pub const core = struct {
    pub const executor = @import("./core/executor.zig");
};

pub const runtime = struct {
    pub const executor = @import("./runtime/executor.zig");
    pub const platform = @import("./runtime/platform.zig");
};