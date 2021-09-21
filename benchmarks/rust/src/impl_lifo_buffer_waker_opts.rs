use std::{
    cell::{Cell, UnsafeCell},
    future::Future,
    marker::{PhantomData, PhantomPinned},
    mem::{self, MaybeUninit},
    num::{NonZeroU16, NonZeroUsize},
    pin::Pin,
    ptr::{self, NonNull},
    sync::{
        atomic::{AtomicPtr, AtomicU8, AtomicUsize, Ordering},
        Arc,
    },
    task::{Context, Poll, RawWaker, RawWakerVTable, Waker},
    thread::{self, Thread},
};

#[derive(Debug, Default)]
pub struct Builder {
    max_threads: Option<NonZeroU16>,
    stack_size: Option<NonZeroUsize>,
}

impl Builder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn max_threads(mut self, num_threads: NonZeroU16) -> Self {
        self.max_threads = Some(num_threads);
        self
    }

    pub fn stack_size(mut self, stack_size: NonZeroUsize) -> Self {
        self.stack_size = Some(stack_size);
        self
    }

    pub fn block_on<F>(self, future: F) -> F::Output
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        let num_workers = self
            .max_threads
            .map(|t| t.get() as usize)
            .unwrap_or(1)
            .min(SyncState::COUNT_MASK)
            .max(1);

        let pool = Arc::new(Pool {
            idle: AtomicUsize::new(0),
            sync: AtomicUsize::new(0),
            pending: AtomicUsize::new(0),
            stack_size: self.stack_size,
            workers: (0..num_workers)
                .map(|_| Worker::default())
                .collect::<Vec<Worker>>()
                .into_boxed_slice()
                .into(),
        });

        // Calls pool.notify() which calls pool.spawn() which runs on main thread for index 0
        let mut join_handle = TaskFuture::spawn(future, &pool, 0);

        // Extract the value out of the spawned join handle assuming the pool has shutdown
        unsafe {
            const PANIC_WAKER_VTABLE: RawWakerVTable = RawWakerVTable::new(
                |_| unreachable!("Waker::clone was called when unsupported"),
                |_| unreachable!("Waker::wake was called when unsupported"),
                |_| unreachable!("Waker::wake_by_ref was called when unsupported"),
                |_| {},
            );

            let waker = Waker::from_raw(RawWaker::new(ptr::null(), &PANIC_WAKER_VTABLE));
            let join_future = Pin::new_unchecked(&mut join_handle);
            let mut context = Context::from_waker(&waker);

            match join_future.poll(&mut context) {
                Poll::Ready(output) => output,
                Poll::Pending => unreachable!("TaskFuture did not complete after pool shutdown"),
            }
        }
    }
}

pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    Pool::with_current(|pool, index| TaskFuture::spawn(future, pool, index))
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum SyncStatus {
    Pending,
    Waking,
    Signaled,
}

#[derive(Copy, Clone, Debug)]
struct SyncState {
    idle: usize,
    spawned: usize,
    notified: bool,
    status: SyncStatus,
}

impl SyncState {
    const COUNT_BITS: u32 = (usize::BITS - 4) / 2;
    const COUNT_MASK: usize = (1 << Self::COUNT_BITS) - 1;
}

impl From<usize> for SyncState {
    fn from(value: usize) -> Self {
        Self {
            idle: (value >> (Self::COUNT_BITS + 4)) & Self::COUNT_MASK,
            spawned: (value >> 4) & Self::COUNT_MASK,
            notified: value & 0b100 != 0,
            status: match value & 0b11 {
                0b00 => SyncStatus::Pending,
                0b01 => SyncStatus::Waking,
                0b10 => SyncStatus::Signaled,
                _ => unreachable!("invalid sync-status"),
            },
        }
    }
}

impl Into<usize> for SyncState {
    fn into(self) -> usize {
        assert!(self.idle <= Self::COUNT_MASK);
        assert!(self.spawned <= Self::COUNT_MASK);

        let mut value = 0;
        value |= self.idle << (Self::COUNT_BITS + 4);
        value |= self.spawned << 4;

        if self.notified {
            value |= 0b100;
        }

        value
            | match self.status {
                SyncStatus::Pending => 0b00,
                SyncStatus::Waking => 0b01,
                SyncStatus::Signaled => 0b10,
            }
    }
}

#[derive(Default)]
struct Worker {
    queue: Queue,
    buffer: Buffer,
    state: AtomicUsize,
    thread: Cell<Option<Thread>>,
}

unsafe impl Send for Worker {}
unsafe impl Sync for Worker {}

struct Pool {
    idle: AtomicUsize,
    sync: AtomicUsize,
    pending: AtomicUsize,
    workers: Pin<Box<[Worker]>>,
    stack_size: Option<NonZeroUsize>,
}

impl Pool {
    fn with_tls<T>(f: impl FnOnce(&mut Option<(NonNull<Arc<Pool>>, usize)>) -> T) -> T {
        thread_local!(static POOL_INDEX: UnsafeCell<Option<(NonNull<Arc<Pool>>, usize)>> = UnsafeCell::new(None));
        POOL_INDEX.with(|pool_index| f(unsafe { &mut *pool_index.get() }))
    }

