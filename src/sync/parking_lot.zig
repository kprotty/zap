const zap = @import("../zap.zig");
const Lock = zap.runtime.Lock;

const WaitRoot = union(enum) {
    prng: usize,
    tree: ?*WaitNode,
};

const WaitBucket = struct {
    lock: Lock = Lock{},
    root: usize = 0,

    fn acquire(address: usize) *WaitBucket {

    }

    fn release(self: *WaitBucket, root: WaitRoot) void {

    }
};

const WaitTree = struct {
    bucket: *WaitBucket,
    root: WaitRoot,

    fn acquire(address: usize) WaitTree {

    }

    fn release(self: WaitTree) void {
        
    }

    fn find(self: *WaitTree, address: usize) WaitList {

    }

    fn insert(self: *WaitTree, address: usize, node: *WaitNode) void {

    }

    fn remove(self: *WaitTree, node: *WaitNode) void {

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
    wakeFn: fn(*WaitNode) void,
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
