const std = @import("std");
const builtin = @import("builtin");
const zuma = @import("../../zap.zig").zuma;
const zync = @import("../../zap.zig").zync;
const zell = @import("../../zap.zig").zell;

pub const Executor = struct {};

pub const Node = struct {};

pub const Worker = struct {};

pub const Thread = struct {};

pub const Task = struct {
    next: ?*@This() = null,
    frame: anyframe = undefined,

    pub fn withResult(comptime func: var, result: *?@typeOf(func).ReturnType, args: ...) void {
        result.* = null;
        const value = func(args);
        result.* = value;
    }

    pub const List = struct {
        size: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,

        pub fn push(self: *@This(), task: *Task) void {
            self.size += 1;
            task.next = null;
            if (self.tail) |tail|
                tail.next = task;
            self.tail = task;
            if (self.tail) |tail|
                self.head = tail;
        }

        pub fn iter(self: @This()) Iterator {
            return Iterator{ .current = self.head };
        }

        pub const Iterator = struct {
            current: ?*Task = null,

            pub fn next(self: *@This()) ?*Task {
                const task = self.current;
                if (self.current) |current_task|
                    self.current = current_task.next;
                return task;
            }
        };
    };
};