    fn with_current<T>(f: impl FnOnce(&Arc<Pool>, usize) -> T) -> T {
        let pool_index = Self::with_tls(|pool_index| *pool_index);
        let (pool, index) = pool_index.expect("Pool::with_current() called outside thread pool");
        f(unsafe { pool.as_ref() }, index)
    }

    fn with_worker(self: &Arc<Pool>, index: usize) {
        let old_pool_index = Self::with_tls(|pool_index| {
            let new_pool_index = Some((NonNull::from(self), index));
            mem::replace(pool_index, new_pool_index)
        });
        self.run(index);
        Self::with_tls(|pool_index| *pool_index = old_pool_index)
    }

    fn clone_ref(self: &Arc<Pool>) {
        let pending = self.pending.fetch_add(1, Ordering::SeqCst);
        assert!(pending != !0usize);
    }

    fn on_drop(self: &Arc<Pool>) {
        let pending = self.pending.fetch_sub(1, Ordering::SeqCst);
        assert!(pending > 0);

        if pending == 1 {
            self.idle_shutdown();
        }
    }

    #[inline]
    fn notify(self: &Arc<Self>, is_waking: bool) {
        if !is_waking {
            let state: SyncState = self.sync.load(Ordering::Relaxed).into();
            if state.notified {
                return;
            }
        }

        self.notify_slow(is_waking)
    }

    #[cold]
    fn notify_slow(self: &Arc<Self>, is_waking: bool) {
        let result = self
            .sync
            .fetch_update(Ordering::Release, Ordering::Relaxed, |state| {
                let mut state: SyncState = state.into();
                assert!(state.idle <= state.spawned);
                if is_waking {
                    assert_eq!(state.status, SyncStatus::Waking);
                }

                let can_wake = is_waking || state.status == SyncStatus::Pending;
                if can_wake && state.idle > 0 {
                    state.status = SyncStatus::Signaled;
                } else if can_wake && state.spawned < self.workers.len() {
                    state.status = SyncStatus::Signaled;
                    state.spawned += 1;
                } else if is_waking {
                    state.status = SyncStatus::Pending;
                } else if state.notified {
                    return None;
                }

                state.notified = true;
                Some(state.into())
            });

        if let Ok(sync) = result.map(SyncState::from) {
            if is_waking || sync.status == SyncStatus::Pending {
                if sync.idle == 0 && sync.spawned < self.workers.len() {
                    if self.spawn(sync.spawned) {
                        return;
                    } else {
                        self.sync
                            .fetch_update(Ordering::Release, Ordering::Relaxed, |state| {
                                let mut state: SyncState = state.into();
                                assert!(state.spawned > 0);
                                state.spawned -= 1;
                                Some(state.into())
                            })
                            .unwrap();
                    }
                }

                self.idle_signal();
            }
        }
    }

    #[cold]
    fn spawn(self: &Arc<Self>, index: usize) -> bool {
        if index == 0 {
            self.with_worker(index);
            return true;
        }

        let mut builder = thread::Builder::new().name(String::from("zap-worker"));

        if let Some(stack_size) = self.stack_size {
            builder = builder.stack_size(stack_size.get());
        }

        let pool = Arc::clone(self);
        builder.spawn(move || pool.with_worker(index)).is_ok()
    }

    fn run(self: &Arc<Self>, index: usize) {
        let mut tick = index;
        let mut is_waking = false;
        let mut xorshift = 0xdeadbeef + index;

        match self.workers[index].thread.replace(Some(thread::current())) {
            Some(_) => unreachable!("data race: multiple workers running on the same instance"),
            None => {}
        }

        while let Ok(waking) = self.wait(index, is_waking) {
            is_waking = waking;

            while let Some((task, pushed)) = self.poll(index, tick, &mut xorshift) {
                tick = tick.wrapping_add(1);

                if pushed || is_waking {
                    self.notify(is_waking);
                    is_waking = false;
                }

                unsafe {
                    let vtable = task.as_ref().vtable;
                    (vtable.poll_fn)(task, self, index);
                }
            }
        }
    }

    #[inline]
    fn poll(
        &self,
        index: usize,
        tick: usize,
        xorshift: &mut usize,
    ) -> Option<(NonNull<Task>, bool)> {
        let _ = tick;
        // if tick % 64 == 0 {
        //     if let Ok(task) = self.workers[index].buffer.consume(&self.workers[index].queue) {
        //         return Some((task, true));
        //     }
        // }

        if let Some(task) = self.workers[index].buffer.pop() {
            return Some((task, false));
        }

        self.steal(index, xorshift).map(|task| (task, true))
    }

