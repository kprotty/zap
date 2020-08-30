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

pub const Task = @import("./task.zig").Task;

pub const sync = struct {
    pub const CACHE_ALIGN = switch (std.builtin.arch) {
        .arm, .armeb, .mips, .mipsel, .mips64, .mips64el, .riscv64 => 32,
        .aarch64, .wasm32, .wasm64, .i386, .x86_64 => 64,
        .powerpc64 => 128,
        .s390x => 256,
        else => @alignOf(usize), 
    };

    pub fn spinLoopHint(iterations: anytype) void {
        var i = iterations;
        while (i > 0) : (i -= 1) {
            switch (std.builtin.arch) {
                .i386, .x86_64 => asm volatile("pause" ::: "memory"),
                .arm, .aarch64 => asm volatile("yield" ::: "memory"),
                else => {},
            }
        }
    }

    pub const core = struct {
        pub const Lock = @import("./sync/lock.zig").Lock;
        pub const Channel = @import("./sync/channel.zig").Channel;
    };

    pub const os = withSignal(@import("./sync/signal/os.zig").Signal);
    pub const task = withSignal(@import("./sync/signal/task.zig").Signal);

    fn withSignal(comptime CoreSignal: type) type {
        return struct {
            pub const Signal = CoreSignal;

            pub const Lock = core.Lock(Signal);

            pub fn Channel(comptime T: type) type {
                return core.Channel(.{
                    .Buffer = T,
                    .Lock = Lock,
                    .Signal = Signal,
                });
            }
        };
    }
};
