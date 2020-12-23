const builtin = @import("builtin");
const system = @import("./system.zig");
const Futex = @import("./futex.zig").Futex;

const sync = @import("../../sync/sync.zig");
const atomic = sync.atomic;

pub const Event = switch (builtin.os.tag) {
    // TODO: .openbsd => OpenbsdEvent,
    // TODO: .dragonfly => DragonflyEvent,
    // TODO: .kfreebsd, .freebsd => FutexEvent
    .macos, .ios, .watchos, .tvos => FutexEvent,
    .linux => FutexEvent,
    .windows => WindowsEvent,
    else => PosixEvent,
};

const WindowsEvent = struct {
    pub fn init(self: *Event) void {
        @compileError("TODO");
    }

    pub fn deinit(self: *Event) void {
        @compileError("TODO");
    }

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) error{TimedOut}!void {
        @compileError("TODO");
    }

    pub fn notify(self: *Event) void {
        @compileError("TODO");
    }

    pub fn yield(iteration: ?usize) bool {
        @compileError("TODO");
    }

    pub fn nanotime() u64 {
        @compileError("TODO");
    }
};

const PosixEvent = extern struct {
    pub fn init(self: *Event) void {
        @compileError("TODO");
    }
    
    pub fn deinit(self: *Event) void {
        @compileError("TODO");
    }

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) error{TimedOut}!void {
        @compileError("TODO");
    }

    pub fn notify(self: *Event) void {
        @compileError("TODO");
    }

    pub fn yield(iteration: ?usize) bool {
        @compileError("TODO");
    }

    pub fn nanotime() u64 {
        @compileError("TODO");
    }
};

const FutexEvent = extern struct {
    pub fn init(self: *Event) void {
        @compileError("TODO");
    }
    
    pub fn deinit(self: *Event) void {
        @compileError("TODO");
    }

    pub fn wait(self: *Event, deadline: ?u64, condition: anytype) error{TimedOut}!void {
        @compileError("TODO");
    }

    pub fn notify(self: *Event) void {
        @compileError("TODO");
    }

    pub fn yield(iteration: ?usize) bool {
        return Futex.yield(iteration);
    }

    pub fn nanotime() u64 {
        return Futex.nanotime();
    }
};
