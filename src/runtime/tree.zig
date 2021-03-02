// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

pub fn Tree(comptime Key: type) type {
    return struct {
        root: ?*Node = null,
        min: @TypeOf(min_init) = min_init,

        const Self = @This();
        const min_init = if (Key.is_heap) @as(?*Node, null) else {};

        pub const Node = struct {
            value: Key.Value,
            link: usize = 0,
            children: [2]?*Node = [_]?*Node{ null, null },

            const Color = enum(u1) {
                Red = 0,
                Black = 1,
            };

            fn getColor(self: Node) Color {
                return @intToEnum(Color, @truncate(u1, self.link));
            }

            fn setColor(self: *Node, color: Color) void {
                self.link = (self.link & ~@as(usize, 0b1)) | @enumToInt(color);
            }

            const Index = enum(u1) {
                Left = 0,
                Right = 1,
            };

            const Parent = struct {
                index: Index,
                node: *Node,
            };

            fn getParent(self: Node) ?Parent {
                if (self.link <= 0b11) 
                    return null;
                return Parent{
                    .index = @intToEnum(Index, @truncate(u1, self.link >> 1)),
                    .node = @intToPtr(?*Node, self.link & ~@as(usize, 0b11)),
                };
            }

            fn setParent(self: *Node, parent: ?Parent) void {
                comptime std.debug.assert(@alignOf(*Node) >= 4);
                self.link = (self.link & 1) | blk: {
                    const p = parent orelse break :blk 0;
                    break :blk @ptrToInt(p.node) | (@as(usize, @enumToInt(p.index)) << 1);
                };
            }
        };

        pub fn find(self: *Self, parent: ?*?*Node, value: Key.Value) ?*Node {
            var current = self.root;
            if (parent) |p|
                p.* = null;

            while (true) {
                const node = current orelse break;
                if (Key.isEqual(value, node.value))
                    break;

                const is_left = Key.isLessThan(value, node.value))
                current = node.children[@boolToInt(!is_left)];
                if (parent) |p|
                    p.* = node;
            }

            return current;
        }

        pub fn insert(self: *Self, parent: ?*Node, node: *Node, value: Key.Value) void {
            node.* = Node{ .value = value };

            if (parent) |p| {
                if (Key.isEqual(p.value, value)) {
                    self.replace(p, node);
                    return;
                } else {
                    const index = @boolToInt(!Key.isLessThan(value, p.value));
                    p.children[index] = node;
                    node.setParent(.{
                        .node = p,
                        .index = @intToEnum(Node.Index, index),
                    });
                }
            } else {
                self.root = node;
            }

            if (Key.is_heap) {
                if (self.min) |min_node| {
                    if (Key.isLessThan(node.value, min_node.value))
                        self.min = node;
                } else {
                    self.min = node;
                }
            }

            self.fixupInsert(node);
        }

        pub fn replace(self: *Self, node: *Node, new_node: ?*Node) void {
            if (new_node) |new|
                new.* = node.*;

            if (node.getParent()) |parent| {
                parent.node.children[@enumToInt(parent.index)] = new_node;
            } else {
                self.root = new_node;
            }

            for (node.children) |child_node, array_index| {
                const child = child_node orelse continue;
                child.setParent(blk: {
                    break :blk Node.Parent{
                        .index = @intToEnum(Node.Index, @truncate(u1, array_index)),
                        .node = new_node orelse break :blk null,
                    };
                }); 
            }
        }

        pub fn delete(self: *Self, node: *Node) void {
            self.replace(node, null);
            self.fixupDelete(node);
        }

        pub fn peekMin(self: *Self) ?*Node {
            return self.min;
        }

        pub fn popMin(self: *Self) ?*Node {
            const node = self.min orelse return null;
            self.delete(node);
            return node;
        }

        fn fixupInsert(self: *Self, inserted_node: *Node) void {
            var current = inserted_node;
            while (true) {
                var parent = current.getParent() orelse break;
                if (parent.node.getColor() != .Red)
                    break;

                var grand_parent = parent.node.getParent() orelse unreachable;
                const is_left = parent.node == grand_parent.node.children[0];
                const uncle = grand_parent.node.children[@boolToInt(is_left)] orelse unreachable;

                if (uncle.getColor() == .Red) {
                    uncle.setColor(.Black);
                    parent.node.setColor(.Black);
                    grand_parent.node.setColor(.Red);
                    current = grand_parent.node;
                } else if (current == parent.node.children[@boolToInt(is_left)]) {
                    current = parent.node;
                    self.rotate(current, !is_left);
                    parent = current.getParent() orelse unreachable;
                    grand_parent = parent.node.getParent() orelse unreachable;
                    parent.node.setColor(.Black);
                    grand_parent.node.setColor(.Red);
                    self.rotate(grand_parent.node, is_left);
                }
            }

            const root = self.root orelse unreachable;
            root.setColor(.Black);
        }

        fn fixupDelete(self: *Self, deleted_node: *Node) void {
            var current = deleted_node;
            while (true) {
                if (current == self.root)
                    break;
                if (current.getColor() == .Black)
                    break;

                var parent = current.getParent() orelse unreachable;
                const is_left = current == parent.node.children[0];

                var other = parent.node.children[@boolToInt(is_left)] orelse unreachable;
                if (other.getColor() == .Red) {
                    other.setColor(.Black);
                    parent.node.setColor(.Red);
                    self.rotate(parent.node, is_left);
                    other = parent.node.children[@boolToInt(is_left)] orelse unreachable;
                }

                var left = other.children[@boolToInt(!is_left)] orelse unreachable;
                var right = other.children[@boolToInt(is_left)] orelse unreachable;
                if (left.getColor() == .Black and right.getColor() == .Black) {
                    other.setColor(.Red);
                    parent = current.getParent() orelse unreachable;
                    current = parent.node;
                } else if (right.getColor() == .Black) {
                    left.setColor(.Black);
                    other.setColor(.Red);
                    self.rotate(other, !is_left);
                    other = parent.node.children[@boolToInt(is_left)] orelse unreachable;
                    parent = current.getParent() orelse unreachable;
                    right = parent.node.children[@boolToInt(is_left)] orelse unreachable;
                    other.setColor(right.getColor());
                    parent.node.setColor(.Black);
                    right = other.node.children[@boolToInt(is_left)] orelse unreachable;
                    right.setColor(.Black);
                    current = self.root orelse return;
                }
            }

            if (self.root) |root|
                root.setColor(.Black);
        }
    };
}
