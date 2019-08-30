const std = @import("std");
const builtin = @import("builtin");
const Task = @import("sched.zig").Node.Task;

const os = std.os;
const system = os.system;

pub const Backend = switch (builtin.os) {
    .windows => WinSock,
    else => PosixSocket,
};

pub const Socket = struct {

};

const IoStream = struct {
    pub const Readable   = u2(0b01);
    pub const Writeable  = u2(0b10);
    pub const Disposable = u2(0b00);

    reader: Event,
    writer: Event,

    pub fn init(self: *@This()) void {
        self.reader.init();
        self.writer.init();
    }

    pub fn signal(self: *@This(), flags: u2, data: u32) ?*Task {
        var reader_task: ?*Task = null;
        var writer_task: ?*Task = null;

        if (flags == Disposable) {
            writer_task = self.writer.signal(Event.Close);
            reader_task = self.reader.signal(Event.Close)
        } else {
            if ((flags & Writeable) != 0)
                writer_task = self.writer.signal(Event.EncodeReady(data));
            if ((flags & Readable) != 0)
                reader_task = self.reader.signal(Event.EncodeReady(data));  
        }

        // return any tasks found. Try and link them together if theres multiple.
        if (writer_task) |task|
            task.link = reader_task;
        return writer_task orelse reader_task;
    }

    const Event = struct {
        /// Thread safe mechanism for event notification and task wakeup.
        /// `state` begins as "Empty" and event pollers signal by setting it to either "Close" or "Ready".
        /// Under "Ready", the upper bits are used as a hint to the IO waiting for event for how many bytes to use.
        /// The upper bits are set only on kevent as they cant be used to know exactly how many bytes to read as an optimization.
        /// If an IO operation fails to consume a "Close" or "Ready" event, it then starts to suspend.
        /// Once suspended, it tries and to consume the event once more just in case it was set during the process.
        /// If that fails as well, the `state` is set to "Waiting" indicating that the upper bits represent a `Task` pointer.
        /// NOTE: The reason these tag states are 2-bits large is that maximum value we can fit into a 32bit or 64bit aligned pointer. 
        pub const Empty   = usize(0b11);
        pub const Close   = usize(0b10);
        pub const Ready   = usize(0b01);
        pub const Waiting = usize(0b00);
        state: usize,

        pub fn init(self: *@This()) void {
            self.state = Empty;
        }

        pub inline fn EncodeReady(data: u32) usize {
            return (@intCast(usize, data) << 2) | Ready;
        }

        pub inline fn DecodeReady(data: usize) u32 {
            return @truncate(u32, data >> 2);
        }

        pub fn signal(self: *@This(), data: usize) ?*Task {
            // PRODUCER: update the state & return a Task if there was any waiting 
            @fence(.Release);
            const state = @atomicRmw(usize, &self.state, .Xchg, data, .Monotonic);
            return if ((state & 0b11) == Waiting) @intToPtr(*Task, state) else null;
        }

        fn consumeSignalWith(self: *@This(), update: usize) !?usize {
            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                switch ((state & 0b11)) {
                    Empty => return null,
                    Waiting => return error.ContendedWaiting,
                    Ready, Close => if (@cmpxchgWeak(usize, &self.state, state, update, .Monotonic, .Monotonic)) |new_state| {
                        state = new_state;
                        continue;
                    } else return state,
                    else => unreachable,
                }
                @fence(.Acquire);
            }
        }

        pub async fn wait(self: *@This()) !?u32 {
            while (true) {
                // CONSUMER: try and consume an event without blocking
                if (try consumeSignalWith(Empty)) |state|
                    return if ((state & 0b11) == Ready) DecodeReady(state) else null;

                // no event was found, try and suspend / reschedule until it is woken up by `signal()`
                // check once more if an event was set during the suspend block before rescheduling
                var result: !?usize = null;
                suspend {
                    var task = Task { .link = null, .frame = @frame() };
                    if (consumeSignalWith(@ptrToInt(task.frame) | Waiting) catch |e| {
                        result = e;
                        resume task.frame;
                    }) |state| {
                        result = state;
                        resume task.frame;
                    } else {
                        task.reschedule();
                    }
                }

                // try and return a result if it was set, else jump back and try to consume the event again
                if (try result) |state|
                    return if ((state & 0b11) == Ready) DecodeReady(state) else null;
            }
        }
    };
};

