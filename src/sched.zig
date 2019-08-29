const std = @import("std");
const builtin = @import("builtin");

const Node = struct {
    workers: [],

    const Task = struct {
        link: ?*Task,
        frame: anyframe,

        pub fn reschedule(self: *@This()) void {
            if (Worker.current) |current_worker|
                current_worker.next_task = self;
        }
    };

    const Worker = struct {
        pub threadlocal var current: ?*Worker = null;

        next_task: ?*Task,
    };
};