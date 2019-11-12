const std = @import("std");
const posix = @import("./posix.zig");
const linux = std.os.linux;

pub const getRandom = posix.getRandom;

pub fn map(numa_node: u16, bytes: usize) ![]align(std.mem.page_size) u8 {
    
}

pub fn decommit(memory: []u8) void {

}

pub fn unmap(memory: []align(std.mem.page_size) u8) void {

}

pub const Thread = struct {
    pub fn exit() void {
        
    }

    pub fn getStackSize(comptime func: var) usize {

    }

    pub fn setAffinity(affinity: CpuAffinity) void  {

    }

    pub fn spawn(stack: []u8, param: var, comptime func: var) !void {

    }
};

pub const CpuAffinity = struct {
    offset: usize,
    mask: usize,

    pub fn getNodeCount() usize {

    }

    pub fn get(numa_node: u16) !CpuAffinity {

    }
};

pub const Reactor = enum {
    uring: UringReactor,
    epoll: posix.Reactor(EpollBackend),
    
    pub fn init() Reactor {
        
    }
};