const std = @import("std");
const assert = std.debug.assert;

const ThreadPool = @This();

max_threads: u16,
counter: u32 = 0,
futex: Futex = .{},
spawned: ?*Worker = null,

pub const InitConfig = struct {
    max_threads: ?u16 = null,
};

pub fn init(config: InitConfig) ThreadPool {
    return .{
        .max_threads = std.math.min(
            std.math.maxInt(u14),
            std.math.max(1, config.max_threads orelse blk: {
                break :blk @intCast(u16, std.Thread.cpuCount() catch 1);
            }),
        ),
    };
}

pub fn deinit(self: *ThreadPool) void {
    self.shutdownWorkers();
    self.joinWorkers();
    self.futex.deinit();
    self.* = undefined;
}

pub fn shutdown(self: *ThreadPool) void {
    return self.shutdownWorkers();
}

pub const ScheduleHints = struct {
    priority: Priority = .Normal,

    pub const Priority = enum {
        High,
        Normal,
        Low,
    };
};

pub fn schedule(self: *ThreadPool, hints: ScheduleHints, batchable: anytype) void {

}

pub const Batch = struct {
    head: ?*Runnable = null,
    tail: *Runnable = undefined,

    pub fn from(batchable: anytype) Batch {
        return switch (@TypeOf(batchable)) {
            Batch => batchable,
            ?*Runnable => from(batchable orelse return Batch{}),
            *Runnable => {
                batchable.next = null;
                return Batch{
                    .head = batchable,
                    .tail = batchable,
                };
            },
            else => |typ| @compileError(@typeName(typ) ++
                " cannot be converted into " ++
                @typeName(Batch)),
        };
    }

    pub fn isEmpty(self: Batch) bool {
        return self.head == null;
    }

    pub const push = pushBack;
    pub fn pushBack(self: *Batch, batchable: anytype) void {
        const batch = from(batchable);
        if (batch.isEmpty())
            return;

        if (self.isEmpty()) {
            self.* = batch;
        } else {
            self.tail.next = batch.head;
            self.tail = batch.tail;
        }
    }

    pub fn pushFront(self: *Batch, batchable: anytype) void {
        const batch = from(batchable);
        if (batch.isEmpty())
            return;

        if (self.isEmpty()) {
            self.* = batch;
        } else {
            batch.tail.next = self.head;
            self.head = batch.head;
        }
    }

    pub const pop = popFront;
    pub fn popFront(self: *Batch) ?*Runnable {
        const runnable = self.head orelse return null;
        self.head = runnable.next;
        return runnable;
    }
};

pub const Runnable = struct {
    next: ?*Runnable = null,
    runFn: fn (*Runnable) void,

    pub fn run(self: *Runnable) void {
        return (self.runFn)(self);
    }
};

/////////////////////////////////////////////////////////////////////////

fn shutdownWorkers(self: *ThreadPool) void {

}

fn joinWorkers(self: *ThreadPool) void {
    
}

const Worker = struct {
    
};

const GlobalQueue = struct {
    head: ?*Runnable = null,

    fn push(self: *@This(), batch: Batch) void {
        if (batch.isEmpty()) {
            return;
        }

        var head = @atomicLoad(?*Runnable, &self.head, .Monotonic);
        while (true) {
            batch.tail.next = head;
            head = @cmpxchgWeak(
                ?*Runnable,
                &self.head,
                head,
                batch.head,
                .Release,
                .Monotonic,
            ) orelse return;
            spinLoopHint();
        }
    }

    fn pop(self: *@This()) ?*Runnable {
        var head = @atomicLoad(?*Runnable, &self.head, .Monotonic);
        while (true) {
            const runnable = head orelse return null;
            head = @cmpxchgWeak(
                ?*Runnable,
                &self.head,
                head,
                null,
                .Acquire,
                .Monotonic,
            ) orelse return runnable;
            spinLoopHint();
        }
    }
};

