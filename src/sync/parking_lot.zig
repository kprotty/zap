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

const WaitTree = struct {
    bucket: *WaitBucket,
    root: WaitRoot,

    fn acquire(address: usize) WaitTree {
        const bucket = WaitBucket.get(address);
        bucket.lock.acquire();
        return WaitTree{
            .bucket = bucket,
            .root = WaitRoot.unpack(bucket.root),
        };
    }

    fn release(self: WaitTree) void {
        self.bucket.root = self.root.pack();
        self.bucket.lock.release();
    }

    fn lookup(self: *WaitTree, address: usize, parent: *?*WaitNode, is_left: *bool) ?*WaitNode {
        const root = switch (self.root) {
            .prng => @as(?*WaitNode, null),
            .tree => |root| root,
        };
        
        parent.* = root;
        is_left.* = false;
        var node = root;

        while (node) |current| {
            if (current.address == address)
                return current;

            parent.* = current;
            is_left.* = current.address > address;
            node = current.children[@boolToInt(!is_left.*)];
        }

        return null;
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

    fn rotate(self: *WaitTree, node: *WaitNode, is_left: bool) {
        const next = node.children[@boolToInt(!is_left)] orelse unreachable;

        if (node.getParent()) |parent| {
            parent.children[@boolToInt(parent.children[0] != node)] = next;
            next.setParent(parent);
        } else {
            self.setRoot(next);
            next.setParent(null);
        }

        node.setParent(next);
        const update = next.children[@boolToInt(is_left)];
        node.children[@boolToInt(!is_left)] = update;
        if (update) |updated|
            updated.setParent(node);
        next.children[@boolToInt(is_left)] = node;
    }

    fn find(self: *WaitTree, address: usize) WaitList {
        var is_left: bool = undefined;
        var parent: ?*WaitNode = undefined;

        return WaitList{
            .tree = self,
            .head = self.lookup(address, &parent, &is_left),
        };
    }

    fn insert(self: *WaitTree, address: usize, node: *WaitNode) void {
        @setRuntimeSafety(false);

        node.address = address;
        node.next = null;
        node.tail = node;

        {
            var is_left: bool = undefined;
            var parent: ?*WaitNode = undefined;
            if (self.lookup(address, &parent, &is_left)) |head| {
                node.prev = head.tail;
                head.tail.next = node;
                head.tail = node;
                return;
            }

            node.prev = null;
            node.setColor(.red);
            node.setParent(parent);
            node.children = [_]?*WaitNode{null, null};
            
            if (parent) |p| {
                p.children[@boolToInt(!is_left)] = node;
            } else {
                self.setRoot(node);
            }
        }

        var current = node;
        while (current.getParent()) |p| {
            var parent = p;
            if (parent.getColor() == .black)
                break;
            
            const grand_parent = parent.getParent() orelse unreachable;
            const is_left = grand_parent.children[0] == parent;

            if (grand_parent.children[@boolToInt(is_left)]) |uncle| {
                if (uncle.getColor() == .black)
                    break;
                parent.setColor(.black);
                uncle.setColor(.black);
                grand_parent.setColor(.red);
                current = grand_parent;
            } else {
                if (current == parent.children[@boolToInt(is_left)]) {
                    self.rotate(parent, is_left);
                    current = parent;
                    parent = current.getParent() orelse unreachable;
                }
                parent.setColor(.black);
                grand_parent.setColor(.red);
                self.rotate(grand_parent, !is_left);
            }
        }

        switch (self.root) {
            .prng => unreachable,
            .tree => |root_node| {
                const root = root_node orelse unreachable;
                root.setColor(.black);
            },
        }
    }

    fn remove(self: *WaitTree, node: *WaitNode) void {
        @setRuntimeSafety(false);

        var new_node: ?*WaitNode = node;
        var color: Color = undefined;
        var new_parent: ?*WaitNode = node.getParent();

        if (node.children[0] == null and node.children[1] == null) {
            if (new_parent) |parent| {
                parent.children[@boolToInt(parent.children[0] != node)] = null;
            } else {
                self.setRoot(null);
            }
            color = node.getColor();
            new_node = null;
        } else {
            var next: *WaitNode = undefined;
            if (node.children[0] == null) {
                next = node.children[1] orelse unreachable;
            } else if (node.children[1] == null) {
                next = node.children[0] orelse unreachable;
            } else {
                next = blk: {
                    var current = node.children[1] orelse unreachable;
                    while (current.children[0]) |left|
                        current = left;
                    break :blk current;
                };
            }

            if (new_parent) |parent| {
                parent.children[@boolToInt(parent.children[0] != node)] = next;
            } else {
                self.setRoot(null);
            }

            if (node.children[0] != null and node.children[1] != null) {
                const left =  orelse unreachable;
                const right = node.children[1] orelse unreachable;

                color = next.getColor();
                next.setColor(node.getColor());
                next.children[0] = left;
                left.setParent(next);

                if (next != right) {
                    const parent = next.getParent() orelse unreachable;
                    next.setParent(node.getParent());
                    new_node = next.children[1];
                    parent.children[0] = node;
                    next.children[1] = right;
                    right.setParent(next);
                } else {
                    next.setParent(new_parent);
                    new_parent = next;
                    new_node = next.children[1];
                }
            } else {
                color = node.getColor();
                new_node = next;
            }
        }

        if (new_node) |n|
            n.setParent(new_parent);
        if (color == .red)
            return;
        
        @compileError("TODO")
    }
};

const WaitList = struct {
    tree: *WaitTree,
    head: ?*WaitNode,

    fn remove(self: *WaitList, node: *WaitNode) void {


        if (self.head == null)  
            self.tree.remove(node);
    }
};

const WaitIter = struct {
    list: *WaitList,
    node: *WaitNode,

    fn next(self: *WaitIter) WaitNodeRef {

    }
};

const WaitNodeRef = struct {
    iter: *WaitIter,
    node: *WaitNode,

    fn remove(self: WaitNodeRef) void {
        self.iter.list.remove(self.node);
    }
};

const WaitNode = struct {
    address: usize align(8),
    token: usize,
    prng: usize,
    times_out: u64,
    prev: ?*WaitNode,
    next: ?*WaitNode,
    tail: *allowzero WaitNode,
    parent_color: usize,
    children: [2]?*WaitNode,
    wakeFn: fn(*WaitNode) void,

    const Color = enum {
        red,
        black,
    };

    fn getColor(self: WaitNode) Color {
        return @intToEnum(Color, @truncate(u1, self.parent_color));
    }

    fn setColor(self: *WaitNode, color: Color) void {
        self.parent_color &= ~@as(usize, 1);
        self.parent_color |= @enumToInt(color);
    }

    fn getParent(self: WaitNode) ?*WaitNode {
        @setRuntimeSafety(false);
        const ptr = self.parent_color & ~@as(usize, 1);
        return @intToPtr(?*WaitNode, ptr);
    }

    fn setParent(self: *WaitNode, parent: ?*WaitNode) void {
        self.parent_color &= @as(usize, 1);
        self.parent_color |= @ptrToInt(parent);
    }

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

}

pub fn unparkFilter(
    address: usize,
    context: anytype,
) void {

}

pub fn unparkOne(
    address: usize,
    context: anytype,
) void  {

}

pub fn unparkAll(
    address: usize,
) void {

}
