const std = @import("std");
const builtin = @import("builtin");

const zuma = @import("../../zap.zig").zuma;
const zync = @import("../../zap.zig").zync;

const os = std.os;
const system = os.system;

// const _SC_NPROCESSORS_ONLN = 84;
// const cpu_count = switch (builtin.os) {
//   .macosx => property(if (only_physical_cpus) c"hw.physicalcpu" else c"hw.logicalcpu"),
//    .dragonfly, .freebsd, .kfreebsd, .netbsd => property(c"hw.ncpu"),
//    .linux => usize(os.CPU_COUNT(os.sched_getaffinity(0) catch 1)),
//    else => @intCast(usize, system.sysconf(_SC_NPROCESSORS_ONLN)),
// };
