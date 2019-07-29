const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    initialized: bool,
    number_of_threads: usize,
    allocator: *std.mem.Allocator,

    pub var Default = Config {
        .initialized = false,
        .number_of_threads = 1,
        .allocator = undefined,
    };
};

pub fn configure(allocator: *std.mem.Allocator) void {
    configureInternal(allocator, 1);
}

pub fn configureThreaded(allocator: *std.mem.Allocator, num_threads: usize) void {
    if (builtin.single_threaded)
        @compileError("configureThreaded() unavaiable in single threaded mode");
    configureInternal(allocator, num_threads);
}

fn configureInternal(allocator: *std.mem.Allocator, num_threads: usize) void {
    Config.getDefault().* = Config {
        .initialized = true,
        .allocator = allocator,
        .number_of_threads = num_threads,
    };
}