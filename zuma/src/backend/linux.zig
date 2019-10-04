const std = @import("std");
const posix = @import("posix.zig");
const builtin = @import("builtin");

const zync = @import("zap").zync;
const zuma = @import("zap").zuma;

const os = std.os;
const linux = os.linux;

pub const CpuSet = struct {
    const Size = 128;
    const Type = usize;
    const Bits = @typeInfo(Type).Int.bits;
    
    bitmask: [Size / @sizeOf(Type)]Type,

    pub fn set(self: *@This(), index: usize, is_set: bool) zuma.CpuSet.IndexError!void {
        if (index / Bits >= self.bitmask.len)
            return zuma.CpuSet.IndexError.InvalidCpu;
        const mask = Type(1) << @truncate(zync.shrType(Type), index % Bits);
        if (is_set) {
            self.bitmask[index / Bits] |= mask;
        } else {
            self.bitmask[index / Bits] &= ~mask;
        }
    }

    pub fn get(self: @This(), index: usize) zuma.CpuSet.IndexError!bool {
        if (index / Bits >= self.bitmask.len)
            return zuma.CpuSet.IndexError.InvalidCpu;
        const mask = Type(1) << @truncate(zync.shrType(Type), index % Bits);
        return (self.bitmask[index / Bits] & mask) != 0;
    }

    pub fn count(self: @This()) usize {
        var bits: usize = 0;
        for (self.bitmask) |value|
            bits += zync.popCount(value);
        return bits;
    }

    pub fn getNodeCount() usize {
        var buffer: [128]u8 = undefined;
        var data = readFile(buffer[0..], "/sys/devices/system/node/online\x00") catch return 1;
        
        // data in the format of many "{numa_node_start}-{numa_node_end}"
        var end: usize = 0;
        var begin: usize = 0;
        var node_count: usize = 0;
        while (readRange(&data, &begin, &end))
            node_count += (end + 1) - begin;
        return node_count;
    }

    pub fn getNodeSize(numa_node: usize) zuma.CpuSet.CpuError!usize {
        var buffer: [2048]u8 = undefined;
        var data = try readFile(buffer[0..], "/sys/devices/system/node/node{}/meminfo\x00", numa_node);

        // data in the format of "Node {numa_node} MemTotal: {node_size_kb}kb\n"
        var node_size_kb: usize = 0;
        const header = "MemTotal:";
        const offset = std.mem.indexOf(u8, data, header) 
            orelse return zuma.CpuSet.NodeError.InvalidNode;
        data = data[(offset + header.len)..];
        if (!readRange(&data, &node_size_kb, null))
            return zuma.CpuSet.NodeError.InvalidNode;
        return node_size_kb * 1024;
    }

    pub fn getCpus(self: *@This(), numa_node: ?usize, only_physical_cpus: bool) zuma.CpuSet.CpuError!void {
        if (numa_node) |node| {
            try self.setNumaNodeCpus(node);
        } else {
            const result = linux.sched_getaffinity(0, @sizeOf(@This()), @ptrCast(*linux.cpu_set_t, self));
            if (linux.getErrno(result) != 0)
                return zuma.CpuSet.CpuError.SystemResourceAccess;
        }

        // iterate all the set cpus & unset any that arent physical
        if (only_physical_cpus) {
            for (self.bitmask) |*value, index| {
                var bits = value.*;
                var pos: zync.shrType(Type) = 0;
                while (bits != 0) : (bits ^= Type(1) << pos) {
                    pos = @truncate(@typeOf(pos), @ctz(Type, ~bits) - 1);
                    const bit = usize(pos) + usize(index * Bits);
                    if (!isPhysicalCpu(bit))
                        try self.set(bit, false);
                }
            }
        }
    }

    fn setNumaNodeCpus(self: *@This(), numa_node: usize) zuma.CpuSet.CpuError!void {
        var buffer: [256]u8 = undefined;
        var data = try readFile(buffer[0..], "/sys/devices/system/node/node{}/cpulist\x00", numa_node);

        // data in the format of many "{cpu_start}-{cpu_end}"
        var end: usize = 0;
        var begin: usize = 0;
        while (readRange(&data, &begin, &end))
            while (begin <= end) : (begin += 1)
                try self.set(begin, true);
    }

    fn isPhysicalCpu(cpu: usize) bool {
        const format = "/sys/devices/system/cpu/cpu{}/topology/thread_siblings_list\x00";
        var buffer: [format.len]u8 = undefined;
        var data = readFile(buffer[0..], format, cpu) catch return false;

        // data in format of "{physical_cpu},{sibling_cpu}"
        var physical_cpu: usize = 0;
        if (!readRange(&data, &physical_cpu, null))
            return false;
        return cpu == physical_cpu;
    }
    
    fn readFile(buffer: []u8, comptime format: []const u8, format_args: ...) zuma.CpuSet.NodeError![]const u8 {
        // open the file in read-only mode. Will only return a constant slice to the buffer
        const path = std.fmt.bufPrint(buffer, format, format_args) 
            catch |e| return zuma.CpuSet.NodeError.InvalidNode;
        const fd = linux.syscall2(linux.SYS_open, @ptrToInt(path.ptr), linux.O_RDONLY | linux.O_CLOEXEC);
        if (linux.getErrno(fd) != 0)
            return zuma.CpuSet.NodeError.InvalidNode;
        defer _ = linux.syscall1(linux.SYS_close, fd);

        // read as much content from the file as possible
        const length = linux.syscall3(linux.SYS_read, fd, @ptrToInt(buffer.ptr), buffer.len);
        if (linux.getErrno(length) != 0)
            return zuma.CpuSet.NodeError.SystemResourceAccess;
        return buffer[0..length];
    }

    fn readRange(noalias input: *[]const u8, noalias start: *usize, noalias end: ?*usize) bool {
        // in order to not repeat
        const Char = struct {
            pub inline fn isDigit(char: u8) bool {
                return char >= '0' and char <= '9';
            }
        };

        // consume the buffer based on inputs read
        var pos: usize = 0;
        const source = input.*;
        defer input.* = source[pos..];

        // skip non digits
        while (pos < source.len and !Char.isDigit(source[pos]))
            pos += 1;
        if (pos >= source.len)
            return false;

        // read the first number
        var number: usize = 0;
        while (pos < source.len and Char.isDigit(source[pos])) : (pos += 1)
            number = (number * 10) + usize(source[pos] - '0');
        start.* = number;

        // skip more non digits
        while (pos < source.len and !Char.isDigit(source[pos]))
            pos += 1;
        if (pos >= source.len)
            return true;

        // try and read the second number
        if (end) |end_ptr| {
            number = 0;
            while (pos < source.len and Char.isDigit(source[pos])) : (pos += 1)
                number = (number * 10) + usize(source[pos] - '0');
            end_ptr.* = number;
        }
        return true;
    }
};

