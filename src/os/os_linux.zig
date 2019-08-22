const std = @import("std");
const linux = std.os.linux;
const Task = @import("../loop.zig").Loop.Task;

pub const Handle = i32;

pub const Thread = {
    handle: Handle,

    pub fn cpuCount() usize {

    }

    pub fn stackSize(comptime function: var) usize {
        
    }

    pub fn spawn(self: *@This(), stack: ?[]align(std.mem.page_size) u8, comptime function: var, parameter: usize) !void {

    }

    pub fn join(self: *@This()) void {

    }
};

pub const Selector = struct {
    pub const Event = linux.epoll_event;

    epoll_fd: Handle,
    event_fd: Handle,

    pub fn init(self: *@This(), concurrency: usize) !void {

    }

    pub fn notify(self: *@This(), task: *Task) void {
        
    }

    pub fn poll(self: *@This(), events: []Event, timeout_ms: ?u32) ?*Task {

    }
};
