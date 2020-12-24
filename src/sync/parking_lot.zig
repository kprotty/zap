
pub fn ParkingLot(comptime config: anytype) type {
    const Lock = config.Lock;
    const bucket_count: usize = config.bucket_count;
    const eventually_fair_after: u64 = config.eventually_fair_after;

    return struct {
        const Bucket = struct {
            lock: Lock = .{},
            tree: Tree = .{},
            fairness: Fairness = .{},

            var array = [_]Bucket{Bucket{}} ** bucket_count;

            pub fn get(address: usize) *Bucket {
                const seed = @truncate(usize, 0x9E3779B97F4A7C15);
                const max = @popCount(usize, ~@as(usize, 0));
                const bits = @ctz(usize, array.len);
                const index = (address *% seed) >> (max - bits);
                return &array[index];
            }
        };

        const Fairness = struct {
            xorshift: u32 = 0,
            times_out: u64 = 0,

            pub fn expired(self: *Fairness, now: u64) bool {
                if (now <= self.times_out)
                    return false;

                if (self.xorshift == 0)
                    self.xorshift = @truncate(u32, @ptrToInt(self) >> @sizeOf(u32));
                self.xorshift ^= self.xorshift << 13;
                self.xorshift ^= self.xorshift >> 17;
                self.xorshift ^= self.xorshift << 5;

                const fair_timeout = self.xorshift % eventually_fair_after;
                self.times_out = now + fair_timeout;
                return true;
            }
        };

        const Tree = struct {
            tree_head: ?*Waiter = null,

            pub fn insert(self: *Tree, address: usize, waiter: *Waiter) void {
                waiter.address = address;
                waiter.tree_next = null;
                waiter.next = null;
                waiter.tail = waiter;

                if (self.lookup(address, &waiter.tree_prev)) |head| {
                    const tail = head.tail orelse unreachable;
                    tail.next = waiter;
                    waiter.prev = tail;
                    head.tail = waiter;
                    return;
                }

                waiter.prev = null;
                if (waiter.tree_prev) |prev| {
                    prev.tree_next = waiter;
                } else {
                    self.tree_head = waiter;
                }            
            }

            pub fn iter(self: *Tree, address: usize) Iter {
                const head = self.lookup(address, null);

                return .{
                    .head = head,
                    .iter = head,
                    .tree = self,
                };
            }

            fn lookup(self: *Tree, address: usize, parent: ?*?*Waiter) ?*Waiter {
                var waiter = self.tree_head;
                if (parent) |p|
                    p.* = waiter;

                while (true) {
                    const head = waiter orelse return null;
                    if (head.address == address)
                        return head;
                    
                    waiter = head.tree_next;
                    if (parent) |p|
                        p.* = head;
                }
            }

            fn replace(self: *Tree, waiter: *Waiter, new_waiter: *Waiter) void {
                new_waiter.tree_next = waiter.tree_next;
                new_waiter.tree_prev = waiter.tree_prev;

                if (new_waiter.tree_prev) |prev|
                    prev.tree_next = new_waiter;

                if (new_waiter.tree_next) |next|
                    next.tree_prev = new_waiter;

                if (self.tree_head == waiter)
                    self.tree_head = new_waiter;
            }

            fn remove(self: *Tree, waiter: *Waiter) void {
                if (waiter.tree_next) |next|
                    next.tree_prev = waiter.tree_prev;

                if (waiter.tree_prev) |prev|
                    prev.tree_next = waiter.tree_next;

                if (self.tree_head == waiter)
                    self.tree_head = null;
            }
        };

        const Iter = struct {
            head: ?*Waiter,
            iter: ?*Waiter,
            tree: *Tree,

            pub fn isEmpty(self: Iter) bool {
                return self.iter == null;
            }

            pub fn next(self: *Iter) ?*Waiter {
                const waiter = self.iter orelse return null;
                self.iter = waiter.next;
                return waiter;
            }

            pub fn isQueueEmpty(self: Iter) bool {
                return self.head == null;
            }

            pub fn tryQueueRemove(self: *Iter, waiter: *Waiter) bool {
                const head = self.head orelse return false;
                if (waiter.tail == null)
                    return false;
                
                if (self.iter == waiter)
                    self.iter = waiter.next;
                if (waiter.prev) |p|
                    p.next = waiter.next;
                if (waiter.next) |n|
                    n.prev = waiter.prev;

                if (waiter == head) {
                    self.head = waiter.next;
                } else if (waiter == head.tail) {
                    head.tail = waiter.prev orelse unreachable;
                }

                if (waiter == head) {
                    if (self.head) |new_head| {
                        new_head.tail = waiter.tail;
                        self.tree.replace(waiter, new_head);
                    } else {
                        self.tree.remove(waiter);
                    }
                }

                waiter.tail = null;
                return true;
            }
        };

        const Waiter = struct {
            tree_prev: ?*Waiter,
            tree_next: ?*Waiter,
            prev: ?*Waiter,
            next: ?*Waiter,
            tail: ?*Waiter,
            address: usize,
            token: usize,
            eventFn: fn(*Waiter, EventOp) u64,

            const EventOp = enum {
                wake,
                nanotime,
            };

            fn wake(self: *Waiter) void {
                _ = (self.eventFn)(self, .wake);
            }

            fn nanotime(self: *Waiter) u64 {
                return (self.eventFn)(self, .nanotime);
            }
        };

        pub const UnparkContext = struct {
            iter: *Iter,
            waiter: *Waiter,
            fairness: *Fairness,

            pub fn getToken(self: UnparkContext) usize {
                return self.waiter.token;
            }

            pub fn hasMore(self: UnparkContext) bool {
                return !self.iter.isEmpty();
            }

            pub fn beFair(self: UnparkContext) bool {
                return self.fairness.expired(self.waiter.nanotime());
            }
        };

        pub fn parkConditionally(
            comptime Event: type,
            address: usize,
            deadline: ?u64,
            context: anytype,
        ) error{TimedOut, Invalid}!usize {
            var bucket = Bucket.get(address);
            bucket.lock.acquire();

            const token: usize = context.onValidate() orelse {
                bucket.lock.release();
                return error.Invalid;
            };

            var event_waiter: struct {
                event: Event,
                waiter: Waiter,

                fn eventFn(waiter: *Waiter, op: Waiter.EventOp) u64 {
                    const this = @fieldParentPtr(@This(), "waiter", waiter);
                    switch (op) {
                        .wake => this.event.notify(),
                        .nanotime => return Event.nanotime(),
                    }
                    return 0;
                }
            } = undefined;
            
            const waiter = &event_waiter.waiter;
            waiter.token = token;
            waiter.eventFn = @TypeOf(event_waiter).eventFn;
            bucket.tree.insert(address, waiter);

            const event = &event_waiter.event;
            event.init();
            defer event.deinit();

            const Context = @TypeOf(context);
            const WaitCondition = struct {
                bucket_ref: *Bucket,
                context_ref: ?Context,

                pub fn wait(this: @This()) bool {
                    if (this.context_ref) |ctx|
                        ctx.onBeforeWait();
                    this.bucket_ref.lock.release();
                    return true;
                }
            };

            var timed_out = false;
            event.wait(deadline, WaitCondition{
                .bucket_ref = bucket,
                .context_ref = context,
            }) catch {
                timed_out = true;
            };

            if (timed_out) {
                bucket = Bucket.get(address);
                bucket.lock.acquire();
                
                var iter = bucket.tree.iter(address);
                if (iter.tryQueueRemove(waiter)) {
                    context.onTimeout(!iter.isEmpty());
                    bucket.lock.release();
                    return error.TimedOut;
                }

                event.wait(null, WaitCondition{
                    .bucket_ref = bucket,
                    .context_ref = null,
                }) catch unreachable;
            }
            
            return waiter.token;
        }

        pub const UnparkFilter = union(enum) {
            stop: void,
            skip: void,
            unpark: usize,
        };

        pub fn unparkFilter(address: usize, context: anytype) void {
            const bucket = Bucket.get(address);
            bucket.lock.acquire();

            var wake_list: ?*Waiter = null;
            var iter = bucket.tree.iter(address);
            
            while (iter.next()) |waiter| {
                switch (@as(UnparkFilter, context.onFilter(UnparkContext{
                    .iter = &iter,
                    .waiter = waiter,
                    .fairness = &bucket.fairness,
                }))) {
                    .stop => break,
                    .skip => continue,
                    .unpark => |new_token| {
                        if (!iter.tryQueueRemove(waiter))
                            unreachable;
                        waiter.token = new_token;
                        waiter.next = wake_list;
                        wake_list = waiter;
                    },
                }
            }

            context.onBeforeWake();
            bucket.lock.release();

            while (true) {
                const waiter = wake_list orelse break;
                wake_list = waiter.next;
                waiter.wake();
            }
        }

        pub const UnparkResult = struct {
            token: ?usize = null,
            has_more: bool = false,
            be_fair: bool = false,
        };

        pub fn unparkOne(address: usize, context: anytype) void {
            const Context = @TypeOf(context);
            const Filter = struct {
                ctx: Context,
                called_unpark: bool = false,

                pub fn onFilter(this: *@This(), unpark_context: UnparkContext) UnparkFilter {
                    if (this.called_unpark)
                        return .stop;

                    const unpark_token: usize = this.ctx.onUnpark(UnparkResult{
                        .token = unpark_context.getToken(),
                        .has_more = unpark_context.hasMore(),
                        .be_fair = unpark_context.beFair(),
                    });

                    this.called_unpark = true;
                    return .{ .unpark = unpark_token };
                }

                pub fn onBeforeWake(this: @This()) void {
                    if (!this.called_unpark) {
                        _ = this.ctx.onUnpark(UnparkResult{});
                    }
                }
            };

            var filter = Filter{ .ctx = context };
            return unparkFilter(address, &filter);
        }

        pub fn unparkAll(address: usize) void {
            const Filter = struct {
                pub fn onBeforeWake(this: @This()) void {}
                pub fn onFilter(this: @This(), _: UnparkContext) UnparkFilter {
                    return .{ .unpark = 0 };
                }
            };
            
            var filter = Filter{};
            return unparkFilter(address, filter);
        }
    };
}
