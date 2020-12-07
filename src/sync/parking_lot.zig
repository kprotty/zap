const zap = @import("../zap.zig");
const Lock = zap.runtime.Lock;
const nanotime = zap.runtime.nanotime;

const WaitRoot = union(enum) {
    prng: usize,
    tree: ?*WaitNode,

    fn pack(self: WaitRoot) usize {
        return switch (self) {
            .prng => |prng| (prng << 1) | 1,
            .tree => |node| @ptrToInt(node),
        };
    }

    fn unpack(value: usize) WaitRoot {
        return switch (@truncate(u1, value)) {
            0 => WaitRoot{ .tree = @intToPtr(?*WaitRoot, value & ~@as(usize, 1)) },
            1 => WaitRoot{ .prng = value >> 1 },
            else => unreachable,
        };
    }
};

const WaitBucket = struct {
    lock: Lock = Lock{},
    root: usize = (WaitRoot{ .tree = null }).pack(),

    var array = [256]WaitBucket{WaitBucket{}};

    fn get(address: usize) *WaitBucket {
        const index = blk: {
            const seed = @truncate(usize, 0x9E3779B97F4A7C15);
            const max = @popCount(usize, ~@as(usize, 0));
            const bits = @ctz(usize, array.len);
            break :blk (address *% seed) >> (max - bits);
        };

        {
            @setRuntimeSafety(false);
            if (index >= array.len)
                unreachable;
        }

        return &array[index];
    }
};

// TODO: use red-black-tree instead of linear scan
pub const WaitTree = struct {
    bucket: *WaitBucket,
    root: WaitRoot,

    pub fn acquire(address: usize) WaitTree {
        const bucket = WaitBucket.get(address);
        bucket.lock.acquire();
        return WaitTree{
            .bucket = bucket,
            .root = WaitRoot.unpack(bucket.root),
        };
    }

    pub fn release(self: WaitTree) void {
        self.bucket.root = self.root.pack();
        self.bucket.lock.release();
    }

    fn setRoot(self: *WaitTree, new_root: ?*WaitNode) void {
        if (new_root) |node| {
            defer self.root = WaitRoot{ .tree = node };
            return switch (self.root) {
                .prng => |prng| {
                    node.prng = prng;
                    node.times_out = nanotime() + node.genTimeout();
                },
                .tree => |old_root| {
                    if (old_root) |old| {
                        node.prng = old.prng;
                        node.times_out = old.times_out;
                    } else {
                        node.prng = @ptrToInt(node);
                        node.times_out = nanotime() + node.genTimeout();
                    }
                }
            };
        }

        self.root = WaitRoot{
            .prng = switch (self.root) {
                .prng => unreachable,
                .tree => |root| (root orelse unreachable).prng,
            },
        };
    }

    pub fn shouldBeFair(self: *WaitTree) bool {
        const root = switch (self.root) {
            .prng => return false,
            .tree => |root| root orelse return false,
        };

        const now = nanotime();
        if (now < root.times_out)
            return false;

        root.times_out = now + root.genTimeout();
        return true;
    }

    fn lookup(self: *WaitTree, address: usize, prev: *?*WaitNode) ?*WaitNode {
        var current = switch (self.root) {
            .prng => null,
            .tree => |root| root,
        };

        prev.* = null;
        while (current) |node| {
            if (node.address == address)
                return node;
            prev.* = node;
            current = node.root_next;
        }

        return null;
    }

    pub fn find(self: *WaitTree, address: usize) WaitList {
        return WaitList{
            .tree = self,
            .head = blk: {
                var prev: ?*WaitNode = undefined;
                break :blk self.lookup(address, &prev);
            },
        };
    }

    pub fn insert(self: *WaitTree, address: usize, node: *WaitNode) void {
        node.address = address;
        node.head = node;
        node.tail = node;
        node.next = null;
        node.prev = null;
        
        if (self.lookup(address, &node.root_prev)) |head| {
            const tail = head.tail orelse unreachable;
            node.head = head;
            node.prev = tail;
            tail.next = node;
            head.tail = node;
            return;
        }

        node.root_next = null;
        if (node.root_prev) |prev| {
            prev.root_next = node;
        } else {
            self.setRoot(node);
        }
    }

    pub fn remove(self: *WaitTree, node: *WaitNode) void {
        if (node.root_prev) |prev|
            prev.root_next = node.root_next;
        if (node.root_next) |next|
            next.root_prev = node.root_prev;
        if (node.root_prev == null) 
            self.setRoot(null);
    }
};

pub const WaitList = struct {
    tree: *WaitTree,
    head: ?*WaitNode,

    pub fn iter(self: *WaitList) WaitIter {
        return WaitIter{
            .list = self,
            .node = self.head,
        };
    }

    pub fn remove(self: *WaitList, node: *WaitNode) void {
        const head = self.head orelse return;
        defer node.tail = null;

        if (node.next) |next|
            next.prev = node.prev;
        if (node.prev) |prev|
            prev.next = node.next;

        if (node == head) {
            self.head = node.next;
        } else if (node == head.tail) {
            head.tail = node.prev;
        }

        if (self.head) |new_head| {
            new_tail.tail.head = new_head;
        } else {
            self.tree.remove(node);
        }
    }
};

pub const WaitIter = struct {
    list: *WaitList,
    node: ?*WaitNode,

    pub fn next(self: *WaitIter) ?WaitNodeRef {
        const node = self.node orelse return null;
        self.node = node.next;

        return WaitNodeRef{
            .iter = self,
            .node = node,
        };
    }
};

