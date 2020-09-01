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

const has_libc = std.builtin.link_libc;
const is_linux = std.builtin.os.tag == .linux;
const is_windows = std.builtin.os.tag == .windows;

const is_posix = (is_linux or is_bsd) and has_libc;
const is_bsd = switch (std.builtin.os.tag) {
    .macosx, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

// Folders which implement OS specific functionality.
// If looking to add support for another OS, possibly add a new dir & case here.
pub const subsystem = 
    if (is_windows)
        "./windows"
    else if (is_posix)
        "./posix"
    else if (is_linux)
        "./linux"
    else
        @compileError("Operating System not supported yet");

pub const Instant = struct {
    const OsTime = @import(subsystem ++ "/time.zig");

    const Frequency = struct {
        const State = enum(u8) {
            uninit,
            fetching,
            cached,
        };

        var state: State = .uninit;
        var value: OsTime.Frequency = undefined;

        inline fn get() OsTime.Frequency {
            // return the frequency value if its already cached.
            // Acquire barrier to see the valid thread writes to value. 
            if (@atomicLoad(State, &state, .Acquire) == .cached)
                return value;

            return getSlow();
        }

        fn getSlow() OsTime.Frequency {
            @setCold(true);

            // get the time frequency without synchronization, assuming its cheap to compute
            const frequency = OsTime.frequency();

            // try to cache it if no other thread is trying to or has already cached it
            if (@cmpxchgStrong(State, &state, .uninit, .fetching, .Acquire, .Monotonic) == null) {
                value = frequency;
                @atomicStore(State, &state, .cached, .Release);
            }

            return frequency;
        }
    };

    const Cache = struct {
        var lock = OsTime.Lock{};
        var first_timestamp: u64 = 0;
        var last_timestamp: u64 = 0;

        fn get32(timestamp: u64) u64 {
            var now = timestamp;
            
            // use the time lock to synchronize updates to the global first & last timestampts
            lock.acquire();
            defer lock.release();

            // ensure `now` is monotonically increasing using last_timestamp
            const last_now = Cache.last_timestamp;
            if (last_now > now) {
                now = last_now;
            } else {
                last_timestamp = now;
            }

            // get the first timestampt to offset of for longer time until overflow
            const first_now = Cache.first_timestamp;
            if (first_now == 0) {
                first_now = now;
                first_timestamp = first_now;
            }

            // return the perceived `now` relative to the first globally recorded `now` 
            return now -% first_now;
        }

        fn get64(timestamp: u64) u64 {
            var now = timestamp;

            // ensure `now` is monotonically increasing using last_timestamp in a lock-free manner
            var last_now = @atomicLoad(u64, &last_timestamp, .Monotonic);
            while (true) {
                if (last_now > now) {
                    now = last_now;
                    break;
                } else {
                    last_now = @cmpxchgWeak(
                        u64,
                        &last_timestamp,
                        last_now,
                        now,
                        .Monotonic,
                        .Monotonic,
                    ) orelse break;
                }
            }

            // get the first timestampt to offset of for longer time until overflow in a wait-free manner
            first_now = @atomicLoad(u64, &first_timestamp, .Monotonic);
            if (first_now == 0) {
                first_now = @cmpxchgStrong(
                    u64,
                    &first_timestamp,
                    0,
                    now,
                    .Monotonic,
                    .Monotonic,
                ) orelse now;
            }

            // return the perceived `now` relative to the first globally recorded `now` 
            return now -% first_now;
        }
    };

    pub fn now() u64 {
        var now = OsTime.now(Frequency.get());
        if (OsTime.is_actually_monotonic)
            return now;

        if (@typeInfo(usize).Int.bits >= 64) {
            now = Cache.get64(now);
        } else {
            now = Cache.get32(now);
        }

        return now;
    }  
};

pub const NumaNode = struct {
    const OsMemory = @import(subsystem ++ "/memory.zig");

    node_id: ?u32,
    affinity: Thread.CpuAffinity,

    pub fn getHugePageSize() ?usize {
        const Cached = struct {
            var value: usize = 0;
        };


    }

    pub fn map(self: *NumaNode, bytes: usize, flags: u32) ?[]align(std.mem.page_size) u8 {

    }

    pub fn modify(self: *NumaNode, memory: []align(std.mem.page_size) u8, flags: u32) ?void {

    }

    pub fn unmap(self: *NumaNode, memory: []align(std.mem.page_size) u8) void {

    }
};

pub const Thread = struct {
    const OsThread = @import(subsystem ++ "/thread.zig");

    pub const SpawnOptions = struct {
        numa_node: *NumaNode,
        stack_size: usize,
    };

    pub fn spawn(
        options: SpawnOptions,
        comptime entry_func: anytype,
        func_args: anytype,
    ) ?*Thread {

    }

    pub const CpuAffinity = struct {
        begin: u32,
        end: u32,
    };

    pub fn bindCpu(self: *Thread, ideal_cpu: u32, affinity: CpuAffinity) void {

    }

    pub fn join(self: *Thread) void {

    }

    pub fn getCurrent() ?*Thread {

    }

    pub fn getId(self: *Thread) usize {

    }

    pub fn getNumaNode(self: *Thread) *NumaNode {

    }

    pub fn getStack(self: *Thread) []align(std.mem.page_size) u8 {

    }

    pub fn sleep(duration: u64) void {

    }

    pub fn yield() void {

    }

    pub fn yieldCpu() void {
        switch (std.builtin.arch) {
            .i386, .x86_64 => asm volatile("pause"),
            .arm, .aarch64 => asm volatile("yield"),
            else => {},
        },
    }    

    pub fn park() error{InvalidThread}!void {
        const self = getCurrent() orelse return error.InvalidThread;
        self.inner.parkUntil(null) orelse unreachable;
    }

    pub fn parkUntil(imestamp: u64) error{InvalidThread, TimedOut}!void {
        const self = getCurrent() orelse return error.InvalidThread;
        self.inner.parkUntil(timestamp) orelse return error.TimedOut;
    }

    pub fn unpark(self: *Thread) void {
        self.inner.unpark();
    }
};
