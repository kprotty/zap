const std = @import("std");
const List = std.TailQueue(anyframe);

var run_queue = List{};

pub fn run(frame: anyframe) !void {
    var frame_node = List.Node{ .data = frame };
    run_queue.append(&frame_node);

    while (run_queue.pop()) |node| {
        resume node.data;
    }
}

pub fn reschedule() void {
    suspend {
        var node = List.Node{ .data = @frame() };
        run_queue.append(&node);
    }
}

pub fn shutdown() void {}