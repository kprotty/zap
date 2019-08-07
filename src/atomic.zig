const std = @import("std");
const builtin = @import("builtin");

/// TODO: replace with atomicStore() https://github.com/ziglang/zig/issues/2995
pub inline fn store(comptime T: type, ptr: *T, value: T, order: builtin.AtomicOrder) void {
    @ptrCast(*volatile T, ptr).* = value;
}

fn isValidNode(comptime Node: type, comptime Field: []const u8) bool {
    const field = if (@hasField(Node, Field)) @typeOf(@field(Node(undefined), Field)) else return false;
    const ftype = if (@typeId(field) == .Optional) @typeInfo(field).Optional.child else return false;
    const ptype = if (@typeId(ftype) == .Pointer) @typeInfo(ftype).Pointer else return false;
    return ptype.size == .One and ptype.child == Node;
}

pub fn Stack(comptime Node: type, comptime Field: []const u8) type {
    comptime std.debug.assert(isValidNode(Node, Field));
    return struct {
        top: ?*Node,

        pub fn init() void {
            self.top = null;
        }

        pub fn push(self: *Queue, node: *Node) void {
            @fence(.Release);
            store(?*Node, &@field(node, Field), @atomicLoad(?*Node, &self.top, .Monotonic), .Monotonic);
            while (@cmpxchgWeak(?*Node, &self.top, @field(node, Field), node, .Monotonic, .Monotonic)) |new_top| {
                store(?*Node, &@field(node, Field), new_top, .Monotonic);
            }
        }

        pub fn pop(self: *Queue) ?*Node {
            var top = @atomicLoad(?*Node, &self.top, .Monotonic);
            while (top) |node| {
                top = @cmpxchgWeak(?*Node, &self.top, top, @field(node, Field), .Monotonic, .Monotonic) 
                    orelse return node;
            }
            @fence(.Acquire);
            return null;
        }
    };
}

pub fn Queue(comptime Node: type, comptime Field: []const u8) type {
    comptime std.debug.assert(isValidNode(Node, Field));
    return struct {
        head: *Node,
        tail: *Node,
        stub: ?*Node,

        pub fn init(self: *Queue) void {
            self.head = @fieldParentPtr(Node, Field, &self.stub);
            self.tail = self.head;
            self.stub = null;
        }

        pub fn push(self: *Queue, node: *Node) void {
            @fence(.Release);
            store(?*Node, &@field(node, Field), null, .Monotonic);
            const previous = @atomicRmw(*Node, &self.head, .Xchg, node, .Monotonic);
            store(?*Node, &@field(previous, Field), node, .Monotonic);
        }

        pub fn pop(self: *Queue) ?*Node {
            var tail = @atomicLoad(*Node, &self.tail, .Monotonic);
            while (true) {
                const next = @atomicLoad(?*Node, &@field(tail, Field), .Monotonic) orelse return null;
                if (@cmpxchgWeak(*Node, &self.tail, tail, next, .Monotonic, .Monotonic)) |new_tail| {
                    tail = new_tail;
                    continue;
                }
                @fence(.Acquire);
                return next;
            }
        }
    };
}