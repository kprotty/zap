const core = @import("../core.zig");
const Atomic = core.sync.atomic.Atomic;

const WaitNode = struct {
    prev: ?*WaitNode align(if (@alignOf(usize) > 8) @alignOf(usize) else 8),
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
    const ROOTED: usize = 1 << 1;

    var table = [_]WaitBucket{WaitBucket{}} ** 1024;

    fn get(address: usize) *WaitBucket {
        @compileError("TODO");
    }

    fn acquire(self: *WaitBucket, comptime Parker: type) ?*WaitNode {
        @compileError("TODO");
    }

    fn release(self: *WaitBucket, root: ?*WaitNode) void {
        @compileError("TODO");
    }
};

const WaitListRef = struct {
    bucket: *WaitBucket,
    root: ?*WaitNode,

    fn acquire(address: usize, comptime Parker: type) WaitListRef {
        const bucket = WaitBucket.get(address);
        const root = bucket.acquire(Parker);

        return WaitListRef{
            .bucket = bucket,
            .root = root,
        };
    }

    fn release(self: WaitListRef) void {
        self.bucket.release(self.root);
    }

    fn insert(self: *WaitListRef, node: *WaitNode) void {
        @compileError("TODO");
    }

    fn remove(self: *WaitListRef, node: *WaitNode) bool {
        @compileError("TODO");
    }

    fn iter(self: *WaitListRef, address: usize) WaitListIter {
        @compileError("TODO");
    }
};

const WaitListIter = struct {
    list: *WaitListRef,
    node: ?*WaitNode,

    fn next(self: *WaitListIter) ?WaitListNodeRef {
        @compileError("TODO");
    }
};

const WaitListNodeRef = struct {
    iter: *WaitListRef,
    node: *WaitNode,

    fn remove(self: *WaitListNodeRef) void {
        @compileError("TODO");
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
        timed_out = wait_list.remove(node);

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
        
        const node = node_ref.node;
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