    #[cold]
    fn steal(&self, index: usize, xorshift: &mut usize) -> Option<NonNull<Task>> {
        let mut queue_attempts = 4;
        loop {
            let shifts = match usize::BITS {
                32 => (13, 17, 5),
                64 => (13, 7, 17),
                _ => unreachable!("architecture unsupported"),
            };

            let mut rng = *xorshift;
            rng ^= rng << shifts.0;
            rng ^= rng >> shifts.1;
            rng ^= rng << shifts.2;
            *xorshift = rng;

            let mut buffer_contended = false;
            let mut queue_contended = match self.workers[index]
                .buffer
                .consume(&self.workers[index].queue)
            {
                Ok(task) => return Some(task),
                Err(contended) => contended,
            };

            let num_workers = self.workers.len();
            let start_index = rng % num_workers;
            for steal_index in (0..num_workers).cycle().skip(start_index).take(num_workers) {
                queue_contended = match self.workers[index]
                    .buffer
                    .consume(&self.workers[steal_index].queue)
                {
                    Ok(task) => return Some(task),
                    Err(contended) => queue_contended || contended,
                };

                if steal_index != index {
                    buffer_contended = match self.workers[steal_index].buffer.steal() {
                        Ok(task) => return Some(task),
                        Err(contended) => buffer_contended || contended,
                    };
                }
            }

            if buffer_contended {
                std::hint::spin_loop();
                continue;
            }

            if queue_contended {
                queue_attempts -= 1;
                if queue_attempts > 0 {
                    thread::yield_now();
                    continue;
                }
            }

            return None;
        }
    }

    #[cold]
    fn wait(self: &Arc<Self>, index: usize, mut is_waking: bool) -> Result<bool, ()> {
        let mut is_idle = false;
        loop {
            let result = self
                .sync
                .fetch_update(Ordering::Acquire, Ordering::Relaxed, |state| {
                    let mut state: SyncState = state.into();
                    if is_waking {
                        assert_eq!(state.status, SyncStatus::Waking);
                    }

                    if is_idle {
                        assert!(state.idle <= state.spawned);
                    } else {
                        assert!(state.idle < state.spawned);
                    }

                    if state.notified {
                        if state.status == SyncStatus::Signaled {
                            state.status = SyncStatus::Waking;
                        }
                        if is_idle {
                            state.idle -= 1;
                        }
                    } else if !is_idle {
                        state.idle += 1;
                        if is_waking {
                            state.status = SyncStatus::Pending;
                        }
                    } else {
                        return None;
                    }

                    state.notified = false;
                    Some(state.into())
                });

            if let Ok(state) = result.map(SyncState::from) {
                if state.notified {
                    return Ok(is_waking || state.status == SyncStatus::Signaled);
                }

                assert!(!is_idle);
                is_idle = true;
                is_waking = false;
            }

            if self.pending.load(Ordering::SeqCst) == 0 {
                return Err(());
            } else {
                self.idle_wait(index);
            }
        }
    }

    const IDLE_BITS: u32 = usize::BITS / 2;
    const IDLE_MASK: usize = (1 << Self::IDLE_BITS) - 1;

    const IDLE_ABA_SHIFT: u32 = Self::IDLE_BITS * 0;
    const IDLE_QUEUE_SHIFT: u32 = Self::IDLE_BITS * 1;

    const IDLE_SHUTDOWN: usize = Self::IDLE_MASK;
    const IDLE_NOTIFIED: usize = Self::IDLE_MASK - 1;

    #[cold]
    fn idle_wait(&self, index: usize) {
        let mut idle = self.idle.load(Ordering::Relaxed);
        loop {
            let mut idle_queue = (idle >> Self::IDLE_QUEUE_SHIFT) & Self::IDLE_MASK;
            let mut idle_aba = (idle >> Self::IDLE_ABA_SHIFT) & Self::IDLE_MASK;
            let mut worker_index = None;

            if idle_queue == Self::IDLE_SHUTDOWN {
                return;
            } else if idle_queue == Self::IDLE_NOTIFIED {
                idle_queue = 0;
            } else {
                worker_index = Some(index);
                self.workers[index]
                    .state
                    .store(idle_queue << 1, Ordering::Relaxed);

                idle_queue = index + 1;
                idle_aba = (idle_aba + 1) & Self::IDLE_MASK;
                assert!(idle_queue != Self::IDLE_NOTIFIED && idle_queue != Self::IDLE_SHUTDOWN);
            }

            if let Err(e) = self.idle.compare_exchange_weak(
                idle,
                (idle_aba << Self::IDLE_ABA_SHIFT) | (idle_queue << Self::IDLE_QUEUE_SHIFT),
                Ordering::SeqCst,
                Ordering::Relaxed,
            ) {
                idle = e;
                continue;
            }

            if let Some(index) = worker_index {
                self.idle_park(index);
            }

            return;
        }
    }

    #[cold]
    fn idle_signal(&self) {
        let mut idle = self.idle.load(Ordering::Relaxed);
        loop {
            let mut idle_queue = (idle >> Self::IDLE_QUEUE_SHIFT) & Self::IDLE_MASK;
            let idle_aba = (idle >> Self::IDLE_ABA_SHIFT) & Self::IDLE_MASK;
            let mut worker_index = None;

            if idle_queue == Self::IDLE_SHUTDOWN {
                return;
            } else if idle_queue == Self::IDLE_NOTIFIED {
                return;
            } else if idle_queue == 0 {
                idle_queue = Self::IDLE_NOTIFIED;
            } else {
                let index = idle_queue - 1;
                worker_index = Some(index);

                idle_queue = self.workers[index].state.load(Ordering::Relaxed) >> 1;
                assert_ne!(idle_queue, Self::IDLE_NOTIFIED);
                assert_ne!(idle_queue, Self::IDLE_SHUTDOWN);
            }

            if let Err(e) = self.idle.compare_exchange_weak(
                idle,
                (idle_aba << Self::IDLE_ABA_SHIFT) | (idle_queue << Self::IDLE_QUEUE_SHIFT),
                Ordering::SeqCst,
                Ordering::Relaxed,
            ) {
                idle = e;
                continue;
            }

            if let Some(index) = worker_index {
                self.idle_unpark(index);
            }

            return;
        }
    }

