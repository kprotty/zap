use std::{
    cell::{RefCell, UnsafeCell},
    future::Future,
    marker::{PhantomData, PhantomPinned},
    mem::{self, MaybeUninit},
    num::NonZeroUsize,
    pin::Pin,
    ptr::{self, NonNull},
    hint::spin_loop,
    rc::Rc,
    sync::{
        atomic::{AtomicPtr, AtomicU8, AtomicUsize, Ordering},
        Arc, Condvar, Mutex,
    },
    task::{Context, Poll, RawWaker, RawWakerVTable, Waker},
};

#[derive(Default)]
pub struct Builder {
    max_threads: Option<NonZeroUsize>,
    stack_size: Option<NonZeroUsize>,
}

impl Builder {
    pub const fn new() -> Self {
        Self {
            max_threads: None,
            stack_size: None,
        }
    }

    pub fn max_threads(mut self, num_threads: NonZeroUsize) -> Self {
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
        let pool = Pool::from_builder(self);
        let mut join_handle = TaskFuture::spawn(&pool, 0, future);

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
                Poll::Pending => unreachable!("Future did not complete after pool shutdown"),
            }
        }
    }
}

pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    Pool::with_current(|pool, worker_index| TaskFuture::spawn(pool, worker_index, future))
        .unwrap_or_else(|| unreachable!("spawn() called outside of thread pool"))
}