pub const Thread = if (builtin.link_libc) posix.Thread else struct {
    id: *i32,

    pub fn now(is_monotonic: bool) u64 {
        var ts: linux.timespec = undefined;
        const clock_type = if (is_monotonic) i32(linux.CLOCK_MONOTONIC_RAW) else linux.CLOCK_REALTIME;
        return switch (os.errno(linux.clock_gettime(clock_type, &ts))) {
            0 => (@intCast(u64, ts.tv_sec) * 1000) + (@intCast(u64, ts.tv_nsec) / 1000000),
            os.EFAULT, os.EPERM => unreachable,
            else => unreachable,
        };
    }

    pub fn sleep(ms: u32) void {
        var ts = toTimespec(ms);
        while (true) {
            switch (os.errno(linux.nanosleep(&ts, &ts))) {
                0, os.EINVAL => return,
                os.EINTR => continue,
                else => unreachable,
            }
        }
    }

    pub fn yield() void {
        _ = linux.syscall0(linux.SYS_sched_yield);
    }

    pub fn getStackSize(comptime function: var) usize {
        var size = @sizeOf(@Frame(function));
        size = std.mem.alignForward(size, @alignOf(i32)) + @sizeOf(i32);
        size = std.mem.alignForward(size, zuma.mem.page_size);
        if (linux.tls.tls_image) |tls_image|
            size = std.mem.alignForward(size, @alignOf(usize)) + tls_image.alloc_size;
        return size;
    }

    pub fn spawn(stack: ?[]align(zuma.mem.page_size) u8, comptime function: var, parameter: var) zuma.Thread.SpawnError!@This() {
        const memory = stack orelse return zuma.Thread.SpawnError.InvalidStack;
        var id = @ptrCast(*i32, memory[0]);
        var clone_flags = 
            os.CLONE_VM | os.CLONE_FS | os.CLONE_FILES |
            os.CLONE_CHILD_CLEARTID | os.CLONE_PARENT_SETTID |
            os.CLONE_THREAD | os.CLONE_SIGHAND | os.CLONE_SYSVSEM;

        var tls_offset: usize = undefined;
        if (system.tls.tls_image) |tls_image| {
            clone_flags |= os.CLONE_SETTLS;
            tls_offset = memory.len - tls_image.alloc_size;
            tls_offset = system.tls.copyTLS(@ptrToInt(&memory[tls_offset]));
        }

        const Wrapper = struct {
            extern fn entry(arg: usize) u8 {
                _ = function(zuma.mem.transmute(@typeOf(parameter), arg));
                return 0;
            }
        };
        
        var stack_offset = @sizeOf(@typeOf(id)) + @sizeOf(@Frame(function));
        stack_offset = std.mem.alignForward(stack_offset, zuma.mem.page_size);
        const stack_ptr = @ptrToInt(&memory[stack_offset]);
        const arg = std.mem.transmute(usize, parameter);
        return switch (os.errno(system.clone(Wrapper.entry, stack_ptr, clone_flags, arg, id, tls_offset, id))) {
            0 => @This() { .id = id },
            os.EPERM, os.EINVAL, os.ENOSPC, os.EUSERS => unreachable,
            os.EAGAIN => zuma.Thread.SpawnError.TooManyThreads,
            os.ENOMEM => zuma.Thread.SpawnError.OutOfMemory,
            else => unreachable,
        };
    }

    pub fn join(self: *@This(), timeout_ms: ?u32) void {
        var ts: linux.timespec = if (timeout_ms) |t| toTimespec(t) else undefined;
        const timeout = if (timeout_ms) |_| &ts else null;
        return switch (os.errno(linux.futex_wait(self.id, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, self.id.*, timeout))) {
            0, os.EINTR, os.EAGAIN => {},
            os.EINVAL => unreachable,
            else => unreachable,
        };
    }

    pub fn setAffinity(cpu_set: *const CpuSet) zuma.Thread.AffinityError!void {
        const tid = linux.syscall0(linux.SYS_gettid);
        return switch (os.errno(linux.syscall3(linux.SYS_sched_setaffinity, tid, @sizeOf(CpuSet), @ptrToInt(cpu_set)))) {
            0 => {},
            os.EFAULT, os.EINVAL => zuma.Thread.AffinityError.InvalidCpuSet,
            os.EPERM => zuma.Thread.AffinityError.InvalidState,
            os.ESRCH => unreachable,
            else => unreachable,
        };
    }

    pub fn getAffinity(cpu_set: *CpuSet) zuma.Thread.AffinityError!void {
        const tid = linux.syscall0(linux.SYS_gettid);
        return switch (os.errno(linux.syscall3(linux.SYS_sched_getaffinity, tid, @sizeOf(CpuSet), @ptrToInt(cpu_set)))) {
            0 => {},
            os.EFAULT, os.EINVAL => zuma.Thread.AffinityError.InvalidCpuSet,
            os.EPERM => zuma.Thread.AffinityError.InvalidState,
            os.ESRCH => unreachable,
            else => unreachable,
        };
    }

    fn toTimespec(ms: u32) linux.timespec {
        return linux.timespec {
            .tv_sec = @intCast(isize, ms / 1000),
            .tv_nsec = @intCast(isize, (ms % 1000) * 1000000),
        };
    }
};