// Copyright 2020 kprotty
//
// Licensed under the Apache License, Version 2.0, <LICENSE-APACHE or
// http://apache.org/licenses/LICENSE-2.0> or the MIT license <LICENSE-MIT or
// http://opensource.org/licenses/MIT>, at your option. This file may not be
// copied, modified, or distributed except according to those terms.

const builtin = @import("builtin");
const sync = @import("./sync.zig");

const SpinWait = sync.SpinWait;
const Atomic = sync.atomic.Atomic;

pub const WaitNode = struct {
    prev: ?*WaitNode align(core.meta.max(8, @alignOf(usize))),
    next: ?*WaitNode,
    tail: *WaitNode,
    parent: usize,
    children: [2]?*WaitNode,
    address: usize,
    wakeFn: fn(*WaitNode) void,
};

const WaitBucket = struct {
    state: Atomic(usize) = Atomic(usize).init(0),

    const LOCKED: usize = 1 << 0;
    const CONTENDED: usize = 1 << 1;
    const STARVED: usize = 1 << 2;
    const POINTER: usize = ~(LOCKED | CONTENDED | STARVED);

    const Waiter = struct {
        prev: ?*Waiter align(core.meta.max(8, @alignOf(usize))),
        next: ?*Waiter,
        tail: ?*Waiter,
        state: usize,
        acquired: bool,
        wakeFn: fn(*Waiter) void,

        fn getTail(self: *Waiter) *Waiter {
            return self.tail orelse {
                var current = self;
                while (true) {
                    const next = current.next orelse unreachable;
                    next.prev = current;
                    current = next;
                    if (current.tail) |tail| {
                        self.tail = tail;
                        return tail;
                    }
                }
            };
        }
    };

    var table = [_]WaitBucket{WaitBucket{}} ** 1024;

    fn get(address: usize) *WaitBucket {
        @compileError("TODO");
    }

    const Root = union(enum) {
        node: *WaitNode,
        prng: u16,

        fn pack(self: Root) usize {
            return switch (self) {
                .node => |node| @ptrToInt(node) | STARVED,
                .prng => |prng| @as(usize, prng) << @popCount(usize, ~POINTER),
            };
        }

        fn unpack(value: usize) Root {
            if (value & STARVED != 0) {
                const ptr = @intToPtr(*WaitNode, value & POINTER);
                return Root{ .node = ptr };
            }

            const prng_bits = value >> @popCount(usize, ~POINTER);
            const prng = core.meta.max(1, @truncate(u16, prng_bits));
            return Root{ .prng = prng };
        }
    };

    fn acquire(self: *WaitBucket, comptime Parker: type) Root {
        const ParkerWaiter = struct {
            waiter: Waiter,
            parker: Parker,

            fn unpark(waiter: *Waiter) void {
                const self = @fieldParentPtr(@This(), "waiter", waiter);
                self.parker.unpark();
            }
        };

        var parker_waiter: ParkerWaiter = undefined;
        const waiter = &parker_waiter.waiter;
        const parker = &parker_waiter.parker;

        var attempts: usize = 0;
        var did_prepare = false;
        var spin_wait = SpinWait(Parker){};
        var state = self.state.load(.relaxed);

        while (true) {    
            if (state & LOCKED == 0) {
                const acquired = switch (builtin.arch) {
                    .i386, .x86_64 => asm volatile(
                        "lock btsl $0, %[ptr]"
                        : [ret] "={@ccc}" (-> u8),
                        : [ptr] "*m" (&self.state)
                        : "cc", "memory"
                    ) == 0,
                    else => self.state.tryCompareAndSwap(
                        state,
                        state | LOCKED,
                        .acquire,
                        .monotonic,
                    ) == null,
                };

                if (acquired) {
                    return Root.unpack(blk: {
                        if (state & CONTENDED == 0)
                            break :blk state;
                        break :blk @intToPtr(*Waiter, ptr).getTail().state;
                    });
                }

                spin_wait.yield();
                state = self.state.load(.relaxed);
                continue;
            }

            var head: ?*Waiter = null;
            if (state & CONTENDED != 0)
                head = @intToPtr(?*Waiter, state & POINTER);
            
            if (head == null and spin_wait.spin()) {
                state = self.state.load(.relaxed);
                continue;
            }

            waiter.prev = null;
            waiter.next = head;
            waiter.tail = if (head == null) &waiter else null;
            waiter.acquired = false;
            waiter.state = state;

            if (!did_prepare) {
                did_prepare = true;
                parker.prepare();
                waiter.wakeFn = ParkerWaiter.unpark;
            }

            var new_state = (state & ~POINTER) | @ptrToInt(waiter) | CONTENDED;
            if (attempts >= 3)
                new_state |= STARVED;

            if (self.state.tryCompareAndSwap(
                state,
                new_state,
                .release,
                .relaxed,
            )) |updated| {
                state = updated;
                continue;
            }

            parker.park();
            if (waiter.acquired)
                return Root.unpack(waiter.state);

            attempts +%= 1;
            spin_wait.reset();
            did_prepare = false;
            state = self.state.load(.relaxed);
        }
    }

    fn release(self: *WaitBucket, root: Root) void {
        var state = self.state.load(.acquire);
        while (true) {
            if (state & CONTENDED == 0) {
                state = self.state.tryCompareAndSwap(
                    state,
                    root.pack(),
                    .release,
                    .acquire,
                ) orelse break;
                continue;
            }

            const head = @intToPtr(*Waiter, state & POINTER);
            const tail = head.getTail();
            const be_fair = state & STARVED != 0;

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                if (!be_fair) {
                    _ = self.state.fetchAnd(~LOCKED, .release);
                }

            } else if (self.state.tryCompareAndSwap(
                state,
                root.pack() | (if (be_fair) LOCKED else 0),
                .release,
                .acquire,
            )) |updated| {
                state = updated;
                continue;
            }

            tail.acquired = be_fair;
            tail.root = root.pack();
            return (tail.wakeFn)(tail);
        }
    }
};

