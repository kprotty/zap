const core = @import("../core.zig");
const Atomic = core.sync.atomic.Atomic;

const WaitAddress = struct {
    ptr: usize,
};

const WaitBucket = struct {
    bucket: *Atomic(usize),
    tree: WaitTree,

    var buckets = [_]Atomic(usize){Atomic(usize).init(0)} ** 1024;

    fn acquire(address: WaitAddress) WaitBucket {

    }

    fn release(self: WaitBucket) void {

    }
};

const WaitTree = struct {
    root: ?*Node,

    const Node = struct {
        address: WaitAddress,
        pcolor: usize = 0,
        child: [2]?*Node = [2]?*Node{ null, null },
    };

    fn isEmpty(self: WaitTree) bool {
        return self.root == null;
    }

    fn find(self: *WaitTree, parent: *?*Node, address: WaitAddress) ?*Node {

    }

    fn insert(self: *WaitTree, parent: ?*Node, address: WaitAddress, node: *Node) void {

    }

    fn remove(self: *WaitAddress, node: *Node) void {

    }
};

const WaitList = struct {
    head: ?*Node = null,

    const Node = struct {
        prev: ?*Node = null,
        next: ?*Node = null,
        tail: ?*Node = null,
        wakeFn: fn(*Node) void,
    };

    fn isEmpty(self: WaitList) bool {
        return self.head == null;
    }

    fn add(self: *WaitList, node: *Node) void {

    }

    fn remove(self: *WaitList, node: *Node) bool {

    }
};

const Waiter = struct {
    tree_node: WaitTree.Node = .{},
    list_node: WaitList.Node = .{},
    list: WaitList = .{},
    token: usize,
};

pub const WaitResult = union(enum) {
    invalid: void,
    notified: usize,
    timeout: usize,
};

pub fn wait(context: anytype) WaitResult {
    @setCold(true);

    const SyncEvent = @TypeOf(context).SyncEvent;
    const WaitEvent = @TypeOf(context).WaitEvent;
    const EventWaiter = struct {
        event: WaitEvent,
        waiter: Waiter,
    };

    const addr = WaitAddress{ .ptr = context.address };
    var bucket = WaitBucket.acquire(addr, SyncEvent);

    var token = context.onValidate() orelse {
        bucket.release();
        return WaitResult{ .invalid = {} };
    };

    var event_waiter: EventWaiter = undefined;
    event_waiter.event.init();
    defer event_waiter.event.deinit();

    const waiter = &event_waiter.waiter;
    waiter.* = Waiter{
        .token = token,
        .tree_node = WaitTree.Node{ .address = address },
        .list_node = WaitList.Node{ .wakeFn = EventWaiter.wake },
    };

    var parent_tree: ?*WaitTree.Node = undefined;
    const tree_root = bucket.tree.find(&parent_tree, addr) orelse blk: {
        bucket.tree.insert(parent_tree, addr, &waiter.tree_node);
        break &waiter.tree_node;
    };

    tree_root.list.add(&waiter.list_node);
    bucket.release();
    context.onBeforeWait();

    var timed_out = !event_waiter.event.wait(context.timeout);
    if (timed_out) {
        bucket = WaitBucket.acquire(addr, SyncEvent);
        defer bucket.release();

        if (bucket.tree.find(&parent_tree, &waiter.tree_node)) |root| {
            timed_out = root.list.remove(&waiter.list_node);
            if (timed_out) {
                context.onTimeOut();
            }
        } else {
            timed_out = false;
        }
    }

    token = waiter.token;
    if (timed_out)
        return WaitResult{ .timed_out = token };
    return WaitResult{ .notified = token };
}

pub const WakeResult = union(enum) {
    wake: usize,
    skip: void,
    stop: void,
};

pub fn wake(address: usize, context: anytype) void {
    @setCold(true);

    const SyncEvent = @TypeOf(context).SyncEvent;
    const addr = WaitAddress{ .ptr = context.address };
    const bucket = WaitBucket.acquire(addr, SyncEvent);

    var wake_list: ?*Waiter = null;
    var parent_tree: ?*WaitTree.Node = undefined;

    if (bucket.tree.find(&parent_tree, addr)) |root| {
        @compileError("TODO: context.onFilter(waiter.token): WakeResult");
    }

    context.onBeforeWake();
    bucket.release();

    while (wake_list) |pending_waiter| {
        const waiter = pending_waiter;
        wake_list = waiter.list_node.next;
        (waiter.list_node.wakeFn)(&waiter.list_node);
    }
}