const zap = @import("../zap.zig");
const Lock = zap.runtime.Lock;
const nanotime = zap.runtime.nanotime;

const Bucket = struct {
    lock: Lock = Lock{},
    queue: Queue = Queue{},
    times_out: u64 = 0,
    prng: u32 = 0,

    var array = [_]Bucket{Bucket{}} ** 256;

    fn get(address: usize) *Bucket {
        const seed = @truncate(usize, 0x9E3779B97F4A7C15);
        const max = @popCount(usize, ~@as(usize, 0));
        const bits = @ctz(usize, array.len);
        const index = (address *% seed) >> (max - bits);
        return &array[index];
    }

    fn shouldBeFair(self: *Bucket) bool {
        if (self.times_out == 0)
            self.prng = @truncate(u32, @ptrToInt(self)) | 1;

        const now = nanotime();
        if (now < self.times_out)
            return false;

        const rand = blk: {
            var x = self.prng;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            self.prng = x;
            break :blk x;
        };

        const timeout = rand % 1_000_000;
        self.times_out = now + timeout;
        return true;
    }
};

const Queue = struct {
    head: ?*Waiter = null,

    fn insert(self: *Queue, address: usize, waiter: *Waiter) void {
        waiter.next = null;
        waiter.tail = waiter;
        waiter.address = address;

        if (self.head) |head| {
            const tail = head.tail orelse unreachable;
            tail.next = waiter;
            waiter.prev = tail;
            head.tail = waiter;
        } else {
            waiter.prev = null;
            self.head = waiter;
        }
    }

    fn remove(self: *Queue, waiter: *Waiter) bool {
        const head = self.head orelse return false;
        const tail = waiter.tail orelse return false;

        if (waiter.prev) |prev|
            prev.next = waiter.next;
        if (waiter.next) |next|
            next.prev = waiter.prev;

        if (head == waiter) {
            self.head = waiter.next;
            if (self.head) |new_head|
                new_head.tail = tail;
        } else if (head.tail == waiter) {
            head.tail = waiter.prev;
        }

        waiter.tail = null;
        return true;
    }

    fn iter(self: *Queue) Iter {
        return Iter{ .waiter = self.head };
    }

    const Iter = struct {
        waiter: ?*Waiter = null,

        fn next(self: *Iter, address: usize) ?*Waiter {
            while (true) {
                const waiter = self.waiter orelse return null;
                self.waiter = waiter.next;
                if (waiter.address == address)
                    return waiter;
            }
        }
    };
};

const Waiter = struct {
    prev: ?*Waiter,
    next: ?*Waiter,
    tail: ?*Waiter,
    token: usize,
    address: usize,
    wakeFn: fn(*Waiter) void,

    fn wake(self: *Waiter) void {
        return (self.wakeFn)(self);
    }
};

pub const ParkResult = union(enum){
    unparked: usize,
    timed_out: void,
    invalidated: void,
};

pub fn parkConditionally(
    comptime Event: type,
    address: usize,
    deadline: ?u64,
    context: anytype,
) ParkResult {
    var bucket = Bucket.get(address);
    bucket.lock.acquire();

    const token: usize = context.onValidate() orelse {
        bucket.lock.release();
        return .invalidated;
    };
    
    const Context = @TypeOf(context);
    const EventWaiter = struct {
        event: Event,
        waiter: Waiter,
        bucket_ref: *Bucket,
        context_ref: ?Context,

        pub fn wait(self: *@This()) bool {
            self.bucket_ref.lock.release();
            if (self.context_ref) |ctx|
                ctx.onBeforeWait();
            return true;
        }

        pub fn wake(waiter: *Waiter) void {
            const self = @fieldParentPtr(@This(), "waiter", waiter);
            self.event.notify();
        }
    };

    var event_waiter: EventWaiter = undefined;
    event_waiter.bucket_ref = bucket;
    event_waiter.waiter.wakeFn = EventWaiter.wake;
    event_waiter.event.init();
    defer event_waiter.event.deinit();

    event_waiter.waiter.token = token;
    bucket.queue.insert(address, &event_waiter.waiter);

    event_waiter.context_ref = context;
    if (event_waiter.event.wait(deadline, &event_waiter))
        return .{ .unparked = event_waiter.waiter.token };

    bucket = Bucket.get(address);
    bucket.lock.acquire();

    if (bucket.queue.remove(&event_waiter.waiter)) {
        context.onTimeout(token, bucket.queue.iter().next(address) != null);
        bucket.lock.release();
        return .timed_out;
    }

    event_waiter.context_ref = null;
    if (event_waiter.event.wait(null, &event_waiter))
        return .{ .unparked = event_waiter.waiter.token };

    unreachable;
}

pub const UnparkResult = struct {
    token: ?usize = null,
    be_fair: bool = false,
    has_more: bool = false,
};

pub fn unparkOne(address: usize, context: anytype) void {
    const bucket = Bucket.get(address);
    bucket.lock.acquire();

    var waiter: ?*Waiter = null;
    var result = UnparkResult{};
    var iter = bucket.queue.iter();
    
    if (iter.next(address)) |pending_waiter| {
        waiter = pending_waiter;
        const next = iter.next(address);
        if (!bucket.queue.remove(pending_waiter))
            unreachable;

        result = UnparkResult{
            .be_fair = bucket.shouldBeFair(),
            .has_more = next != null,
            .token = pending_waiter.token,
        };
    }

    const token: usize = context.onUnpark(result);
    bucket.lock.release();

    if (waiter) |pending_waiter| {
        pending_waiter.token = token;
        pending_waiter.wake();
    }
}

pub fn unparkAll(address: usize) void {
    const bucket = Bucket.get(address);
    bucket.lock.acquire();

    var wake_list: ?*Waiter = null;
    var iter = bucket.queue.iter();
    var next_waiter: ?*Waiter = iter.next(address);

    while (true) {
        const pending_waiter = next_waiter orelse break;
        next_waiter = iter.next(address);
        if (!bucket.queue.remove(pending_waiter))
            unreachable;

        pending_waiter.next = wake_list;
        wake_list = pending_waiter;
    }

    bucket.lock.release();

    while (true) {
        const pending_waiter = wake_list orelse break;
        wake_list = pending_waiter.next;
        pending_waiter.wake();
    }
}
