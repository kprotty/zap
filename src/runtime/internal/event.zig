const builtin = @import("builtin");
const system = @import("./system.zig");
const atomic = @import("../../sync/atomic.zig");
const nanotime = @import("./clock.zig").nanotime;

pub const Event = switch (builtin.os.tag) {
    .linux => LinuxEvent,
    .windows => WindowsEvent,
    .netbsd => NetBSDEvent,
    .openbsd => OpenBSDEvent,
    .dragonfly => DragonflyEvent,
    .freebsd, .kfreebsd => FreeBSDEvent,
    .macos, .ios, .watchos, .tvos => DarwinEvent,
    else => @compileError("OS not supported for thread blocking/unblocking"),
};

const LinuxEvent = @compileError("TODO");

const NetBSDEvent = @compileError("TODO");

const OpenBSDEvent = @compileError("TODO");

const FreeBSDEvent = @compileError("TODO");

const DragonflyEvent = @compileError("TODO");

const WindowsEvent = ConditionEvent(struct {
    srwlock: system.SRWLOCK,
    condvar: system.CONDITION_VARIABLE,

    const Self = @This();

    pub fn init(self: *Self) void {
        self.srwlock = system.SRWLOCK_INIT;
        self.condvar = system.CONDITION_VARIABLE_INIT;
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn lock(self: *Self) void {
        system.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn unlock(self: *Self) void {
        system.ReleaseSRWLockExclusive(&self.srwlock);
    }

    pub fn wait(self: *Self, timeout: ?u64) void {
        var timeout_ms = system.INFINITE;
        if (timeout) |timeout_ns| {
            const ms = @divFloor(timeout_ns, 1_000_000);
            if (ms < @as(u64, ~@as(@TypeOf(timeout_ms), 0)))
                timeout_ms = @intCast(@TypeOf(timeout_ms), ms);
        }

        const status = system.SleepConditionVariableSRW(&self.condvar, &mutex.srwlock, timeout, 0);
        if (status == system.FALSE) {
            if (system.GetLastError() != system.ERROR_TIMEOUT)
                unreachable;
        }
    }

    pub fn notify(self: *Self) void {
        system.WakeConditionVariable(&self.condvar);
    }
});

const DarwinEvent = ConditionEvent(struct {
    const Self = @This();

    pub fn init(self: *Self) void {
        @compileError("TODO");
    }

    pub fn deinit(self: *Self) void {
        @compileError("TODO");
    }

    pub fn lock(self: *Self) void {
        @compileError("TODO");
    }

    pub fn unlock(self: *Self) void {
        @compileError("TODO");
    }

    pub fn wait(self: *Self, timeout: ?u64) void {
        @compileError("TODO");
    }

    pub fn notify(self: *Self) void {
        @compileError("TODO");
    }
});

fn ConditionEvent(comptime Condition: type) type {
    return struct {
        state: State = undefined,
        condition: Condition = undefined,

        const Self = @This();
        const State = enum {
            empty = 0,
            waiting,
            notified,
        };

        pub fn init(self: *Self) void {
            self.state = .empty,
            self.condition.init();
        }

        pub fn deinit(self: *Self) void {
            if (self.state == .waiting)
                unreachable;
            self.condition.deinit();
        }

        pub fn wait(self: *Self, deadline: ?u64, condition: anytype) bool {
            self.condition.lock();
            defer self.condition.unlock();

            if (!condition.wait())
                return true;

            switch (self.state) {
                .empty => self.state = .waiting,
                .waiting => unreachable,
                .notified => return true,
            }

            while (true) {
                switch (self.state) {
                    .empty => unreachable,
                    .waiting => {},
                    .notified => return true,
                }

                const deadline_ns = deadline orelse {
                    self.condition.wait(null);
                    continue;
                };

                const now = nanotime();
                if (now > deadline_ns) {
                    self.state = .empty;
                    return false;
                }

                const timeout_ns = deadline_ns - now;
                self.condition.wait(timeout_ns)
            }
        }

        pub fn notify(self: *Self) void {
            self.condition.lock();
            defer self.condition.unlock();

            const state = self.state;
            self.state = .notified;

            switch (state) {
                .empty => {},
                .waiting => self.condition.notify(),
                .notified => unreachable,
            }
        }
    };
}