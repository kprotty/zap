const std = @import("std");
const Affinity = @import("./thread.zig").Thread.Affinity;

pub const Node = switch (std.builtin.os.tag) {
    .linux => @import("../linux/node.zig").Node,
    else => struct {
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
                .affinity = Affinity{
                    .num_threads = 1,
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
            default_topology[0].affinity.num_threads = try std.Thread.cpuCount();
            return default_topology[0..];
        }
    },
};