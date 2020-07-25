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
const windows = @import("./windows.zig");

const VersionState = enum(usize) {
    uninit,
    newer,
    older,
};

pub fn isWindowsVersionOrHigher(
    comptime version: std.Target.Os.WindowsVersion,
) bool {
    const Cached = struct {
        var version_state: VersionState = .uninit;

        fn get() bool {
            const state = @atomicLoad(VersionState, &version_state, .Monotonic);
            if (state == .uninit)
                return getSlow();
            return state == .newer;
        }

        fn getSlow() bool {
            @setCold(true);

            const is_version_or_higher = switch (version) {
                .win7 => IsWindowsVersionOrGreater(.WIN7, 0),
                .vista => IsWindowsVersionOrGreater(.VISTA, 0),
                else => @compileError("TODO: add more windows version checks"),
            };

            const state: VersionState = if (is_version_or_higher) .newer else .older;
            @atomicStore(VersionState, &version_state, state, .Monotonic);
            return is_version_or_higher;
        }

        fn IsWindowsVersionOrGreater(
            nt_version: windows._WIN32_WINNT,
            service_pack: windows.WORD,
        ) bool {
            var vi = std.mem.zeroes(windows.OSVERSIONINFOEXW);
            vi.dwOSVersionInfoSize = @sizeOf(@TypeOf(vi));
            vi.dwMajorVersion = @enumToInt(nt_version) >> 8;
            vi.dwMinorVersion = @enumToInt(nt_version) & 0xff;
            vi.wServicePackMajor = service_pack;
            
            return windows.VerifyVersionInfoW(
                &vi,
                windows.VER_MAJORVERSION | windows.VER_MINORVERSION | windows.VER_SERVICEPACKMAJOR,
                windows.VerSetConditionMask(
                    windows.VerSetConditionMask(
                        windows.VerSetConditionMask(
                            @as(windows.ULONGLONG, 0),
                            windows.VER_MAJORVERSION,
                            windows.VER_GREATER_EQUAL,
                        ),
                        windows.VER_MINORVERSION,
                        windows.VER_GREATER_EQUAL,
                    ),
                    windows.VER_SERVICEPACKMAJOR,
                    windows.VER_GREATER_EQUAL,
                ),
            ) == windows.TRUE;
        }
    };

    return Cached.get();
}

