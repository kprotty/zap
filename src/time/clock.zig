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
const zap = @import("./zap.zig");

pub const nanotime = OsTime.nanotime;

const OsTime = struct {
    var frequency_state: FrequencyState = .uninit;
    var frequency: OsClock.Frequency = undefined;

    const FrequencyState = enum(u8) {
        uninit,
        creating,
        init,
    };

    fn getFrequency() OsClock.Frequency {
        if (@atomicLoad(FrequencyState, &frequency_state, .Acquire) == .init)
            return frequency;
        return getFrequencySlow();
    }

    fn getFrequencySlow() OsClock.Frequency {
        @setCold(true);
        const freq = OsClock.getFrequency();
        
        if (@cmpxchgStrong(
            FrequencyState,
            &frequency_state,
            .uninit,
            .creating,
            .Acquire,
            .Monotonic,
        ) == null) {
            frequency = freq;
            @atomicStore(FrequencyState, &frequency_state, .init, .Release);
        }

        return freq;
    }

    var last_now: u64 = 0;
    var lock = zap.sync.os.Lock{};

    inline fn nanotime() u64 {
        const freq = getFrequency();
        var now = OsClock.getNow();

        if (!OsClock.is_actually_monotonic) {
            if (@typeInfo(usize).Int.bits < 64) {
                lock.acquire();
                defer lock.release();

                if (last_now >= now) {
                    now = last_now;
                } else {
                    last_now = now;
                }

            } else {
                var last = @atomicLoad(u64, &last_now, .Monotonic);
                while (true) {
                    if (last >= now) {
                        now = last;
                        break;
                    } else {
                        last = @cmpxchgWeak(
                            u64,
                            &last_now,
                            last,
                            now,
                            .Monotonic,
                            .Monotonic,
                        ) orelse break;
                    }
                }
            }
        }

        return OsClock.getScaled(freq, now);
    }
};

const OsClock = 
    if (std.builtin.os.tag == .windows)
        WindowsClock
    else if (std.Target.current.isDarwin())
        DarwinClock
    else
        PosixClock;

const WindowsClock = struct {
    const windows = std.os.windows;

    const Frequency = u64;
    const is_actually_monotonic = false;

    fn getFrequency() Frequency {
        return windows.QueryPerformanceFrequency();
    }

    fn getNow() u64 {
        return windows.QueryPerformanceCounter();
    }

    fn getScaled(frequency: Frequency, counter: u64) u64 {
        return @divFloor(counter * std.time.ns_per_s, frequency);
    }
};

const DarwinClock = struct {
    const darwin = std.os.darwin;

    const Frequency = darwin.mach_timebase_info_data;
    const is_actually_monotonic = true;

    fn getFrequency() Frequency {
        var frequency: Frequency = undefined;
        darwin.mach_timebase_info(&frequency);
        return frequency;
    }

    fn getNow() u64 {
        return darwin.mach_absolute_time();
    }

    fn getScaled(frequency: Frequency, counter: u64) u64 {
        return @divFloor(counter * frequency.numer, frequency.denom);
    }
};

const PosixClock = struct {
    const Frequency = void;
    const is_actually_monotonic = (
        (std.builtin.os.tag == .linux and (std.builtin.arch == .aarch64 or .arch == .s390x)) or
        (std.builtin.os.tag == .openbsd and std.builtin.arch == .x86_64)
    );

    fn getFrequency() Frequency {
        return undefined;
    }

    fn getNow() u64 {
        var ts: std.os.timespec = undefined;
        std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;
        return @intCast(u64, ts.tv_sec) * std.time.ns_per_s + @intCast(u64, ts.tv_nsec);
    }

    fn getScaled(frequency: Frequency, counter: u64) u64 {
        return counter;
    }
};