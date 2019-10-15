const std = @import("std");
const posix = @import("posix.zig");
const builtin = @import("builtin");

const zio = @import("../../zap.zig").zio;
const zync = @import("../../../zap.zig").zync;
const zuma = @import("../../../zap.zig").zuma;

const os = std.os;
const linux = os.linux;

/// More ergonomic equivalent of std.os.linux.cpu_set_t
const cpu_set_t = struct {
    const byte_size = 128;
    const bits = @typeInfo(usize).Int.bits;
    bitmask: [byte_size / @sizeOf(usize)]usize,

    pub fn count(self: @This()) usize {
        var sum: usize = 0;
        for (self.bitmask) |word|
            sum += zync.popCount(word);
        return sum;
    }

    pub fn get(self: @This(), index: usize) bool {
        if (index / bits >= self.bitmask.len)
            return false;
        const mask = usize(1) << @truncate(zync.shrType(usize), index % bits);
        return (self.bitmask[index / bits] & mask) != 0;
    }

    pub fn set(self: *@This(), index: usize, is_set: bool) void {
        if (index / bits >= self.bitmask.len)
            return;
        const mask = usize(1) << @truncate(zync.shrType(usize), index % bits);
        if (is_set) {
            self.bitmask[index / bits] |= mask;
        } else {
            self.bitmask[index / bits] &= ~mask;
        }
    }

    pub fn fromCpuAffinity(cpu_affinity: zuma.CpuAffinity) @This() {
        var self: @This() = undefined;
        std.mem.set(usize, self.bitmask[0..], 0);
        self.bitmask[cpu_affinity.group] = cpu_affinity.mask;
        return self;
    }

    pub fn toCpuAffinity(self: @This()) zuma.CpuAffinity {
        var cpu_affinity: zuma.CpuAffinity = undefined;
        for (self.bitmask) |word, index| {
            if (word != 0) {
                cpu_affinity.group = index;
                cpu_affinity.mask = word;
                return cpu_affinity;
            }
        }
        cpu_affinity.clear();
        return cpu_affinity;
    }
};

pub const CpuAffinity = struct {
    pub fn getNodeCount() usize {
        // data in the format of many? "{node_start}-{node_end}"
        var data = readFile(c"/sys/devices/system/node/online") catch return 1;
        var node_count: usize = 0;
        while (readInt(&data)) |start|
            node_count += ((readInt(&data) orelse start) + 1) - start;
        return node_count;
    }

    pub fn getCpuCount(numa_node: ?usize, only_physical_cpus: bool) zuma.CpuAffinity.TopologyError!usize {
        // get the linux cpu set and count the number of bits
        const cpu_set = try getCpuSet(numa_node, only_physical_cpus);
        return cpu_set.count();
    }

    pub fn getCpus(self: *zuma.CpuAffinity, numa_node: ?usize, only_physical_cpus: bool) zuma.CpuAffinity.TopologyError!void {
        // get the linux cpu set and find the first word with set bits
        const cpu_set = try getCpuSet(numa_node, only_physical_cpus);
        self.* = cpu_set.toCpuAffinity();
    }

    fn getCpuSet(numa_node: ?usize, only_physical_cpus: bool) zuma.CpuAffinity.TopologyError!cpu_set_t {
        var cpu_set: cpu_set_t = undefined;
        std.mem.set(usize, cpu_set.bitmask[0..], 0);

        // fetch the cpu_set_t for a given numa node
        if (numa_node) |node| {
            getNumaCpuSet(node, &cpu_set) catch |err| return switch (err) {
                error.InvalidPath => zuma.CpuAffinity.TopologyError.InvalidNode,
                error.InvalidRead => zuma.CpuAffinity.TopologyError.InvalidResourceAccess,
            };

            // fetch all the of the cpu's set for the current process
        } else {
            const current_process = 0;
            const cpu_set_ptr = @ptrCast(*linux.cpu_set_t, &cpu_set);
            const result = linux.sched_getaffinity(current_process, @sizeOf(cpu_set_t), cpu_set_ptr);
            if (linux.getErrno(result) != 0)
                return zuma.CpuAffinity.TopologyError.InvalidResourceAccess;
        }

        // filter out set cpu_set_t bits to physical cpus if required
        if (only_physical_cpus) {
            for (cpu_set.bitmask) |word, index| {
                var bits = word;
                var pos: zync.shrType(usize) = undefined;
                while (bits != 0) : (bits ^= usize(1) << pos) {
                    pos = @truncate(@typeOf(pos), @ctz(usize, ~bits) - 1);
                    const bit = usize(pos) + (index * @typeInfo(usize).Int.bits);
                    if (!isPhysicalCpu(bit))
                        cpu_set.set(bit, false);
                }
            }
        }
        return cpu_set;
    }

    fn isPhysicalCpu(cpu: usize) bool {
        // data in format of "{physical_cpu},{sibling_cpu}"
        var data = readFile(c"/sys/devices/system/cpu/cpu{}/topology/thread_siblings_list", cpu) catch return false;
        if (readInt(&data)) |physical_cpu|
            return cpu == physical_cpu;
        return false;
    }

    fn getNumaCpuSet(numa_node: usize, cpu_set: *cpu_set_t) !void {
        // data is in the format of many? "{cpu_start}-{cpu_end}"
        var data = try readFile(c"/sys/devices/system/node/node{}/cpulist", numa_node);
        while (readInt(&data)) |start| {
            cpu_set.set(start, true);
            var end = readInt(&data) orelse start;
            while (end != start) : (end -= 1)
                cpu_set.set(end, true);
        }
    }
};

