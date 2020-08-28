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
const zap = @import("../../zap.zig");

pub fn OneShot(comptime T: type) type {
    return struct {
        const Self = @This();

        state: ?*Waiter = null,

        const Waiter = struct {
            task: zap.Task,
            value: ?T,
        };

        pub fn close(self: *Self) void {
            if (@atomicRmw(?*Waiter, &self.state, .Xchg, null, .Acquire)) |waiter| {
                waiter.value = null;
                waiter.task.schedule();
            }
        }

        pub fn put(self: *Self, value: T) error{Closed}!void {
            var waiter = Waiter{
                .task = zap.Task.init(@frame()),
                .value = value,
            };

            suspend {
                if (@cmpxchgStrong(
                    ?*Waiter,
                    &self.state,
                    null,
                    &waiter,
                    .Release,
                    .Acquire,
                )) |receiver_ptr| {
                    const receiver = receiver_ptr.?;
                    receiver.value = waiter.value;

                    const thread = zap.Task.getCurrentThread();
                    var batch = zap.Task.Batch.from(&waiter.task);

                    if (thread.scheduleNext(&receiver.task)) |old_next|
                        batch.pushFront(old_next);
                    thread.schedule(batch);
                }
            }

            if (waiter.value == null)
                return error.Closed;
        }

        pub fn get(self: *Self) error{Closed}!T {
            var waiter = Waiter{
                .task = zap.Task.init(@frame()),
                .value = undefined,
            };

            suspend {
                if (@cmpxchgStrong(
                    ?*Waiter,
                    &self.state,
                    null,
                    &waiter,
                    .Release,
                    .Acquire,
                )) |sender_ptr| {
                    const sender = sender_ptr.?;
                    waiter.value = sender.value;

                    var batch = zap.Task.Batch.from(&sender.task);
                    const thread = zap.Task.getCurrentThread();

                    if (thread.scheduleNext(&waiter.task)) |old_next|
                        batch.pushFront(old_next);
                    thread.schedule(batch);
                }
            }

            return waiter.value orelse error.Closed;
        }
    };
}