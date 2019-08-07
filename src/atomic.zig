const std = @import("std");

fn isValidNode(comptime Node: type, comptime Field: []const u8) bool {
    const field = if (@hasField(Node, Field)) @typeOf(@field(Node(undefined), Field)) else return false;
    const ftype = if (@typeId(field) == .Optional) @typeInfo(field).Optional.child else return false;
    const ptype = if (@typeId(ftype) == .Pointer) @typeInfo(ftype).Pointer else return false;
    return ptype.size == .One and ptype.child == Node;
}

inline fn storeField(node: var, comptime Field: []const u8, value: ?*Node) void {
    // TODO: replace with atomicStore() https://github.com/ziglang/zig/issues/2995
    @ptrCast(*volatile ?@typeOf(node), &@field(node, Field)).* = value;
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
            storeField(node, Field, @atomicLoad(?*Node, &self.top, .Unordered));
            while (@cmpxchgWeak(?*Node, &self.top, @field(node, Field), node, .Monotonic, .Monotonic)) |new_top| {
                storeField(node, Field, new_top);
            }
        }

        pub fn pop(self: *Queue) ?*Node {
            var top = @atomicLoad(?*Node, &self.top, .Unordered);
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
            storeField(node, Field, null);
            const previous = @atomicRmw(*Node, &self.head, .Xchg, node, .Monotonic);
            storeField(previous, Field, node);
        }

        pub fn pop(self: *Queue) ?*Node {
            var tail = @atomicLoad(*Node, &self.tail, .Unordered);
            while (true) {
                const next = @atomicLoad(?*Node, &@field(tail, Field), .Unordered) orelse return null;
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