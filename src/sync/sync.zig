const zap = @import("../zap.zig");
const builtin = zap.builtin;
const system = zap.system;

pub const atomic = @import("./atomic.zig");

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
    pub const Lock = @import("./generic/Lock.zig").Lock;
    
    pub const ParkingLot = @import("./generic/ParkingLot.zig").ParkingLot;
    pub const Mutex = @import("./generic/Mutex.zig").Mutex;
};

pub const primitives = struct {
    pub const spin = generic.Generic(.{});
    pub const os = generic.Generic(.{
        .Lock = backend.os.Lock,
        .Event = backend.os.Event,
    });
};