pub const Thread = if (builtin.link_libc) posix.Thread else struct {
    pub const Handle = *i32;

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
        return computeStackSize(function);
    }

    pub fn create(stack: ?[]align(zuma.page_size) u8, comptime function: var, parameter: var) zuma.Thread.CreateError!Handle {
        var tls_offset: usize = 0;
        var tid_offset: usize = 0;
        var stack_offset: usize = 0;
        const stack_size = computeStackSize(function, &tid_offset, &tls_offset, &stack_offset);

        const memory = stack orelse return zuma.Thread.CreateError.InvalidStack;
        if (memory.len < stack_size)
            return zuma.Thread.CreateError.InvalidStack;

        var clone_flags: u32 = os.CLONE_VM | os.CLONE_FS | os.CLONE_FILES |
            os.CLONE_CHILD_CLEARTID | os.CLONE_PARENT_SETTID |
            os.CLONE_THREAD | os.CLONE_SIGHAND | os.CLONE_SYSVSEM;
        if (linux.tls.tls_image) |tls_image| {
            clone_flags |= os.CLONE_SETTLS;
            tls_offset = linux.tls.copyTLS(@ptrToInt(&memory[tls_offset]));
        }

        const Parameter = @typeOf(parameter);
        const Wrapper = struct {
            extern fn entry(arg: usize) u8 {
                _ = function(zuma.transmute(Parameter, arg));
                return 0;
            }
        };

        const arg = zuma.transmute(usize, parameter);
        const stack_ptr = @ptrToInt(&memory[stack_offset]);
        const tid = @ptrCast(*i32, @alignCast(@alignOf(*i32), &memory[tid_offset]));
        return switch (os.errno(linux.clone(Wrapper.entry, stack_ptr, clone_flags, arg, tid, tls_offset, tid))) {
            0 => tid,
            os.EPERM, os.EINVAL, os.ENOSPC, os.EUSERS => unreachable,
            os.EAGAIN => zuma.Thread.CreateError.TooManyThreads,
            os.ENOMEM => zuma.Thread.CreateError.OutOfMemory,
            else => unreachable,
        };
    }

    fn computeStackSize(comptime function: var, offsets: ...) usize {
        // pid offset
        var size: usize = 0;
        if (offsets.len > 0)
            offsets[0].* = size;
        size += @sizeOf(i32);

        // tls offset
        if (linux.tls.tls_image) |tls_image| {
            size = std.mem.alignForward(size, @alignOf(usize));
            if (offsets.len > 1)
                offsets[1].* = size;
            size += tls_image.alloc_size;
        }

        // stack offset
        size = std.mem.alignForward(size, zuma.page_size);
        if (offsets.len > 2)
            offsets[2].* = size;
        size = std.mem.alignForward(size, @alignOf(@Frame(function)));
        size += @sizeOf(@Frame(function));
        return size;
    }

    pub fn join(handle: Handle, timeout_ms: ?u32) zuma.Thread.JoinError!void {
        var ts: linux.timespec = if (timeout_ms) |t| toTimespec(t) else undefined;
        const timeout = if (timeout_ms) |_| &ts else null;
        const value = @atomicLoad(i32, handle, .Monotonic);
        if (value == 0)
            return;
        return switch (os.errno(linux.futex_wait(handle, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, value, timeout))) {
            0, os.EINTR, os.EAGAIN => {},
            os.ETIMEDOUT => zuma.Thread.JoinError.TimedOut,
            os.EINVAL, os.EPERM, os.ENOSYS, os.EDEADLK => unreachable,
            else => unreachable,
        };
    }

    pub fn setAffinity(cpu_affinity: zuma.CpuAffinity) zuma.Thread.AffinityError!void {
        var cpu_set = cpu_set_t.fromCpuAffinity(cpu_affinity);
        const tid = linux.syscall0(linux.SYS_gettid);
        const result = linux.syscall3(linux.SYS_sched_setaffinity, tid, @sizeOf(cpu_set_t), @ptrToInt(&cpu_set));
        return switch (os.errno(result)) {
            0 => {},
            os.EFAULT, os.EINVAL => zuma.Thread.AffinityError.InvalidCpuAffinity,
            os.EPERM => zuma.Thread.AffinityError.InvalidState,
            os.ESRCH => unreachable,
            else => unreachable,
        };
    }

    pub fn getAffinity(cpu_affinity: *zuma.CpuAffinity) zuma.Thread.AffinityError!void {
        var cpu_set: cpu_set_t = undefined;
        const tid = linux.syscall0(linux.SYS_gettid);
        const result = linux.syscall3(linux.SYS_sched_getaffinity, tid, @sizeOf(cpu_set_t), @ptrToInt(&cpu_set));
        return switch (os.errno(result)) {
            0 => cpu_affinity.* = cpu_set.toCpuAffinity(),
            os.EFAULT, os.EINVAL => zuma.Thread.AffinityError.InvalidCpuAffinity,
            os.EPERM => zuma.Thread.AffinityError.InvalidState,
            os.ESRCH => unreachable,
            else => unreachable,
        };
    }

    fn toTimespec(ms: u32) linux.timespec {
        return linux.timespec{
            .tv_sec = @intCast(isize, ms / 1000),
            .tv_nsec = @intCast(isize, (ms % 1000) * 1000000),
        };
    }
};

