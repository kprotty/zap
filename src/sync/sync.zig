const zap = @import("../zap");
const builtin = zap.builtin;
const system = zap.system;

pub const atomic = @import("./atomic.zig");
pub const ParkingLot = @import("./parking_lot.zig").ParkingLot;

pub const backend = struct {
    pub const spin = @import("./backend/spin.zig");
    pub const os = if (system.is_windows)
        @import("./backend/windows.zig")
    else if (system.is_linux)
        @import("./backend/linux.zig")
    else if (system.is_darwin)
        @import("./backend/darwin.zig")
    else if (system.is_posix and system.has_libc)
        @import("./backend/posix.zig")
    else
        @compileError("OS sync backend not supported");
};

pub const generic = struct {
    pub const Generic = @import("./generic/Generic.zig").Generic;
    pub const EventLock = @import("./generic/EventLock.zig").EventLock;
    pub const EventSignal = @import("./generic/EventSignal.zig").EventSignal;
    
    pub const Mutex = @import("./generic/Mutex.zig").Mutex;
};

pub const spin = Generic(.{});
pub const os = Generic(.{
    .Lock = backend.os.Lock,
    .Event = backend.os.Event,
});
