const std = @import("std");
const linux = std.os.linux;
const Affinity = @import("./thread.zig").Thread.Affinity;

const MADV_FREE = 8;
const MPOL_BIND = 2;
const MPOL_DEFAULT = 0;
const MPOL_PREFERRED = 1;

pub const Node = struct {
    numa_id: ?u16,
    affinity: Affinity,

    pub fn alloc(
        self: Node,
        comptime alignment: u29,
        bytes: usize,
    ) ?[]align(alignment) u8 {
        // TODO: mimalloc-style allocator backed by map()
        const addr = self.map(bytes) orelse return null;
        return @alignCast(alignment, addr)[0..bytes];
    }

    pub fn free(
        self: Node,
        comptime alignment: u29,
        memory: []align(alignment) u8,
    ) void {
        // TODO: mimalloc-style deallocator backed by unmap()
        const addr = @alignCast(std.mem.page_size, memory.ptr);
        return self.unmap(addr, memory.len);
    }

    fn map(
        self: Node,
        bytes: usize,
    ) ?[*]align(std.mem.page_size) u8 {
        const memory = std.os.mmap(
            null,
            bytes,
            std.os.PROT_READ | std.os.PROT_WRITE,
            std.os.MAP_PRIVATE | std.os.MAP_ANONYMOUS,
            -1,
            0,
        ) catch return null;

        if (self.numa_id) |numa_node| {
            var node_mask: [1 << @typeInfo(u16).Int.bits]u8 align(@alignOf(c_long)) = undefined;
            node_mask = std.mem.zeroes(@TypeOf(node_mask));
            node_mask[numa_node / 8] |= @as(u8, 1) << @intCast(std.math.Log2Int(u8), numa_node % 8);

            const flags = 0;
            const rc = linux.syscall6(
                .mbind,
                @ptrToInt(memory.ptr),
                memory.len,
                MPOL_PREFERRED,
                @ptrToInt(&node_mask[0]),
                node_mask.len / @sizeOf(c_ulong),
                flags,
            );

            switch (linux.getErrno(rc)) {
                0 => {},
                linux.ENOMEM => {
                    std.os.munmap(memory);
                    return null;
                },
                linux.EINVAL => unreachable,
                linux.EFAULT => unreachable,
                linux.EIO => unreachable,
                linux.EPERM => unreachable,
                else => unreachable,
            }
        }
        
        return memory.ptr;
    }

    fn unmap(
        self: Node,
        addr: [*]align(std.mem.page_size) u8,
        bytes: usize,
    ) void {
        const memory = addr[0..bytes];
        std.os.munmap(memory);
    }

    var has_cached = false;
    var cached_lock = std.Mutex.init();
    var cached_topology: []Node = undefined;
    var default_topology = [_]Node{
        Node{
            .numa_id = null,
            .affinity = Affinity{
                .begin = 0,
                .end = 0,
            },
        },
    };

    pub fn getTopology() []Node {
        if (@atomicLoad(bool, &has_cached, .Acquire))
            return cached_topology;

        const held = cached_lock.acquire();
        defer held.release();

        if (@atomicLoad(bool, &has_cached, .Acquire))
            return cached_topology;

        cached_topology = getSystemTopology() catch default_topology[0..];
        @atomicStore(bool, &has_cached, true, .Release);
        return cached_topology;
    }

    fn getSystemTopology() ![]Node {
        var num_nodes: usize = 0;
        var nodes = try std.heap.page_allocator.alloc(Node, 1 << @typeInfo(u16).Int.bits);
        errdefer std.heap.page_allocator.free(nodes);

        var end: u16 = undefined;
        var begin: u16 = undefined;
        var buffer: [1024]u8 = undefined;
        var buf = try read(buffer[0..], "/sys/devices/system/node/has_cpu", .{});

        while (readRange(&buf, &begin, &end)) {
            if (begin > end)
                continue;
            while (begin <= end) : (begin += 1) {
                const numa_id = begin;
                var cpu_end: u16 = undefined;
                var cpu_begin: u16 = undefined;
                var cpu_buffer: [1024]u8 = undefined;
                var cpu_buf = try read(cpu_buffer[0..], "/sys/devices/system/node/node{}/cpulist", .{numa_id});

                while (readRange(&cpu_buf, &cpu_begin, &cpu_end)) {
                    if (cpu_begin > cpu_end)
                        continue;
                    defer num_nodes += 1;
                    nodes[num_nodes] = Node{
                        .numa_id = numa_id,
                        .affinity = Affinity{
                            .begin = cpu_begin,
                            .end = cpu_end,
                        },
                    };
                }
            }
        }

        return nodes[0..num_nodes];
    }

    fn read(buffer: []u8, comptime fmt: []const u8, args: var) ![]u8 {
        const path = try std.fmt.bufPrint(buffer, fmt ++ "\x00", args);

        const fd = linux.syscall2(.open, @ptrToInt(path.ptr), linux.O_RDONLY | linux.O_CLOEXEC);
        if (linux.getErrno(fd) != 0)
            return error.InvalidPath;
        defer {
            const rc = linux.syscall1(.close, fd);
            std.debug.assert(linux.getErrno(fd) == 0);
        }

        const len = linux.syscall3(.read, fd, @ptrToInt(buffer.ptr), buffer.len);
        if (linux.getErrno(len) != 0)
            return error.InvalidRead;
        return buffer[0..len];
    }

    fn readRange(buffer: *[]const u8, begin: *u16, end: *u16) bool {
        var buf = buffer.*;
        defer buffer.* = buf;

        while (buf.len != 0 and !(buf[0] >= '0' and buf[0] <= '9'))
            buf = buf[1..];        
        if (buf.len == 0)
            return false;

        var value: u16 = 0;
        while (buf.len != 0 and buf[0] >= '0' and buf[0] <= '9') {
            value = (value * 10) + @as(u16, buf[0] - '0');
            buf = buf[1..];
        }
        begin.* = value;
        if (buf.len == 0) {
            end.* = value;
            return true;
        }

        while (buf.len != 0 and !(buf[0] >= '0' and buf[0] <= '9'))
            buf = buf[1..];        
        if (buf.len == 0) {
            end.* = value;
            return true;
        }

        value = 0;
        while (buf.len != 0 and buf[0] >= '0' and buf[0] <= '9') {
            value = (value * 10) + @as(u16, buf[0] - '0');
            buf = buf[1..];
        }
        end.* = value;
        return true;
    }
};