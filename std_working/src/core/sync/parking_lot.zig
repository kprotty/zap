const std = @import("std");
const core = @import("../core.zig");

const Lock = core.sync.Lock;
const Waker = core.sync.Waker;
const Condition = core.sync.Condition;

pub const Parker = struct {
    callFn: fn(*Parker, Action) void,

    pub const Action = union(enum) {
        validate: *?usize,
        parking: void,
        timeout: Timeout,

        pub const Timeout = struct {
            token: usize,
            remaining: usize,
        };
    };

    pub fn call(self: *Parker, action: Action) void {
        return (self.callFn)(self, action);
    }
};

pub const ParkResult = union(enum) {
    invalid: void,
    unparked: usize,
    timeout: usize,
};

pub const Unparker = struct {
    filterFn: fn(*Unparker, usize, usize, fairCheck: *FairCheck) UnparkResult,

    pub fn filter(self: *Unparker, token: *usize, remaining: usize, fairCheck: *FairCheck) UnparkResult {
        return (self.filterfn)(self, token, remaining, fairCheck);
    }
};

pub const FairCheck = struct {
    beFairFn: fn(*FairCheck) bool,

    pub fn shouldBeFair(self: *FairCheck) bool {
        return (self.beFairFn)(self);
    }
};

pub const UnparkResult = enum {
    stop,
    skip,
    unpark,
};

pub fn Bucket(comptime Timestamp: type) type {
    return struct {
        lock: Lock = Lock{},
        head: ?*Waiter = null,
        times_out: Timestamp = Timestamp{},
        xorshift: u32 = 0,

        const Waiter = struct {
            prev: ?*Waiter = undefined,
            next: ?*Waiter = undefined,
            tail: ?*Waiter = undefined,
            address: usize,
            token: usize,
            waker: Waker,
        };
    };
}

pub fn BucketParkingLot(
    comptime BucketTimestamp: type,
    comptime BucketProvider: type,
) type {
    return extern struct {
        const Self = @This();
        const ParkBucket = Bucket(BucketTimestamp);

        pub fn park(_: *Self, address: usize, parker: *Parker, comptime Futex: type, deadline: ?*BucketTimestamp) ParkResult {
            const ParkFuture = struct {
                parker: ?*Parker,
                futex: Futex = Futex{},
                waiter: ParkBucket.Waiter = ParkBucket.Waiter{ .waker = Waker{ .wakeFn = wake }},
                
                const Future = @This();

                fn wake(waker: *Waker) void {
                    const waiter = @fieldParentPtr(ParkBucket.Waiter, "waker", waker);
                    const future = @fieldParentPtr(Future, "waiter", waiter);
                    future.futex.wake();
                }

                pub fn isMet(future: *Future) bool {
                    const bucket: *ParkBucket = BucketProvider.fromAddress(future.waiter.address);
                    bucket.lock.acquire(Futex);

                    var park_token: ?usize = null;
                    const parker = future.parker.?;
                    parker.call(.{ .validate = &park_token });

                    future.waiter.token = park_token orelse {
                        future.parker = null;
                        bucket.lock.release();
                        return true;
                    };

                    const waiter = &future.waiter;
                    waiter.next = null;
                    waiter.tail = waiter;
                    if (bucket.head) |head| {
                        const tail = bucket.tail.?;
                        tail.next = waiter;
                        waiter.prev = tail;
                        bucket.tail = waiter;
                    } else {
                        waiter.prev = null;
                        bucket.head = waiter;
                    }

                    bucket.lock.release();
                    parker.call(.parking);
                    return false;
                }
            };
            
            var future = Future{ .parker = parker };
            future.waiter.address = address;
            if (future.futex.wait(deadline, &future)) {
                if (future.parker == null)
                    return .invalid;
                return .{ .unparked = future.waiter.token };
            }

            const bucket: *ParkBucket = BucketProvider.fromAddress(address);
            bucket.lock.acquire(Futex);

            if (future.waiter.tail == null) {
                bucket.lock.release();
                return .{ .unparked = future.waiter.token };
            }

            const token = future.waiter.token;
            parker.call(.{
                .timeout = .{
                    .token = token,
                    .remaining = bucket.getRemaining(address),
                },
            });

            bucket.lock.release();
            return .{ .timeout = token };
        }

        pub fn unpark(self: *Self, address: usize, unparker: *Unparker, comptime Futex: type) void {
            const bucket: *ParkBucket = BucketProvider.fromAddress(address);
            bucket.lock.acquire(Futex);

            var remaining: ?usize = null;
            var unparked: ?*ParkBucket.Waiter = null;
            var current: ?*ParkBucket.Waiter = bucket.head;

            while (current) |waiter| {
                current = waiter.next;
                if (waiter.address != address)
                    continue;

                const remains = remaining orelse blk: {
                    var scan = current;
                    var remains: usize = 0;
                    while (scan) |sw| {
                        if (sw.address == address)
                            remains += 1;
                        scan = sw.next;
                    }
                    remaining = remains;
                    break :blk remains;
                };

                const FairnessCheck = struct {
                    fair_check: FairCheck = FairCheck{ .beFairFn = beFair },
                    bucket: *ParkBucket,

                    fn beFairFn(fair_check: *FairCheck) bool {
                        const fairness_check = @fieldParentPtr(@This(), "fair_check", fair_check);
                        const bucket = fairness_check.bucket;

                        var now = BucketTimestamp{};
                        now.current();
                        if (!now.since(&bucket.times_out))
                            return false;

                        // TODO
                    }
                };

                var fairness_check = FairnessCheck{ .bucket = bucket };
                switch (unparker.filter(&waiter.token, remains, &fairness_check.fair_check)) {
                    .stop => break,
                    .skip => continue,
                    .unpark => {

                    },
                }
            }
        }
    };
}