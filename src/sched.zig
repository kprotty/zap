const std = @import("std");
const builtin = @import("builtin");

const Node = struct {
    workers: [],

    const Task = struct {
        link: ?*Task,
        frame: anyframe,

        pub inline fn getCurrent() ?*Task {
            return (worker.current orelse return null).task;
        }
    };

    const Worker = struct {
        pub threadlocal var current: ?*Worker = null;

        task: *Task,
    };
};