pub fn getPageSize() ?usize {
    const map_size_kb = readValue(c"/proc/meminfo", "Mapped:"[0..]) catch |_| return null;
    const map_size = readValue(c"/proc/vmstat", "nr_mapped:"[0..]) catch |_| return null;
    return map_size_kb / map_size;
}

pub fn getHugePageSize() ?usize {
    const huge_page_size_kb = readValue(c"/proc/meminfo", "Hugepagesize:"[0..]) catch |_| return null;
    return huge_page_size_kb * 1024;
}

pub fn getNodeAvailableMemory(numa_node: usize) zuma.NumaError!usize {
    const value = readValue(c"/sys/devices/system/node/node{}/meminfo", "MemTotal:"[0..], numa_node);
    const bytes_kb = value catch |_| return zuma.NumaError.InvalidNode;
    return bytes_kb * 1024;
}

const MADV_FREE = 8;
const MPOL_BIND = 2;
const MPOL_DEFAULT = 0;
const MPOL_PREFERRED = 1;

pub fn map(address: ?[*]u8, bytes: usize, flags: u32, numa_node: ?usize) zuma.MemoryError![]align(zuma.page_size) u8 {
    // map the memory into the address space
    var map_flags: u32 = linux.MAP_PRIVATE | linux.MAP_ANONYMOUS;
    if ((flags & zuma.PAGE_HUGE) != 0)
        map_flags |= linux.MAP_HUGETLB;
    const addr = linux.mmap(address, bytes, getProtectFlags(flags), map_flags, -1, 0);
    switch (linux.getErrno(addr)) {
        0 => {},
        os.ENOMEM => return zuma.MemoryError.OutOfMemory,
        os.EINVAL => return zuma.MemoryError.InvalidAddress,
        os.EACCES, os.EAGAIN, os.EBADF, os.EEXIST, os.ENODEV, os.ETXTBSY, os.EOVERFLOW => unreachable,
        else => unreachable,
    }

    // try and bind the address range memory to a (preferred) numa node
    if (numa_node) |node| {
        var node_mask: [32]c_ulong = undefined;
        const bits = @typeInfo(c_ulong).Int.bits;
        std.mem.set(c_ulong, node_mask[0..], 0);
        node_mask[node / bits] = c_ulong(1) << @truncate(zync.shrType(c_ulong), node % bits);

        const result = linux.syscall6(linux.SYS_mbind, addr, bytes, MPOL_PREFERRED, @ptrToInt(node_mask[0..].ptr), node_mask.len, 0);
        switch (linux.getErrno(result)) {
            0 => {},
            os.ENOMEM => return zuma.MemoryError.OutOfMemory,
            os.EINVAL => return zuma.MemoryError.InvalidNode,
            os.EFAULT, os.EIO, os.EPERM => unreachable,
            else => unreachable,
        }
    }

    return @intToPtr([*]align(zuma.page_size) u8, addr)[0..bytes];
}

