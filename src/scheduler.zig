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
const system = @import("./system.zig");
const Runnable = @import("./task.zig").Task;

pub const Task = struct {
    runnable: Runnable,
    frame: anyframe,

    pub fn init(frame: anyframe) Task {
        return Task{
            .runnable = Runnable.init(Task.@"resume"),
            .frame = frame,
        };
    }

    fn @"resume"(
        noalias runnable: *Runnable,
        noalias inner_thread: *Runnable.Thread,
    ) callconv(.C) void {
        const task = @fieldParentPtr(Task, "runnable", runnable);
        const thread = @fieldParentPtr(Thread, "inner", inner_thread);

        resume task.frame;
    }

    pub const Batch = struct {
        inner: Runnable.Batch = Runnable.Batch{},

        pub fn from(task: *Task) Batch {
            return fromRunnable(&task.runnable);
        }

        pub fn fromRunnable(runnable: *Runnable) Batch {
            return Batch{ .inner = Runnable.Batch.from(runnable) };
        }

        pub fn push(noalias self: *Batch, noalias task: *Task) void {
            return self.pushRunnable(&task.runnable);
        }

        pub fn pushRunnable(noalias self: *Batch, noalias runnable: *Runnable) void {
            return self.pushBackRunnable(runnable);
        }

        pub fn pushBack(noalias self: *Batch, noalias task: *Task) void {
            return self.pushBackRunnable(&task.runnable);
        }

        pub fn pushFront(noalias self: *Batch, noalias task: *Task) void {
            return self.pushFrontRunnable(&task.runnable);
        }

        pub fn pushBackRunnable(noalias self: *Batch, noalias runnable: *Runnable) void {
            return self.pushBackMany(Batch.fromRunnable(runnable));
        }

        pub fn pushFrontRunnable(noalias self: *Batch, noalias runnable: *Runnable) void {
            return self.pushFrontMany(Batch.fromRunnable(runnable));
        }

        pub fn pushMany(noalias self: *Batch, batch: Batch) void {
            return self.pushBackMany(batch);
        }

        pub fn pushBackMany(noalias self: *Batch, batch: Batch) void {
            return self.inner.pushBackMany(batch.inner);
        }

        pub fn pushFrontMany(noalias self: *Batch, batch: Batch) void {
            return self.inner.pushFrontMany(batch.inner);
        }

        pub fn popFrontRunnable(noalias self: *Batch) ?*Runnable {
            return self.inner.popFront();
        }

        pub fn popFront(noalias self: *Batch) ?*Task {
            return @fieldParentPtr(Task, "runnable", self.popFrontRunnable() orelse return null);
        }

        pub fn popRunnable(noalias self: *Batch) ?*Runnable {
            return self.popFrontRunnable();
        }

        pub fn pop(noalias self: *Batch) ?*Task {
            return self.popFront();
        }
    };

    pub const Node = struct {
        core_pool: Pool,
        blocking_pool: Pool,
        numa_node: *system.NumaNode,

        const Pool = struct {
            inner: Runnable.Pool,
            stack_size: u32,

            fn isBlocking(self: Pool) bool {
                return (self.stack_size & 1) != 0;
            }
        };

        pub const Worker = Runnable.Worker;

        pub const Config = struct {
            workers: []Worker,
            stack_size: u32,
        };

        pub fn init(
            noalias self: *Node,
            noalias numa_node: *system.NumaNode,
            core_config: Config,
            blocking_config: Config,
        ) void {

        }
    };

    

    pub const Thread = struct {
        inner: Runnable.Thread,
        event: system.Event,

        threadlocal current: ?*Thread = null;

        fn getCurrent() *Thread {
            return current orelse {
                std.debug.panic("Thread.getCurrent() called when not running in Task.Thread", .{});
            };
        }

        fn run()
    };

    pub fn yield() void {
        @panic("TODO");
    }

    pub fn schedule(self: *Task) void {
        return Batch.from(self).schedule();
    }

    pub fn scheduleNext(self: *Task) void {
        @panic("TODO");
    }

    pub const RunConfig = union {
        smp: Smp,
        numa: Numa,

        pub const Smp = struct {
            core_config: Config,
            blocking_config: Config,

            pub const Config = struct {
                max_threads: u32,
                stack_size: u32,
            };
        };

        pub const Numa = struct {
            cluster: Node.Cluster,
            start_index: usize,
        };

        pub fn default() RunConfig {
            return RunConfig{
                .smp = Smp{
                    .core_config = Smp.Config{
                        .max_threads = std.math.maxInt(u32),
                        .stack_size = 1 * 1024 * 1024,
                    },
                    .blocking_config = Smp.Config{
                        .max_threads = 64,
                        .stack_size = 128 * 1024,
                    },
                },
            };
        }
    };

    pub fn runAsync(comptime func: anytype, func_args: anytype) !@TypeOf(func).ReturnType {
        return runAsyncWithConfig(RunConfig.default(), func, func_args);
    }

    pub fn runAsyncWithConfig(config: RunConfig, comptime func: anytype, func_args: anytype) !@TypeOf(func).ReturnType {
        const Args = @TypeOf(func_args);
        const ReturnType = @TypeOf(func).ReturnType;

        const Wrapper = struct {
            fn entry(args: Args, task_ptr: *Task, result_ptr: *?ReturnType) void {
                suspend task_ptr.* = Task.init(@frame());
                const result = @call(.{}, func, args);
                suspend result_ptr.* = result;
            }
        };

        var task: Task = undefined;
        var result: ?ReturnType = null;
        var frame = async Wrapper.entry(func_args, &task, &result);

        try runWithConfig(config, &task.runnable);

        return result orelse error.AsyncDidNotComplete;
    }

    pub fn run(runnable: *Runnable) !void {
        return runWithConfig(RunConfig.default(), runnable);
    }

    pub fn runWithConfig(config: RunConfig, runnable: *Runnable) !void {
        // Run the scheduler using the Numa config if it has one.
        // If not, then create one using the smp config.
        const smp = switch (config) {
            .smp => |smp_config| smp_config,
            .numa => |numa_config| return runNuma(numa_config, runnable);
        };

        // prepare a cluster that will hold all the allocated Nodes.
        // at the end (regardless of error), free all the existing nodes in the cluster
        var cluster = Node.Cluster{};
        defer {
            while (cluster.pop()) |node| {
                var bytes = std.mem.alignForward(@sizeOf(Node), @alignOf(Node.Worker));
                bytes += node.core_pool.inner.getWorkers().len * @sizeOf(Node.Worker);
                bytes += node.blocking_pool.inner.getWorkers().len * @sizeOf(Node.Worker);

                const memory = @ptrCast([*]align(std.mem.page_size) u8, @alignCast(std.mem.page_size, &node))[0..bytes];
                node.numa_node.free(memory);
            }
        }

        var num_nodes: usize = 0;
        var remaining_core_threads = smp.core_config.max_threads;
        var remaining_blocking_threads = smp.blocking_config.max_threads;

        const topology = system.NumaNode.getTopology();
        std.debug.assert(topology.len > 0);

        for (topology) |*numa_node, index| {
            // stop creating nodes if there are no more threads to assign to them
            if ((remaining_core_threads == 0) or (remaining_blocking_threads == 0))
                break;

            // use a custom method to handle single threaded execution
            const node_core_threads = (numa_node.cpu_end + 1) - numa_node.cpu_begin;
            if (std.builtin.single_threaded or ((index == 0) and (node_core_threads == 1)))
                return runSerial(runnable);

            // compute the amount of core threads for this Node
            const core_threads = std.math.min(node_core_threads, remaining_core_threads);
            remaining_core_threads -= core_threads;

            // compute the amount of blocking threads for this Node
            const node_blocking_threads = smp.core_config.max_threads / topology.len'
            const blocking_threads = std.math.min(node_blocking_threads, remaining_blocking_threads);
            remaining_blocking_threads -= blocking_threads;

            // allocate all the necessary memory for the Node using the system.NumaNode.
            const worker_offset = std.mem.alignForward(@sizeOf(Node), @alignOf(Node.Worker));
            const bytes = worker_offset + ((core_threads + blocking_threads) * @sizeOf(Node.Worker));
            const memory = try numa_node.alloc(bytes);

            // initialize the Node and push it to the cluster
            const node = @ptrCast(*Node, @alignCast(@alignOf(Node), &memory[0]));
            const workers = @ptrCast([*]Node.Worker, @alignCast(@alignOf(Node.Worker), &memory[worker_offset]));
            defer cluster.push(node);
            node.init(
                numa_node,
                Node.Config{
                    .workers = workers[0..core_threads],
                    .stack_size = smp.core_config.stack_size,
                },
                Node.Config{
                    .workers = workers[core_threads..(core_threads + blocking_threads)],
                    .stack_size = smp.blocking_config.stack_size,
                },
            );
        }

        var rand = std.rand.DefaultPrng.init(system.nanotime());
        var start_index = rand.random.int(usize, num_nodes); 

        return runNuma(RunConfig.Numa{
            .cluster = cluster,
            .start_index = start_index,
        }, runnable);
    }

    fn runNuma(numa_config: RunConfig.Numa, runnable: *Runnable) void  {
        // discover the starting Node using the start_index
        const start_node = blk: {
            var node_index: usize = 0;
            var node_iter = numa_config.cluster.node_iter();
            while (node_iter.next()) |node| {
                if (node_index == numa_config.start_index)
                    break :blk node;
                node_index += 1;
            }
            return;
        };
        
        
    }
};