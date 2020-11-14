const std = @import("std");

pub const Lock = struct {
    mutex: std.Mutex = std.Mutex{},

    pub fn acquire(self: *Lock) void {
        _ = self.mutex.acquire();
    }

    pub fn release(self: *Lock) void {
        (std.Mutex.Held{ .mutex = &self.mutex }).release();
    }
};