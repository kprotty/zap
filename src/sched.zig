const std = @import("std");
const builtin = @import("builtin");

const Node = struct {
    workers: [],

    const Task = struct {
        link: ?*Task,
        frame: anyframe,

        pub fn reschedule(self: *@This()) void {
            if (Worker.current) |current_worker|
                current_worker.run_queue.push(self);
        }
    };

    const Worker = struct {
        pub threadlocal var current: ?*Worker = null;

        task: *Task,
    };
};