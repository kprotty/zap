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

pub const subsystem = 
    if (is_windows)
        "./windows"
    else if (is_posix)
        "./posix"
    else if (is_linux)
        "./linux"
    else
        @compileError("Operating System not supported yet");


pub const Event = @import(subsystem ++ "/event.zig").Event;
pub const Thread = @import(subsystem ++ "/thread.zig").Thread;
pub const NumaNode = @import(subsystem ++ "/numa.zig").NumaNode;
