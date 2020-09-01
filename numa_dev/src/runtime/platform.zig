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

pub const is_windows = std.builtin.os.tag == .windows;
pub const is_linux = std.builtin.os.tag == .linux;
pub const is_bsd = switch (std.builtin.os.tag) {
    .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};
pub const is_posix = std.builtin.link_libc and (is_linux or is_bsd);

const system =  
    if (is_windows)
        struct {
            pub usingnamespace @import("./windows/numa.zig");
            pub usingnamespace @import("./windows/event.zig");
            pub usingnamespace @import("./windows/thread.zig");
        }
    else if (is_posix)
        struct {
            pub usingnamespace @import("./posix/numa.zig");
            pub usingnamespace @import("./posix/event.zig");
            pub usingnamespace @import("./posix/thread.zig");
        }
    else if (is_linux)
        struct {

        }
    else @compileError("Operating system not supported");

pub const Event = system.Event;
pub const Thread = system.Thread;
pub const NumaNode = system.NumaNode;