pub const WaitNodeRef = struct {
    iter: *WaitIter,
    node: *WaitNode,

    pub fn get(self: WaitNodeRef) *WaitNode {
        return self.node;
    }

    pub fn remove(self: WaitNodeRef) void {
        self.iter.list.remove(self.node);
    }
};

const WaitNode = struct {
    address: usize align(8),
    prng: usize,
    times_out: u64,
    root_prev: ?*WaitNode,
    root_next: ?*WaitNode,
    prev: ?*WaitNode,
    next: ?*WaitNode,
    tail: ?*WaitNode,
    head: *WaitNode,
    token: usize,
    wakeFn: fn(*WaitNode) void,

    fn genTimeout(self: WaitNode, now: u64) u32 {
        switch (@sizeOf(usize)) {
            8 => {
                var x = @truncate(u32, self.prng);
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                self.prng = x;
            },
            4 => {
                var x = @truncate(u16, self.prng);
                x ^= x << 7;
                x ^= x >> 9;
                x ^= x << 8;
                self.prng = x;
            },
            else => {
                @compileError("Architecture not supported for PRNG");
            }
        }

        const timeout_ns = 1_000_000;
        const timeout = self.prng % timeout_ns;
        return @truncate(u32, timeout);
    }
};

pub fn parkConditionally(
    comptime Event: type,
    address: usize,
    deadline: ?u64,
    context: anytype,
) bool {
    var tree = WaitTree.acquire(address);

    const token: usize = context.onValidate() orelse {
        tree.release();
        return true;
    };

    const Context = @TypeOf(context);
    const Waiter = struct {
        event: Event,
        node: WaitNode,

        fn wake(node: *WaitNode) void {
            const self = @fieldParentPtr(@This(), "node", node);
            self.event.notify();
        }
    };

    var waiter: Waiter = undefined;
    waiter.node.token = token;
    waiter.node.wakeFn = Waiter.wake;
    tree.insert(address, &waiter.node);

    waiter.event = Event{};
    var notified: bool = waiter.event.wait(deadline, struct {
        wait_tree: *WaitTree,
        ctx: Context,

        pub fn wait(self: @This()) bool {
            self.wait_tree.release();
            self.ctx.onBeforeWait();
            return true;
        }
    }{
        .wait_tree = &tree,
        .ctx = context, 
    });

    if (notified)
        return true;

    wait_tree = WaitTree.acquire(address);

    if (waiter.node.tail != null) {
        var wait_list = WaitList{
            .tree = &wait_tree,
            .head = waiter.node.head,
        };
        wait_list.remove(&waiter.node);
        context.onTimeout();
        wait_tree.release();
        return false;
    }

    notified = waiter.event.wait(null, struct {
        wait_tree: *WaitTree,

        pub fn wait(self: @This()) bool {
            self.wait_tree.release();
            return true;
        }
    }{
        .wait_tree = &tree,
    });

    if (!notified)
        unreachable;
    return true;
}

pub const UnparkFilter = enum {
    stop,
    skip,
    unpark,
};

pub fn unparkFilter(
    address: usize,
    context: anytype,
) void {
    var wait_tree = WaitTree.acquire(address);
    var wait_list = wait_tree.find(address);
    
    var wake_list: ?*WaitNode = null;
    var wait_iter = wait_list.iter();
    while (wait_iter.next()) |wait_node_ref| {

        const node = wait_node_ref.get();
        const result: UnparkFilter = context.onFilter(&node.token);
        switch (result) {
            .stop => break,
            .skip => continue,
            .unpark => {
                wait_node_ref.remove();
                node.next = wake_list;
                wake_list = node;
            }
        }
    }

    context.onBeforeWake();
    wait_tree.release();

    while (wake_list) |wake_node| {
        const node = wake_node;
        wake_list = node.next;
        (node.wakeFn)(node);
    }
}

pub const UnparkResult = struct {
    token: ?usize = null,
    be_fair: bool = false,
    has_more: bool = false,
};

pub fn unparkOne(
    address: usize,
    context: anytype,
) void {
    var wait_tree = WaitTree.acquire(address);
    var wait_list = wait_tree.find(address);
    var wait_iter = wait_list.iter();
    
    var result = UnparkResult{};

    var wait_node: ?*WaitNode = null;
    if (wait_iter.next()) |wait_node_ref| {
        wait_node = wait_node_ref.get();
        result.token = wait_node.token;
        result.be_fair = wait_list.shouldBeFair();
        wait_node_ref.remove();
        result.has_more = wait_list.head != null;
    }

    const token: usize = context.onUnpark(result);
    wait_tree.release();

    if (wait_node) |node| {
        node.token = token;
        (node.wakeFn)(node);
    }
}

pub fn unparkAll(
    address: usize,
) void {
    var wait_tree = WaitTree.acquire(address);
    var wait_list = wait_tree.find(address);
    var wait_iter = wait_list.iter();

    var wake_list: ?*WaitNode = null;
    while (wait_iter.next()) |wait_node_ref| {
        const node = wait_node_ref.get();
        wait_node_ref.remove();
        node.next = wake_list;
        wake_list = node;
    }

    wait_tree.release();

    while (wake_list) |wake_node| {
        const node = wake_node;
        wake_list = node.next;
        (node.wakeFn)(node);
    }
}
