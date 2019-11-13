const std = @import("std");

pub const Executor = struct {
    nodes: []*Node,
    next_node: usize,
    active_tasks: usize,
    active_workers: usize,
};

pub const Node = extern struct {
    // thread pool cache-line
    thread_mutex: u32 align(64),
    free_count: u16,
    num_threads: u16,
    num_workers: u16,
    stack_ptr: u16,
    stack_end: u16,
    stack_size: u16,
    stack_top: ?*usize,
    free_thread: ?*Thread,
    executor: *Executor,
    idle_workers: usize,

    // thread-exit cache-lines
    exit_mutex: u32 align(64),
    exit_stack: [128 - 16]u8 align(16),

    runq_mutex: u32,
    runq_size: u32,
    runq_head: ?*Task,
    runq_tail: ?*Task,
    
};

const Thread = struct {
    pub threadlocal var current: ?*Thread = null;

    next: ?*Thread,
    node: *Node,
    worker: *Worker,


};

const Worker = struct {
    const STACK_ALIGN = 64 * 1024;
    const STACK_SIZE = 4 * 1024 * 1024;

    runq_head: u32,
    runq_tail: u32,
    runq_tick: usize,
    runq_next: ?*Task,
    thread: ?*Thread,
    block_expires: u64,
    node: *Node,
    stack: [*]align(STACK_ALIGN) u8,
    reserved: usize,
};

const Task = struct {
    next: ?*Task,
    frame: anyframe,
};