
pub const Task = struct {
    next: ?*Task = undefined,
    frame: usize,

    pub fn init(frame: anyframe) Task {
        return Task{ .frame = @ptrToInt(frame) };
    }

    inline fn run(self: *Task) void {
        resume blk: {
            @setRuntimeSafety(false);
            break :blk @intToPtr(anyframe, self.frame);
        };
    }

    pub const Batch = struct {
        head: ?*Task = null,
        tail: *Task = undefined,
    };
};

pub const Worker = struct {
    pool: *Pool,
    state: usize = undefined,
    target: ?*Worker = null,
    active_next: ?*Worker = null,
    run_queue: BoundedQueue = BoundedQueue{},
    run_queue_next: ?*Task = null,
    run_queue_lifo: ?*Task = null,
    run_queue_overflow: UnboundedQueue = UnboundedQueue{},

    pub const ScheduleHint = enum {
        next,
        lifo,
        fifo,
        yield,
    };

    pub fn schedule(self: *Worker, hint: ScheduleHint, batchable: anytype) void {

    }

    fn run(pool: *Pool, is_coordinator: bool) void {

    }

    fn poll(self: *Worker) ?*Task {
        var tick = self.state >> 1;
        var is_waking = self.state & 1 != 0; 
        const task = self.pollRunnable(tick) orelse return null;

        if (is_waking) {
            self.pool.notify(is_waking);
            is_waking = false;
        }

        tick += 1;
        if (tick >= ~@as(usize, 0) >> 1)
            tick = 0;

        self.state = (tick << 1) | @boolToInt(is_waking);
        return task;
    }

    fn pollRunnable(self: *Worker, tick: usize) ?*Task {

    }
};

pub const Pool = struct {
    max_workers: u16,
    idle_queue: u32 = 0,
    active_queue: ?*Worker = null,
    run_queue: UnboundedQueue = UnboundedQueue{},
    
    const IdleQueue = struct {
        idle: u16 = 0,
        spawned: u16 = 0,
        state: State = .pending,

        const State = enum(u4) {
            pending = 0,
            notified,
            waking,
            waker_notified,
            shutdown,
        };

        fn pack(self: IdleQueue) u32 {
            var value: u32 = 0;
            value |= @enumToInt(self.state);
            value |= @as(u32, @intCast(u14, self.idle)) << 4;
            value |= @as(u32, @intCast(u14, self.spawned)) << (14 + 4);
            return value;
        }

        fn unpack(value: u32) IdleQueue {
            return IdleQueue{
                .state = @intToEnum(State, @truncate(u4, value)),
                .idle = @truncate(u14, value >> 4),
                .spawned = @truncate(u14, value >> (4 + 14)),
            };
        }
    };

    pub fn run(max_workers: u16, batchable: anytype) !void {

    }

    pub fn schedule(self: *Pool, batchable: anytype) void {

    }
};

const UnboundedQueue = struct {

};

const BoundedQueue = struct {

};

const WaitQueue = struct {
    fn wait(self: *WaitQueue) void {

    }

    fn notify(self: *WaitQueue) void {
        // on wakeup, if shutdown (in pool), then notify again
    }
};