
pub const Lock = @import("./lock.zig").Lock;
pub const Event = @import("./event.zig").Event;
pub const Thread = @import("./thread.zig").Thread;
pub const Allocator = @import("std").mem.Allocator;
pub const target = @import("./target.zig");
pub const scheduler = @import("./scheduler.zig");
pub const system = @import("./system/system.zig");
pub const nanotime = @import("./time.zig").nanotime;

pub const RunConfig = struct {

};

fn ReturnTypeOf(comptime asyncFn: anytype) type {
    return @typeInfo(@TypeOf(asyncFn)).Fn.return_type.?;
}

pub fn runAsync(config: RunConfig, comptime asyncFn: anytype, args: anytype) !ReturnTypeOf(asyncFn) {

}

pub const SpawnConfig = struct {

};

pub fn spawnAsync(config: SpawnConfig, comptime: asyncFn: anytype, args: anytype) !void {

}

pub fn yieldAsync() void {

}

pub const AsyncEvent = struct {
    pub fn wait(self: *AsyncEvent, callback: anytype) void {

    }

    pub fn notify(self: *AsyncEvent) void {

    }
};