pub fn unmap(memory: []u8, node: ?usize) void {
    _ = linux.munmap(memory.ptr, memory.len);
}

pub fn modify(memory: []u8, flags: u32, node: ?usize) zuma.MemoryError!void {
    const protect_flags = getProtectFlags(flags);
    if (protect_flags != 0) {
        switch (linux.getErrno(linux.mprotect(memory.ptr, memory.len, protect_flags))) {
            0 => {},
            os.EACCES => return zuma.MemoryError.InvalidMemory,
            os.EINVAL => return zuma.MemoryError.InvalidAddress,
            os.ENOMEM => return zuma.MemoryError.OutOfMemory,
            else => unreachable,
        }
    }

    switch (flags & (zuma.PAGE_COMMIT | zuma.PAGE_DECOMMIT)) {
        zuma.PAGE_COMMIT | zuma.PAGE_DECOMMIT => return zuma.MemoryError.InvalidFlags,
        zuma.PAGE_DECOMMIT => {
            while (true) {
                const result = linux.syscall3(linux.SYS_madvise, @ptrToInt(memory.ptr), memory.len, MADV_FREE);
                switch (linux.getErrno(result)) {
                    0 => break,
                    os.EINVAL => return zuma.MemoryError.InvalidAddress,
                    os.ENOMEM => return zuma.MemoryError.OutOfMemory,
                    os.EACCES, os.EIO, os.EPERM => unreachable,
                    os.EAGAIN => continue,
                    else => unreachable,
                }
            }
        },
        else => {},
    }
}

fn getProtectFlags(flags: u32) usize {
    var protect_flags: usize = 0;
    if ((flags & zuma.PAGE_EXEC) != 0)
        protect_flags |= linux.PROT_EXEC;
    if ((flags & zuma.PAGE_READ) != 0)
        protect_flags |= linux.PROT_READ;
    if ((flags & zuma.PAGE_WRITE) != 0)
        protect_flags |= linux.PROT_WRITE;
    return protect_flags;
}

fn readValue(comptime format: [*]const u8, comptime header: []const u8, format_args: ...) !usize {
    var data = try readFile(format, format_args);
    const offset = std.mem.indexOf(u8, data, header) orelse return error.InvalidValue;
    data = data[(offset + header.len)..];
    return readInt(&data) orelse return error.InvalidValue;
}

threadlocal var buffer: [4096]u8 = undefined;
fn readFile(comptime format: [*]const u8, format_args: ...) ![]const u8 {
    // TODO: https://github.com/ziglang/zig/issues/3433
    const buf = @intToPtr([*]u8, @ptrToInt(&buffer[0]))[0..buffer.len];
    const format_str = format[0..(comptime std.mem.len(u8, format) + 1)];
    const path = std.fmt.bufPrint(buf[0..], format_str, format_args) catch |_| return error.InvalidPath;

    // open the file in read-only mode. Will only return a constant slice to the buffer
    const fd = linux.syscall2(linux.SYS_open, @ptrToInt(path.ptr), linux.O_RDONLY | linux.O_CLOEXEC);
    if (linux.getErrno(fd) != 0)
        return error.InvalidPath;
    defer _ = linux.syscall1(linux.SYS_close, fd);

    // read as much content from the file as possible
    const length = linux.syscall3(linux.SYS_read, fd, @ptrToInt(buf.ptr), buf.len);
    if (linux.getErrno(length) != 0)
        return error.InvalidRead;
    return buf[0..length];
}

fn readInt(input: *[]const u8) ?usize {
    // update the input after reading
    var pos: usize = 0;
    const source = input.*;
    defer input.* = source[pos..];

    // skip non integer characters
    while (pos < source.len and !(source[pos] >= '0' and source[pos] <= '9'))
        pos += 1;
    if (pos >= source.len)
        return null;

    // read the number
    var number: usize = 0;
    while (pos < source.len and (source[pos] >= '0' and source[pos] <= '9')) : (pos += 1)
        number = (number * 10) + usize(source[pos] - '0');
    return number;
}
