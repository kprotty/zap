const std = @import("std");
const zap = @import("../zap.zig");

const core = zap.core;
const sync = zap.runtime.sync;
const Task = zap.runtime.Task;

pub const OsFutex = struct {
    event: Event = Event{},

    const Event = 
        if (core.is_windows) @import("./windows/event.zig").Event
        else if (core.is_posix) @import("./posix/event.zig").Event
        else if (core.is_linux) @import("./linux/event.zig").Event
        else @compileError("OS not supported for thread blocking/unblocking");

    pub fn wait(self: *OsFutex, deadline: ?*Timestamp, condition: *core.sync.Condition) bool {
        self.event.prepare();

        if (condition.isMet())
            return true;

        return self.event.wait(if (deadline) |d| d.* else null);
    }

    pub fn wake(self: *OsFutex) void {
        self.event.notify();
    }

    pub fn yield(self: *OsFutex, iteration: ?usize) bool {
        if (std.builtin.single_threaded)
            return false;

        var iter = iteration orelse {
            Event.yield();
            return false;
        };

        if (iter <= 3) {
            while (iter != 0) : (iter -= 1)
                sync.yieldCpu();
        } else {
            Event.yield();
        }

        return true;
    }

    pub const Timestamp = u64;

    pub fn timestamp(self: *OsFutex, current: *Timestamp) void {
        current.* = nanotime();
    }

    pub fn timeSince(self: *OsFutex, t1: *Timestamp, t2: *Timestamp) u64 {
        return t1.* - t2.*;
    }

    var last_lock = sync.Lock{};
    var last_now = sync.atomic.Atomic(u64).init(0);

    pub fn nanotime() u64 {
        const now = Event.nanotime();
        if (Event.is_monotonic)
            return now;

        if (std.meta.bitCount(usize) < 64) {
            last_lock.acquire();
            defer last_lock.release();
            
            const last = last_now.get();
            if (last > now)
                return last;
            
            last_now.set(now);
            return now;
        }

        var last = last_now.load(.relaxed);
        while (true) {
            if (last > now)
                return last;
            last = last_now.tryCompareAndSwap(
                last,
                now,
                .relaxed,
                .relaxed,
            ) orelse return now;
        }
    }
};

pub const AsyncFutex = struct {
    task: core.sync.atomic.Atomic(usize) = undefined,

    pub fn wait(self: *AsyncFutex, deadline: ?*Timestamp, condition: *core.sync.Condition) bool {
        // TODO: integrate timers with deadline

        self.task.set(0);
        
        if (condition.isMet())
            return true;

        suspend {
            var task = Task.initAsync(@frame());
            const t = self.task.swap(@ptrToInt(&task), .acq_rel);

            std.debug.warn("{*} sleeping = {}\n", .{&task, t});
            if (t == 1)
                task.scheduleNext();
        }

        return true;
    }

    pub fn wake(self: *AsyncFutex) void {
        const task = self.task.swap(1, .acq_rel);
        if (task > 1) {
            const t =@intToPtr(*Task, task);
            std.debug.warn("{*} waking\n", .{t});
            t.schedule();
        }
    }

    pub fn yield(self: *AsyncFutex, iteration: ?usize) bool {
        if (std.builtin.single_threaded)
            return false;

        const max_spin = 8;
        const max_iter = @ctz(usize, max_spin);
        
        var iter = iteration orelse max_iter;
        if (iter > max_iter)
            return false;

        iter = @as(usize, 1) << @intCast(std.math.Log2Int(usize), iter);
        while (iter != 0) : (iter -= 1)
            sync.atomic.spinLoopHint();

        return true;
    }

    pub const Timestamp = u64;

    pub fn timestamp(self: *AsyncFutex, current: *Timestamp) void {
        current.* = OsFutex.nanotime();
    }

    pub fn timeSince(self: *AsyncFutex, t1: *Timestamp, t2: *Timestamp) u64 {
        return t1.* - t2.*;
    }
};