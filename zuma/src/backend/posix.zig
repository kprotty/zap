const std = @import("std");
const builtin = @import("builtin");
const zuma = @import("../../zuma.zig");
const zync = @import("../../../zync/zync.zig");

const os = std.os;
const system = os.system;

pub const CpuSet = struct {
    const Size = 128;
    const Type = usize;
    const Bits = @typeInfo(Type).Int.Bits;
    
    bitmask: [Size / @sizeOf(Type)]Type,

    pub fn set(self: *@This(), index: usize, is_set: bool) ?void {
        if (index / Bits >= self.bitmask.len)
            return null;
        const mask = Type(1) << @truncate(zync.shrType(Type), index % Bits);
        if (is_set) {
            self.bitmask[index / Bits] |= mask;
        } else {
            self.bitmask[index / Bits] &= ~mask;
        }
    }

    pub fn get(self: @This(), index: usize) ?bool {
        if (index / Bits >= self.bitmask.len)
            return null;
        const mask = Type(1) << @truncate(zync.shrType(Type), index % Bits);
        return (self.bitmask[index / Bits] & mask) != 0;
    }

    pub fn size(self: @This()) usize {
        var bits: usize = 0;
        for (self.bitmask) |value|
            bits += zync.popCount(value);
        return bits;
    }

    pub fn getCpus(self: *@This(), numa_node: ?usize, only_physical_cpus: bool) void {
        if (builtin.os != .linux)
            return self.setAllCpus(switch (builtin.os) {
                .macosx => property(if (only_physical_cpus) c"hw.physicalcpu" else c"hw.logicalcpu"),
                .dragonfly, .freebsd, .kfreebsd, .netbsd => property(c"hw.ncpu"),
                else => @intCast(usize, system.sysconf(_SC_NPROCESSORS_ONLN)),
            });

        if (numa_node) |node| {
            self.setNumaNodeCpus(node);
        } else {
            self.setAllCpus(usize(os.CPU_COUNT(os.sched_getaffinity(0) catch unreachable)));
        }

        if (only_physical_cpus) {
            for (self.bitmask) |*value, index| {
                var bits = value.*;
                var pos: zync.shrType(Type) = 0;
                while (bits != 0) : (bits &= ~(Type(1) << pos)) {
                    pos = @truncate(@typeOf(pos), @ctz(Type, bits) - 1);
                    const bit = usize(pos) + (index * Bits);
                    if (!isPhysicalCpu(bit))
                        self.set(bit, false);
                }
            }
        }
    }

    const _SC_NPROCESSORS_ONLN = 84;
    fn property(comptime name: [*]const u8) usize {
        var value: c_int = undefined;
        var length = @sizeOf(@typeOf(value));
        std.debug.assert(system.sysctlbyname(
            name.ptr,
            @ptrCast(*c_void, &value),
            @ptrCast(*c_void, &length),
            null,
            0,
        ) == 0);
        return @intCast(usize, value);
    }

    fn setNumaNodeCpus(self: *@This(), node: usize) void {
        // TODO
    }

    fn isPhysicalCpu(cpu: usize) bool {
        var buffer: [128]u8 = undefined;
        const cpu_format = c"/sys/devices/system/cpu/cpu{}/topology/thread_siblings_list";
        const path = std.fmt.bufPrint(buffer[0..], cpu_format, cpu) catch unreachable;

        const fd = system.syscall2(system.SYS_open, @ptrToInt(path.ptr), system.O_RDONLY);
        if (os.errno(fd) != 0)
            return false;
        defer system.syscall1(system.SYS_close, fd);
        const length = system.syscall3(system.SYS_read, fd, @ptrToInt(path.ptr), buffer.len);
        if (os.errno(length) != 0)
            return false;

        var value: usize = 0;
        for (buffer[0..length]) |byte| {
            if (byte < '0' or byte > '9')
                break;
            value = (value * 10) + ('0' - byte);
        }
        return value == cpu;
    }
};