pub const WaitListRef = struct {
    bucket: *WaitBucket,
    root: WaitBucket.Root,

    pub fn acquire(address: usize, comptime Parker: type) WaitListRef {
        const bucket = WaitBucket.get(address);
        const root = bucket.acquire(Parker);

        return WaitListRef{
            .bucket = bucket,
            .root = root,
        };
    }

    pub fn release(self: WaitListRef) void {
        self.bucket.release(self.root);
    }

    pub fn insert(self: *WaitListRef, node: *WaitNode) void {
        // TODO: red-black tree

    }

    pub fn remove(self: *WaitListRef, node: *WaitNode) void {
        // TODO: red-black tree

    }

    pub fn iter(self: *WaitListRef, address: usize) WaitListIter {
        // TODO: red-black tree

    }
};

pub const WaitListIter = struct {
    list: *WaitListRef,
    head: ?*WaitNode,
    node: ?*WaitNode,

    pub fn next(self: *WaitListIter) ?WaitListNodeRef {
        const node = self.node orelse return null;
        self.node = node.next;
        
        return WaitListNodeRef{
            .iter = self,
            .node = node,
        };
    }

    fn remove(self: *WaitListIter, node: *WaitNode) void {
        const head = self.head orelse unreachable;
        const prev = node.prev;
        const next = node.next;

        if (prev) |p|
            p.next = next;
        if (next) |n|
            n.prev = prev;

        if (head == node) {
            self.head = next;
            if (next) |n|
                n.tail = node.tail;

        } else if (head.tail == node) {
            head.tail = prev orelse unreachable;
        }

        
    }
};

pub const WaitListNodeRef = struct {
    iter: *WaitListIter,
    node: *WaitNode,

    pub fn getNode(self: WaitListNodeRef) *WaitNode {
        return self.node;
    }

    pub fn remove(self: *WaitListNodeRef) void {
        return self.iter.remove(self.node);
    }
};

pub fn parkConditionally(
    address: usize,
    deadline: u64,
    token: usize,
    callback: anytype,
) error{Invalid, TimedOut}!usize {
    @setCold(true);

    const SyncParker = @TypeOf(callback).SyncParker;
    const WaitParker = @TypeOf(callback).WaitParker;
    const Waiter = struct {
        node: WaitNode,
        parker: WaitParker,

        fn unpark(node: *WaitNode) void {
            const self = @fieldParentPtr(@This(), "node", node);
            self.parker.unpark();
        }
    };

    var wait_list = WaitListRef.acquire(address, SyncParker);
    if (!callback.onValidate()) {
        wait_list.release();
        return error.Invalid;
    }

    var waiter: Waiter = undefined;
    const node = &waiter.node;
    const parker = &waiter.parker;

    node.token = token;
    node.address = address;
    node.wakeFn = Waiter.unpark;
    wait_list.insert(node);

    var timed_out = blk: {
        parker.prepare();
        wait_list.release();
        callback.onBeforePark();
        break :blk parker.park(deadline);
    };

    if (timed_out) {
        wait_list = WaitListRef.acquire(address, SyncParker);
        
        timed_out = blk: {
            if (node.tail == null)
                break :blk false;

            var list_iter = wait_list.iter(address);
            var node_ref = WaitListNodeRef{
                .iter = &list_iter,
                .node = node,
            };

            node_ref.remove(node);
            break :blk true;
        };

        if (timed_out) {
            callback.onTimeOut();
            wait_list.release();
        } else {
            wait_list.release();
            _ = parker.wait(null);
        }
    }

    if (timed_out)
        return error.TimedOut;
    return node.token;
}

pub fn unparkFilter(address: usize, callback: anytype) void {
    @setCold(true);

    const SyncParker = @TypeOf(callback).SyncParker;
    var wait_list = WaitListRef.acquire(address, SyncParker);

    var wake_list: ?*WaitNode = null;
    var list_iter = wait_list.iter(address);
    filter: while (list_iter.next()) |node_ref| {
        
        const node = node_ref.getNode();
        const unpark_token = callback.onFilter(node.token) catch |err| switch (err) {
            error.Skip => continue,
            error.Stop => break :filter,
            else => @compileError("invalid onFilter() error union for " ++ @typeName(@TypeOf(callback))),
        };

        node_ref.remove();
        node.token = unpark_token;
        if (wake_list) |head| {
            head.tail.next = node;
            head.tail = node;
        } else {
            node.tail = node;
            wake_list = node;
        }
    }
    
    callback.onBeforeUnpark();
    wait_list.release();

    while (wake_list) |wait_node| {
        const node = wait_node;
        wake_list = node.next;
        (node.wakeFn)(node);
    }
}

pub const UnparkResult = struct {
    unparked: usize,
    has_more: bool,
    be_fair: bool,
};

pub fn unparkOne(address: usize, callback: anytype) void {
    @compileError("TODO");
}

pub fn unparkAll(address: usize) void {
    @compileError("TODO");
}