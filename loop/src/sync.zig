
pub const task = Sync(@import("./task.zig").Task.AutoResetEvent);
pub const thread = Sync(@import("./system/system.zig").AutoResetEvent);

fn Sync(comptime AutoResetEvent: type) type {
    return struct {
        pub const Lock = @import("./core/sync/lock.zig").Lock(AutoResetEvent);

        pub fn Channel(comptime T: type) type {
            return @import("./core/sync/channel.zig").Channel(AutoResetEvent, T);
        } 
    };
}