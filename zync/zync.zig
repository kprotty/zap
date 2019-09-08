
const utils = @import("src/utils.zig");
const atomic = @import("src/atomic.zig");

pub usingnamespace utils;
pub usingnamespace atomic;

test "zync" {
    _ = utils;
    _ = atomic;
}
