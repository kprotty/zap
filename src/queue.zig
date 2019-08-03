const std = @import("std");
const builtin = @import("builtin");

const Xchg = builtin.AtomicRmwOp.Xchg;
const Acquire = builtin.AtomicOrder.Acquire;
const Release = builtin.AtomicOrder.Release;
const Unordered = builtin.AtomicOrder.Unordered;
const Monotonic = builtin.AtomicOrder.Monotonic;

fn isNode(comptime Node: type, comptime linkField: []const u8) bool {
    const field = if (@hasField(Node, linkField)) @typeOf(@field(Node(undefined), linkField)) else return false;
    const ftype = if (@typeId(field) == .Optional) @typeInfo(field).Optional.child else return false;
    const ptype = if (@typeId(ftype) == .Pointer) @typeInfo(ftype).Pointer else return false;
    return ptype.size == .One and ptype.child == Node;
}

pub fn Mpsc(comptime Node: type, comptime linkField: []const u8) type {
    comptime std.debug.assert(isNode(Node, linkField));
    return struct {
        head: *Node,
        tail: *Node,

        pub fn init(self: *@This(), stub: *Node) void {
            self.head = stub;
            self.tail = stub;
            @field(stub, linkField) = null;
        }

        pub fn push(self: *@This(), node: *Node) void {
            @fence(Release);
            const previous = @atomicRmw(*Node, &self.head, Xchg, node, Monotonic);
            @field(previous, linkField) = node;
        }

        pub fn pop(self: *@This()) ?*Node {
            const node = &@field(self.tail, linkField);
            const next = @atomicLoad(?*Node, node, Unordered) orelse return null;
            self.tail = next;
            @fence(Acquire);
            return next;
        }
    };
}

pub fn Mpmc(comptime Node: type, comptime linkField: []const u8) type {
    comptime std.debug.assert(isNode(Node, linkField));
    return struct {
        head: *Node,
        tail: TailNode,

        pub fn init(self: *@This(), stub: *Node) void {
            self.head = stub;
            self.tail.data.node = stub;
            @field(stub, linkField) = null;
        }

        pub fn push(self: *@This(), node: *Node) void {
            @fence(Release);
            const previous = @atomicRmw(*Node, &self.head, Xchg, node, Monotonic);
            @field(previous, linkField) = node;
        }

        pub fn pop(self: *@This()) ?*Node {
            var cmp: TailNode = self.tail;
            var xchg: TailNode = undefined;

            while (true) {
                const node = &@field(cmp.data.node, linkField);
                const next = @atomicLoad(?*Node, node, Unordered) orelse return null;
                xchg.update(cmp, next);
                if (!self.tail.cas(&cmp, xchg))
                    continue;
                @fence(Acquire);
                return next;                    
            }
        }

        const TailNode = extern union {
            raw: IntType,
            data: NodeData,

            const IntType = @IntType(false, @truncate(u16, @sizeOf(NodeData) * 8));
            const is_x86 = builtin.arch == .x86_64 or builtin.arch == .i386;
            const Counter = if (is_x86) usize else void;

            const NodeData = struct {
                node: *Node,
                counter: Counter,
            };

            pub inline fn update(self: *TailNode, cmp: TailNode, next: *Node) void {
                if (is_x86) self.data.counter = cmp.data.counter + 1;
                self.data.node = next;
            }

            pub inline fn cas(self: *TailNode, cmp: *TailNode, xchg: TailNode) bool {
                if (@cmpxchgWeak(IntType, &self.raw, cmp.raw, xchg.raw, Monotonic, Monotonic)) |new_value| {
                    cmp.raw = new_value;
                    return false;
                } else {
                    return true;
                }
            }
        };
    };
}

const TestNode = struct {
    next: ?*TestNode,
    value: u32,
};

test "multi-producer single-consumer" {
    var stub = TestNode { .next = null, .value = 0 };
    var node1 = TestNode { .next = null, .value = 1 };
    var node2 = TestNode { .next = null, .value = 2 };
    var node3 = TestNode { .next = null, .value = 3 };

    var queue: Mpsc(TestNode, "next") = undefined;
    queue.init(&stub);
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    std.debug.assert(queue.pop().?.value == node1.value);
    std.debug.assert(queue.pop().?.value == node2.value);
    std.debug.assert(queue.pop().?.value == node3.value);
    std.debug.assert(queue.pop() == null);
}

test "multi-producer multi-consumer" {
    var stub = TestNode { .next = null, .value = 0 };
    var node1 = TestNode { .next = null, .value = 1 };
    var node2 = TestNode { .next = null, .value = 2 };
    var node3 = TestNode { .next = null, .value = 3 };

    var queue: Mpmc(TestNode, "next") = undefined;
    queue.init(&stub);
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    std.debug.assert(queue.pop().?.value == node1.value);
    std.debug.assert(queue.pop().?.value == node2.value);
    std.debug.assert(queue.pop().?.value == node3.value);
    std.debug.assert(queue.pop() == null);
}