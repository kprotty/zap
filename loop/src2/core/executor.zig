const std = @import("std");

pub fn Executor(comptime Platform: type) type {
    /// The CPU cache-line as reported by the given Platform.
    /// This is used to pad atomically accessed types to avoid false sharing.
    ///
    /// https://en.wikipedia.org/wiki/False_sharing
    const CACHE_LINE =
        if (@hasDecl(Platform, "CACHE_LINE")) Platform.CACHE_LINE
        else 64;

    return struct {
        pub const Scheduler = extern struct {
            platform: *Platform,
            nodes_ptr: [*]*Node,
            nodes_len: usize,
            start_node: usize,

            /// Run a scheduler with the platform using the given nodes.
            /// Using the nodes[start_node] (or any node after with workers),
            /// schedule the provided task as the main task and run a worker for it.
            ///
            /// This assumes that all provided nodes have been initialized with Node.prepare() beforehand.
            pub fn run(
                platform: *Platform,
                nodes: []*Node,
                start_node: usize,
                start_task: *Task,
            ) void {
                if (nodes.len == 0)
                    return;

                var self = Scheduler{
                    .platform = platform,
                    .nodes_ptr = nodes.ptr,
                    .nodes_len = nodes.len,
                    .start_node = undefined,
                };

                for (nodes) |node|
                    node.init(&self);
                defer for (nodes) |node|
                    node.deinit();
                
                // Iterate all the nodes starting at the start_node
                // until there is one with idle workers and use that as starting point.
                var i: usize = 0;
                var node_index: usize = start_node;
                while (i < nodes.len) : ({
                    i += 1;
                    node_index +%= 1;
                }) {
                    if (node_index >= nodes.len)
                        node_index = 0;
                    const node = nodes[node_index];
                    self.start_node = node_index;

                    // Found a node with idle runs, use this node to run the main worker.
                    if (node.idle_workers != WORKERS_EMPTY) {
                        const worker = @intToPtr(*Worker, node.idle_workers);
                        node.idle_workers = @ptrToInt(worker.next);
                        node.push(Task.Queue.from(task));
                        
                        // Run a worker from the node using the main thread.
                        var started = false;
                        worker.state = .Searching;
                        platform.emit(Worker.Event{ .Run = &started }, worker);
                        if (!started)
                            worker.state = .Stopped;
                        return;
                    }
                }
            }

            /// Get a slice of the nodes provided in the run() function.
            pub fn nodes(self: Scheduler) []*Node {
                return self.nodes_ptr[0..self.nodes_ptr];
            }

            /// Shutdown all Nodes in the scheduler by 
            /// - setting the state of all suspended workers to stopping
            /// - and having future workers trying to suspend convert their state into stopping.
            pub fn shutdown(self: *Scheduler) void {
                for (self.nodes()) |node|
                    node.shutdown();
            }
        };

        pub const Node = extern struct {
            const WORKERS_EMPTY = 0x0;
            const WORKERS_NOTIFIED = 0x1;
            const WORKERS_STOPPING = 0x2;

            idle_workers: usize align(CACHE_LINE),
            shared_sender: UnboundedSender,
            local_sender: UnboundedSender,
            shared_receiver: UnboundedReceiver,
            local_receiver: UnboundedReceiver,
            scheduler: *Scheduler,
            workers_ptr: [*]*Worker,
            workers_len: usize,

            /// Initialize the node to an empty state using the provided scheduler.
            ///
            /// Warning: prepare() must be called on the Node before hand
            fn init(self: *Node, scheduler: *Scheduler) void {
                self.idle_workers = WORKERS_EMPTY;
                for (self.workers()) |worker|
                    worker.init(self);

                self.shared_receiver.init(&self.shared_sender);
                self.local_receiver.init(&self.local_sender);
                self.scheduler = scheduler;
            }

            /// Tear-down any of the node state that was initialized.
            fn deinit(self: *Node) void {
                defer self.* = undefined;

                for (self.workers()) |worker|
                    worker.deinit();

                self.shared_receiver.deinit(&self.shared_sender);
                self.local_receiver.deinit(&self.local_sender);
            }

            /// The user must call this function on the node to prepare it for execution.
            /// The user provides the workers for each node intrusively.
            pub fn prepare(self: *Node, workers: []*Worker) void {
                self.workers_ptr = workers.ptr;
                self.workers_len = workers.len;
            }

            /// Get a slice of the workers set on the node by prepare().
            pub fn workers(self: Node) []*Worker {
                return self.workers_ptr[0..self.workers_len];
            }

            /// Returns true if the nodes's local queue is empty.
            ///
            /// This function can be called from any thread.
            pub fn isLocalEmpty(self: *const Node) bool {
                return self.local_receiver.isEmpty(&self.local_sender);
            }
            
            /// Returns true if the nodes's shared queue is empty.
            ///
            /// This function can be called from any thread.
            pub fn isEmpty(self: *const Node) bool {
                return self.shared_receiver.isEmpty();
            }

            /// Push a batch of tasks into the Node's shared queue.
            ///
            /// This function can be called from any thread.
            pub fn push(self: *Node, batch: Task.Queue) void {
                return self.shared_sender.push(batch);
            }

            /// Push a batch of tasks into the Node's local queue.
            ///
            /// This function can be called from any thread.
            pub fn pushLocal(self: *Node, batch: Task.Queue) void {
                return self.local_sender.push(batch);
            }

            /// Pop a task from the Node's shared queue.
            ///
            /// This function should not be called by multiple threads at the same time.
            pub fn pop(self: *Node) ?*Task {
                return self.shared_receiver.pop();
            }

            /// Pop a task from the Node's local queue.
            ///
            /// This function should not be called by multiple threads at the same time.
            pub fn popLocal(self: *Node) ?*Task {
                return self.local_receiver.pop();
            }

            /// Mark this node as shutdown and try to stop any suspended workers on it.
            fn shutdown(self: *Node) void {
                var idle_workers = @atomicRmw(usize, &self.idle_workers, .Xchg, WORKERS_STOPPING, .Acquire);
                while (true) {
                    switch (idle_workers) {
                        WORKERS_EMPTY, WORKERS_NOTIFIED, WORKERS_STOPPING => return,
                        else => |worker| {
                            _ = worker.tryShutdown();
                            idle_workers = @ptrToInt(worker.next);
                        }
                    }
                }
            }
            
            /// Try to run a worker on the node if there aren't any running already.
            pub fn tryResumeWorker(self: *Node) bool {
                // .Acquire memory ordering required on each iteration
                // since may possibly dereference the worker.next when trying to LIFO dequeue
                // and needs visibility to `worker.next = ` field write in suspendWorker().
                var idle_workers = @atomicLoad(usize, &self.idle_workers, .Acquire);

                while (true) {
                    switch (idle_workers) {
                        // The worker is shutting down. Should not try to resume it.
                        WORKERS_STOPPING => return false,
                        // The worker was already notified via a previous tryResume()
                        WORKERS_NOTIFIED => return false,
                        // No workers were observed in the idle queue.
                        // Set a notification so that the resume signal doesnt get lost.
                        WORKERS_EMPTY => idle_workers = @cmpxchgWeak(
                            usize,
                            &self.idle_workers,
                            WORKERS_EMPTY,
                            WORKERS_NOTIFIED,
                            .Acquire,
                            .Acquire,
                        ) orelse return true,
                        // Found an idle worker in the queue.
                        // Try to dequeue it and resume it.
                        else => {
                            const worker = @intToPtr(*Worker, idle_workers);
                            idle_workers = @cmpxchgWeak(
                                usize,
                                &self.idle_workers,
                                idle_workers,
                                @ptrToInt(worker.next),
                                .Acquire,
                                .Acquire,
                            ) orelse blk: {
                                if (worker.tryResume())
                                    return true;
                                break :blk @atomicLoad(usize, &self.idle_workers, .Acquire);
                            };
                        }
                    }
                }
            }

            /// Try to suspend the worker on the node if possible.
            pub fn trySuspendWorker(self: *Node, worker: *Worker) bool {
                var idle_workers = @atomicLoad(usize, &self.idle_workers, .Monotonic);

                while (true) {
                    switch (idle_workers) {
                        // The node is trying to shutdown, mark the worker as appropriate.
                        WORKERS_STOPPING => {
                            @atomicStore(State, &worker.state, .Stopping, .Monotonic);
                            return false;
                        },
                        // There was a previous tryResumeWorker() call on an empty idle queue.
                        // It left a notification to make sure the signal doesn't get lost.
                        // Consume the notification and retry the worker search again.
                        WORKERS_NOTIFIED => idle_workers = @cmpxchgWeak(
                            usize,
                            &self.idle_workers,
                            WORKERS_NOTIFIED,
                            WORKERS_EMPTY,
                            .Monotonic,
                            .Monotonic,
                        ) orelse {
                            @atomicStore(State, &worker.state, .Searching, .Monotonic);
                            return false;
                        },
                        // Try to enqueue the worker onto the idle list, then try to suspend it.
                        // .Release memory ordering to make sure the worker.next write is visible to tryResumeWorker() thread.
                        else => {
                            worker.next = @ptrToInt(?*Worker, idle_workers);
                            idle_workers = @cmpxchgWeak(
                                usize,
                                &self.idle_workers,
                                idle_workers,
                                @ptrToInt(worker),
                                .Release,
                                .Monotonic,
                            ) orelse return worker.trySuspend();
                        }
                    }
                }
            }
        };

        pub const Worker = extern struct {
            pub const Event = union(enum) {
                Run: bool,
                Poll: *?*Task,
                Resume: void,
                Suspend: void,
                Execute: *Task,
            };

            pub const State = extern enum(usize) {
                Stopped,
                Stopping,
                Suspended,
                Notified,
                Searching,
                Running,
            };

            runq_pos: BoundedPos,
            state: State align(CACHE_LINE),
            local_sender: UnboundedSender,
            local_receiver: UnboundedReceiver,
            runq_buffer: BoundedBuffer,
            node: *Node,
            next: ?*Worker,

            /// Intiailize the worker state to empty using the node.
            fn init(self: *Worker, node: *Node) void {
                self.runq_pos.init(&self.runq_buffer);
                self.state = .Stopped;
                self.local_receiver.init(&self.local_sender);
                self.node = node;
                self.next = @intToPtr(?*Worker, node.idle_workers);
                node.idle_workers = @ptrToInt(self);
            }

            /// Tear-down the state for the Worker.
            fn deinit(self: *Worker) void {
                defer self.* = undefined;
                self.runq_pos.deinit();
                self.local_receiver.deinit(&self.local_sender);
                
                // make sure the worker is stopped on deinit
                if (std.debug.runtime_safety) {
                    const state = @atomicLoad(State, &self.state, .Monotonic);
                    std.debug.assert(state == .Stopped);
                }
            }

            /// Get the current state of the worker.
            pub fn state(self: *const Worker) State {
                return @atomicLoad(State, &self.state, .Monotonic);
            }

            /// Run the workers polling loop, assuming the worker isn't running anywhere else.
            pub fn run(self: *Worker) void {
                const platform = self.node.scheduler.platform;

                // All workers should start running in a searching state as they have no local tasks.
                std.debug.assert(@atomicLoad(State, &self.state, .Monotonic) == .Searching);
                defer {
                    std.debug.assert(@atomicLoad(State, &self.state, .Monotonic) == .Stopping);
                    @atomicStore(State, &self.state, .Stopped, .Monotonic);
                };

                while (true) {
                    // Poll for a task on the platform using the worker as context.
                    @atomicStore(State, &self.state, .Searching, .Monotonic);
                    var task: ?*Task = null;
                    platform.emit(Event{ .Poll = &task }, worker);

                    // Run the found task or stop polling if there was none.
                    const task_ptr = task orelse break;
                    @atomicStore(State, &self.state, .Running, .Monotonic);
                    platform.emit(Event{ .Execute = task_ptr }, worker);
                }
            }
            
            /// Returns true if the worker's local queue is empty.
            ///
            /// This function can be called from any thread.
            pub fn isLocalEmpty(self: *const Worker) bool {
                return self.local_receiver.isEmpty(&self.local_sender);
            }
            
            /// Returns true if the worker's shared queue is empty.
            ///
            /// This function can be called from any thread.
            pub fn isEmpty(self: *const Worker) bool {
                return self.runq_pos.isEmpty();
            }

            /// Try to push a task onto the worker's shared queue on the given Side.
            /// If the shared queue is full, half of its tasks are returned as a Task.Queue
            /// and the provided task is not enqueued into the queue.
            ///
            /// This function should not be called by multiple threads at the same time.
            pub fn push(
                noalias self: *Worker,
                noalias task: *Task,
                side: Task.Queue.Side,
            ) ?Task.Queue {
                return self.runq_pos.push(&self.runq_buffer, task, side);
            }

            /// Push a batch of tasks into the worker's local queue.
            /// This queue cannot be stolen from.
            ///
            /// This function can be called from any thread.
            pub fn pushLocal(self: *Worker, batch: Task.Queue) void {
                return self.local_sender.push(batch);
            }

            /// Pop a task from the worker's shared queue on the given Side.
            ///
            /// This function should not be called by multiple threads at the same time.
            pub fn pop(self: *Worker, side: Task.Queue.Side) ?*Task {
                return self.runq_pos.pop(&self.runq_buffer, side);
            }

            /// Pop a task from the worker's local queue.
            /// This queue cannot be stolen from.
            ///
            /// This function should not be called by multiple threads at the same time.
            pub fn popLocal(self: *Worker) ?*Task {
                return self.local_receiver.pop();
            }

            /// Try to steal a batch of tasks from the target worker's shared queue into our worker's shared queue.
            /// Returns the first task stolen and adds the rest to our worker's queue.
            /// 
            /// This function should not be called by multiple threads at the same time,
            /// but it is safe to perform steal(w1, w2) + steal(w2, w1) at the same time.
            pub fn steal(noalias self: *Worker, noalias target: *Worker) ?*Task {
                return self.runq_pos.steal(
                    &self.runq_buffer,
                    &target.runq_pos,
                    &target.runq_buffer,
                );
            }

            /// Shutdown the worker if its suspended by swapping its state to stopping.
            fn tryShutdown(self: *Worker) bool {
                if (@atomicLoad(State, &self.state, .Monotonic) == .Suspended) {
                    if (@cmpxchgStrong(
                        State,
                        &self.state,
                        .Suspended,
                        .Stopping,
                        .Monotonic,
                        .Monotonic,
                    ) == null) {
                        self.node.scheduler.platform.emit(Event{ .Resume = {} }, self);
                        return true;
                    }
                }

                return false;
            }

            /// Try to transition the worker into a suspended state.
            /// Returns true if this call initiated the worker to suspend.
            fn trySuspend(self: *Worker) bool {
                var state = @atomicLoad(State, &self.state, .Monotonic);

                while (true) {
                    switch (state) {
                        // The worker was tryResumed() and should consume that notification.
                        .Notified => state = @cmpxchgWeak(
                            State,
                            &self.state,
                            .Notified,
                            .Searching,
                            .Monotonic,
                            .Monotonic,
                        ) orelse return false,
                        // The worker was searching and should now try to suspend
                        .Searching => state = @cmpxchgWeak(
                            State,
                            &self.state,
                            .Searching,
                            .Suspended,
                            .Monotonic,
                            .Monotonic,
                        ) orelse {
                            self.node.scheduler.platform.emit(Event{ .Suspend = {} }, self);
                            return true;
                        },
                        // A worker should not suspend if it was running.
                        // Only after .Searching for other tasks should it suspend.
                        .Running => unreachable,
                        // The worker is shutting down. It should not suspend.
                        .Stopping => return false,
                        // A worker cannot be currently running and suspended/stopped at the same time.
                        .Suspended => unreachable,
                        .Stopped => unreachable,
                    }
                }
            }

            /// Try to run a worker if it is not running already.
            /// Returns true if this call initiated the worker to start running.
            pub fn tryResume(self: *Worker) bool {
                var state = @atomicLoad(State, &self.state, .Monotonic);

                while (true) {
                    switch (state) {
                        // The worker isnt running, try to run it using the platform.
                        .Stopped => state = @cmpxchgWeak(
                            State,
                            &self.state,
                            .Stopped,
                            .Searching,
                            .Monotonic,
                            .Monotonic,
                        ) orelse {
                            var started: bool = false;
                            self.node.scheduler.platform.emit(Event{ .Run = &started }, self);
                            if (started)
                                return true;
                            @atomicStore(State, &self.state, .Stopped, .Monotonic);
                            return false;
                        },
                        // The worker is suspended, resume it to search for more tasks.
                        .Suspended => state = @cmpxchgWeak(
                            State,
                            &self.state,
                            .Suspended,
                            .Searching,
                            .Monotonic,
                            .Monotonic,
                        ) orelse {
                            self.node.scheduler.platform.emit(Event{ .Resume = {} }, self);
                            return true;
                        },
                        // The worker is already running, but need to notify it to not suspend.
                        .Searching, .Running => state = @cmpxchgWeak(
                            State,
                            &self.state,
                            state,
                            .Notified,
                            .Monotonic,
                            .Monotonic,
                        ) orelse return true,
                        // The worker is already running and has been notified to resume
                        .Notified => return false,
                        // The worker is trying to shut down.
                        .Stopping => return false,
                    }
                }
            }
        };

        pub const Task = extern struct {
            next: ?*Task,

            pub const Queue = extern struct {
                /// The side of the queue to operate on
                pub const Side = enum {
                    Front,
                    Back,
                };

                head: ?*Task = null,
                tail: ?*Task = null,

                /// Create an empty task queue
                pub fn init() Queue {
                    return Queue{};
                }

                /// Create a task queue with one task.
                pub fn from(task: *Task) Queue {
                    var self = Queue.init();
                    self.push(task);
                    return self;
                }

                /// Returns true if there are no tasks in the queue.
                pub fn isEmpty(self: Queue) bool {
                    return self.head == null;
                }

                /// Enqueue a task at the back of the queue,
                /// effectively transferring ownership of the Task to the Queue.
                pub fn push(self: *Queue, side: Side, task: *Task) void {
                    switch (side) {
                        .Front => {
                            task.next = self.head;
                            if (self.tail == null)
                                self.tail = task;
                            self.head = task;
                        },
                        .Back => {
                            task.next = null;
                            if (self.tail) |tail|
                                tail.next = task;
                            if (self.head == null)
                                self.head = task;
                            self.tail = task;
                        },
                    }
                }

                /// Dequeue a task from the Side.Front of the queue,
                /// effectively transferring ownership of the Task to the caller.
                pub fn pop(self: *Queue) ?*Task {
                    const task = self.head orelse return null;
                    self.head = task.next;
                    if (self.head == null)
                        self.tail = null;
                    return task;
                }
            };
        };

        /// Bare-bones exclusive non-blocking primitive used to guard critical section ownership.
        const Guard = extern struct {
            owned: bool align(CACHE_LINE),

            /// Initialize the guard state.
            pub fn init(self: *Guard) void {
                self.owned = false;
            }

            /// Tear-down the guard state.
            pub fn deinit(self: *Guard) void {
                defer self.* = undefined;
                if (std.debug.runtime_safety)
                    std.debug.assert(!@atomicLoad(bool, &self.owned, .Monotonic));
            }

            /// Try to take ownership of the guard without blocking.
            pub fn tryAcquire(self: *Guard) bool {
                if (@atomicLoad(bool, &self.owned, .Monotonic))
                    return false;
                return switch (std.builtin.arch) {
                    .i386, .x86_64 => asm volatile(
                        "lock btsl $0, %[state]\n" ++
                        "setnc %[bit_is_now_set]"
                        : [bit_is_now_set] "=r" (-> bool)
                        : [state] "*m" (&self.owned)
                        : "cc", "memory"
                    ),
                    else => @cmpxchgStrong(
                        bool,
                        &self.owned,
                        false,
                        true,
                        .Acquire,
                        .Monotonic,
                    ) == null,
                };
            }

            /// Release ownership of the guard.
            pub fn release(self: *Guard) void {
                @atomicStore(bool, &self.owned, false, .Release);
            }
        };

        /// Shared enqueue portion of a Unbounded Multi-Producer-Single-Consumer FIFO queue.
        ///
        /// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
        pub const UnboundedSender = extern struct {
            head: *Task align(CACHE_LINE),

            /// Enqueue a batch of tasks into the unbounded queue
            /// in a wait-free fashion (technically blocking fashion).
            pub fn push(self: *Sender, batch: Task.Queue) void {
                const front = batch.head orelse return;
                const back = batch.tail orelse return;

                // Update the head of the queue with the batch tail,
                // then form the link from the previous head to the batch head.
                //
                // old_head -> batch.head -> batch.tail
                //                           ^ new_head
                //
                // .Acquire memory barrier to observe the .next = null writes from other push() threads.
                // .Release memory barrier to make our .next = null writes visible to push() & pop() threads.
                back.next = null;
                const prev = @atomicRmw(*Task, &self.head, .Xchg, back, .AcqRel);
                @atomicStore(?*Task, &prev.next, front, .Release);
            }
        };

        /// Owned dequeue portion of a Unbounded Multi-Producer-Single-Consumer FIFO queue.
        ///
        /// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue 
        pub const UnboundedReceiver = extern struct {
            tail: *Task,
            stub: Task,

            /// Setup the receiver and sender to an empty state.
            pub fn init(
                noalias self: *UnboundedReceiver,
                noalias sender: *UnboundedSender,
            ) void {
                self.stub = Task{ .next = null };
                self.tail = stub;
                sender.head = stub;
            }

            /// Tear down the receiver and sender states.
            pub fn deinit(
                noalias self: *UnboundedReceiver,
                noalias sender: *UnboundedSender,
            ) void {
                if (std.debug.runtime_safety)
                    std.debug.assert(self.isEmpty());
                self.* = undefined;
                sender.* = undefined;
            }

            /// Returns true if the receiver and sender pair is empty.
            pub fn isEmpty(
                noalias self: *const UnboundedReceiver,
                noalias sender: *const UnboundedSender,
            ) bool {
                const head = @atomicLoad(*Task, &sender.head, .Monotonic);
                return head == &self.stub;
            }

            /// Dequeue a task which was enqueued by the unbounded sender,
            /// returning null if there are no tasks or a push() thread is in the middle of adding one.
            ///
            /// This should only be called by one thread at a time.
            pub fn pop(
                noalias self: *UnboundedReceiver,
                noalias sender: *UnboundedSender,
            ) ?*Task {
                // Loads on the sender.head & task.next use .Acquire memory ordering
                // to make visible the .next = null write in UnboundedSender.push().
                var tail = self.tail;
                var next = @atomicLoad(?*Task, &tail.next, .Acquire);

                // Skip the stub pointer in the queue
                if (tail == &self.stub) {
                    tail = next orelse return null;
                    self.tail = tail;
                    next = @atomicLoad(?*Task, &tail.next, .Acquire);
                }

                // There was a task enqueued, consume it.
                if (next) |next_task| {
                    self.tail = next_task;
                    return tail;
                }

                // A task was added but the link was not made.
                // The sender thread has done the Xchg but not the Store yet.
                // Could spin on the head a bit but its better to suspend later until it becomes visible.
                const head = @atomicLoad(*Task, &sender.head, .Monotonic);
                if (head != tail)
                    return null;
                
                // A new task was added and the link was made.
                // Since we observed that this is the only task,
                // add the stub to the queue so that the head can continuously push.
                sender.push(&self.stub);
                self.tail = @atomicLoad(?*Task, &tail.next, .Acquire) orelse return null;
                return tail; 
            }
        };

        /// A fixed size, wrapping, ring buffer of Task pointers.
        pub const BoundedBuffer = extern struct {
            pub const SIZE = Platform.LOCAL_TASK_BUFFER_SIZE;

            buffer: [SIZE]*Task,

            /// Read a task from the buffer wrapping the index to fit the buffer size.
            pub fn read(
                self: *const BoundedBuffer,
                index: BoundedPos.Index,
            ) *Task {
                return self.buffer[index % SIZE];
            }

            /// Write the task into the buffer wrapping the index to fit the buffer size.
            pub fn write(
                noalias self: *BoundedBuffer,
                index: BoundedPos.Index,
                noalias task: *Task,
            ) void {
                self.buffer[index % SIZE] = task;
            }
        };
        
        /// The position for a Single-Producer-Multi-Consumer ring buffer backed by BoundedBuffer.
        pub const BoundedPos = extern struct {
            pos: usize align(CACHE_LINE),

            /// The maximum size of the ring buffers.
            const SIZE = BoundedBuffer.SIZE;

            /// The type index which represents the head & tail of the ring buffer.
            /// It is half of a usize so that the head & tail can be updated together atomically.
            pub const Index = @Type(std.builtin.TypeInfo{
                .Int = std.builtin.TypeInfo.Int{
                    .bits = @typeInfo(usize).Int.bits / 2,
                    .is_signed = false,
                },
            });

            /// Setup the position and buffer to an empty state.
            pub fn init(
                noalias self: *BoundedPos,
                noalias buffer: *BoundedBuffer,
            ) void {
                self.pos = 0;
                buffer.* = undefined;
            }

            /// Teardown the position and buffer state.
            pub fn deinit(
                noalias self: *BoundedPos,
                noalias buffer: *BoundedBuffer,
            ) void {
                if (std.debug.runtime_safety)
                    std.debug.assert(self.len() == 0);
                self.* = undefined;
                buffer.* = undefined;
            }

            /// Convert the head and tail positions into a machine word.
            pub fn encode(head: Index, tail: Index) usize {
                return @bitCast(usize, [2]Int{ head, tail });
            }

            /// Extract the head position from a machine word.
            pub fn decodeHead(pos: usize) Index {
                return @bitCast([2]Index, pos)[0];
            }

            /// Extract the tail position from a machine word.
            pub fn decodeTail(pos: usize) Index {
                return @bitCast([2]Index, pos)[1];
            }

            /// Get a pointer to the head position of the BoundedPos.
            pub fn headPtr(self: *BoundedPos) *Index {
                return &@ptrCast(*[2]Index, &self.pos)[0];
            }

            /// Get a pointer to the tail position of the BoundedPos.
            pub fn tailPtr(self: *BoundedPos) *Index {
                return &@ptrCast(*[2]Index, &self.pos)[1];
            }

            /// Get the current length of the BoundedPos.
            pub fn len(self: *const BoundedPos) Index {
                const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                const tail = decodeTail(pos);
                const head = decodeHead(pos);
                return tail -% head;
            }
            
            /// Returns true if there are no tasks in the BoundedPos.
            pub fn isEmpty(self: *const BoundedPos) bool {
                return self.len() == 0;
            }

            /// Enqueue the task into the buffer using this position.
            /// If the position/buffer is full then this call:
            /// - does not enqueue the provided task and
            /// - migrates half the tasks into a queue and returns it
            ///
            /// This should only be called by the producer thread of the BoundedPos
            /// and takes advantage of this variant to relax atomic synchronization.
            pub fn push(
                noalias self: *BoundedPos,
                noalias buffer: *BoundedBuffer,
                noalias task: *Task,
                side: Task.Queue.Side,
            ) ?Task.Queue {
                const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                var head = decodeHead(pos);
                var tail = decodeTail(pos);

                while (true) {
                    // Push the task to the queue if its not full.
                    // After writing to the buffer, use .Release memory ordering
                    // to make sure that the write is visible from stealing threads.
                    if (tail -% head < SIZE) {
                        switch (side) {
                            .Front => {
                                buffer.write(head -% 1, task);
                                head = @cmpxchgWeak(
                                    Index,
                                    self.headPtr(),
                                    head,
                                    head -% 1,
                                    .Release,
                                    .Monotonic,
                                ) orelse return null;
                                continue;
                            },
                            .Back => {
                                buffer.write(tail, task);
                                @atomicStore(Index, self.tailPtr(), tail +% 1, .Release);
                                return null;
                            },
                        }
                    }

                    // The queue is full, try to consume half for overflow.
                    var migrate = SIZE / 2;
                    if (@cmpxchgWeak(
                        usize,
                        &self.pos,
                        encode(head, tail),
                        encode(head, tail -% migrate),
                        .Monotonic,
                        .Monotonic,
                    )) |new_pos| {
                        head = decodeHead(new_pos);
                        continue;
                    }

                    // Create and return the batch of tasks which overflowed.
                    var batch = Task.Queue.init();
                    while (migrate != 0) : (migrate -= 1) {
                        tail -%= 1;
                        batch.add(buffer.read(tail));
                    }
                    return batch;
                }
            }
            
            /// Dequeue a task from the buffer using this position at the given queue side.
            ///
            /// This should only be called by the producer thread of the BoundedPos
            /// and takes advantage of this variant to relax atomic synchronization.
            pub fn pop(
                noalias self: *BoundedPos,
                noalias buffer: *const BoundedBuffer,
                side: Task.Queue.Side,
            ) ?*Task {
                var pos = @atomicLoad(usize, &self.pos, .Monotonic);

                while (true) {
                    var tail = decodeTail(pos);
                    var head = decodeHead(pos);

                    if (tail -% head == 0)
                        return null;

                    const task = switch (side) {
                        .Front => blk: {
                            defer head +%= 1;
                            break :blk buffer.read(head);
                        },
                        .Back => blk: {
                            tail -%= 1;
                            break :blk buffer.read(tail);
                        },
                    };

                    pos = @cmpxchgWeak(
                        usize,
                        &self.pos,
                        pos,
                        encode(head, tail),
                        .Monotonic,
                        .Monotonic,
                    ) orelse return task;
                }
            }

            /// Try to steal half the tasks from the target's position and buffer into ours.
            ///
            /// Safe to be called by the consumer threads but cannot steal from itself.
            pub fn steal(
                noalias self: *BoundedPos,
                noalias buffer: *BoundedBuffer,
                noalias target: *BoundedPos,
                noalias target_buffer: *const BoundedBuffer,
            ) ?*Task {
                const pos = @atomicLoad(usize, &self.pos, .Monotonic);
                const head = decodeHead(pos);
                const tail = decodeTail(pos);

                // Should only try to steal if the local queue is empty.
                std.debug.assert(tail -% head == 0);

                // When stealing from the target's pos, need to use .Acquire barrier.
                // This is to make the target's thread buffer writes visible to us.
                var target_pos = @atomicLoad(usize, &target.pos, .Acquire);
                while (true) {
                    var target_head = decodeHead(target_pos);
                    var target_tail = decodeTail(target_pos);

                    // Try to steal @ceil(half of the target's tasks)
                    const migrate = switch (target_tail -% target_head) {
                        0 => return null,
                        1 => 1,
                        else => |size| size >> 2,
                    };

                    // Copy the target's tasks into our buffer,
                    // saving the first task since it will be returned ...
                    var i: Index = 0;
                    var first_task: *Task = undefined;
                    while (i < migrate) : (i += 1) {
                        const task = target_bufer.read(target_head +% i);
                        if (i == 0) {
                            first_task = task;
                        } else {
                            buffer.write(tail +% i, task);
                        }
                    }

                    /// ... then try to commit the steal.
                    if (@cmpxchgWeak(
                        usize,
                        &target.pos,
                        target_pos,
                        encode(target_head +% migrate, target_tail),
                        .Acquire, // technically could be .Monotonic but not allowed
                        .Acquire,
                    )) |new_pos| {
                        target_pos = new_pos;
                        continue;
                    }

                    // Update the tail of our buffer to reflect our newly stolen tasks.
                    // Use .Release memory ordering to make our buffer writes visible to other stealers.
                    if (migrate > 1)
                        @atomicStore(Index, self.tailPtr(), tail +% (migrate - 1), .Release);
                    return first_task;
                }
            }
        };
    };
}

