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

pub const Task = @import("./task.zig").Task;

pub const sync = struct {
    pub const core = struct {
        pub const Lock = @import("./sync/lock.zig").Lock;

        pub const Channel = @import("./sync/channel.zig").Channel;
    };

    pub const os = struct {
        pub const Signal = @import("./sync/signal/os.zig").Signal;

        pub const Lock = core.Lock(Signal);

        pub fn Channel(comptime T: type) type {
            return core.Channel(.{
                .Type = T,
                .Lock = Lock,
                .Signal = Signal,
            });
        }
    };

    pub const task = struct {
        pub const Signal = @import("./sync/signal/task.zig").Signal;

        pub const Lock = core.Lock(Signal);

        pub fn Channel(comptime T: type) type {
            return core.Channel(.{
                .Type = T,
                .Lock = os.Lock,
                .Signal = Signal,
            });
        }
    };
};