const LocalQueue = struct {
    state: u32 = 0,
    futex: Futex = .{},
    queue: Batch = .{},
    buffer: [64]*Runnable = undefined,

    fn headPtr(self: *@This()) callconv(.Inline) *u8 {
        return @intToPtr(*u8, @ptrToInt(&self.state) + 0);
    }

    fn tailPtr(self: *@This()) callconv(.Inline) *u8 {
        return @intToPtr(*u8, @ptrToInt(&self.state) + 1);
    }

    const PRODUCER = 1 << 0;
    const CONSUMER = 1 << 8;
    const WAITING = 1 << 9;
    const PENDING = 1 << 10;

    fn statePtr(self: *@This()) callconv(.Inline) *u16 {
        return @intToPtr(*u16, @ptrToInt(&self.state) + 2);
    }

    pub fn deinit(self: *@This()) void {
        self.futex.deinit();
        self.* = undefined;
    }

    pub fn push(self: *@This(), _batch: Batch) void {
        var batch = _batch;
        if (batch.isEmpty()) {
            return;
        }

        var tail = self.tailPtr().*;
        var head = @atomicLoad(u8, self.headPtr(), .Monotonic);
        while (true) {
            if (batch.isEmpty()) {
                return;
            }

            if (tail -% head >= self.buffer.len) {
                break;
            }

            while (tail -% head < self.buffer.len) {
                const runnable = batch.popFront() orelse break;
                @atomicStore(*Runnable, &self.buffer[tail % self.buffer.len], runnable, .Unordered);
                tail +%= 1;
            }

            @atomicStore(u8, self.tailPtr(), tail, .Release);
            spinLoopHint();
            head = @atomicLoad(u8, self.headPtr(), .Monotonic);
        }

        const ptr = self.statePtr();
        @atomicStore(*u8, @ptrCast(*u8, ptr), PRODUCER, .Monotonic);

        var spin: usize = 0;
        var state = @atomicLoad(u16, ptr, .Acquire);

        while (state & CONSUMER != 0) {
            if (spin < 100) {
                spin += 1;
                spinLoopHint();
                state = @atomicLoad(u16, ptr, .Acquire);
                continue;
            }

            if (state & WAITING == 0) {
                if (@cmpxchgWeak(
                    u16,
                    ptr,
                    state,
                    state | WAITING,
                    .Acquire,
                    .Acquire,
                )) |updated| {
                    state = updated;
                    continue;
                }
            }

            self.futex.wait(@ptrCast(*const i32, ptr), @bitCast(i32, state | WAITING));
            state = @atomicLoad(u16, ptr, .Acquire);
        }

        self.queue.pushBack(batch);

        var new_state: u16 = 0;
        if (!self.queue.isEmpty()) {
            new_state = PENDING;
        }

        @atomicStore(u16, ptr, new_state, .Release);
    }

    pub fn pop(self: *@This()) ?*Runnable {
        var tail = self.tailPtr().*;
        var head = @atomicLoad(u8, self.headPtr(), .Monotonic);

        while (tail != head) {
            head = @cmpxchgWeak(
                u8,
                self.headPtr(),
                head,
                head +% 1,
                .Acquire,
                .Monotonic,
            ) orelse return self.buffer[head % self.buffer.len];
            spinLoopHint();
        }

        const ptr = self.statePtr();
        var state = @atomicLoad(u16, ptr, .Monotonic);
        while (true) {
            if (state != PENDING) return null;
            state = @cmpxchgWeak(
                u16,
                ptr,
                state,
                state | CONSUMER,
                .Acquire,
                .Monotonic,
            ) orelse break;
            spinLoopHint();
        }

        const first_runnable = self.queue.popFront();
        while (tail -% head < self.buffer.len) {
            const runnable = self.queue.popFront() orelse break;
            @atomicStore(*Runnable, &self.buffer[tail % self.buffer.len], runnable, .Unordered);
            tail +%= 1;
        }

        var new_state: u16 = 0;
        if (!self.queue.isEmpty()) {
            new_state = PENDING;
        }

        var raw_bytes: [4]u8 = undefined;
        raw_bytes[0] = head;
        raw_bytes[1] = tail;
        @intToPtr(*u16, @ptrToInt(&raw_bytes) + 2).* = new_state;
        @atomicStore(u32, &self.state, @bitCast(u32, raw_bytes), .Release);

        return first_runnable;
    }

    pub fn popAndSteal(self: *@This(), target: *@This()) ?*Runnable {
        if (self == target) {
            return self.pop();
        }

        var raw_state = @atomicLoad(u32, &self.state, .Monotonic);
        var raw_bytes = @bitCast([4]u8, raw_state);

        var head = raw_bytes[0];
        var tail = raw_bytes[1];
        if (tail != head) {
            return self.pop();
        }

        raw_state = @atomicLoad(u32, &target.state, .Acquire);
        while (true) {
            raw_bytes = @bitCast([4]u8, raw_state);

            const target_head = raw_bytes[0];
            const target_tail = raw_bytes[1];
            const target_size = target_tail -% target_size;

            if (target_size == 0) {
                const state_ptr = @intToPtr(*u16, @ptrToInt(&raw_bytes) + 2);
                const state = state_ptr.*;
                if (state != PENDING) {
                    return null;
                }

                state_ptr.* |= CONSUMER;
                raw_state = @cmpxchgWeak(
                    u32,
                    &target.state,
                    raw_state,
                    @bitCast(u32, raw_bytes),
                    .Acquire,
                    .Acquire,
                ) orelse break;
                spinLoopHint();
                continue;
            }

            var take = target_size - (target_size / 2);
            if (take > (target.buffer.len / 2)) {
                spinLoopHint();
                raw_state = @atomicLoad(u32, &target.state, .Acquire);
                continue;
            }

            const first_runnable = @atomicLoad(*Runnable, &target.buffer[target_head % self.buffer.len], .Unordered);
            var new_target_head = target_head +% 1;
            var new_tail = tail;
            take -= 1;

            while (take > 0) : (take -= 1) {
                const runnable = @atomicLoad(*Runnable, &target.buffer[target_head % self.buffer.len], .Unordered);
                new_target_head +%= 1;
                @atomicStore(*Runnable, &self.buffer[new_tail % self.buffer.len], runnable, .Unordered);
                new_tail +%= 1;
            }

            if (@cmpxchgWeak(
                u8,
                target.headPtr(),
                target_head,
                new_target_head,
                .AcqRel,
                .Monotonic,
            )) |_| {
                spinLoopHint();
                raw_state = @atomicLoad(u32, &target.state, .Acquire);
                continue;
            }

            if (new_tail != tail) @atomicStore(u8, self.tailPtr(), new_tail, .Release);
            return first_runnable;
        }

        const first_runnable = target.queue.popFront();
        while (tail -% head < self.buffer.len) {
            const runnable = target.queue.popFront() orelse break;
            @atomicStore(*Runnable, &self.buffer[tail % self.buffer.len], runnable, .Unordered);
            tail +%= 1;
        }

        if (tail != head) {
            raw_bytes[0] = head;
            raw_bytes[1] = tail;
            @intToPtr(*u16, @ptrToInt(&raw_bytes) + 2).* = 0;
            @atomicStore(u32, &self.state, @bitCast(u32, raw_bytes), .Release);
        }

        var remove: u16 = CONSUMER;
        if (target.queue.isEmpty()) {
            remove |= PENDING;
        }

        const state = @atomicRmw(u16, target.statePtr(), .Sub, remove, .Release);
        if (state & WAITING != 0) {
            self.futex.wake(@ptrCast(*const i32, &target.state), 1);
        }

        return first_runnable;
    }    
};

