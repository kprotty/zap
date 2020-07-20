const std = @import("std");
const _task = @import("./task.zig");
const system = @import("./system.zig");
const scheduler = @import("./scheduler.zig");

pub const Task = _task.Task;
pub const Link = scheduler.Link;
pub const Builder = scheduler.Builder;
pub const Runnable = scheduler.Runnable;

pub const sync = struct {
    pub const GenericLock = @import("./sync/lock.zig").Lock;
    pub const GenericChannel = @import("./sync/channel.zig").Channel;

    pub const thread = struct {
        pub const AutoResetEvent = system.AutoResetEvent;

        pub const Lock = GenericLock(AutoResetEvent);

        pub fn Channel(comptime T: type) type {
            return GenericChannel(AutoResetEvent, Lock, T);
        }
    };

    pub const task = struct {
        pub const AutoResetEvent = Task.AutoResetEvent;

        pub const Lock = GenericLock(AutoResetEvent);

        pub fn Channel(comptime T: type) type {
            return GenericChannel(AutoResetEvent, thread.Lock, T);
        }
    };
};