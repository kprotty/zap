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
const zap = @import("zap");

const assert = std.testing.expect;
const assertEq = std.testing.expectEqual;

const Wheel = zap.core.Timer.Wheel;
const DefaultWheel = zap.core.Timer.DefaultWheel;

test "timer wheel queue" {
    inline for ([_]type {
        DefaultWheel,
        // different bit sizes
        Wheel(u128, 7, 4),
        Wheel(u64, 6, 4),
        Wheel(u64, 5, 4),
        Wheel(u64, 4, 4),
        Wheel(u64, 3, 4),
        // different tick sizes
        Wheel(u128, 3, 4),
        Wheel(u32, 3, 4),
        Wheel(u16, 3, 4),
    }) |WheelType| {
        const Entry = WheelType.Entry;
        const Poll = WheelType.Poll;

        var queue = WheelType{};
        assertEq(@as(?Poll, null), queue.poll());
        assertEq(@as(?Poll, null), queue.poll());

        var _5: Entry = undefined;
        queue.expireAfter(&_5, 5);
        assert(queue.hasPending());
        assert(!queue.hasExpired());
        assertEq(@as(?Poll, Poll{.wait_for = 5}), queue.poll());

        queue.advance(3);
        assert(queue.hasPending());
        assert(!queue.hasExpired());
        assertEq(@as(?Poll, Poll{.wait_for = 5 - 3}), queue.poll());

        queue.advance(2);
        assert(!queue.hasPending());
        assert(queue.hasExpired());

        assertEq(@as(?Poll, Poll{.expired = &_5}), queue.poll());
        assertEq(@as(?Poll, null), queue.poll());
        assertEq(@as(?Poll, null), queue.poll());

        var _past: Entry = undefined;
        var _10: Entry = undefined;
        var _10_2: Entry = undefined;
        var _1000: Entry = undefined;
        var _1500: Entry = undefined;
        var _10000: Entry = undefined;

        queue.expireAt(&_past, 0);
        queue.expireAfter(&_10, 10);
        queue.expireAfter(&_10_2, 10);
        queue.expireAfter(&_1000, 1000);
        queue.expireAfter(&_1500, 1500);
        queue.expireAfter(&_10000, 10000);

        assertEq(@as(?Poll, Poll{.expired = &_past}), queue.poll());

        const p10 = queue.poll();
        assert(p10 != null);
        assert(p10.?.wait_for <= 10);
        queue.update(queue.now() + 10);
        assertEq(@as(?Poll, Poll{.expired = &_10}), queue.poll());
        assertEq(@as(?Poll, Poll{.expired = &_10_2}), queue.poll());

        const p1000 = queue.poll();
        assert(p1000 != null);
        assert(p1000.?.wait_for <= 1000 - 10);
        queue.advance(1000 - 10);
        assertEq(@as(?Poll, Poll{.expired = &_1000}), queue.poll());

        queue.remove(&_1500);

        const p10000 = queue.poll();
        assert(p10000 != null);
        assert(p10000.?.wait_for <= 10000 - 1000);
        queue.advance(20000);
        assertEq(@as(?Poll, Poll{.expired = &_10000}), queue.poll());
        assertEq(@as(?Poll, null), queue.poll());
        assertEq(@as(?Poll, null), queue.poll());
    }
}