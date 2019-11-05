const std = @import("std");
const builtin = @import("builtin");

pub const runtime = struct {
    pub usingnamespace @import("src/runtime/executor.zig");
};