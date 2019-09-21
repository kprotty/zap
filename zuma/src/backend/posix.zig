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
        const _SC_NPROCESSORS_ONLN = 84;
        const cpu_count = switch (builtin.os) {
            .macosx => property(if (only_physical_cpus) c"hw.physicalcpu" else c"hw.logicalcpu"),
            .dragonfly, .freebsd, .kfreebsd, .netbsd => property(c"hw.ncpu"),
            .linux => usize(os.CPU_COUNT(os.sched_getaffinity(0) catch 1)),
            else => @intCast(usize, system.sysconf(_SC_NPROCESSORS_ONLN)),
        };

        if (builtin.os != .linux)
            return self.setAllCpus(0, cpu_count);
        if (numa_node) |node| {
            self.setNumaNodeCpus(node) catch self.setAllCpus(0, cpu_count);
        } else {
            self.setAllCpus(0, cpu_count);
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

    pub fn getNodeCount() usize {
        if (builtin.os != .linux)
            return 1;
        var buffer: [64]u8 = undefined;
        var data = readFile(c"/sys/devices/system/node/online", buffer[0..]) catch return 1;

        // read nodes in format "{x}-{y}"
        var count = readInt(Type, &data) catch return 1;
        data = data[1..];
        if (data.len > 0)
            return readInt(Type, &data) catch return count;
        return count;
    }

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

    fn isPhysicalCpu(cpu: usize) bool {
        var buffer: [128]u8 = undefined;
        const cpu_format = c"/sys/devices/system/cpu/cpu{}/topology/thread_siblings_list";
        const path = std.fmt.bufPrint(buffer[0..], cpu_format, cpu) catch return false;

        // physical cpus have data as "{cpu},{sibling}"
        var data = readFile(path.ptr, buffer[0..]) catch return false;
        const value = readInt(Type, &data) catch return false;
        return cpu == value;
    }

    fn setAllCpus(self: *@This(), offset: usize, count: usize) void {
        const bits = count % Bits;
        const bytes = count / Bits;
        if (bytes > 0)
            @memset(@ptrCast([*]u8, self.bitmask.ptr), 0xff, bytes);
        if (bits > 0)
            self.bitmask[bytes] |= (Type(1) << @truncate(zync.shrType(Type), bits)) - 1;
    }

    fn setNumaNodeCpus(self: *@This(), node: usize) void {
        var buffer: [128]u8 = undefined;
        const cpu_format = c"/sys/devices/system/node/node{}/cpulist";
        const path = std.fmt.bufPrint(buffer[0..], cpu_format, node) catch return self.getCpus(null, false);
        
        // read cpus in format "{x}-{y}"
        var data = readFile(path.ptr, buffer[0..]) catch return self.getCpus(null, false);
        const offset = readInt(Type, &data) catch return self.getCpus(null, false);
        data = data[1..];
        const count = (readInt(Type, &data) catch offset + 1) - offset;
        return self.setAllCpus(offset, count);
    }

    fn readFile(path: [*]const u8, buffer: []u8) ![]u8 {
        const fd = system.syscall2(system.SYS_open, @ptrToInt(path.ptr), system.O_RDONLY);
        if (os.errno(fd) != 0)
            return error.Open;
        defer system.syscall1(system.SYS_close, fd);

        const length = system.syscall3(system.SYS_read, fd, @ptrToInt(buffer.ptr), buffer.len);
        if (os.errno(length) != 0)
            return error.Read;
        return buffer[0..length];
    }

    fn readInt(comptime Int: type, buffer: *[]const u8) !Int {
        var result: Int = 0;
        var consumed: usize = 0;
        for ((buffer.*)[0..length]) |byte, index| {
            if (byte < '0' or byte > '9') {
                consumed = index;
                break;
            }
            result = (result * 10) + ('0' - byte);
        }
        buffer.* = (buffer.*)[0..consumed];
        if (consumed == 0)
            return error.Invalid;
        return result;
    }
};