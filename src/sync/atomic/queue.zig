const std = @import("std");
const builtin = @import("builtin");

fn isNode(comptime T: type) bool {
    switch (@typeInfo(T)) {
        builtin.TypeId.Struct |s| => {
            inline for (s.fields) |field|
                if (std.mem.eql(u8, field.name, "next"))
                    if (@typeId(field.field_type) == builtin.TypeId.Pointer)
                        return true;
            return false;
        },
        else => return false,
    }
}

pub fn MPMC(comptime Node: type) type {
    std.debug.assert(isNode(Node));

    return struct {
        const Self = @This();
        head: *Node,
        tail: HazardPtr,

        pub fn init(self: *Self, stub: *Node) void {
            self.head = stub;
            self.tail.node = stub;
        }

        pub fn push(self: *Self, node: *Node) void {
            @fence(builtin.AtomicOrder.Release);
            const previous = @atomicRmw(
                *Node,
                &self.head,
                builtin.AtomicRmwOp.Xchg,
                node,
                builtin.AtomicOrder.Monotonic,
            );
            previous.next = node;
        }

        pub fn pop(self: *Self) ?*Node {
            var cmp: HazardPtr = self.tail;
            var xchg: HazardPtr = undefined;

            while (true) {
                const next = @atomicLoad(?*Node, &cmp.node, builtin.AtomicOrder.Unordered)
                    orelse return null;
                xchg.update(next, cmp);
                if (!self.tail.compare_and_swap(&cmp, xchg))
                    continue;
                @fence(builtin.AtomicOrder.Acquire);
                return next;
            }
        }

        const HazardPtr = switch (builtin.arch) {
            .x86_64 => struct {
                node: ?*Node,
                counter: usize,

                pub inline fn update(self: *HazardPtr, next: *Node, cmp: HazardPtr) void {
                    self.node = next;
                    self.counter = cmp.counter + 1;
                }

                const c = @cImport({ @cInclude("cmpxchg.c") });
                pub inline fn compare_and_swap(self: *HazardPtr, cmp: *HazardPtr, swap: HazardPtr) bool {
                    return c.cmpxchg(@ptrToInt(self), @ptrToInt(cmp), @ptrToInt(swap.node), swap.counter);
                }
            },
            else => struct {
                node: ?*Node,

                pub inline fn update(self: *HazardPtr, next: *Node, cmp: HazardPtr) void {
                    self.node = next;
                }

                pub inline fn compare_and_swap(self: *HazardPtr, cmp: *HazardPtr, swap: HazardPtr) bool {
                    const relaxed = builtin.AtomicOrder.Monotonic;
                    if (@cmpxchgWeak(*Node, &self.node, cmp.node, swap.node, relaxed, relaxed)) |node| {
                        cmp.* = node;
                        return false;
                    } else {
                        return true;
                    }
                }
            },
        };
    };
}