pub const builtin = @import("builtin");

pub const system = @import("./system/system.zig");
pub const time = @import("./time/time.zig");
pub const sync = @import("./sync/sync.zig");
pub const meta = @import("./meta.zig");

test "" {
    meta.refAllDeclsRecursive(@This());
}