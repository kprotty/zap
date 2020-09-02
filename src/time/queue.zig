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

const zig_timeout_wheel = @import("./zig-timeout-wheel.zig");
const TimeoutWheel = zig_timeout_wheel.TimeoutWheel(u64, 6, 6, .NoIntervals, .AllowRelative);

pub const TimeoutQueue = struct {
    wheel: TimeoutWheel,

    pub fn init(self: *TimeoutQueue) void {
        self.wheel = TimeoutWheel.init();
    }

    pub fn deinit(self: *TimeoutQueue) void {
        self.wheel.reset();
    }

    pub const Entry = struct {
        timeout: TimeoutWheel.Timeout,
    };

    pub fn insert(self: *TimeoutQueue, entry: *Entry, expires_in: u64) void {
        entry.* = Entry{ .timeout = TimeoutWheel.Timeout.init(null) };
        self.wheel.add(&entry.timeout, expires_in / std.time.ns_per_ms);
    }

    pub fn remove(self: *TimeoutQueue, entry: *Entry) bool {
        const timeout = &entry.timeout;
        const in_list = timeout.isPending() or timeout.isExpired();

        if (!in_list)
            return false;

        entry.timeout.remove();
        return true;
    }

    pub fn advance(self: *TimeoutQueue, ticks: u64) void {
        self.wheel.step(ticks / std.time.ns_per_ms);
    }

    pub const Poll = union(enum) {
        wait_for: u64,
        expired: *Entry,
    };

    pub fn poll(self: *TimeoutQueue) ?Poll {
        if (self.wheel.get()) |timeout|
            return Poll{ .expired = @fieldParentPtr(Entry, "timeout", timeout) };

        const expires_in = self.wheel.timeout();
        if (expires_in != 0)
            return Poll{ .wait_for = expires_in * std.time.ns_per_ms };

        return null;
    }
};