    #[cold]
    fn idle_shutdown(&self) {
        let idle_shutdown = Self::IDLE_SHUTDOWN << Self::IDLE_QUEUE_SHIFT;
        let idle = self.idle.swap(idle_shutdown, Ordering::SeqCst);

        let mut idle_queue = (idle >> Self::IDLE_QUEUE_SHIFT) & Self::IDLE_MASK;
        loop {
            let index = match idle_queue {
                0 | Self::IDLE_NOTIFIED | Self::IDLE_SHUTDOWN => return,
                worker_index => worker_index - 1,
            };

            idle_queue = self.workers[index].state.load(Ordering::Relaxed) >> 1;
            self.idle_unpark(index);
        }
    }

    #[cold]
    fn idle_park(&self, index: usize) {
        let _ = (unsafe { &*self.workers[index].thread.as_ptr() })
            .as_ref()
            .expect("worker waiting without a thread");

        while self.workers[index].state.load(Ordering::Acquire) & 1 == 0 {
            thread::park();
        }
    }

    #[cold]
    fn idle_unpark(&self, index: usize) {
        self.workers[index].state.store(1, Ordering::Release);
        (unsafe { &*self.workers[index].thread.as_ptr() })
            .as_ref()
            .expect("unparking worker without a thread")
            .unpark()
    }
}

struct List {
    head: NonNull<Task>,
    tail: NonNull<Task>,
}

struct Queue {
    stub: Task,
    head: AtomicPtr<Task>,
    tail: AtomicPtr<Task>,
}

impl Default for Queue {
    fn default() -> Self {
        const STUB_VTABLE: TaskVTable = TaskVTable {
            poll_fn: |_, _, _| unreachable!("vtable call to stub poll_fn"),
            wake_fn: |_, _| unreachable!("vtable call to stub wake_fn"),
            drop_fn: |_| unreachable!("vtable call to stub drop_fn"),
            clone_fn: |_| unreachable!("vtable call to stub clone_fn"),
            detach_fn: |_| unreachable!("vtable call to stub detach_fn"),
            join_fn: |_, _, _| unreachable!("vtable call to stub join_fn"),
        };

        Self {
            stub: Task {
                next: AtomicPtr::new(ptr::null_mut()),
                vtable: &STUB_VTABLE,
                _pinned: PhantomPinned,
            },
            head: AtomicPtr::new(ptr::null_mut()),
            tail: AtomicPtr::new(ptr::null_mut()),
        }
    }
}

impl Queue {
    const IS_CONSUMING: NonNull<Task> = NonNull::<Task>::dangling();

    unsafe fn push(&self, list: List) {
        list.tail
            .as_ref()
            .next
            .store(ptr::null_mut(), Ordering::Relaxed);
        let tail = self.tail.swap(list.tail.as_ptr(), Ordering::AcqRel);

        let prev = NonNull::new(tail).unwrap_or(NonNull::from(&self.stub));
        prev.as_ref()
            .next
            .store(list.head.as_ptr(), Ordering::Release);
    }

    #[inline]
    fn consume<'a>(&'a self) -> Result<impl Iterator<Item = NonNull<Task>> + 'a, bool> {
        let tail = self.tail.load(Ordering::Acquire);
        if tail.is_null() || tail == NonNull::from(&self.stub).as_ptr() {
            Err(false)
        } else {
            self.consume_slow()
        }
    }

    #[cold]
    fn consume_slow<'a>(&'a self) -> Result<impl Iterator<Item = NonNull<Task>> + 'a, bool> {
        let head = self
            .head
            .swap(Self::IS_CONSUMING.as_ptr(), Ordering::Acquire);
        if head == Self::IS_CONSUMING.as_ptr() {
            return Err(true);
        }

        struct Consumer<'a> {
            queue: &'a Queue,
            head: NonNull<Task>,
        }

        impl<'a> Drop for Consumer<'a> {
            fn drop(&mut self) {
                assert_ne!(self.head, Queue::IS_CONSUMING);
                self.queue.head.store(self.head.as_ptr(), Ordering::Release);
            }
        }

        impl<'a> Iterator for Consumer<'a> {
            type Item = NonNull<Task>;

            fn next(&mut self) -> Option<Self::Item> {
                unsafe {
                    let stub = NonNull::from(&self.queue.stub);
                    if self.head == stub {
                        let next = self.head.as_ref().next.load(Ordering::Acquire);
                        self.head = NonNull::new(next)?;
                    }

                    let next = self.head.as_ref().next.load(Ordering::Acquire);
                    if let Some(next) = NonNull::new(next) {
                        return Some(mem::replace(&mut self.head, next));
                    }

                    let tail = self.queue.tail.load(Ordering::Acquire);
                    if Some(self.head) != NonNull::new(tail) {
                        return None;
                    }

                    self.queue.push(List {
                        head: stub,
                        tail: stub,
                    });

                    let next = self.head.as_ref().next.load(Ordering::Acquire);
                    let next = NonNull::new(next)?;
                    Some(mem::replace(&mut self.head, next))
                }
            }
        }

        Ok(Consumer {
            queue: self,
            head: NonNull::new(head).unwrap_or(NonNull::from(&self.stub)),
        })
    }
}

