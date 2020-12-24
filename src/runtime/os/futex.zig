const builtin = @import("builtin");
const system = @import("./system.zig");
const Event = @import("./event.zig").Event;

const sync = @import("../../sync/sync.zig");
const UnfairLock = sync.UnfairLock;
const ParkingLot = sync.ParkingLot;
const atomic = sync.atomic;

pub const Futex = switch (builtin.os.tag) {
    // TODO: .kfreebsd, .freebsd => FreebsdFutex
    .macos, .ios, .watchos, .tvos => DarwinFutex,
    .linux => LinuxFutex,
    else => ParkingFutex,
};

const DarwinFutex = struct {
    pub fn wait(ptr: *const u32, cmp: u32, timeout: ?u64) error{TimedOut}!void {
        @compileError("TODO");
    }

    pub fn wake(ptr: *const u32) void {
        @compileError("TODO");
    }

    pub fn yield(iteration: ?usize) bool {
        @compileError("TODO");
    }

    pub fn nanotime() u64 {
        return Clock.nanoTime();
    }
};

const LinuxFutex = struct {
    pub fn wait(ptr: *const u32, cmp: u32, timeout: ?u64) error{TimedOut}!void {
        @compileError("TODO");
    }

    pub fn wake(ptr: *const u32) void {
        @compileError("TODO");
    }

    pub fn yield(iteration: ?usize) bool {
        @compileError("TODO");
    }

    pub fn nanotime() u64 {
        return Clock.nanoTime();
    }
};

const ParkingFutex = struct {
    const ParkingLock = struct {
        lock: UnfairLock = .{},

        pub fn acquire(self: *ParkingLock) void {
            self.lock.acquire(Event);
        }

        pub fn release(self: *ParkingLock) void {
            self.lock.release();
        }
    };

    const parking_lot = ParkingLot(.{
        .Lock = ParkingLock,
        .bucket_count = 64,
        .eventually_fair_after = 0,
    });

    pub fn wait(ptr: *const u32, cmp: u32, timeout: ?u64) error{TimedOut}!void {
        const Parker = struct {
            futex_ptr: *const u32,
            futex_cmp: u32,

            pub fn onBeforeWait(this: @This()) void {}
            pub fn onTimeout(this: @This(), has_more: bool) void {}
            pub fn onValidate(this: @This()) ?usize {
                if (atomic.load(this.futex_ptr, .seq_cst) != this.futex_cmp)
                    return null;
                return 0;
            }
        };

        const parker = Parker{
            .futex_ptr = ptr,
            .futex_cmp = cmp,
        };

        var deadline: ?u64 = null;
        if (timeout) |timeout_ns| {
            const now = Event.nanotime();
            deadline = now + timeout_ns;
        }

        _ = parking_lot.parkConditionally(
            Event,
            @ptrToInt(ptr),
            deadline,
            parker,
        ) catch |err| switch (err) {
            error.Invalid => {},
            error.TimedOut => return error.TimedOut,
        };
    }

    pub fn wake(ptr: *const u32) void {
        const Unparker = struct {
            pub fn onUnpark(this: @This(), result: parking_lot.UnparkResult) usize {
                return 0;
            }
        };
        
        return parking_lot.unparkOne(
            @ptrToInt(ptr),
            Unparker{},
        );
    }

    pub fn yield(iteration: ?usize) bool {
        return Event.yield(iteration);
    }

    pub fn nanotime() u64 {
        return Event.nanotime();
    }
};