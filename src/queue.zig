const std = @import("std");
const builtin = @import("builtin");

const Xchg = builtin.AtomicRmwOp.Xchg;
const Acquire = builtin.AtomicOrder.Acquire;
const Release = builtin.AtomicOrder.Release;
const Unordered = builtin.AtomicOrder.Unordered;
const Monotonic = builtin.AtomicOrder.Monotonic;

pub fn Mpsc(comptime linkField: []const u8, comptime Node: type) type {
    comptime std.debug.assert(isNode(Node));
    return struct {
        head: *Node,
        tail: *Node,

        pub fn init(self: *@This(), stub: *Node) void {
            self.head = stub;
            self.tail = stub;
        }

        pub fn push(self: *@This(), node: *Node) void {
            @fence(Release);
            const previous = @atomicRmw(Node, &self.head, Xchg, node, Monotonic);
            @field(previous, linkField).* = node;
        }

        pub fn pop(self: *@This()) ?*Node {
            const node = @field(self.tail, linkField);
            const next = @atomicLoad(?*Node, node, Unordered) orelse return null;
            self.tail = next;
            @fence(Acquire);
            return next;
        }
    };
}

pub fn Mpmc(comptime linkField: []const u8, comptime Node: type) type {
    comptime std.debug.assert(isNode(Node));
    return struct {
        head: *Node,
        tail: TailNode,

        pub fn init(self: *@This(), stub: *Node) void {
            self.head = stub;
            self.tail.node = stub;
        }

        pub fn push(self: *@This(), node: *Node) void {
            @fence(Release);
            const previous = @atomicRmw(Node, &self.head, Xchg, node, Monotonic);
            @field(previous, linkField).* = node;
        }

        pub fn pop(self: *@This()) ?*Node {
            var cmp: TailNode = self.tail;
            var xchg: TailNode = undefined;

            while (true) {
                const node = @field(cmp.node, linkField);
                const next = @atomicLoad(?*Node, node, Unordered) orelse return null;
                xchg.update(cmp, next);
                if (@cmpxchgWeak(TailNode, &self.tail, cmp, xchg, Monotonic, Monotonic)) |value| {
                    cmp = value;
                    continue;
                }
                @fence(Acquire);
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