struct Buffer {
    head: AtomicUsize,
    tail: AtomicUsize,
    array: [AtomicPtr<Task>; Self::CAPACITY],
}

impl Default for Buffer {
    fn default() -> Self {
        const EMPTY: AtomicPtr<Task> = AtomicPtr::new(ptr::null_mut());
        Self {
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            array: [EMPTY; Self::CAPACITY],
        }
    }
}

impl Buffer {
    const CAPACITY: usize = 256;

    #[inline]
    fn read(&self, index: usize) -> NonNull<Task> {
        let slot = &self.array[index % self.array.len()];
        let task = NonNull::new(slot.load(Ordering::Relaxed));
        task.expect("read an invalid task from a Buffer")
    }

    #[inline]
    fn write(&self, index: usize, task: NonNull<Task>) {
        let slot = &self.array[index % self.array.len()];
        slot.store(task.as_ptr(), Ordering::Relaxed)
    }

    #[inline]
    unsafe fn push(&self, task: NonNull<Task>) -> Result<(), List> {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Relaxed);

        let size = tail.wrapping_sub(head);
        assert!(size <= self.array.len());

        if size < self.array.len() {
            self.write(tail, task);
            self.tail.store(tail.wrapping_add(1), Ordering::Release);
            return Ok(());
        }

        self.push_overflow(head, tail, task)
    }

    #[cold]
    fn push_overflow(&self, head: usize, tail: usize, task: NonNull<Task>) -> Result<(), List> {
        let size = tail.wrapping_sub(head);
        assert_eq!(size, self.array.len());

        let migrate = size / 2;
        if let Err(head) = self.head.compare_exchange(
            head,
            head.wrapping_add(migrate),
            Ordering::AcqRel,
            Ordering::Relaxed,
        ) {
            let size = tail.wrapping_sub(head);
            assert!(size < self.array.len());

            self.write(tail, task);
            self.tail.store(tail.wrapping_add(1), Ordering::Release);
            return Ok(());
        }

        let first = self.read(head);
        let last = (0..migrate).fold(first, |_, offset| {
            let last = self.read(head.wrapping_add(offset));
            let next = match offset + 1 {
                o if o == migrate => ptr::null_mut(),
                o => self.read(head.wrapping_add(o)).as_ptr(),
            };
            unsafe { last.as_ref().next.store(next, Ordering::Relaxed) };
            last
        });

        unsafe { last.as_ref().next.store(task.as_ptr(), Ordering::Relaxed) };
        return Err(List {
            head: first,
            tail: task,
        });
    }

    fn pop(&self) -> Option<NonNull<Task>> {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Relaxed);

        let size = tail.wrapping_sub(head);
        assert!(size <= self.array.len());
        if size == 0 {
            return None;
        }

        let new_tail = tail.wrapping_sub(1);
        self.tail.store(new_tail, Ordering::SeqCst);
        let head = self.head.load(Ordering::SeqCst);

        let size = tail.wrapping_sub(head);
        assert!(size <= self.array.len());

        let task = self.read(new_tail);
        if size > 1 {
            return Some(task);
        }

        self.tail.store(tail, Ordering::Relaxed);
        if size == 1 {
            match self
                .head
                .compare_exchange(head, tail, Ordering::SeqCst, Ordering::Relaxed)
            {
                Ok(_) => return Some(task),
                Err(_) => {}
            }
        }

        None
    }

    fn steal(&self) -> Result<NonNull<Task>, bool> {
        let head = self.head.load(Ordering::Acquire);
        let tail = self.tail.load(Ordering::Acquire);

        let size = tail.wrapping_sub(head);
        if size == 0 || size > self.array.len() {
            return Err(false);
        }

        let task = self.read(head);
        match self.head.compare_exchange(
            head,
            head.wrapping_add(1),
            Ordering::SeqCst,
            Ordering::Relaxed,
        ) {
            Ok(_) => Ok(task),
            Err(_) => Err(true),
        }
    }

    #[cold]
    fn consume(&self, queue: &Queue) -> Result<NonNull<Task>, bool> {
        queue.consume().and_then(|mut consumer| {
            consumer.next().ok_or(false).map(|consumed| {
                let head = self.head.load(Ordering::Relaxed);
                let tail = self.tail.load(Ordering::Relaxed);

                let size = tail.wrapping_sub(head);
                assert!(size <= self.array.len());

                let new_tail =
                    consumer
                        .take(self.array.len() - size)
                        .fold(tail, |new_tail, task| {
                            self.write(new_tail, task);
                            new_tail.wrapping_add(1)
                        });

                if new_tail != tail {
                    self.tail.store(new_tail, Ordering::Release);
                }

                consumed
            })
        })
    }
}

#[repr(align(4))]
struct Task {
    next: AtomicPtr<Self>,
    vtable: &'static TaskVTable,
    _pinned: PhantomPinned,
}

