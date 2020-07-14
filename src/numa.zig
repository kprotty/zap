const std = @import("std");

pub const Node = struct {
    numa_id: u32,
    cpu_begin: u16,
    cpu_end: u16,

    pub fn alloc(self: *Node, bytes: usize) ![]align(std.mem.page_size) u8 {

    }

    pub fn free(self: *Node, memory: []align(std.mem.page_size) u8) void {

    }

    pub fn spawn(self: *Node, worker: *Worker) bool {

    }

    pub fn join(self: *Node) void {

    }
};