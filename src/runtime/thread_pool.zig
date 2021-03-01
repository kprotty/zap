// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const atomic = @import("../sync/atomic.zig");
const Lock = @import("./lock.zig").Lock;
const Event = @import("./event.zig").Event;

pub const ThreadPool = struct {
    counter: usize,
    max_workers: usize,
    pending_events: usize,
    idle_lock: Lock,
    idle_stack: ?*Worker,

    // beginEvent()
    // completeEvent()
    // tryPollEvents()

    const Self = @This();
    const Counter = struct {
        state: State = .Pending,
        is_polling: bool = false,
        is_notified: bool = false,
        idle: usize = 0,
        spawned: usize = 0,

        const count_bits = @divFloor(std.meta.bitCount(usize) - 4, 2);
        const Count = std.meta.Int(.unsigned, count_bits);
        const State = enum(u2) {
            Pending = 0,
            Waking,
            Signaled,
            Shutdown,
        };

        fn pack(self: Counter) usize {
            return (
                (@as(usize, @enumToInt(self.state)) << 0) |
                (@as(usize, @boolToInt(self.is_polling)) << 2) |
                (@as(usize, @boolToInt(self.is_notified)) << 3) |
                (@as(usize, @intCast(Count, self.idle)) << 4) |
                (@as(usize, @intCast(Count, self.spawned)) << (4 + count_bits))
            );
        }

        fn unpack(value: usize) Counter {
            return .{
                .state = @intToEnum(State, @truncate(u2, value)),
                .is_polling = value & (1 << 2) != 0,
                .is_notified = value & (1 << 3) != 0,
                .idle = @truncate(Count, value >> 4),
                .spawned = @truncate(Count, value >> (4 + count_bits)),
            };
        }
    };

    pub fn init(max_workers: usize) Self {
        return .{
            .counter = (Counter{}).pack(),
            .max_workers = blk: {
                const num_workers = std.math.max(1, max_workers);
                const max_workers = std.math.cast(Counter.Count, num_workers) catch std.math.maxInt(Counter.Count);
                break :blk max_workers;
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub const Worker = enum {
        Running,
        
    }

    pub fn notify(self: *Self)
};