struct TaskVTable {
    poll_fn: unsafe fn(NonNull<Task>, &Arc<Pool>, usize),
    wake_fn: unsafe fn(NonNull<Task>, bool),
    drop_fn: unsafe fn(NonNull<Task>),
    clone_fn: unsafe fn(NonNull<Task>),
    detach_fn: unsafe fn(NonNull<Task>),
    join_fn: unsafe fn(NonNull<Task>, &Waker, *mut ()) -> bool,
}

enum TaskData<F: Future> {
    Polling(F),
    Ready(F::Output),
    Consumed,
}

struct TaskFuture<F: Future> {
    task: Task,
    ref_count: AtomicUsize,
    data: UnsafeCell<TaskData<F>>,
    data_state: AtomicU8,
    waker: UnsafeCell<Option<Waker>>,
    waker_state: AtomicU8,
}

impl<F: Future> TaskFuture<F> {
    const DATA_IDLE: u8 = 0b00;
    const DATA_SCHEDULED: u8 = 0b01;
    const DATA_RUNNING: u8 = 0b10;
    const DATA_NOTIFIED: u8 = 0b11;
    const DATA_READY: u8 = 0b100;

    const WAKER_EMPTY: u8 = 0b00;
    const WAKER_UPDATING: u8 = 0b01;
    const WAKER_READY: u8 = 0b10;
    const WAKER_NOTIFIED: u8 = 0b11;

    const TASK_VTABLE: TaskVTable = TaskVTable {
        poll_fn: Self::on_poll,
        wake_fn: Self::on_wake,
        drop_fn: Self::on_drop,
        clone_fn: Self::on_clone,
        detach_fn: Self::on_detach,
        join_fn: Self::on_join,
    };

    fn spawn(future: F, pool: &Arc<Pool>, worker_index: usize) -> JoinHandle<F::Output>
    where
        F: Send + 'static,
        F::Output: Send + 'static,
    {
        let this = Box::pin(TaskFuture {
            task: Task {
                next: AtomicPtr::new(ptr::null_mut()),
                vtable: &Self::TASK_VTABLE,
                _pinned: PhantomPinned,
            },
            ref_count: AtomicUsize::new(2),
            data_state: AtomicU8::new(Self::DATA_SCHEDULED),
            data: UnsafeCell::new(TaskData::Polling(future)),
            waker: UnsafeCell::new(None),
            waker_state: AtomicU8::new(Self::WAKER_EMPTY),
        });

        unsafe {
            let this = Pin::into_inner_unchecked(this);
            let this_ptr = NonNull::new_unchecked(Box::into_raw(this));
            let task_ptr = NonNull::from(&this_ptr.as_ref().task);

            pool.clone_ref();
            Self::schedule_with(task_ptr, pool, worker_index, false);

            JoinHandle {
                task: Some(task_ptr),
                _phantom: PhantomData,
            }
        }
    }

    unsafe fn schedule(task: NonNull<Task>, be_fair: bool) {
        Pool::with_current(|pool, worker_index| {
            Self::schedule_with(task, pool, worker_index, be_fair)
        });
    }

    unsafe fn schedule_with(
        task: NonNull<Task>,
        pool: &Arc<Pool>,
        worker_index: usize,
        be_fair: bool,
    ) {
        Self::with(task, |this| {
            assert_ne!(this.ref_count.load(Ordering::Relaxed), 0);

            let data_state = this.data_state.load(Ordering::Relaxed);
            assert_eq!(data_state & Self::DATA_READY, 0);
            match data_state {
                Self::DATA_NOTIFIED => {}
                Self::DATA_SCHEDULED => {}
                Self::DATA_IDLE => {
                    unreachable!("scheduled task without transitioning to scheduled")
                }
                Self::DATA_RUNNING => unreachable!("scheduled task when already running"),
                data_state => unreachable!("invalid data_state {:?}", data_state),
            }
        });

        if be_fair {
            pool.workers[worker_index].queue.push(List {
                head: task,
                tail: task,
            });
        } else if let Err(overflowed) = pool.workers[worker_index].buffer.push(task) {
            pool.workers[worker_index].queue.push(overflowed);
        }

        let is_waking = false;
        pool.notify(is_waking)
    }

    fn from_task(task: NonNull<Task>) -> NonNull<Self> {
        let this = MaybeUninit::<Self>::uninit();
        let this_task_ptr = unsafe { ptr::addr_of!((*this.as_ptr()).task) };
        let this_task_offset = (this_task_ptr as usize) - (this.as_ptr() as usize);

        let this_ptr = (task.as_ptr() as usize) - this_task_offset;
        NonNull::new(this_ptr as *mut Self).expect("invalid task for containerof()")
    }

    unsafe fn with<T>(task: NonNull<Task>, f: impl FnOnce(Pin<&Self>) -> T) -> T {
        let this_ptr = Self::from_task(task);
        f(Pin::new_unchecked(this_ptr.as_ref()))
    }