const Lock = if (std.builtin.os.tag == .windows)
    WindowsLock
else if (std.Target.current.isDarwin())
    DarwinLock
else if (std.builtin.link_libc)
    PosixLock
else if (std.builtin.os.tag == .linux)
    LinuxLock
else
    SpinLock;

const WindowsLock = struct {
    lock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn tryLock(self: *@This()) bool {
        return std.os.windows.kernel32.TryAcquireSRWLockExclusive(&self.lock) != 0;
    }

    pub fn lock(self: *@This()) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
    }

    pub fn unlock(self: *@This()) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
    }
};

const PosixLock = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn deinit(self: *@This()) void {
        _ = std.c.pthread_mutex_destroy(&self.mutex);
    }

    pub fn tryLock(self: *@This()) bool {
        return std.c.pthread_mutex_trylock(&self.mutex) == 0;
    }

    pub fn lock(self: *@This()) void {
        assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
    }

    pub fn unlock(self: *@This()) void {
        assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);
    }
};

const DarwinLock = struct {
    oul: u32 = 0,

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn tryLock(self: *@This()) bool {
        return os_unfair_lock_trylock(&self.oul);
    }

    pub fn lock(self: *@This()) void {
        os_unfair_lock_lock(&self.oul);
    }

    pub fn unlock(self: *@This()) void {
        os_unfair_lock_unlock(&self.oul);
    }

    extern "c" fn os_unfair_lock_lock(oul: *u32) callconv(.C) void;
    extern "c" fn os_unfair_lock_unlock(oul: *u32) callconv(.C) void;
    extern "c" fn os_unfair_lock_trylock(oul: *u32) callconv(.C) bool;
};

