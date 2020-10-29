const std = @import("std");

pub const Signal = struct {
    event: std.AutoResetEvent = std.AutoResetEvent{},

    pub fn init(self: *Signal) void {
        self.* = Signal{};
    }

    pub fn deinit(self: *Signal) void {
        self.* = undefined;
    }

    pub fn wait(self: *Signal) void {
        self.event.wait();
    }

    pub fn notify(self: *Signal) void {
        self.event.set();
    }
};