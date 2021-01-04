const zap = @import("../../zap.zig");
const sync = zap.sync;
const time = zap.time;

pub fn Generic(comptime config: anytype) type {
    return struct {
        pub const Event = switch (@hasField(@TypeOf(config), "Event")) {
            true => config.Event,
            else => sync.backend.spin.Event,
        };

        pub const Lock = extern struct {
            inner: switch (@hasField(@TypeOf(config), "Lock")) {
                true => config.Lock,
                else => extern struct {
                    inner: sync.generic.Lock = .{},

                    fn tryAcquire(self: *@This()) bool {
                        return self.inner.tryAcquire();
                    }

                    fn acquire(self: *@This()) void {
                        self.inner.acquire(Event);
                    }

                    fn release(self: *@This()) void {
                        self.inner.release();
                    }
                },
            } = .{},

            pub fn acquire(self: *Lock) Held {
                self.inner.acquire();
                return Held{ .lock = self };
            }

            pub fn tryAcquire(self: *Lock) ?Held {
                if (self.inner.tryAcquire())
                    return Held{ .lock = self };
                return null;
            }

            pub const Held = extern struct {
                lock: *Lock,

                pub fn release(self: Held) void {
                    self.lock.release();
                }
            };

            pub fn release(self: *Lock) void {
                return self.inner.release();
            }  
        };

        pub const parking_lot = sync.generic.ParkingLot(.{
            .Lock = Lock,
            .bucket_count = switch (@hasField(@TypeOf(config), "bucket_count")) {
                true => config.bucket_count,
                else => 256,
            },
            .eventually_fair_after = switch (@hasField(@TypeOf(config), "eventually_fair_after")) {
                true => config.eventually_fair_after,
                else => 1 * time.ns_per_ms,
            },
        });

        pub const Mutex = extern struct {
            inner: sync.generic.Mutex(parking_lot) = .{},

            pub fn acquire(self: *Mutex) Held {
                self.inner.acquire(Event);
                return Held{ .mutex = self };
            }

            pub fn tryAcquire(self: *Mutex) ?Held {
                if (self.inner.tryAcquire())
                    return Held{ .mutex = self };
                return null;
            }

            pub fn tryAcquireFor(self: *Mutex, duration: u64) error{TimedOut}!Held {
                try self.inner.tryAcquireFor(Event, duration);
                return Held{ .mutex = self };
            }

            pub fn tryAcquireUntil(self: *Mutex, deadline: u64) error{TimedOut}!Held {
                try self.inner.tryAcquireUntil(Event, deadline);
                return Held{ .mutex = self };
            }

            pub const Held = extern struct {
                mutex: *Mutex,

                pub fn release(self: Held) void {
                    self.mutex.release();
                }

                pub fn releaseFair(self: Held) void {
                    self.mutex.releaseFair();
                }
            };

            pub fn release(self: *Mutex) void {
                return self.inner.release();
            }

            pub fn releaseFair(self: *Mutex) void {
                return self.inner.releaseFair();
            }
        };
    };
}
