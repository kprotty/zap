// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

pub fn Treap(comptime Key: type) type {
    return struct {
        root: ?*Node = null,
        min: @TypeOf(min_init) = min_init,

        const Self = @This();
        const min_init = if (Key.use_min) @as(?*Node, null) else {};

        const Parent = struct {
            node: *Node,
            is_left: bool,

            fn pack(parent: ?Parent) usize {
                const self = parent orelse return 0;
                return @ptrToInt(self.node) | @as(usize, @boolToInt(self.is_left));
            }

            fn unpack(value: usize) ?Parent {
                return Parent{
                    .node = @intToPtr(?*Node, value & ~@as(usize, 0b1)) orelse return null,
                    .is_left = value & 1 != 0,
                };
            }
        };

        pub const Node = struct {
            key: Key,
            parent: usize,
            children: [2]?*Node,
        };

        pub const Lookup = struct {
            node: ?*Node,
            parent: ?Parent,
        };

        pub fn find(self: *Self, key: Key) Lookup {
            var lookup = Lookup{
                .node = self.root,
                .parent = null,
            };

            while (true) {
                const node = lookup.node orelse break;
                if (Key.isEqual(key, node.key))
                    break;

                const is_left = Key.isLessThan(key, node.key);
                lookup = Lookup{
                    .node = node.children[@boolToInt(!is_left)],
                    .parent = Parent{
                        .node = node,
                        .is_left = is_left,
                    },
                };
            }

            return lookup;
        }

        pub fn insert(self: *Self, lookup: Lookup, node: *Node, key: Key) void {
            node.* = Node{
                .key = key,
                .parent = Parent.pack(lookup.parent),
                .children = [2]?*Node{ null, null },
            };

            if (Key.use_min) {
                if (self.min) |min_node| {
                    if (Key.isLessThan(key, min_node.key)) {
                        self.min = node;
                    }
                } else {
                    self.min = node;
                }
            }

            if (lookup.parent) |parent| {
                parent.node.children[@boolToInt(!parent.is_left)] = node;
            } else {
                self.root = node;
            }

            self.fixupInsert(node);
        }

        pub fn remove(self: *Self, node: *Node) void {
            if (Key.use_min and self.min == node) {
                if (new_node) |new| {
                    self.min = new;
                } else {
                    self.min = self.findNextMin(node);
                }
            }

            self.fixupRemove(node);

            if (Parent.unpack(node.parent)) |parent| {
                parent.node.children[@boolToInt(!parent.is_left)] = new_node;
            } else {
                self.root = new_node;
            }
        }

        fn fixupInsert(self: *Self, node: *Node) void {
            while (true) {
                const parent = Parent.unpack(node.parent) orelse break;
                if (!Key.isMoreImportant(parent.node.key, node.key))
                    break;

                const children = &parent.node.children;
                std.debug.assert(node == children[0] or node == children[1]);
                self.rotate(parent.node, node == children[1]);
            }
        }

        fn fixupRemove(self: *Self, node: *Node) void {
            while (true) {
                if (node.children[0] == null and node.children[1] == null)
                    break;

                self.rotate(node, blk: {
                    const right = node.children[1] orelse break :blk false;
                    const left = node.children[0] orelse break :blk true;
                    break :blk !Key.isMoreImportant(left.key, right.key);
                });
            }
        }

        fn rotate(self: *Self, node: *Node, is_left: bool) void {
            std.debug.assert(self.root != null);
            std.debug.assert(node.children[@boolToInt(is_left)] != null);

            const parent = Parent.unpack(node.parent);
            const swap_node = node.children[@boolToInt(is_left)] orelse unreachable;
            const child_node = swap_node.children[@boolToInt(!is_left)];

            swap_node.children[@boolToInt(!is_left)] = node;
            node.parent = Parent.pack(Parent{
                .node = swap_node,
                .is_left = is_left,
            });

            node.children[@boolToInt(is_left)] = child_node;
            if (child_node) |child| {
                child.parent = Parent.pack(Parent{
                    .node = node,
                    .is_left = !is_left,
                });
            }

            swap_node.parent = parent;
            if (parent) |p| {
                const children = &p.node.children;
                std.debug.assert(node == children[0] or node == children[1]);
                children[@boolToInt(node == children[1])] = swap_node;
            } else {
                self.root = swap_node;
            }
        }

        pub fn replace(self: *Self, node: *Node, new_node: ?*Node) void {
            if (new_node) |new|
                new.* = node.*;

            if (Key.use_min and self.min == node) {
                if (new_node) |new| {
                    self.min = new;
                } else {
                    self.min = self.findNextMin(node);
                }
            }

            if (Parent.unpack(node.parent)) |parent| {
                parent.node.children[@boolToInt(!parent.is_left)] = new_node;
            } else {
                self.root = new_node;
            }

            for (node.children) |*child_node, index| {
                const child = child_node orelse continue;
                child.parent = Parent.pack(blk: {
                    break :blk Parent{
                        .node = new_node orelse break :blk null,
                        .is_left = index == 0,
                    };
                });
            }
        }

        fn findNextMin(self: *Self, node: *Node) ?*Node {
            std.debug.assert(self.min == node);
            std.debug.assert(node.children[0] == null);

            var next_min = blk: {
                if (node.children[1]) |right|
                    break :blk right;
                const parent = Parent.unpack(node.parent) orelse return null;
                std.debug.assert(node == parent.node.children[0]);
                break :blk parent.node.children[1] orelse parent.node;
            };

            while (next_min.children[0]) |left_node| {
                if (left_node == node)
                    break;
                next_min = left_node;
            }

            return next_min;
        }

        pub fn peekMin(self: *Self) ?*Node {
            if (!Key.use_min)
                @compileError("Treap not configured for priority operations");
            return self.min;
        }

        pub fn popMin(self: *Self) ?*Node {
            const node = self.peekMin() orelse return null;
            self.remove(node);
            return node;
        }
    };
}