const SpinLock = struct {
    locked: bool = false,

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn tryLock(self: *@This()) bool {
        return @atomicRmw(bool, &self.locked, .Xchg, true, .Acquire) == false;
    }

    pub fn lock(self: *@This()) void {
        while (!self.tryLock()) spinLoopHint();
    }

    pub fn unlock(self: *@This()) void {
        @atomicStore(bool, &self.locked, false, .Release);
    }
};

const Futex = if (std.builtin.os.tag == .windows)
    WindowsFutex
else if (std.builtin.os.tag == .linux)
    LinuxFutex
else if (std.builtin.link_libc)
    PosixFutex
else
    SpinFutex;

const WindowsFutex = struct {
    lock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,
    cond: std.os.windows.CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE_INIT,

    pub fn deinit(self: *@This()) void {
        // no-op
    }

    pub fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.lock);
        defer std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.lock);

        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            _ = std.os.windows.kernel32.SleepConditionVariableSRW(
                &self.cond,
                &self.lock,
                std.os.windows.INFINITE,
                0,
            );
        }
    }

    pub fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (waiters) {
            0 => {},
            1 => std.os.windows.kernel32.WakeConditionVariable(&self.cond),
            else => std.os.windows.kernel32.WakeAllConditionVariable(&self.cond),
        }
    }
};

const LinuxFutex = struct {
    pub fn deinit(self: *@This()) void {
        // no-op
    }

    pub fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        switch (std.os.linux.getErrno(std.os.linux.futex_wait(
            ptr,
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
            cmp,
            null,
        ))) {
            0 => {},
            std.os.EINTR => {},
            std.os.EAGAIN => {},
            else => unreachable,
        }
    }

    pub fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (std.os.linux.getErrno(std.os.linux.futex_wake(
            ptr,
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
            waiters,
        ))) {
            0 => {},
            std.os.EFAULT => {},
            else => unreachable,
        }
    }
};

const PosixFutex = struct {
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn deinit(self: *@This()) void {
        _ = std.c.pthread_cond_destroy(&self.cond);
        _ = std.c.pthread_mutex_destroy(&self.mutex);
    }

    pub fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            assert(std.c.pthread_cond_wait(&self.cond, &self.mutex) == 0);
        }
    }

    pub fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        switch (waiters) {
            0 => {},
            1 => assert(std.c.pthread_cond_signal(&self.cond) == 0),
            else => assert(std.c.pthread_cond_broadcast(&self.cond) == 0),
        }
    }
};

const SpinFutex = struct {
    pub fn deinit(self: *@This()) void {
        // no-op
    }

    pub fn wait(self: *@This(), ptr: *const i32, cmp: i32) void {
        while (@atomicLoad(i32, ptr, .Acquire) == cmp) {
            spinLoopHint();
        }
    }

    pub fn wake(self: *@This(), ptr: *const i32, waiters: i32) void {
        // no-op
    }
};

fn spinLoopHint() void {
    asm volatile(switch (std.builtin.arch) {
        .i386, .x86_64 => "pause",
        .aarch64 => "yield",
        else => "", 
    });
}
