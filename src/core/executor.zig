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
const scheduler = @import("./task.zig");

pub fn Executor(comptime Platform: type) type {
    return struct {
        pub const Task = extern struct {
            inner: scheduler.Task,

            pub const Callback = scheduler.Task.Callback;

            pub fn fromFrame(frame: anyframe) Task {
                return Task{ .inner = scheduler.Task.fromFrame(frame) };
            }

            pub fn fromCallback(callback: Callback) Task {
                return Task{ .inner = scheduler.Task.fromCallback(callback) };
            }

            pub const Batch = struct {
                inner: scheduler.Task.Batch = scheduler.Task.Batch{};

                pub fn isEmpty(self: Batch) bool {
                    return self.inner.isEmpty();
                }

                pub fn from(task: ?*Task) Batch {
                    return Batch{ .inner = scheduler.Task.Batch.from(&task.inner) };
                }

                pub fn push(self: *Batch, task: *Task) void {
                    return self.pushBack(task);
                }

                pub fn pushBack(self: *Batch, task: *Task) void {
                    return self.pushBackMany(from(task));
                }

                pub fn pushFront(self: *Batch, task: *Task) void {
                    return self.pushFrontMany(from(task));
                }

                pub fn pushBackMany(self: *Batch, other: Batch) void {
                    return self.inner.pushBackMany(other.inner);
                }

                pub fn pushFrontMany(self: *Batch, other: Batch) void {
                    return self.inner.pushFrontMany(other.inner);
                }

                pub fn pop(self: *Batch) ?*Task {
                    return self.popFront();
                }

                pub fn popFront(self: *Batch) ?*Task {
                    const inner = self.inner.popFront() orelse return null;
                    return @fieldParentPtr(Task, "inner", inner);
                }

                pub fn schedule(self: Batch) void {
                    @compileError("TODO");
                }
            };

            pub fn run(self: *Task, nodes: Node.Cluster, start_node: *Node) !void {
                
            }
        };

        pub const Thread = extern struct {

           
        };

        pub const Pool = extern struct {

        };

        pub const Node = extern struct {

        };
    };
}
