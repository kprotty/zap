use std::{
    cell::{Cell, UnsafeCell},
    future::Future,
    marker::{PhantomData, PhantomPinned},
    mem::{self, MaybeUninit},
    num::{NonZeroU16, NonZeroUsize},
    pin::Pin,
    ptr::{self, NonNull},
    sync::{
        atomic::{AtomicPtr, AtomicUsize, Ordering},
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

        value | match self.status {
            SyncStatus::Pending => 0b00,
            SyncStatus::Waking => 0b01,
            SyncStatus::Signaled => 0b10,
        }
    }
}

#[derive(Default)]
struct Worker {
    queue: Queue,
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

    fn drop_ref(self: &Arc<Pool>) {
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
        let result = self.sync.fetch_update(Ordering::Release, Ordering::Relaxed, |state| {
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
        let mut is_waking = false;
        let mut xorshift = 0xdeadbeef + index;

        match self.workers[index].thread.replace(Some(thread::current())) {
            Some(_) => unreachable!("data race: multiple workers running on the same instance"),
            None => {}
        }

        while let Ok(waking) = self.wait(index, is_waking) {
            is_waking = waking;

            while let Some((task, pushed)) = self.poll(index, &mut xorshift) {
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
    fn poll(&self, index: usize, xorshift: &mut usize) -> Option<(NonNull<Task>, bool)> {
        if let Ok(task) = self.workers[index].queue.pop() {
            return Some((task, false));
        }

        self.steal(index, xorshift).map(|task| (task, true))
    }

    #[cold]
    fn steal(&self, index: usize, xorshift: &mut usize) -> Option<NonNull<Task>> {
        for _ in 0..4 {
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

            let num_workers = self.workers.len();
            let start_index = rng % num_workers;
            let mut was_contended = match self.workers[index].queue.pop() {
                Ok(task) => return Some(task),
                Err(contended) => contended,
            };

            for steal_index in (0..num_workers).cycle().skip(start_index).take(num_workers)
            {
                was_contended = match self.workers[steal_index].queue.pop() {
                    Ok(task) => return Some(task),
                    Err(contended) => was_contended || contended,
                };
            }

            if was_contended {
                std::hint::spin_loop(); // thread::yield_now();
            } else {
                break;
            }
        }

        None
    }

    #[cold]
    fn wait(self: &Arc<Self>, index: usize, mut is_waking: bool) -> Result<bool, ()> {
        let mut is_idle = false;
        loop {
            let result = self.sync.fetch_update(Ordering::Acquire, Ordering::Relaxed, |state| {
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
    const IS_POPPING: NonNull<Task> = NonNull::<Task>::dangling();

    unsafe fn push(&self, task: NonNull<Task>) {
        task.as_ref().next.store(ptr::null_mut(), Ordering::Relaxed);
        let tail = self.tail.swap(task.as_ptr(), Ordering::AcqRel);

        let prev = NonNull::new(tail).unwrap_or(NonNull::from(&self.stub));
        prev.as_ref().next.store(task.as_ptr(), Ordering::Release);
    }

    fn pop(&self) -> Result<NonNull<Task>, bool> {
        if self.tail.load(Ordering::Acquire).is_null() {
            return Err(false);
        }

        let head = self.head.swap(Self::IS_POPPING.as_ptr(), Ordering::Acquire);
        if head == Self::IS_POPPING.as_ptr() {
            return Err(true);
        }

        unsafe {
            let mut head = NonNull::new(head).unwrap_or(NonNull::from(&self.stub));
            if head == NonNull::from(&self.stub) {
                head = match NonNull::new(head.as_ref().next.load(Ordering::Acquire)) {
                    Some(next) => next,
                    None => {
                        self.head.store(ptr::null_mut(), Ordering::Release);
                        return Err(false);
                    }
                };
            }

            if let Some(next) = NonNull::new(head.as_ref().next.load(Ordering::Acquire)) {
                self.head.store(next.as_ptr(), Ordering::Release);
                return Ok(head);
            }

            let tail = self.tail.load(Ordering::Acquire);
            if Some(head) != NonNull::new(tail) {
                self.head.store(head.as_ptr(), Ordering::Release);
                return Err(true);
            }

            self.push(NonNull::from(&self.stub));
            
            if let Some(next) = NonNull::new(head.as_ref().next.load(Ordering::Acquire)) {
                self.head.store(next.as_ptr(), Ordering::Release);
                Ok(head)
            } else {
                self.head.store(head.as_ptr(), Ordering::Release);
                Err(false)
            }
        }
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

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum TaskStatus {
    Running = 0,
    Scheduled = 1,
    Idle = 2,
    Notified = 3,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum TaskWaker {
    Empty = 0,
    Updating = 1,
    Ready = 2,
}

#[derive(Copy, Clone, Debug)]
struct TaskState {
    ref_count: usize,
    completed: bool,
    waker: TaskWaker,
    status: TaskStatus,
}

impl TaskState {
    const TASK_MASK: usize = 0b11;
    const TASK_RUNNING: usize = 0b00;
    const TASK_SCHEDULED: usize = 0b01;
    const TASK_IDLE: usize = 0b10;
    const TASK_NOTIFIED: usize = 0b11;

    const WAKER_MASK: usize = 0b1100;
    const WAKER_EMPTY: usize = 0b0000;
    const WAKER_UPDATING: usize = 0b0100;
    const WAKER_READY: usize = 0b1000;

    const REF_COUNT_SHIFT: u32 = 5;
    const FUTURE_COMPLETED: usize = 0b10000;
}

impl From<usize> for TaskState {
    fn from(value: usize) -> Self {
        Self {
            ref_count: value >> Self::REF_COUNT_SHIFT,
            completed: value & Self::FUTURE_COMPLETED != 0,
            waker: match value & Self::WAKER_MASK {
                Self::WAKER_EMPTY => TaskWaker::Empty,
                Self::WAKER_UPDATING => TaskWaker::Updating,
                Self::WAKER_READY => TaskWaker::Ready,
                _ => unreachable!("invalid task waker state"),
            },
            status: match value & Self::TASK_MASK {
                Self::TASK_RUNNING => TaskStatus::Running,
                Self::TASK_SCHEDULED => TaskStatus::Scheduled,
                Self::TASK_IDLE => TaskStatus::Idle,
                Self::TASK_NOTIFIED => TaskStatus::Notified,
                _ => unreachable!("invalid task status"),
            },
        }
    }
}

impl Into<usize> for TaskState {
    fn into(self) -> usize {
        let mut value = 0;
        value |= self.ref_count << Self::REF_COUNT_SHIFT;
        assert!(self.ref_count <= !0usize >> Self::REF_COUNT_SHIFT);

        if self.completed {
            value |= Self::FUTURE_COMPLETED;
        }

        value |= match self.waker {
            TaskWaker::Empty => Self::WAKER_EMPTY,
            TaskWaker::Updating => Self::WAKER_UPDATING,
            TaskWaker::Ready => Self::WAKER_READY,
        };

        value
            | match self.status {
                TaskStatus::Running => Self::TASK_RUNNING,
                TaskStatus::Scheduled => Self::TASK_SCHEDULED,
                TaskStatus::Idle => Self::TASK_IDLE,
                TaskStatus::Notified => Self::TASK_NOTIFIED,
            }
    }
}

struct TaskFuture<F: Future> {
    task: Task,
    state: AtomicUsize,
    data: UnsafeCell<TaskData<F>>,
    waker: UnsafeCell<Option<Waker>>,
}

impl<F: Future> TaskFuture<F> {
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
            state: AtomicUsize::new(
                TaskState {
                    ref_count: 2,
                    completed: false,
                    waker: TaskWaker::Empty,
                    status: TaskStatus::Scheduled,
                }
                .into(),
            ),
            data: UnsafeCell::new(TaskData::Polling(future)),
            waker: UnsafeCell::new(None),
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
        let state: TaskState = Self::with(task, |this| this.state.load(Ordering::Relaxed)).into();
        assert_ne!(state.ref_count, 0);
        assert_ne!(state.completed, true);

        match state.status {
            TaskStatus::Running => unreachable!("scheduled a task that was running"),
            TaskStatus::Idle => unreachable!("scheduled a task that was idle"),
            TaskStatus::Scheduled => {}
            TaskStatus::Notified => {}
        }

        let _ = be_fair;
        pool.workers[worker_index].queue.push(task);

        pool.notify(false);
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
            this.state
                .fetch_update(Ordering::Acquire, Ordering::Relaxed, |state| {
                    let mut state: TaskState = state.into();
                    assert_ne!(state.ref_count, 0);
                    assert_eq!(state.completed, false);

                    state.status = match state.status {
                        TaskStatus::Running => {
                            unreachable!("tried to poll future that was already running")
                        }
                        TaskStatus::Idle => {
                            unreachable!("tried to poll future that wasn't scheduled")
                        }
                        TaskStatus::Scheduled => TaskStatus::Running,
                        TaskStatus::Notified => TaskStatus::Running,
                    };

                    Some(state.into())
                })
                .unwrap();

            match this.poll() {
                Poll::Ready(output) => Ok(output),
                Poll::Pending => Err({
                    let become_idle =
                        this.state
                            .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |state| {
                                let mut state: TaskState = state.into();
                                assert_ne!(state.ref_count, 0);
                                assert_eq!(state.completed, false);

                                state.status = match state.status {
                                    TaskStatus::Scheduled => {
                                        unreachable!("future was polled when task wasn't running")
                                    }
                                    TaskStatus::Idle => {
                                        unreachable!("future was polled when task was idle")
                                    }
                                    TaskStatus::Running => TaskStatus::Idle,
                                    TaskStatus::Notified => return None,
                                };

                                Some(state.into())
                            });

                    match become_idle {
                        Ok(_) => Poll::Pending,
                        Err(_) => Poll::Ready(()),
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
            match mem::replace(&mut *this.data.get(), TaskData::Ready(output)) {
                TaskData::Polling(future) => mem::drop(future),
                TaskData::Ready(_) => unreachable!("future marked ready when already ready"),
                TaskData::Consumed => unreachable!("future marked ready when already joined"),
            }

            let state = this
                .state
                .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |state| {
                    let mut state: TaskState = state.into();
                    assert_ne!(state.ref_count, 0);
                    assert_ne!(state.completed, true);
                    assert_ne!(state.status, TaskStatus::Scheduled);
                    assert_ne!(state.status, TaskStatus::Idle);
                    state.completed = true;
                    Some(state.into())
                })
                .map(TaskState::from)
                .unwrap();

            if let Some(waker) = match state.waker {
                TaskWaker::Empty => None,
                TaskWaker::Updating => None,
                TaskWaker::Ready => mem::replace(&mut *this.waker.get(), None),
            } {
                waker.wake();
            }
        });

        pool.drop_ref();
        Self::drop_ref(task)
    }

    unsafe fn on_wake(task: NonNull<Task>, also_drop: bool) {
        if let Ok(state) = Self::with(task, |this| {
            this.state
                .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |state| {
                    let mut state: TaskState = state.into();
                    assert_ne!(state.ref_count, 0);

                    if state.completed {
                        return None;
                    }

                    state.status = match state.status {
                        TaskStatus::Running => TaskStatus::Notified,
                        TaskStatus::Idle => TaskStatus::Scheduled,
                        TaskStatus::Scheduled => return None,
                        TaskStatus::Notified => return None,
                    };

                    Some(state.into())
                })
                .map(TaskState::from)
        }) {
            assert_ne!(state.ref_count, 0);
            assert_ne!(state.completed, true);
            assert_ne!(state.status, TaskStatus::Scheduled);
            assert_ne!(state.status, TaskStatus::Notified);

            if state.status == TaskStatus::Idle {
                Self::schedule(task, false);
            }
        }

        if also_drop {
            Self::drop_ref(task);
        }
    }

    unsafe fn on_clone(task: NonNull<Task>) {
        Self::with(task, |this| {
            this.state
                .fetch_update(Ordering::Acquire, Ordering::Relaxed, |state| {
                    let mut state: TaskState = state.into();
                    assert_ne!(state.ref_count, 0);
                    state.ref_count += 1;
                    Some(state.into())
                })
                .unwrap()
        });
    }

    unsafe fn on_drop(task: NonNull<Task>) {
        Self::drop_ref(task)
    }

    unsafe fn drop_ref(task: NonNull<Task>) {
        let state = Self::with(task, |this| {
            this.state
                .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |state| {
                    let mut state: TaskState = state.into();
                    assert_ne!(state.ref_count, 0);
                    state.ref_count -= 1;
                    Some(state.into())
                })
                .map(TaskState::from)
                .unwrap()
        });

        if state.ref_count == 1 {
            assert_ne!(state.completed, false);
            assert_ne!(state.waker, TaskWaker::Updating);
            assert_ne!(state.status, TaskStatus::Scheduled);

            let this_ptr = Self::from_task(task);
            mem::drop(Box::from_raw(this_ptr.as_ptr()));
        }
    }

    unsafe fn on_detach(task: NonNull<Task>) {
        Self::with(task, |this| {
            let remove_waker =
                this.state
                    .fetch_update(Ordering::Acquire, Ordering::Acquire, |state| {
                        let mut state: TaskState = state.into();
                        assert_ne!(state.ref_count, 0);
                        assert_ne!(state.waker, TaskWaker::Updating);

                        if state.completed || state.waker == TaskWaker::Empty {
                            return None;
                        }

                        assert_eq!(state.waker, TaskWaker::Ready);
                        state.waker = TaskWaker::Empty;
                        Some(state.into())
                    });

            if remove_waker.is_ok() {
                let old_waker = mem::replace(&mut *this.waker.get(), None);
                let old_waker = old_waker.expect("removed an invalid Waker");
                mem::drop(old_waker);
            }
        });
    }

    unsafe fn on_join(task: NonNull<Task>, waker_ref: &Waker, output_ptr: *mut ()) -> bool {
        let update_waker = Self::with(task, |this| {
            this.state
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |state| {
                    let mut state: TaskState = state.into();
                    assert_ne!(state.ref_count, 0);
                    assert_ne!(state.waker, TaskWaker::Updating);

                    if state.completed {
                        return None;
                    }

                    state.waker = TaskWaker::Updating;
                    Some(state.into())
                })
        });

        if let Ok(mut state) = update_waker.map(TaskState::from) {
            state = Self::with(task, |this| {
                match mem::replace(&mut *this.waker.get(), Some(waker_ref.clone())) {
                    None => assert_eq!(state.waker, TaskWaker::Empty),
                    Some(old_waker) => {
                        assert_eq!(state.waker, TaskWaker::Ready);
                        mem::drop(old_waker);
                    }
                }

                let mut removed_waker = false;
                this.state
                    .fetch_update(Ordering::Release, Ordering::Relaxed, |state| {
                        let mut state: TaskState = state.into();
                        assert_ne!(state.ref_count, 0);
                        assert_eq!(state.waker, TaskWaker::Updating);

                        state.waker = TaskWaker::Ready;
                        if state.completed {
                            state.waker = TaskWaker::Empty;

                            if !removed_waker {
                                let old_waker = mem::replace(&mut *this.waker.get(), None);
                                let old_waker = old_waker.expect("removed invalid Waker");
                                mem::drop(old_waker);
                                removed_waker = true;
                            }
                        }

                        assert_ne!(state.waker, TaskWaker::Updating);
                        Some(state.into())
                    })
                    .unwrap()
                    .into()
            });

            assert_ne!(state.ref_count, 0);
            if !state.completed {
                return false;
            }
        }

        Self::with(task, |this| {
            match mem::replace(&mut *this.data.get(), TaskData::Consumed) {
                TaskData::Consumed => unreachable!("data consumed when already consumed"),
                TaskData::Polling(_) => unreachable!("data consumed before future completed"),
                TaskData::Ready(output) => ptr::write(output_ptr as *mut F::Output, output),
            }
        });

        Self::drop_ref(task);
        true
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
