const zap = @import("../../zap.zig");
const target = zap.runtime.target;

pub usingnamespace 
    if (target.has_libc) 
        @import("./posix.zig") 
    else 
        struct {};