#[allow(unused)]
#[derive(Debug)]
enum PoolEvent {
    TaskSpawned {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskIdling {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskScheduled {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskPolling {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskPolled {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskShutdown {
        worker_index: usize,
        task: NonNull<Task>,
    },
    WorkerSpawned {
        worker_index: usize,
    },
    WorkerPushed {
        worker_index: usize,
        task: NonNull<Task>,
    },
    WorkerPopped {
        worker_index: usize,
        task: NonNull<Task>,
    },
    WorkerStole {
        worker_index: usize,
        target_index: usize,
        count: usize,
    },
    WorkerIdling {
        worker_index: usize,
    },
    WorkerScheduled {
        worker_index: usize,
    },
    WorkerShutdown {
        worker_index: usize,
    },
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum SyncStatus {
    Pending,
    Waking,
    Signaled,
}

#[derive(Copy, Clone, Debug)]
struct SyncState {
    status: SyncStatus,
    notified: bool,
    spawned: usize,
    idle: usize,
}

impl SyncState {
    const COUNT_BITS: u32 = (usize::BITS - 4) / 2;
    const COUNT_MASK: usize = (1 << Self::COUNT_BITS) - 1;
}

impl From<usize> for SyncState {
    fn from(value: usize) -> Self {
        Self {
            status: match value & 0b11 {
                0b00 => SyncStatus::Pending,
                0b01 => SyncStatus::Waking,
                0b10 => SyncStatus::Signaled,
                _ => unreachable!("invalid sync-status"),
            },
            notified: value & 0b100 != 0,
            spawned: (value >> 4) & Self::COUNT_MASK,
            idle: (value >> (Self::COUNT_BITS + 4)) & Self::COUNT_MASK,
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
    injector: Injector,
    buffer: Buffer,
}

struct Pool {
    idle_cond: Condvar,
    idle_sema: Mutex<usize>,
    stack_size: Option<NonZeroUsize>,
    sync: AtomicUsize,
    pending: AtomicUsize,
    injecting: AtomicUsize,
    workers: Box<[Worker]>,
}

impl Pool {
    pub fn from_builder(builder: Builder) -> Arc<Pool> {
        let num_threads = builder
            .max_threads
            .map(|t| t.get())
            .unwrap_or(0)
            .max(1);

        Arc::new(Self {
            idle_cond: Condvar::new(),
            idle_sema: Mutex::new(0),
            stack_size: builder.stack_size,
            sync: AtomicUsize::new(0),
            pending: AtomicUsize::new(0),
            injecting: AtomicUsize::new(0),
            workers: (0..num_threads)
                .map(|_| Worker::default())
                .collect::<Vec<_>>()
                .into_boxed_slice()
        })
    }

    pub fn emit(self: &Arc<Self>, event: PoolEvent) {
        // TODO: Add custom tracing/handling here
        let _ = event;
    }

    fn mark_task_begin(self: &Arc<Self>) {
        let pending = self.pending.fetch_add(1, Ordering::Relaxed);
        assert_ne!(pending, usize::MAX);
    }

    fn mark_task_end(self: &Arc<Self>) {
        let pending = self.pending.fetch_sub(1, Ordering::AcqRel);
        assert_ne!(pending, 0);

        if pending == 1 {
            self.idle_post(self.workers.len());
        }
    }

    #[cold]
    fn notify(self: &Arc<Self>, is_waking: bool) {
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
                if sync.idle > 0 {
                    return self.idle_post(1);
                }
                
                if sync.spawned >= self.workers.len() {
                    return;
                }

                // Run the first worker using the caller's thread
                let worker_index = sync.spawned;
                if worker_index == 0 {
                    return self.with_worker(worker_index);
                }

                // Create a ThreadBuilder to spawn a worker thread
                let mut builder = std::thread::Builder::new()
                    .name(String::from("zap-worker-thread"));
                if let Some(stack_size) = self.stack_size {
                    builder = builder.stack_size(stack_size.get());
                }

                let pool = Arc::clone(self);
                let join_handle = builder
                    .spawn(move || pool.with_worker(worker_index))
                    .expect("Failed to spawn a worker thread");

                mem::drop(join_handle);
                return;
            }
        }
    }

    #[cold]
    fn wait(self: &Arc<Self>, index: usize, mut is_waking: bool) -> Option<bool> {
        let mut is_idle = false;
        loop {
            let result = self.sync.fetch_update(Ordering::Acquire, Ordering::Relaxed, |state| {
                let mut state: SyncState = state.into();
                if is_waking {
                    assert_eq!(state.status, SyncStatus::Waking);
                }

                assert!(state.idle <= state.spawned);
                if !is_idle {
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
                    return Some(is_waking || state.status == SyncStatus::Signaled);
                }

                assert!(!is_idle);
                is_idle = true;
                is_waking = false;
            }

            match self.pending.load(Ordering::SeqCst) {
                0 => return None,
                _ => self.idle_wait(index),
            }
        }
    }

    #[cold]
    fn idle_wait(self: &Arc<Self>, index: usize) {
        self.emit(PoolEvent::WorkerIdling {
            worker_index: index,
        });

        {
            let mut idle_sema = self.idle_sema.lock().unwrap();
            while *idle_sema == 0 {
                idle_sema = self.idle_cond.wait(idle_sema).unwrap();
            }
            *idle_sema -= 1;
        }

        self.emit(PoolEvent::WorkerScheduled {
            worker_index: index,
        });
    }

    #[cold]
    fn idle_post(self: &Arc<Self>, waiting: usize) {
        let mut idle_sema = self.idle_sema.lock().unwrap();
        *idle_sema = idle_sema.checked_add(waiting).expect("idle semaphore count overflowed");

        match waiting {
            1 => self.idle_cond.notify_one(),
            _ => self.idle_cond.notify_all(),
        }
    }

    fn with_thread_local<T>(f: impl FnOnce(&mut Option<Rc<(Arc<Self>, usize)>>) -> T) -> T {
        thread_local!(static POOL_REF: RefCell<Option<Rc<(Arc<Pool>, usize)>>> = RefCell::new(None));
        POOL_REF.with(|pool_ref| {
            f(&mut *pool_ref.borrow_mut())
        })
    }

    fn with_worker(self: &Arc<Self>, index: usize) {
        let old_pool_ref = Self::with_thread_local(|pool_ref| {
            let new_pool_ref = Rc::new((Arc::clone(self), index));
            mem::replace(pool_ref, Some(new_pool_ref))
        });

        self.run(index);

        Self::with_thread_local(|pool_ref| {
            *pool_ref = old_pool_ref;
        })
    }

    fn with_current<T>(f: impl FnOnce(&Arc<Self>, usize) -> T) -> Option<T> {
        Self::with_thread_local(|pool_ref| pool_ref.as_ref().map(|p| Rc::clone(p)))
            .map(|pool_ref| f(&pool_ref.0, pool_ref.1))
    }

    fn run(self: &Arc<Self>, index: usize) {
        let mut tick: usize = 0;
        let mut is_waking = false;
        let mut xorshift = 0xdeadbeef + index;

        self.emit(PoolEvent::WorkerSpawned {
            worker_index: index,
        });

        while let Some(waking) = self.wait(index, is_waking) {
            is_waking = waking;

            while let Some(popped) = {
                let be_fair = tick % 64 == 0;
                self.pop(index, &mut xorshift, be_fair)
            } {
                if is_waking || popped.pushed > 0 {
                    self.notify(is_waking);
                    is_waking = false;
                }

                let task = popped.task;
                self.emit(PoolEvent::TaskScheduled {
                    worker_index: index,
                    task,
                });

                tick = tick.wrapping_add(1);
                unsafe {
                    let vtable = task.as_ref().vtable;
                    (vtable.poll_fn)(task, self, index)
                }
            }
        }

        self.emit(PoolEvent::WorkerShutdown {
            worker_index: index,
        });
    }

    unsafe fn push(self: &Arc<Self>, index: Option<usize>, task: NonNull<Task>, mut be_fair: bool) {
        let index = index.unwrap_or_else(|| {
            be_fair = true;
            let inject_index = self.injecting.fetch_add(1, Ordering::Relaxed);
            inject_index % self.workers.len()
        });

        let injector = Pin::new_unchecked(&self.workers[index].injector);
        if be_fair {
            injector.push(List {
                head: task,
                tail: task,
            });
        } else {
            self.workers[index].buffer.push(task, injector);
        }

        self.emit(PoolEvent::WorkerPushed {
            worker_index: index,
            task,
        });

        let is_waking = false;
        self.notify(is_waking)
    }

    fn pop(self: &Arc<Self>, index: usize, xorshift: &mut usize, be_fair: bool) -> Option<Popped> {
        if be_fair {
            if let Some(popped) = self.consume(index, index) {
                return Some(popped);
            }
        }

        if let Some(popped) = self.workers[index].buffer.pop() {
            self.emit(PoolEvent::WorkerPopped {
                worker_index: index,
                task: popped.task,
            });

            return Some(popped);
        }

        self.steal(index, xorshift)
    }

    #[cold]
    fn consume(self: &Arc<Self>, index: usize, target_index: usize) -> Option<Popped> {
        self.workers[index]
            .buffer
            .consume(unsafe {
                Pin::new_unchecked(&self.workers[target_index].injector)
            })
            .map(|popped| {
                self.emit(PoolEvent::WorkerStole {
                    worker_index: index,
                    target_index,
                    count: popped.pushed + 1,
                });

                self.emit(PoolEvent::WorkerPopped {
                    worker_index: index,
                    task: popped.task,
                });

                popped
            })
    }

    #[cold]
    fn steal(self: &Arc<Self>, index: usize, xorshift: &mut usize) -> Option<Popped> {
        if let Some(popped) = self.consume(index, index) {
            return Some(popped);
        }

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

        (0..self.workers.len())
            .cycle()
            .skip(rng % self.workers.len())
            .take(self.workers.len())
            .map(|steal_index| {
                self.consume(index, steal_index).or_else(|| {
                    if index == steal_index {
                        return None;
                    }

                    self.workers[index]
                        .buffer
                        .steal(&self.workers[steal_index].buffer)
                        .map(|popped| {
                            self.emit(PoolEvent::WorkerStole {
                                worker_index: index,
                                target_index: steal_index,
                                count: popped.pushed + 1,
                            });

                            self.emit(PoolEvent::WorkerPopped {
                                worker_index: index,
                                task: popped.task,
                            });

                            popped
                        })
                })
            })
            .filter_map(|popped| popped)
            .next()
    }
}

struct Popped {
    task: NonNull<Task>,
    pushed: usize,
}

struct List {
    head: NonNull<Task>,
    tail: NonNull<Task>,
}

struct Injector {
    stub: Task,
    head: AtomicPtr<Task>,
    tail: AtomicPtr<Task>,
}

impl Default for Injector {
    fn default() -> Self {
        const STUB_VTABLE: TaskVTable = TaskVTable {
            poll_fn: |_, _, _| unreachable!("vtable call to stub poll_fn"),
            wake_fn: |_, _| unreachable!("vtable call to stub wake_fn"),
            drop_fn: |_| unreachable!("vtable call to stub drop_fn"),
            clone_fn: |_| unreachable!("vtable call to stub clone_fn"),
            join_fn: |_, _| unreachable!("vtable call to stub join_fn"),
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

impl Injector {
    const IS_CONSUMING: NonNull<Task> = NonNull::<Task>::dangling();

    unsafe fn push(self: Pin<&Self>, list: List) {
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

    fn consume<'a>(self: Pin<&'a Self>) -> Option<impl Iterator<Item = NonNull<Task>> + 'a> {
        let tail = NonNull::new(self.tail.load(Ordering::Acquire));
        if tail.is_none() || tail == Some(NonNull::from(&self.stub)) {
            return None;
        }

        let is_consuming = Self::IS_CONSUMING.as_ptr();
        let head = self.head.swap(is_consuming, Ordering::Acquire);
        if head == is_consuming {
            return None;
        }

        struct Consumer<'a> {
            injector: Pin<&'a Injector>,
            head: NonNull<Task>,
        }

        impl<'a> Drop for Consumer<'a> {
            fn drop(&mut self) {
                assert_ne!(self.head, Injector::IS_CONSUMING);
                self.injector.head.store(self.head.as_ptr(), Ordering::Release);
            }
        }

        impl<'a> Iterator for Consumer<'a> {
            type Item = NonNull<Task>;

            fn next(&mut self) -> Option<Self::Item> {
                unsafe {
                    let stub = NonNull::from(&self.injector.stub);
                    if self.head == stub {
                        let next = self.head.as_ref().next.load(Ordering::Acquire);
                        self.head = NonNull::new(next)?;
                    }

                    let next = self.head.as_ref().next.load(Ordering::Acquire);
                    if let Some(next) = NonNull::new(next) {
                        return Some(mem::replace(&mut self.head, next));
                    }

                    let tail = self.injector.tail.load(Ordering::Acquire);
                    if Some(self.head) != NonNull::new(tail) {
                        return None;
                    }

                    self.injector.push(List {
                        head: stub,
                        tail: stub,
                    });

                    let next = self.head.as_ref().next.load(Ordering::Acquire);
                    let next = NonNull::new(next)?;
                    Some(mem::replace(&mut self.head, next))
                }
            }
        }

        Some(Consumer {
            injector: self,
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

    fn write(&self, index: usize, task: NonNull<Task>) {
        let slot = &self.array[index % self.array.len()];
        slot.store(task.as_ptr(), Ordering::Relaxed)
    }

    fn read(&self, index: usize) -> NonNull<Task> {
        let slot = &self.array[index % self.array.len()];
        let task = NonNull::new(slot.load(Ordering::Relaxed));
        task.expect("invalid task read from Buffer")
    }

    unsafe fn push(&self, task: NonNull<Task>, overflow_injector: Pin<&Injector>) {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Relaxed);

        let size = tail.wrapping_sub(head);
        assert!(size <= self.array.len());

        if size < self.array.len() {
            self.write(tail, task);
            self.tail.store(tail.wrapping_add(1), Ordering::Release);
            return;
        }

        let migrate = size / 2;
        if let Err(head) = self.head.compare_exchange(
            head,
            head.wrapping_add(migrate),
            Ordering::Acquire,
            Ordering::Relaxed,
        ) {
            let size = tail.wrapping_sub(head);
            assert!(size <= self.array.len());

            self.write(tail, task);
            self.tail.store(tail.wrapping_add(1), Ordering::Release);
            return;
        }

        let first = self.read(head);
        let last = (1..(migrate + 1)).fold(first, |last, offset| {
            let next = match offset {
                _ if offset == migrate => task,
                _ => self.read(head.wrapping_add(offset)),
            };
            unsafe { last.as_ref().next.store(next.as_ptr(), Ordering::Relaxed) };
            next
        });

        overflow_injector.push(List {
            head: first,
            tail: last,
        })
    }

    fn pop(&self) -> Option<Popped> {
        let mut head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Relaxed);

        loop {
            let size = tail.wrapping_sub(head);
            assert!(size <= self.array.len());

            if size == 0 {
                return None;
            }

            match self.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Err(new_head) => head = new_head,
                Ok(_) => {
                    return Some(Popped {
                        task: self.read(head),
                        pushed: 0,
                    })
                }
            };
        }
    }

    fn steal(&self, buffer: &Self) -> Option<Popped> {
        loop {
            let buffer_head = buffer.head.load(Ordering::Acquire);
            let buffer_tail = buffer.tail.load(Ordering::Acquire);

            let buffer_size = buffer_tail.wrapping_sub(buffer_head);
            if buffer_size == 0 {
                return None;
            }

            if buffer_size > buffer.array.len() {
                spin_loop();
                continue;
            }

            let buffer_steal = buffer_size - (buffer_size / 2);
            assert_ne!(buffer_steal, 0);

            let head = self.head.load(Ordering::Relaxed);
            let tail = self.tail.load(Ordering::Relaxed);
            let size = tail.wrapping_sub(head);
            assert_eq!(size, 0);

            let new_tail = (0..buffer_steal).fold(tail, |new_tail, offset| {
                let task = buffer.read(buffer_head.wrapping_add(offset));
                self.write(new_tail, task);
                new_tail.wrapping_add(1)
            });

            if let Err(_) = buffer.head.compare_exchange(
                buffer_head,
                buffer_head.wrapping_add(buffer_steal),
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                spin_loop();
                continue;
            }

            let new_tail = new_tail.wrapping_sub(1);
            if new_tail != tail {
                self.tail.store(new_tail, Ordering::Release);
            }

            return Some(Popped {
                task: self.read(new_tail),
                pushed: new_tail.wrapping_sub(tail),
            });
        }
    }

    fn consume(&self, injector: Pin<&Injector>) -> Option<Popped> {
        injector.consume().and_then(|mut consumer| {
            consumer.next().map(|consumed| {
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

                Popped {
                    task: consumed,
                    pushed: new_tail.wrapping_sub(tail),
                }
            })
        })
    }
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum WakerState {
    Empty = 0,
    Updating = 1,
    Ready = 2,
    Waking = 3,
}

impl From<u8> for WakerState {
    fn from(value: u8) -> Self {
        match value {
            0 => Self::Empty,
            1 => Self::Updating,
            2 => Self::Ready,
            3 => Self::Waking,
            _ => unreachable!("invalid WakerState"),
        }
    }
}

#[derive(Default)]
struct AtomicWaker {
    state: AtomicU8,
    waker: UnsafeCell<Option<Waker>>,
}

unsafe impl Send for AtomicWaker {}
unsafe impl Sync for AtomicWaker {}

impl AtomicWaker {
    fn wake(&self) {
        let state: WakerState = self
            .state
            .swap(WakerState::Waking as u8, Ordering::AcqRel)
            .into();

        assert_ne!(state, WakerState::Waking);
        if state == WakerState::Ready {
            mem::replace(unsafe { &mut *self.waker.get() }, None)
                .expect("waker state was Ready without a Waker")
                .wake();
        }
    }

    fn update(&self, waker_ref: Option<&Waker>) -> bool {
        let state: WakerState = self.state.load(Ordering::Acquire).into();
        match state {
            WakerState::Empty | WakerState::Ready => {}
            WakerState::Updating => unreachable!("multiple threads trying to update Waker"),
            WakerState::Waking => return false,
        }

        if let Err(new_state) = self.state.compare_exchange(
            state as u8,
            WakerState::Updating as u8,
            Ordering::Acquire,
            Ordering::Acquire,
        ) {
            let new_state: WakerState = new_state.into();
            assert_eq!(new_state, WakerState::Waking);
            return false;
        }

        match mem::replace(
            unsafe { &mut *self.waker.get() },
            waker_ref.map(|waker| waker.clone()),
        ) {
            Some(_dropped_waker) => assert_eq!(state, WakerState::Ready),
            None => assert_eq!(state, WakerState::Empty),
        }

        let new_state = match waker_ref {
            Some(_) => WakerState::Ready,
            None => WakerState::Empty,
        };

        if let Err(new_state) = self.state.compare_exchange(
            WakerState::Updating as u8,
            new_state as u8,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            let new_state: WakerState = new_state.into();
            assert_eq!(new_state, WakerState::Waking);
            unsafe { *self.waker.get() = None };
            return false;
        }

        true
    }
}

struct Task {
    next: AtomicPtr<Self>,
    vtable: &'static TaskVTable,
    _pinned: PhantomPinned,
}

struct TaskVTable {
    clone_fn: unsafe fn(NonNull<Task>),
    drop_fn: unsafe fn(NonNull<Task>),
    wake_fn: unsafe fn(NonNull<Task>, bool),
    poll_fn: unsafe fn(NonNull<Task>, &Arc<Pool>, usize),
    join_fn: unsafe fn(NonNull<Task>, Option<(&Waker, *mut ())>) -> Poll<()>,
}

enum TaskData<F: Future> {
    Polling(F),
    Ready(F::Output),
    Joined,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum TaskState {
    Idle = 0,
    Scheduled = 1,
    Running = 2,
    Notified = 3,
    Ready = 4,
}

impl From<u8> for TaskState {
    fn from(value: u8) -> Self {
        match value {
            0 => Self::Idle,
            1 => Self::Scheduled,
            2 => Self::Running,
            3 => Self::Notified,
            4 => Self::Ready,
            _ => unreachable!("invalid TaskState"),
        }
    }
}

struct TaskFuture<F: Future> {
    task: Task,
    pool: Arc<Pool>,
    waker: AtomicWaker,
    ref_count: AtomicUsize,
    state: AtomicU8,
    data: UnsafeCell<TaskData<F>>,
}

impl<F: Future> TaskFuture<F> {
    const TASK_VTABLE: TaskVTable = TaskVTable {
        clone_fn: Self::on_clone,
        drop_fn: Self::on_drop,
        wake_fn: Self::on_wake,
        poll_fn: Self::on_poll,
        join_fn: Self::on_join,
    };

    pub fn spawn(pool: &Arc<Pool>, worker_index: usize, future: F) -> JoinHandle<F::Output> {
        let this_ptr = NonNull::<Self>::from(Box::leak(Box::new(Self {
            task: Task {
                next: AtomicPtr::new(ptr::null_mut()),
                vtable: &Self::TASK_VTABLE,
                _pinned: PhantomPinned,
            },
            pool: Arc::clone(pool),
            waker: AtomicWaker::default(),
            ref_count: AtomicUsize::new(2),
            state: AtomicU8::new(TaskState::Scheduled as u8),
            data: UnsafeCell::new(TaskData::Polling(future)),
        })));

        unsafe {
            let task = NonNull::from(&this_ptr.as_ref().task);

            pool.mark_task_begin();
            pool.emit(PoolEvent::TaskSpawned { worker_index, task });

            pool.push(Some(worker_index), task, false);
            JoinHandle {
                task: Some(task),
                _phantom: PhantomData,
            }
        }
    }

    unsafe fn from_task(task: NonNull<Task>) -> NonNull<Self> {
        let task_offset = {
            let stub = MaybeUninit::<Self>::uninit();
            let base_ptr = stub.as_ptr();
            let field_ptr = ptr::addr_of!((*(base_ptr)).task);
            (field_ptr as usize) - (base_ptr as usize)
        };

        let self_offset = (task.as_ptr() as usize) - task_offset;
        let self_ptr = NonNull::new(self_offset as *mut Self);
        self_ptr.expect("invalid Task ptr for container_of")
    }

    unsafe fn with<T>(task: NonNull<Task>, f: impl FnOnce(Pin<&Self>) -> T) -> T {
        let self_ptr = Self::from_task(task);
        f(Pin::new_unchecked(self_ptr.as_ref()))
    }

    unsafe fn on_clone(task: NonNull<Task>) {
        Self::with(task, |this| {
            let ref_count = this.ref_count.fetch_add(1, Ordering::Relaxed);
            assert_ne!(ref_count, usize::MAX);
            assert_ne!(ref_count, 0);
        })
    }

    unsafe fn on_drop(task: NonNull<Task>) {
        let dealloc = Self::with(task, |this| {
            let ref_count = this.ref_count.fetch_sub(1, Ordering::AcqRel);
            assert_ne!(ref_count, 0);
            ref_count == 1
        });

        if dealloc {
            Self::with(task, |this| {
                let state: TaskState = this.state.load(Ordering::Relaxed).into();
                assert_eq!(state, TaskState::Ready);
            });

            let self_ptr = Self::from_task(task);
            mem::drop(Box::from_raw(self_ptr.as_ptr()));
        }
    }

    unsafe fn on_wake(task: NonNull<Task>, also_drop: bool) {
        let schedule = match Self::with(task, |this| {
            this.state
                .fetch_update(
                    Ordering::AcqRel,
                    Ordering::Relaxed,
                    |state| match state.into() {
                        TaskState::Running => Some(TaskState::Notified as u8),
                        TaskState::Idle => Some(TaskState::Scheduled as u8),
                        _ => None,
                    },
                )
                .map(TaskState::from)
        }) {
            Ok(TaskState::Running) => false,
            Ok(TaskState::Idle) => true,
            Ok(_) => unreachable!(),
            _ => false,
        };

        let be_fair = false;
        if schedule {
            Pool::with_current(|pool, index| pool.push(Some(index), task, be_fair))
                .unwrap_or_else(|| {
                    Self::with(task, |this| {
                        assert!(this.ref_count.load(Ordering::Acquire) > 1);
                        this.pool.push(None, task, be_fair);
                    });
                });
        }

        if also_drop {
            Self::on_drop(task);
        }
    }

    unsafe fn on_poll(task: NonNull<Task>, pool: &Arc<Pool>, worker_index: usize) {
        let poll_result = Self::with(task, |this| {
            let state: TaskState = this.state.load(Ordering::Relaxed).into();
            match state {
                TaskState::Scheduled | TaskState::Notified => {},
                TaskState::Idle => unreachable!("polling task when idle"),
                TaskState::Running => unreachable!("polling task when already running"),
                TaskState::Ready => unreachable!("polling task when already completed"),
            }

            pool.emit(PoolEvent::TaskPolling { worker_index, task });
            this.state
                .store(TaskState::Running as u8, Ordering::Relaxed);

            let poll_result = this.poll_future();
            pool.emit(PoolEvent::TaskPolled { worker_index, task });
            poll_result
        });

        let poll_output = match poll_result {
            Poll::Ready(output) => output,
            Poll::Pending => {
                match Self::with(task, |this| {
                    this.state
                        .compare_exchange(
                            TaskState::Running as u8,
                            TaskState::Idle as u8,
                            Ordering::AcqRel,
                            Ordering::Relaxed,
                        )
                        .map(TaskState::from)
                }) {
                    Ok(_) => {
                        return pool.emit(PoolEvent::TaskIdling { worker_index, task });
                    }
                    Err(state) => {
                        let state: TaskState = state.into();
                        assert_eq!(state, TaskState::Notified);
                        return pool.push(Some(worker_index), task, false);
                    }
                }
            }
        };

        Self::with(task, |this| {
            match mem::replace(&mut *this.data.get(), TaskData::Ready(poll_output)) {
                TaskData::Polling(future) => mem::drop(future),
                TaskData::Ready(_) => unreachable!("TaskData already had an output value"),
                TaskData::Joined => unreachable!("TaskData already joind when setting output"),
            }

            this.state.store(
                TaskState::Ready as u8,
                Ordering::Release,
            );

            this.waker.wake();
        });

        pool.mark_task_end();
        pool.emit(PoolEvent::TaskShutdown { worker_index, task });
        Self::on_drop(task)
    }

    unsafe fn poll_future(&self) -> Poll<F::Output> {
        unsafe fn waker_vtable(ptr: *const (), f: impl FnOnce(&'static TaskVTable, NonNull<Task>)) {
            let task_ptr = ptr as *const Task as *mut Task;
            let task = NonNull::new(task_ptr).expect("invalid task ptr for Waker");
            let vtable = task.as_ref().vtable;
            f(vtable, task)
        }

        const WAKER_VTABLE: RawWakerVTable = RawWakerVTable::new(
            |ptr| unsafe {
                waker_vtable(ptr, |vtable, task| (vtable.clone_fn)(task));
                RawWaker::new(ptr, &WAKER_VTABLE)
            },
            |ptr| unsafe { waker_vtable(ptr, |vtable, task| (vtable.wake_fn)(task, true)) },
            |ptr| unsafe { waker_vtable(ptr, |vtable, task| (vtable.wake_fn)(task, false)) },
            |ptr| unsafe { waker_vtable(ptr, |vtable, task| (vtable.drop_fn)(task)) },
        );

        let ptr = NonNull::from(&self.task).as_ptr() as *const ();
        let raw_waker = RawWaker::new(ptr, &WAKER_VTABLE);
        let waker = Waker::from_raw(raw_waker);

        let poll_output = match &mut *self.data.get() {
            TaskData::Polling(ref mut future) => {
                let mut context = Context::from_waker(&waker);
                Pin::new_unchecked(future).poll(&mut context)
            }
            TaskData::Ready(_) => unreachable!("TaskData polled when already ready"),
            TaskData::Joined => unreachable!("TaskData polled when already joined"),
        };

        mem::forget(waker); // don't drop since we didn't clone it
        poll_output
    }

    unsafe fn on_join(task: NonNull<Task>, context: Option<(&Waker, *mut ())>) -> Poll<()> {
        let waker_ref = context.map(|c| c.0);
        let output_ptr = context
            .and_then(|c| NonNull::new(c.1))
            .map(|p| p.cast::<F::Output>());

        let updated_waker = Self::with(task, |this| {
            this.waker.update(waker_ref)
        });

        if updated_waker && waker_ref.is_some() {
            return Poll::Pending;
        }

        if let Some(output_ptr) = output_ptr {
            Self::with(task, |this| {
                let state: TaskState = this.state.load(Ordering::Acquire).into();
                assert_eq!(state, TaskState::Ready);
    
                match mem::replace(&mut *this.data.get(), TaskData::Joined) {
                    TaskData::Polling(_) => unreachable!("TaskData joined while still polling"),
                    TaskData::Ready(output) => ptr::write(output_ptr.as_ptr(), output),
                    TaskData::Joined => unreachable!("TaskData already joined when joining"),
                }
            });
        }

        Self::on_drop(task);
        Poll::Ready(())
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
                let _ = (vtable.join_fn)(task, None);
            }
        }
    }
}

impl<T> Future for JoinHandle<T> {
    type Output = T;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        unsafe {
            let mut_self = Pin::get_unchecked_mut(self);
            let task = mut_self.task.expect("JoinHandle polled after completion");

            let mut output = MaybeUninit::<T>::uninit();
            let join_context = (ctx.waker(), output.as_mut_ptr() as *mut ());

            let vtable = task.as_ref().vtable;
            if let Poll::Pending = (vtable.join_fn)(task, Some(join_context)) {
                return Poll::Pending;
            }

            mut_self.task = None;
            Poll::Ready(output.assume_init())
        }
    }
}