    unsafe fn poll(self: Pin<&Self>) -> Poll<F::Output> {
        const WAKER_VTABLE: RawWakerVTable = RawWakerVTable::new(
            |ptr| unsafe {
                let task = NonNull::new_unchecked(ptr as *mut Task);
                let vtable = task.as_ref().vtable;
                (vtable.clone_fn)(task);
                RawWaker::new(ptr, &WAKER_VTABLE)
            },
            |ptr| unsafe {
                let task = NonNull::new_unchecked(ptr as *mut Task);
                let vtable = task.as_ref().vtable;
                (vtable.wake_fn)(task, true)
            },
            |ptr| unsafe {
                let task = NonNull::new_unchecked(ptr as *mut Task);
                let vtable = task.as_ref().vtable;
                (vtable.wake_fn)(task, false)
            },
            |ptr| unsafe {
                let task = NonNull::new_unchecked(ptr as *mut Task);
                let vtable = task.as_ref().vtable;
                (vtable.drop_fn)(task)
            },
        );

        let ptr = &self.task as *const Task as *const ();
        let raw_waker = RawWaker::new(ptr, &WAKER_VTABLE);
        let waker = Waker::from_raw(raw_waker);
        let mut context = Context::from_waker(&waker);

        let polled = match &mut *self.data.get() {
            TaskData::Polling(ref mut future) => Pin::new_unchecked(future).poll(&mut context),
            TaskData::Ready(_) => unreachable!("tried to poll future that was already complete"),
            TaskData::Consumed => unreachable!("tried to poll future that was already joined"),
        };

        mem::drop(context); // still references the waker
        mem::forget(waker); // don't drop waker. It wasn't cloned so drop would consume a ref count
        polled
    }

    unsafe fn on_poll(task: NonNull<Task>, pool: &Arc<Pool>, worker_index: usize) {
        let poll_result = Self::with(task, |this| {
            assert_ne!(this.ref_count.load(Ordering::Relaxed), 0);

            let data_state = this.data_state.load(Ordering::Relaxed);
            assert_eq!(data_state & Self::DATA_READY, 0);
            match data_state {
                Self::DATA_SCHEDULED => {}
                Self::DATA_NOTIFIED => {}
                Self::DATA_IDLE => unreachable!("polling task without transitioning to scheduled"),
                Self::DATA_RUNNING => unreachable!("polling task when already running"),
                data_state => unreachable!("invalid data_state {:b}", data_state),
            }

            this.data_state.store(Self::DATA_RUNNING, Ordering::Relaxed);
            match this.poll() {
                Poll::Ready(output) => Ok(output),
                Poll::Pending => Err({
                    match this.data_state.compare_exchange(
                        Self::DATA_RUNNING,
                        Self::DATA_IDLE,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    ) {
                        Ok(_) => Poll::Pending,
                        Err(Self::DATA_NOTIFIED) => Poll::Ready(()),
                        Err(data_state) => unreachable!("invalid data_state {:b}", data_state),
                    }
                }),
            }
        });

        let output = match poll_result {
            Ok(output) => output,
            Err(Poll::Pending) => return,
            Err(Poll::Ready(_)) => return Self::schedule_with(task, pool, worker_index, true),
        };

        Self::with(task, |this| {
            assert_ne!(this.ref_count.load(Ordering::Relaxed), 0);
            match mem::replace(&mut *this.data.get(), TaskData::Ready(output)) {
                TaskData::Polling(future) => mem::drop(future),
                TaskData::Ready(_) => unreachable!("future marked ready when already ready"),
                TaskData::Consumed => unreachable!("future marked ready when already joined"),
            }

            let data_state = this.data_state.load(Ordering::Relaxed);
            assert_eq!(data_state & Self::DATA_READY, 0);
            match data_state {
                Self::DATA_RUNNING => {}
                Self::DATA_NOTIFIED => {}
                Self::DATA_IDLE => unreachable!("completing task while not running"),
                Self::DATA_SCHEDULED => unreachable!("completing task that is scheduled"),
                data_state => unreachable!("invalid data_state {:b}", data_state),
            }

            this.data_state.store(
                Self::DATA_READY | Self::DATA_NOTIFIED,
                Ordering::Release,
            );

            if let Some(waker) = match this
                .waker_state
                .swap(Self::WAKER_NOTIFIED, Ordering::AcqRel)
            {
                Self::WAKER_EMPTY => None,
                Self::WAKER_UPDATING => None,
                Self::WAKER_READY => mem::replace(&mut *this.waker.get(), None),
                Self::WAKER_NOTIFIED => unreachable!("waker already notified"),
                waker_state => unreachable!("invalid waker_state {:b}", waker_state),
            } {
                waker.wake();
            }
        });

        pool.on_drop();
        Self::on_drop(task)
    }

    unsafe fn on_wake(task: NonNull<Task>, also_drop: bool) {
        match Self::with(task, |this| {
            assert_ne!(this.ref_count.load(Ordering::Relaxed), 0);
            this.data_state
                .fetch_update(
                    Ordering::AcqRel,
                    Ordering::Relaxed,
                    |data_state| {
                        if data_state & Self::DATA_READY != 0 {
                            return None;
                        }

                        match data_state {
                            Self::DATA_IDLE => Some(Self::DATA_SCHEDULED),
                            Self::DATA_RUNNING => Some(Self::DATA_NOTIFIED),
                            Self::DATA_SCHEDULED => None,
                            Self::DATA_NOTIFIED => None,
                            _ => unreachable!("invalid data_state {:b}", data_state),
                        }
                    },
                )
        }) {
            Ok(Self::DATA_IDLE) => Self::schedule(task, false),
            Ok(Self::DATA_RUNNING) => {}
            Ok(_) => unreachable!(),
            Err(_) => {}
        }

        if also_drop {
            Self::on_drop(task);
        }
    }

