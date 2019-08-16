const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    max_workers: usize,
    max_threads: usize,
    allocator: *std.mem.Allocator,

    pub fn default() Config {
        return Config {
            .max_threads = 10 * 1000,
            .allocator = std.debug.allocator,
            .max_workers = std.Thread.cpuCount() catch 1,
        };
    }
};