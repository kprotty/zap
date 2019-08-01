const builtin = @import("builtin");

pub const SharedQueue = struct {
    pub fn SingleConsumer(comptime Node: type) type {
        return struct {
            head: *Node,
            tail: *Node,

            pub fn init(self: *@This(), stub: *Node) void {
                self.head = stub;
                self.tail = stub;
            }

            pub fn push(self: *@This(), node: *Node) void {
                @fence(builtin.AtomicOrder.Release);
                const prev = @atomicRmw(Node, &self.head, builtin.AtomicRmwOp.Xchg, node, builtin.AtomicOrder.Monotonic);
                prev.next = node;
            }

            pub fn pop(self: *@This()) ?*Node {
                const next = @atomicLoad(?*Node, &self.tail.next, builtin.AtomicOrder.Unordered) orelse return null;
                self.tail = next;
                @fence(builtin.AtomicOrder.Acquire);
                return next;
            }
        };
    }

    pub fn MultiConsumer(comptime Node: type) type {
        return struct {
            head: *Node,
            tail: TailNode,

            pub fn init(self: *@This(), stub: *Node) void {
                self.head = stub;
                self.tail.node = stub;
            }

            pub fn push(self: *@This(), node: *Node) void {
                @fence(builtin.AtomicOrder.Release);
                const prev = @atomicRmw(Node, &self.head, builtin.AtomicRmwOp.Xchg, node, builtin.AtomicOrder.Monotonic);
                prev.next = node;
            }

            pub fn pop(self: *@This()) ?*Node {
                var cmp: TailNode = self.tail;
                var xchg: TailNode = undefined;

                while (true) {
                    const next = @atomicLoad(?*Node, cmp.node.linkPtr(), builtin.AtomicOrder.Unordered) orelse return null;
                    xchg.update(cmp, next);
                    if (@cmpxchgWeak(TailNode, &self.tail, cmp, xchg, builtin.AtomicOrder.Monotonic, builtin.AtomicOrder.Monotonic)) |value| {
                        cmp = value;
                        continue;
                    }
                    @fence(builtin.AtomicOrder.Acquire);
                    return next;                    
                }
            }

            const TailNode = struct {
                const is_x86 = builtin.arch == .x86_64 or builtin.arch == .i386;
                const Counter = if (is_x86) usize else void;

                node: *Node,
                counter: Counter,

                pub inline fn update(self: *TailNode, cmp: TailNode, next: *Node) void {
                    if (is_x86) self.counter = cmp.counter + 1;
                    self.node = next;
                }
            };
        };
    }
};