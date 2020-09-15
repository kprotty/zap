// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const zap = @import("../zap.zig");

pub const Config = union(enum) {
    smp: Smp,
    numa: Numa,

    const Smp = struct {
        blocking_threads: usize = 16,
        task_threads: usize = 0,
        stack_size: usize = 0,
    };

    const Numa = struct {
        cluster: Node.Cluster,
        start_node: *Node,
    };

    pub fn default() Config {
        return Config{ .smp = .{} };
    }

    fn ReturnTypeOf(comptime function: anytype) type {
        return @typeInfo(@TypeOf(function)).Fn.ReturnType;
    }

    pub fn runAsync(
        self: Config,
        comptime asyncFn: anytype,
        args: anytype,
    ) !ReturnTypeOf(asyncFn) {
        const Arguments = @TypeOf(args);
        const ReturnType = ReturnTypeOf(asyncFn);
        const Wrapper = struct {
            fn entry(
                fn_args: Arguments,
                task_ptr: *Task,
                result_ptr: *?ReturnType,
            ) void {
                suspend task_ptr.* = Task.init(@frame());
                const result = @call(.{}, asyncFn, fn_args);
                suspend result_ptr.* = result;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(args, &task, &result);

        try run(self, &task);

        return result orelse error.DeadLocked;
    }

    pub fn run(self: Config, task: *Task) !void {
        switch (self) {
            .numa => |numa_config| {
                return runNuma(task, numa_config);
            },
            .smp => |smp_config| {
                const topology = platform.Node.getTopology();

                if (std.builtin.single_threaded) {
                    var node: Node = undefined;
                    var workers: [1]Worker = undefined;
                    try node.init(workers[0..], 1, &topology[0]);
                    return runNuma(task, RunConfig.Numa{
                        .cluster = Node.Cluster.from(&node),
                        .start_index = 0,
                    });
                }

                var cluster = Node.Cluster{};
                defer while (cluster.pop()) |node| {
                    var bytes = std.mem.alignForward(@sizeOf(Node), @alignOf(Worker));
                    bytes += node.workers_len * @sizeOf(Worker);
                    const ptr = @ptrCast([*]align(std.mem.page_size) u8, @alignCast(std.mem.page_size, node));
                    node.numa_node.unmap(ptr[0..bytes]);
                };

                var num_blocking_threads = smp_config.blocking.threads;
                if (num_blocking_threads == 0)
                    num_blocking_threads = 64;

                var num_non_blocking_threads = smp_config.non_blocking.threads;
                if (num_non_blocking_threads == 0) {
                    for (topology) |numa_node|
                        num_non_blocking_threads += numa_node.getAffinitySize();
                }

                var num_nodes: u32 = 0;
                var remaining_blocking = num_blocking_threads;
                var remaining_non_blocking = num_non_blocking_threads;

                for (topology) |*numa_node, index| {
                    var blocking: u32 = undefined;
                    var non_blocking: u32 = undefined;
                    if (remaining_blocking == 0 or remaining_non_blocking == 0)
                        break;

                    if (index == topology.len - 1) {
                        blocking = remaining_blocking;
                        non_blocking = remaining_non_blocking;
                    } else {
                        blocking = std.math.min(num_blocking_threads / topology.len, remaining_blocking);
                        non_blocking = std.math.min(num_non_blocking_threads / topology.len, remaining_non_blocking);
                        remaining_blocking -= blocking;
                        remaining_non_blocking -= non_blocking;
                    }

                    const num_workers = blocking + non_blocking;
                    const worker_offset = std.mem.alignForward(@sizeOf(Node), @alignOf(Worker));
                    const bytes = worker_offset + (num_workers * @sizeOf(Worker));

                    const memory = try numa_node.map(bytes);
                    const node = @ptrCast(*Node, @alignCast(@alignOf(Node), &memory[0]));
                    const workers = @ptrCast([*]Worker, @alignCast(@alignOf(Worker), &memory[worker_offset]));

                    node.setup(workers[0..num_workers], non_blocking, numa_node);
                    cluster.push(node);
                    num_nodes += 1;
                }

                return runNuma(task, Config.Numa{
                    .cluster = cluster,
                    .start_node = start_node,
                });
            },
        }
    }

    fn runNuma(task: *Task, numa_config: RunConfig.Numa) !void {
        
    }
};


