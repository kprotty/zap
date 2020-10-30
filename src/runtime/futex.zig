const std = @import("std");
const zap = @import("../zap.zig");

pub const OsFutex = zap.core.sync.SpinFutex;