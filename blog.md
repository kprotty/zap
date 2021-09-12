I'd like to share what I've been working on for the past 2 years give or take. It's a thread pool that checks a bunch of boxes: lock-free, allocation-free\* (excluding spawning threads), supports batch scheduling, and dynamically spawns threads while handling thread spawn failure. 

To preface, this assumes you're familiar with thread synchronization patterns and manual memory management. It's also more of a letter to other people implementing schedulers than it is to benefit most programmers. So if you don't understand what's going on sometimes, that's perfectly fine. I try to explain what led to each thought and if you're just interested in how the claims above materialized, go read [the source](https://github.com/kprotty/zap/blob/blog/src/thread_pool.zig) directly.

## Thread Pools?

For those unaware, a thread pool is just a group of threads that work can be dispatched to. Having a group amortizes the costs of creating and shutting down threads which can be expensive in comparison to the work being performed. It also prevents a task from blocking another by having other thread ready to process it.

Thread pools are used everywhere from your favorite I/O event loop (Golang, Tokio, Akka, Node.js), to game logic or simulation processing (OpenMP, Intel TBB, Rayon, Bevy), and even broader applications (Linkers, Machine Learning, and more). It's a pretty well explored abstraction, but *there's still more room for improvement.*

## Why Build Your Own?

A good question. Given the abundance of solutions (I've listed some above), why not just use an existing thread pool? Aren't thread pools a solved problem? Aren't they just all the same: a group of threads? It's reasonable to have this line of though if the processing isn't your main concern. However I like tinkering, optimizing and have quite a bit of free time. These are shared formulas with which helped build the existing solutions.

First, I'd like to set the stage. I'm very into Zig. The time is somewhere after Zig `0.5`. Andrew just recently introduced Zig's [new `async/await` semantics](https://ziglang.org/download/0.5.0/release-notes.html#Async-Functions) (I hope to do a post about this in the future) and the standard library event loop (async I/O driver) is only at its baby stages. This is a chance to get Zig into the big player domain like Go and Rust for async I/O stuff. A good thread pool appears necessary.

Second, **thread pools aren't a solved problem**. While the existing reference implementations are quite fast for their needs, they personally have some inefficient design choices that I believed could be improved on. Even between Intel TBB and Go's runtime, their implementations aren't that similar to each other and arguably pretty ew code wise [TBH](https://www.howtogeek.com/447760/what-does-tbh-mean-and-how-do-you-use-it/#:~:text=%E2%80%9CTo%20Be%20Honest%E2%80%9D%20or%20%E2%80%9C,%2C%20and%20text%2Dmessage%20culture.) The former is a jungle of classes spread over different files to get to the meat of scheduling. The latter has a lot of short context-lacking variable names mixed with GC/tracing stuff which distracted me when I was first understanding it. (**Update**: Go cleaned up [the scheduler](https://golang.org/src/runtime/proc.go) and It's much nicer now).

Third, good thread pools aren't always straight forward. The [META](https://www.arc.unsw.edu.au/blitz/read/explainer-what-is-a-metaquestion#:~:text=In%20essence%2C%20a%20%22meta%22,%E2%80%9Cmost%20effective%20tactics%20available%E2%80%9D.) nowadays for I/O event loops is a work-stealing, wake-throttling, I/O sharing, mostly-cooperative, task scheduler. Yea it's a mouth full and, and yea each of the components carries its own implementation trade-offs, but this matrix of scheduling options will help understand why I started with such a design.

## Resource Efficiency

Zig has a certain ethos or [Zen](https://ziglang.org/documentation/master/#Zen) which attracted me to the language in the first place. That is: the focus on edge cases and utilizing the hardware's resources in a good and less wasteful way. The best example of this is program memory. Having developed on a machine with relatively low memory as a restraint when starting out, this is a problem I wished to address early on the thread pool's design.

When you simplify a thread pool's API, it all comes down a function which takes a Task or Unit-of-Work and queues it up for execution on some thread: `schedule(Task)`. Some implementations will often store the tasks in the thread pools itself and basically have an unbounded queue of them which heap allocates to grow. This can be wasteful memory-wise (and add synchronization overhead) so I decided to have Tasks in my thread pool be intrusively provided.

## Intrusive Memory

Intrusive data structures are, as I understand it, when you store a reference to the callers data with the caller having more context on what that reference is. This contrasts to non-intrusive data structures which copy or move the callers data into container for ownership. 

Poor explanation, I know, but as an example you can think of a hash map as non-intrusive since it owns whatever key/value you insert into it and can changes its memory internally when growing. While a linked list in which the caller provides the node pointers, and can only deallocate the node once it's removed from the list, is labeled as intrusive. A [possibly better explanation here](https://www.boost.org/doc/libs/1_55_0/doc/html/intrusive/intrusive_vs_nontrusive.html), but our thread pool tasks now look like this:

```zig
pub const Task = struct {
    next: ?*Task = null,
    callback: fn (*Task) void,
};

pub fn schedule(task: *Task) void {
    // ...
}
```

To schedule a callback with some context, you would generally store the Task itself *with* the context and use the [`@fieldParentPtr()`](https://ziglang.org/documentation/master/#fieldParentPtr) to convert the Task pointer back into the context pointer. If you're familiar with C, this is basically `containerof` but a bit more type safe. It takes a pointer to a field and gives you a pointer to the parent/container struct/class.

```zig
const Context = struct {
    value: usize,
    task: Task,

    pub fn scheduleToIncrement(this: *Context) void {
        this.task = Task{ .callback = onScheduled };
        schedule(&this.task);
    }

    fn onScheduled(task_ptr: *Task) void {
        const this = @fieldParentPtr(Context, "task", task_ptr);
        this.value += 1;
    }
};
```

This is a very powerful and memory efficient way to model callbacks. It leaves the scheduler to only interact with opaque Task pointers which are effectively just linked-list nodes. Zig makes this pattern easy and common too; The standard library uses intrusive memory and `containerof` to model runtime polymorphism for Allocators by having them hold a function pointer which takes in an opaque Allocator pointer where the function's implementation uses `@fieldParentPtr` on the Allocator pointer to get its allocator-specific context. It's like a cool alternative to [vtables](https://en.wikipedia.org/wiki/Virtual_method_table).

## Scheduling and the Run Loop

Now that we have the basic API down, we can actually make a single threaded implementation to understand the concept of task schedulers.

```zig
stack: ?*Task = null,

pub fn schedule(task: *Task) void {
    task.next = stack;
    stack = task;
}

pub fn run() void {
    while (stack) |task| {
        stack = task.next;
        (task.callback)(task);
    }
}
```

This is effectively what most schedulers, and hence thread pools, boil down to. The main difference from this and a threaded version is that the queue of Tasks to run called `stack` here is conceptually shared between threads and multiple threads are popping from it in order to call Task callbacks. Let's make our simple example thread-safe by adding a Mutex.

```zig
lock: std.Mutex = .{},
stack: ?*Task = null,

pub fn schedule(task: *Task) void {
    const held = self.lock.acquire();
    defer held.release();
    
    task.next = stack;
    stack = task.next;
}

fn runOnEachThread() void {
    while (dequeue()) |task|
        (task.callback)(task);
}

fn dequeue() ?*Task {
    const held = self.lock.acquire();
    defer held.release();

    const task = stack orelse return null;
    stack = task.next;
    return task;    
}
```

Did you spot the inefficiency here? We musn't forget that now there's multiple threads dequeueing from `stack`. If there's only one task running and the `stack` is empty, then all the other threads are just spinning on dequeue(). To save execution resources those threads should be put to sleep until `stack` is populated. I'll spare you the details this time but we've boiled down the API for a multi-threaded thread-pool here to this pseudo code:

## The Algorithm

```rs
schedule(task):
    run_queue.push(task)
    threads.notify()

join():
    shutdown = true
    for all threads |t|:
        t.join()

run_on_each_thread():
    while not shutdown:
        if run_queue.pop() |task|:
            task.run()
        else:
            threads.wait()
```

Here is the algorithm that we will implement for our thread pool. I will refer back to this here and there and also reiterate over it later. For now, keep this as a reminder for where we're working on.

## Run Queues

Let's focus on the run queue first. Having a shared run queue for all threads increases how much they fight over it when going to dequeue and is quite the bottleneck. This fighting is known as **contention** in synchronization terms and is the primary slowdown of any sync mechanism from Locks down to atomic instructions. The less threads are stomping over each other, the better the throughput in most cases.

To help decrease contention on the shared run queue, we just give each thread its own run queue! When threads schedule(), they push to their own run queue. When they pop(), they first dequeue from their own, then try to dequeue() from others as a last resort. **This is nothing new, but is what people call work-stealing**. 

If the total work on the system is being pushed in by different threads, then this scales great since they're not touching each other most of the time. But when they start stealing, the contention slowdown reels it's head in again. This can happen a lot if there's only a few threads pushing work to their queues and the rest are just stealing. Time to investigate what we can do about that.

### Going Lock-Free: Bounded

**WARNING**: here be atomics. Skip to [Notification Throttling](#Notification-Throttling) to get back into algorithm territory

The first thing we can do is to get rid of the locks on the run queues. When there's a lot of contention a lock, the thread has to be put to sleep. This is a relatively expensive operation compared to the actual dequeue; It's a syscall for the losing thread to sleep and often a syscall for the winning thread to wake up a losing thread. We can avoid this with a few realizations.

One realization is that there's only one producer to our thread local queues while there's multiple consumers in the form of "the work stealing threads". This means we don't need to synchronize the producer side and can use lock-free SPMC (single-producer-multi-consumer) algorithms. Golang uses a good one (which I believed is borrowed from Cilk?) that has a really efficient push() and can steal in batches, all without locks:

```rs
head = 0
tail = 0
buffer: [N]*Task = uninit

// -% is wrapping subtraction
// +% is wrapping addition
// `ATOMIC_CMPXCHG(): ?int` where `null` is success and `int` is failure with new value.

push(task):
    h = ATOMIC_LOAD(&head, Relaxed)
    if tail -% h >= N:
        return Full
    // store to buffer must be atomic since slow steal() threads may still load().
    ATOMIC_STORE(&buffer[tail % N], task, Unordered)
    ATOMIC_STORE(&tail, t +% 1, Release)

pop():
    h = ATOMIC_LOAD(&head, Relaxed)
    while h != tail:
        h = ATOMIC_CMPXCHG(&head, h, h +% 1, Acquire) orelse:
            return buffer[head % N]
    return null

steal(into):
    while True:
        h = ATOMIC_LOAD(&head, Acquire)
        t = ATOMIC_LOAD(&tail, Acquire)
        if t -% h > N: continue // preempted too long between loads
        if t == h: return Empty

        // steal half to amortize the cost of stealing.
        // loads from buffer must be atomic since may be getting updated by push().
        // stores to `into` buffer must be atomic since it's pushing. see push().
        half = (t -% h) - ((t -% h) / 2) 
        for i in 0..half:
            task = ATOMIC_LOAD(&buffer[(h +% i) % N], Unordered)
            ATOMIC_STORE(&into.buffer[(into.tail +% i) % N], task, Unordered)
        
        _ = ATOMIC_CMPXCHG(&head, h, h +% half, AcqRel) orelse:
            new_tail = into.tail +% half
            ATOMIC_STORE(&into.tail, new_tail -% 1, Release)
            return into.buffer[new_tail % N]
```

You can ignore the details but just know that this algorithm is nice because it allows stealing to happen concurrently to producing. Stealing can also happen concurrently to other steal()s and pop()s without ever having to pause the thread from issuing a blocking syscall. Basically, we've made the serialization points (places where mutual exclusion is needed) to be the atomic operations which happen in hardware instead of the locks which serialize entire OS threads using syscalls in software.

Unfortunately, this algorithm is only for a bounded array. `N` could be pretty small relative to the overall Tasks that may be queued on a given thread so we need a way to hold tasks which overflow, but without re-introducing locks. This is where other implementations stop but we can keep going lock-free with more realizations.

### Going Lock-Free: Unbounded

If we refer back to the pseudo code, `run_queue.push` is always followed by `threads.notify`. And a failed `run_queue.pop` is always followed by `threads.wait`. This means that the `run_queue.pop` is allowed to spuriously see empty run queues and wait without worry as long as there's a matching notification to wake it up. 

This is actually a powerful realization. It means that any OS thread blocking/unblocking from syscalls done in the run queue operations can actually be omitted since `threads.wait` and `threads.notify` are already doing the blocking/unblocking! **If a run queue operation would normally block, _it just shouldn't_** since it will already block once it fails anyways. The thread can use that free time to check other thread run queues (instead of blocking) before reporting an empty dequeue. We've effectively merged thread sleep/wakeup mechanisms with run queue synchronization.

We can translate this realization to each thread having a non-blocking-lock (i.e. `try_lock()`, no `lock()`) protected queue  *along with the SPMC buffer*. When our thread's buffer overflows, we take/steal half of it, build a linked list from that, then lock our queue and push that linked list. Migrating half instead of 1 amortizes the cost of stealing from ourselves on push() and makes future pushes go directly to the buffer which is fast.

When we dequeue and our buffer is empty, we *try to lock* our queue and pop/refill our buffer with tasks from the queue. If both our buffer and queue are empty (or if another thread is holding our queue lock) then we steal by *try_locking* and refilling from *other* thread queues, stealing from their buffer if that doesn't work. This is in reverse order to how they dequeue to, again, avoid contention.

```rs
run_queue.push():
    if thread_local.buffer.push(task) == Full:
        migrated = thread_local.buffer.steal() + task
        thread_local.queue.lock_and_push(migrated)

run_queue.pop(): ?*Task
    if thread_local.buffer.pop() |task|
        return task
    if thread_local.queue.try_lock_and_pop() |task|
        return task
    for all other threads |t|:
        if t.queue.try_lock_and_pop() |task| 
            return task
        if t.buffer.steal(into: &thread_local.buffer) |task| 
            return task
    return null
```

----

This might have been a lot to process, but hopefully the code shows what's going on. If you're still reading ... take a minute break or something; There's still more to come. If you're attentive, you may remember that I said we should do this without locks but there's still `lock_and_push()` in the producer! Well here we go again.

----

### Going Lock-Free: Unbounded; Season 1 pt. 2

You also may have noticed that the "try_lock_" in `try_lock_and_pop` for our thread queues is just there to enforce serialization on the consumer side. There's also still only one producer. Using these assumptions, we can reduce the queues down to non-blocking-lock protected lock-free SPSC queues. This would allow the producer to operate lock-free to the consumer and remove the final blocking serialization point that is `lock_and_push()`.

Unfortunately, there don't seem to be any unbounded lock-free SPSC queues out there which are fully intrusive *and* don't use atomic read-modify-write instructions (that's generally avoided for SPSC). But that's fine! We can just use an intrusive unbounded MPSC instead. Dmitry Vyukov developed/discovered a [fast algorithm](https://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue) for such use-case a while back which has been well known and used everywhere from [Rust stdlib](https://doc.rust-lang.org/src/std/sync/mpsc/mpsc_queue.rs.html) to [Apple GCD](https://github.com/apple/swift-corelibs-libdispatch/blob/34f383d34450d47dd5bdfdf675fcdaa0d0ec8031/src/inline_internal.h#L1510) to [Ponylang](https://github.com/ponylang/ponyc/blob/7d38ffa91cf5f89f94daf6f195dfae3bd3395355/src/libponyrt/actor/messageq.c#L31).

We can also merge the non-blocking-lock acquisition and release into the MPSC algorithm itself by having the pop-end be `ATOMIC_CMPXCHG` acquired with a sentinel value and released by storing the actual pointer after popping from the queue with the acquired pop-end. Again, here's just the nitty gritty for those interested.

```rs
stub: Task = .{ .next = null },
head: usize = 0
tail: ?*Task = null

CONSUMING = 1

push(migrated):
    migrated.tail.next = null
    t = ATOMIC_SWAP(&tail, migrated.tail, AcqRel)
    prev = t orelse &stub
    ATOMIC_STORE(&prev.next, migrated.head, Release)

try_lock(): ?*Task
    h = ATOMIC_LOAD(&head, Relaxed)
    while True:
        if h == 0 and ATOMIC_LOAD(&tail, Relaxed) == null:
            return null // Empty queue
        if h == CONSUMING:
            return null // Queue already locked

        h = ATOMIC_CMPXCHG(&head, h, CONSUMING, Acquire) orelse:
            return (h as ?*Task) orelse &stub

pop(ref locked_head: *Task): ?*Task
    if locked_head == &stub:
        locked_head = ATOMIC_LOAD(&stub.next, Acquire) orelse return null

    if ATOMIC_LOAD(&locked_head.next, Acquire) |next|
        defer locked_head = next;
        return locked_head;
    
    // push was preempted between SWAP and STORE
    // its ok since we can safely return spurious empty
    if ATOMIC_LOAD(&tail, Acquire) != locked_head:
        return null 

    // Try to Ensure theres a next node
    push(LinkedList.from(&stub))

    // Same thing as above
    const next = ATOMIC_LOAD(&locked_head.next, Acquire) orelse return null
    defer locked_head = next;
    return locked_head

unlock(locked_head: *Task):
    assert(ATOMIC_LOAD(&head, Unordered) == CONSUMING)
    ATOMIC_STORE(&head, locked_head as usize, Release)
```

**SIDENOTE**: A different algorithm ended up in the final thread pool since I discovered a "mostly-LIFO" version of this which performs about the same in practice. It's a [Treiber Stack](https://en.wikipedia.org/wiki/Treiber_stack) MPSC which swaps the entire stack with null for consumer. The idea used fairly often in the wild (See [mimalloc: 2.4 The Thread Free List](https://www.microsoft.com/en-us/research/uploads/prod/2019/06/mimalloc-tr-v1.pdf)), but I just figured out a way to add try-lock usage to the consumer end.

```rs
stack: usize = 0
cache: ?*Task = null

MASK = ~0b11
CACHED = 0b01
CONSUMING = 0b10

// Classic treiber stack push
push(migrated):
    s = ATOMIC_LOAD(&stack, Relaxed)
    while True:
        migrated.tail.next = (s & MASK) as ?*Task
        new = (migrated.head as usize) | (s & ~MASK)
        s = ATOMIC_CMPXCHG(&stack, s, new, Release) orelse break

try_lock(): ?*Task
    s = ATOMIC_LOAD(&stack, Relaxed)
    while True:
        if s & CONSUMING != 0:
            return null // Queue already locked
        if s & (MASK | CACHED) == 0:
            return null // Queue is empty

        // Grab consuming, but also grab the pushed stack if nothings cached
        new = s = CONSUMING | CACHED
        if s & CACHED == 0:
            new &= ~MASK

        s = ATOMIC_CMPXCHG(&stack, s, new, Acquire) orelse:
            return cache orelse ((s & MASK) as *Task)

pop(ref locked_stack: ?*Task): ?*Task
    // fast path
    if locked_stack |task|:
        locked_stack = task.next
        return task
    
    // quick load before the swap to avoid taking ownership of cache line
    if ATOMIC_LOAD(&stack, Relaxed) & MASK == 0:
        return null

    // grab the stack in one foul swoop
    s = ATOMIC_SWAP(&stack, CONSUMING | CACHED, Acquire)
    task = ((s & MASK) as ?*Task) orelse return null
    locked_stack = task.next
    return task


unlock(locked_stack: ?*Task):
    // remove the CACHED bit if the cache is empty
    // which will cause next try_lock() to consume the stack
    sub = CONSUMING
    if locked_stack == null:
        sub |= CACHED

    cache = locked_stack
    ATOMIC_SUB(&stack, sub, Release)
```

### Going Lock-Free: Unbounded; Season 1 pt. 3

Now that the entire run queue is lock-free, we've actually introduced a situation where thread A can grab the queue lock of thread B and the thread B would see empty (its queue is currently locked) and sleep on `threads.wait`. This is expected, but the sad part is that the queue lock holder may leave some remaining Tasks after refilling it's buffer even while there's sleeping threads that could process those Tasks! As a general rule, **anytime we push to the buffer in any way, even when work-stealing, follow it up with a notification**. This prevents under-utilization of threads in the pool and we must change the algorithm to reflect this:

```rs
run_on_each_thread():
    while not shutdown:
        if run_queue.pop() |(task, pushed)|:
            if pushed: threads.notify()
            task.run()
        else:
            threads.wait()

run_queue.pop(): ?(task: *Task, pushed: bool)
    if thread_local.buffer.pop() |task|
        return (task, false)
    if steal_queue(&thread_local.queue) |task|
        return (task, true)
    for all other threads |t|:
        if steal_queue(&t.queue) |task| 
            return (task, true)
        if t.buffer.steal(into: &thread_local.buffer) |task| 
            return (task, true)
    return null
```

## Notification Throttling

The run queue is now optimized and by this point it has improved throughput the most so far. The next thing to do is to optimize how threads are put to sleep and woken up through `threads.wait` and `threads.notify`. The run queue relies on `wait()` to handle spurious reports of being empty, and `notify()` is now called on every steal, so both functions have to be efficient.

I mentioned before that putting a thread to sleep and waking it up are both "expensive" syscalls. We should also not try to wake up all threads for each `notify()` as that would increase contention on the run queues (even if we're already trying hard to avoid it). The best solution that myself and others have found in practice is to throttle thread wake ups.

Throttling in this case means that **when we *do* wake up a thread, we don't wake up another until the woken up thread has actually been scheduled by the OS**. We can take this even further by requiring that the woken up thread to find Tasks before waking another. This is what Golang and Rust async executors do to great results and is what we will do as well, but in a *different* way.

For context, Golang and Rust use a counter of all the threads who are stealing. They only wake up a thread if there's no threads currently stealing. So `notify()` tries to `ATOMIC_CMPXCHG()` the stealing count from 0 to 1 and wakes only if that's successful. When entering the work stealing portion, the count is incremented if some heuristics deem OK. When leaving, the stealing count is decremented and if the last thread to exit stealing finds a Task, it will try to `notify()` again. This works for other thread pools, but is a bit awkward for us for a few reasons.

We want to have a similar throttling but have different requirements. Unlike Rust, we spawn threads lazily to support static initialization for our thread pool. Unlike Go, we don't use locks for mutual exclusion to know whether to wake up or spawn a new thread on `notify()`. We also want to allow thread spawning to fail without bringing the entire program down from a `panic()` like both Go and Rust. Threads are a resource which, like memory, can be constrained at runtime and we should be explicit about handle it as per Zig Zen.

(**Update**: I found a way to make the Go-style system work for our thread pool after the blog was written. Go [check out the source](https://github.com/kprotty/zap/blob/blog/src/thread_pool_go_based.zig))

I came up with a different solution which I believe is a bit friendlier to [LL/SC](https://en.wikipedia.org/wiki/Load-link/store-conditional) systems like ARM, but also solves the problems listed above. I originally called it `Counter` but have started calling it `Sync` out of simplicity. All thread coordination state is stored in a single machine word which packs the bits full of meaning (yay memory efficiency!) and is atomically transitioned through `ATOMIC_CMPXCHG`.

### Counter/Sync Algorithm

```zig
enum State(u2):
    pending     = 0b00
    waking      = 0b01
    signaled    = 0b10
    shutdown    = 0b11

packed struct Sync(u32):
    state: State
    notified: bool(u1)
    unused: bool(u1)
    idle_threads: u14
    spawned_threads: u14
```

The thicc-but-not-really `Sync` struct tracks the "pool state" which is used to control thread signaling, shutdown, and throttling. That's followed by a boolean called `notified` which helps in thread notification, `unused` which you can ignore (it's just there to pad it to `u32`), and counters for the amount of threads sleeping and the amount of threads created. You could extend `Sync`'s size from `u32` to `u64` on 64bit platforms and grow the counters, but if you need more than 16K (`1 << 14`) threads in your thread pool, you have bigger issues...

In order to implement thread wakeup throttling, we introduce something called "the waking thread". To wake up a thread, the `state` is transitioned from `pending` to `signaled`. Once a thread wakes up, it consumes this signal by transitioning the state from `signaled` to `waking`. The winning thread to consume the signal now becomes the "waking thread".

While there is a "waking thread", no other thread can be woken up. The waking thread will either dequeue a Task or go back to sleep. If it finds a Task, it must transfer its "waking" status to someone else by transitioning from `waking` to `signaled` and wake up another thread. If it doesn't find Tasks, it must transition from `waking` to `pending` before going back to sleep.

This results in the same throttling mechanisms found in Go and Rust by avoiding a [thundering herd](https://en.wikipedia.org/wiki/Thundering_herd_problem) of threads on `notify()`, decreases contention on the amount of stealing threads, and amortizes the syscall cost of actually waking up a thread:

* T1 pushes Tasks to its run queue and calls `notify()`
* T2 is woken up and designated as the "waking thread"
* T1 pushses Tasks again but can't wake up other threads since T2 is still "waking"
* T2 steals Tasks from T1 and wakes up T3 as the new "waking" thread
* T3 steals from from either T2 or T1 and wakes T4 as the new "waking" thread.
* By the time T4 wakes up, all Tasks have been processed
* T4 fails to steal Tasks, gives up the "waking thread" status, and goes back to sleep on `wait()`

### Thread Counters and Races

So far, we've only talked about the `state`, but there's still `notified`, `idle_threads` and `spawned_threads`. These are here to optimize the algorithm and provide lazy/faillable thread spawning as I mentioned a while back. Let's go through all of them:

First, let's check out `spawned_threads`. Since it's handled atomically with `idle_threads`, this gives us a choice on how we want to "wake" up a thread. If there's existing idle/sleeping threads, we should of course prefer waking up those instead of spawning new ones. But if there aren't any, we can accurately spawn more until we reach a user-set "max threads" capacity. **If spawning a thread fails, we just decrement this count**. `spawned_threads` is also used to synchronize shutdown which is explained later.

Then there's `notified`. Even when there's a "waking" thread, we still don't want `notify()`s to be lost as then that's missed wake ups which lead to CPU under-utilization. So every time we `notify()`, we also set the `notified` bit if it's not already. Threads going to sleep can observe the `notified` bit and try to consume it. Consuming it acts like a pseudo wake up so the thread should recheck run queues again instead of sleeping, which applies to the "waking" thread as well. This keeps the Threads on their toes by having at most one other non-waking thread searching for Tasks. For `Sync(u64)`, we could probably extend this to a counter to have more active searching threads.

Finally there's `idle_threads`. When a thread goes to sleep, it increments `idle_threads` by one then sleeps on a semaphore or something. A non-zero idle count allows `notify()` to know to transition to `signaled` and post to the theoretical semaphore. It's the notification-consuming thread's responsibility to decrement the `idle_threads` count when it transitions the state from `signaled` to `waking` or munches up the `notified` bit. Those familiar with [semaphore internals](https://code.woboq.org/userspace/glibc/nptl/sem_waitcommon.c.html#__new_sem_wait_slow) or [event counts](https://github.com/r10a/Event-Counts) will recognize this `idle_threads` algorithm.

### Shutdown Synchronization

When the book of revelations comes to pass, and the thread pool is ready to reap and ascend to reclaimed memory, it must first make peace with its children to join gracefully. For thou pool must not be eager to return, else they risk the memory corruption of others. The scripture recites a particular mantra to perform the process:

Transition the `state` from whatever it is to `shutdown`, then post to the semaphore if there were any `idle_threads`. This notifies the threads that the end is *among us*. `notify()` bails if it observes the state to be `shutdown`. `wait()` decrements `spawned_threads` and bails when it observes `shutdown`. The last thread to decrement the spawned count to zero must notify the pool that *it is time*.

The thread pool can iterate its children threads and sacrifice them to the kernel... but wait, we never explained how the thread pool keeps track of threads? Well, to keep with the idea of intrusive memory, a thread pushes itself to a lock-free stack in the thread pool on spawn. Threads find each other by following that stack and restarting from the top when the first-born is reached. We just follow this stack as well when `spawned_threads` reaches 0 to join them.

The final algorithm is as follows. Thank you for coming to my TED talk.

```rs

notify(is_waking: bool):
    s = ATOMIC_LOAD(&sync, Relaxed)
    while s.state != .shutdown:
        new = { s | notified: true }
        can_wake = is_waking or s.state == .pending
        if can_wake and s.idle > 0:
            new.state = .signaled
        else if can_wake and s.spawned < max_spawn:
            new.state = .signaled
            new.spawned += 1
        else if is_waking: // nothing to wake, transition out of waking
            new.state = .pending
        else if !s.notified:
            return // nothing to wake or notify

        s = ATOMIC_CMPXCHG(&sync, s, new, Release) orelse:
            if can_wake and s.idle > 0:
                return thread_sema.post(1)
            if can_wake and s.spawned < max_spawn:
                return spawn_thread(run_on_each_thread) catch kill_thread(null)
            return

wait(is_waking: bool): error{Shutdown}!bool
    is_idle = false
    s = ATOMIC_LOAD(&sync, Relaxed)
    while True:
        if s.state == .shutdown:
            return error.Shutdown

        if s.notified or !is_idle:
            new = { s | notified: false }
            if s.notified:
                if s.state == .signaled:
                    new.state = .waking
                if is_idle:
                    new.idle -= 1
            else:
                new.idle += 1
                if is_waking:
                    new.state = .pending

            s = ATOMIC_CMPXCHG(&sync, s, new, Acquire) orelse:
                if s.notified:
                    return is_waking or s.state == .signaled
                is_waking = false
                is_idle = true
                s = new
            continue

        thread_sema.wait()
        s = ATOMIC_LOAD(&sync, Relaxed)

kill_thread(thread: ?*Thread):
    s = ATOMIC_SUB(&sync, Sync{ .spawned = 1 }, Release)
    if s.state == .shutdown and s.spawned - 1 == 0:
        shutdown_sema.notify()

    if thread |t|:
        t.join_sema.wait()

shutdown_and_join():
    s = ATOMIC_SWAP(&sync, Sync{ .state = .shutdown }, AcqRel);
    if s.idle > 0:
        thread_sema.post(s.idle)

    shutdowm_sema.wait()
    for all_threads following stack til null |t|:
        t.join_sema.post(1)

run_on_each_thread():
    atomic_stack_push(&all_threads, &thread_local)
    defer kill_thread(&thread_local)

    is_waking = false
    while True:
        is_waking = try wait(is_waking)

        while dequeue() |(task, pushed)|:
            if is_waking or pushed:
                notify(is_waking)
            is_waking = false
            task.run()

dequeue(): ?(task: *Task, pushed: bool)
    if thread_local.buffer.pop() |task|
        return (task, false)
    if steal_queue(&thread_local.queue) |task|
        return (task, true)

    for all_threads following stack til null |t|:
        if steal_queue(&t.queue) |task| 
            return (task, true)
        if t.buffer.steal(into: &thread_local.buffer) |task| 
            return (task, true)
    return null
```

## Closings

I probably missed something in my explanations. If so, I urge you to read the [source](https://github.com/kprotty/zap/blob/blog/src/thread_pool.zig). It's well commented I assure you :). I've provided a [Zig `async` wrapper](https://github.com/kprotty/zap/blob/blog/benchmarks/zig/async.zig) to the thread pool as well as [benchmarks](https://github.com/kprotty/zap/tree/blog/benchmarks) for competing async runtimes in the repository. Feel free run those locally, add your own, or modify the zig one. Learned a lot by doing this so here's some other links to articles about varying [schedulers along with my own tips](https://twitter.com/kingprotty/status/1416774977836093445). *And as always, hope you learned something*