    unsafe fn on_clone(task: NonNull<Task>) {
        Self::with(task, |this| {
            let ref_count = this.ref_count.fetch_add(1, Ordering::Relaxed);
            assert_ne!(ref_count, !0usize);
            assert_ne!(ref_count, 0);
        });
    }

    unsafe fn on_drop(task: NonNull<Task>) {
        if Self::with(task, |this| {
            let ref_count = this.ref_count.fetch_sub(1, Ordering::AcqRel);
            assert_ne!(ref_count, 0);

            let last_ref = ref_count == 1;
            if last_ref {
                let data_state = this.data_state.load(Ordering::Relaxed);
                assert_ne!(data_state & Self::DATA_READY, 0);
                assert_ne!(data_state & 0b11, Self::DATA_SCHEDULED);
                assert_ne!(data_state & 0b11, Self::DATA_IDLE);

                let waker_state = this.waker_state.load(Ordering::Relaxed);
                assert_eq!(waker_state, Self::WAKER_NOTIFIED);
            }

            last_ref
        }) {
            let this_ptr = Self::from_task(task);
            mem::drop(Box::from_raw(this_ptr.as_ptr()));
        }
    }

    unsafe fn on_detach(task: NonNull<Task>) {
        let _ = Self::update_waker(task, None);
        Self::on_drop(task)
    }

    unsafe fn on_join(task: NonNull<Task>, waker_ref: &Waker, output_ptr: *mut ()) -> bool {
        if Self::update_waker(task, Some(waker_ref)) {
            return false;
        }

        Self::with(task, |this| {
            assert_ne!(this.ref_count.load(Ordering::Relaxed), 0);

            let data_state = this.data_state.load(Ordering::Acquire);
            assert_ne!(data_state & Self::DATA_READY, 0);

            match mem::replace(&mut *this.data.get(), TaskData::Consumed) {
                TaskData::Consumed => unreachable!("data consumed when already consumed"),
                TaskData::Polling(_) => unreachable!("data consumed before future completed"),
                TaskData::Ready(output) => ptr::write(output_ptr as *mut F::Output, output),
            }
        });

        Self::on_drop(task);
        true
    }

    unsafe fn update_waker(task: NonNull<Task>, waker_ref: Option<&Waker>) -> bool {
        Self::with(task, |this| {
            assert_ne!(this.ref_count.load(Ordering::Relaxed), 0);

            let data_state = this.data_state.load(Ordering::Relaxed);
            if data_state & Self::DATA_READY != 0 {
                return false;
            }

            let waker_state = this.waker_state.load(Ordering::Relaxed);
            match waker_state {
                Self::WAKER_NOTIFIED => return false,
                Self::WAKER_EMPTY if waker_ref.is_none() => return false,
                Self::WAKER_UPDATING => unreachable!("multiple threads trying to update waker"),
                Self::WAKER_EMPTY => {}
                Self::WAKER_READY => {}
                _ => unreachable!("invalid waker_state {:b}", waker_state),
            }

            match this.waker_state.compare_exchange(
                waker_state,
                Self::WAKER_UPDATING,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => {}
                Err(Self::WAKER_NOTIFIED) => return false,
                Err(waker_state) => unreachable!("invalid waker_state {:b}", waker_state),
            }

            match mem::replace(&mut *this.waker.get(), waker_ref.map(|waker| waker.clone())) {
                Some(_dropped_waker) => assert_eq!(waker_state, Self::WAKER_READY),
                None => assert_eq!(waker_state, Self::WAKER_EMPTY),
            }

            match this.waker_state.compare_exchange(
                Self::WAKER_UPDATING,
                match waker_ref {
                    Some(_) => Self::WAKER_READY,
                    None => Self::WAKER_EMPTY,
                },
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Ok(_) => return true,
                Err(Self::WAKER_NOTIFIED) => {}
                Err(waker_state) => unreachable!("invalid waker_state {:b}", waker_state),
            }

            *this.waker.get() = None;
            false
        })
    }
}

pub struct JoinHandle<T> {
    task: Option<NonNull<Task>>,
    _phantom: PhantomData<T>,
}

unsafe impl<T: Send> Send for JoinHandle<T> {}

impl<T> Drop for JoinHandle<T> {
    fn drop(&mut self) {
        if let Some(task) = self.task {
            unsafe {
                let vtable = task.as_ref().vtable;
                (vtable.detach_fn)(task)
            }
        }
    }
}

impl<T> Future for JoinHandle<T> {
    type Output = T;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut_self = unsafe { Pin::get_unchecked_mut(self) };
        let task = mut_self.task.expect("JoinHandle polled after completion");

        let mut output = MaybeUninit::<T>::uninit();
        let output_ready = unsafe {
            let vtable = task.as_ref().vtable;
            (vtable.join_fn)(task, ctx.waker(), output.as_mut_ptr() as *mut ())
        };

        if output_ready {
            mut_self.task = None;
            Poll::Ready(unsafe { output.assume_init() })
        } else {
            Poll::Pending
        }
    }
}
