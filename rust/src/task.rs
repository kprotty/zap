use std::{
    any::Any,
    cell::Cell,
    hash::Builder,
    future::Future,
    task::{Poll, Context, Waker, RawWaker, RawWakerVTable},
    marker::{PhantomPinned, PhantomData},
    mem::{self, MaybeUninit},
    pin::Pin,
    ptr::{self, NonNull},
    sync::atomic::{spin_loop_hint, AtomicBool, AtomicPtr, AtomicUsize, compiler_fence, Ordering},
};

type FutureError = Box<dyn Any + Send + 'static>;

pub fn run<F>(future: F) -> Result<F::Output, FutureError>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    unimplemented!("TODO")
}

pub fn spawn<F>(future: F) -> impl Future<Output = JoinHandle<F::Output>>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    unimplemented!("TODO")
}

pub fn spawn_local<F>(future: F) -> impl Future<Output = JoinHandle<F::Output>>
where
    F: Future + 'static,
    F::Output: 'static,
{
    unimplemented!("TODO")
}

pub fn spawn_blocking<F, R>(f: F) -> impl Future<Output = JoinHandle<R>>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    unimplemented!("TODO")
}

pub fn yield_now() -> impl Future<Output = ()> {
    struct YieldFuture {
       yielded: bool,
    }

    impl Future for YieldFuture {
        type Output = ();

        fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
            if self.yielded {
                return Poll::Ready(());
            }
            
            unsafe {
                Some(FutureContext::<'_>::current())
                    .and_then(|current| match Pin::new(&current).poll(ctx) {
                        Poll::Ready(current) => current,
                        Poll::Pending => unreachable!(),
                    })
                    .expect("yield_now() called outside of run()")
                    .header
                    .runnable
                    .set_priority(Priority::Lifo);
            }

            self.yielded = true;
            ctx.waker().wake_by_ref();
            Poll::Pending
        }
    }

    YieldFuture { yielded: false }
}

struct JoinHandle<T> {
    _pinned: PhantomPinned,
    _phantom: PhantomPinned<*mut T>,
    state: AtomicUsize,
    waker: Option<Waker>,
    header: NonNull<FutureHeader>,
}

impl<T> Drop for JoinHandle<T> {
    fn drop(&mut self) {

    }
}

impl<T> Future for JoinHandle<T> {
    type Output = Result<T, FutureError>;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        unsafe {

        }
    }
}

#[repr(C, usize)]
enum FutureState<F: Future> {
    Pending(F),
    Ready(F::Output),
    Error(FutureError),
}

#[repr(C)]
struct FutureHeader {
    runnable: Runnable,
    ref_count: AtomicUsize,
    state: AtomicUsize,
}

impl FutureHeader {
    fn ptr<T>(&self) -> NonNull<T> {
        unsafe {
            NonNull::new_unchecked((self as *const Self).add(1) as *mut T)
        }
    }
}

struct FutureContext<'a> {
    context: Context<'a>,
    thread: &'a Thread,
    header: &'a FutureHeader,
}

impl<'a> FutureContext<'a> {
    unsafe fn current() -> impl Future<Output = Option<&'a Self>>> {
        struct GetThread;
    
        impl Future for GetThread {
            type Output = Option<NonNull<Thread>>;
    
            fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
                Poll::Ready({
                    let ptr = ctx as *mut _ as usize;
                    if ptr & 1 != 0 {
                        Some(&*((ptr & !1) as *const Self))
                    } else {
                        None
                    }
                })
            }
        }
    
        GetThread
    }
}

#[repr(C)]
struct FutureTask<F: Fututre> {
    runnable: Runnable,
    ref_count: AtomicUsize,
    future_state: FutureState<F>,
}

impl<F: Future> FutureTask<F> {
    fn header(&self) -> &FutureHeader {
        unsafe { &*(self as *const Self as *const FutureHeader) }
    }
}

#[repr(C)]
struct Executor {
    core_pool: Pool,
    blocking_pool: Pool,
    workers_active: AtomicUsize,
    workers_ptr: NonNull<Worker>,
}

#[repr(align(4))]
struct Pool {
    run_queue: GlobalQueue,
    idle_queue: AtomicUsize,
    workers_len: usize,
}

impl Pool {
    fn init(self: Pin<&mut Self>, is_blocking: bool, num_workers: usize) {
        let mut_self = unsafe {
            let mut_self = Pin::into_inner_unchecked(self);
            let run_queue = Pin::new_unchecked(&mut mut_self.run_queue);
            run_queue.init();
            mut_self
        };

        assert!(num_workers < (usize::MAX >> 11));
        mut_self.workers_len = (num_workers << 1) | (is_blocking as usize);

        mut_self.idle_queue = AtomicUsize::new({
            let mut idle_queue = 0;
            for worker in mut_self.workers().iter() {
                let next = NonNull::new(idle_queue as *mut Worker);
                let worker_ref = WorkerRef::Worker(next);
                worker.next.store(worker_ref.into(), Ordering::Relaxed);
                idle_queue = worker as *const _ as usize;
            }
            num_workers << 11
        });
    }

    fn is_blocking(&self) -> bool {
        self.workers_len & 1 != 0
    }

    fn executor(&self) -> NonNull<Executor> {
        let mut offset = 0;
        if self.is_blocking() {
            offset = std::mem::size_of::<Self>();
        }

        let executor_ptr = (self as *const _ as usize) - offset;
        let executor_ptr = executor_ptr as *mut Executor;
        NonNull::new(executor_ptr).expect("Pool without valid executor")
    }

    fn workers(&self) -> &[Worker] {
        unsafe {
            let executor = self.executor().as_ref();

            let mut workers_offset = 0;
            if self.is_blocking() {
                workers_offset = executor.core_pool.workers_len >> 1;
            }

            let workers_len = self.workers_len >> 1;
            let workers_ptr = executor.workers_ptr.as_ptr();
            let workers_ptr = workers_ptr.add(workers_offset);
            std::slice::from_raw_parts(workers_ptr, workers_len)
        }
    }
}

#[repr(align(4))]
struct Worker {
    next: AtomicUsize,
}

#[derive(Debug)]
enum WorkerRef {
    Worker(Option<NonNull<Worker>>),
    Thread(NonNull<Thread>),
    Handle(Option<NonNull<ThreadHandle>>),
}

impl Into<usize> for WorkerRef {
    fn into(self) -> usize {
        unimplemented!("TODO")
    }
}

impl From<usize> for WorkerRef {
    fn from(value: usize) -> Self {
        let ptr = value & !0b11usize;
        match value & 0b11 {
            0 => Self::Worker(NonNull::new(ptr as *mut _)),
            1 => Self::Thread(NonNull::new(ptr as *mut _).expect("null thread ref")),
            2 => Self::Handle(NonNull::new(ptr as *mut _)),
            _ => unreachable!("invalid worker ref ptr {:?b}", value),
        }
    }
}

#[repr(align(4))]
struct ThreadHandle {
    inner: std::thread::JoinHandle<()>,
}

#[repr(align(4))]
struct Thread {
    _pinned: PhantomPinned,
    state: AtomicUsize,
    inner: std::thread::Thread,
    run_queue: LocalQueue,
    pool: NonNull<Pool>,
    handle: Cell<Option<NonNull<ThreadHandle>>>,
}

impl Thread {
    const RUNNING: usize = 0;
    const WAKING: usize = 1;
    const SUSPENDED: usize = 2;
    const SHUTDOWN: usize = 3;

    unsafe fn start(pool: NonNull<Pool>, worker: NonNull<Worker>) {
        Pin::new_unchecked(&Self {
            _pinned: PhantomPinned,
            state: AtomicUsize::new(Self::WAKING),
            inner: std::thread::current(),
            run_queue: LocalQueue::new(),
            pool,
            handle: Cell::new(None),
        })
        .run(pool.as_ref(), worker.as_ref())
    }

    fn run(self: Pin<&Self>, pool: &Pool, worker: &Worker) {
        let worker_ref = WorkerRef::Thread(NonNull::from(&*self));
        let worker_ref = worker.next.swap(worker_ref.into(), Ordering::AcqRel);
        match WorkerRef::from(worker_ref) {
            WorkerRef::Handle(handle) => self.handle.set(handle),
            worker_ref => unreachable!("invalid worker ref on thread init {:?}", worker_ref),
        }

        let mut tick = 0;
        let mut is_waking = true;
        let mut prng = std::collections::hash_map::RandomState::new()
            .build_hasher()
            .write_usize(self as *const _ as usize)
            .write_usize(pool as *const _ as usize)
            .write_usize(worker as *const _ as usize)
            .finish();

        'run: loop {
            if let Some(runnable) = self.poll(pool, tick, &mut prng) {
                if is_waking {
                    is_waking = false;
                    pool.stop_waking();
                }

                tick = tick.wrapping_add(1);
                unsafe {
                    let mut runnable = Pin::new_unchecked(runnable.as_mut());
                    runnable.run(Pin::new_unchecked(&*self))
                }

                continue;
            }

            pool.suspend(&*self, is_waking);
            'suspend: loop {
                let state = self.state.load(Ordering::Acquire);
                match state & 0b11 {
                    Self::RUNNING => {
                        is_waking = false;
                        break 'suspend;
                    }
                    Self::WAKING => {
                        is_waking = true;
                        break 'suspend;
                    }
                    Self::SUSPENDED => {
                        std::thread::park();
                    }
                    Self::SHUTDOWN => {
                        break 'run;
                    }
                    _ => unreachable!(),
                }
            }
        }
    }

    fn poll(&self, pool: &Pool, tick: usize, prng: &mut u64) -> Option<NonNull<Runnable>> {
        if tick % 61 == 0 {
            if let Some(runnable) = self.run_queue.try_steal_global(&pool.run_queue) {
                return Some(runnable);
            }
        }

        if let Some(runnable) = self.run_queue.poll() {
            return Some(runnable);
        }

        for steal_attempt in 0..4 {
            if let Some(runnable) = self.run_queue.try_steal_global(&pool.run_queue) {
                return Some(runnable);
            }

            let workers = pool.workers();
            let mut worker_index = {
                let mut rng = *prng;
                rng ^= rng << 13;
                rng ^= rng >> 7;
                rng ^= rng << 17;
                *prng = rng;
                (rng as usize) % workers.len()
            };

            let steal_next = steal_attempt > 2;
            if let Some(runnable) = (0..workers.len())
                .map(|_| {
                    let index = worker_index;
                    worker_index += 1;
                    if worker_index >= workers.len() {
                        worker_index = 0;
                    }
                    index
                })
                .filter_map(|index| {
                    let worker_ptr = workers[index].next.load(Ordering::Acquire);
                    match WorkerRef::from(worker_ptr) {
                        WorkerRef::Thread(thread) => Some(thread),
                        _ => None,
                    }
                })
                .filter(|&thread| thread != NonNull::from(self))
                .and_then(|thread| {
                    let run_queue = unsafe { thread.as_ref().run_queue };
                    self.run_queue.try_steal_local(run_queue, steal_next)
                })
                .next()
            {
                return Some(runnable);
            }
        }

        None
    }
}

#[derive(Debug, Copy, Clone, Eq, PartialEq, Hash)]
enum Priority {
    Fifo = 0,
    Lifo = 1,
}

impl Default for Priority {
    fn default() -> Self {
        Self::Fifo
    }
}

type Callback = extern "C" fn(*mut Runnable, *const Thread);

#[repr(C)]
struct Runnable {
    _pinned: PhantomPinned,
    next: AtomicPtr<Runnable>,
    data: Cell<usize>,
}

impl From<Callback> for Runnable {
    fn from(callback: Callback) -> Self {
        Self::new(Priority::default(), callback)
    }
}

impl Runnable {
    fn new(priority: Priority, callback: Callback) -> Self {
        Self {
            _pinned: PhantomPinned,
            next: AtomicPtr::default(),
            data: Cell::new((callback as usize) | (priority as usize)),
        }
    }

    fn priority(&self) -> Priority {
        match self.data & 1 {
            0 => Priority::Fifo,
            1 => Priority::Lifo,
        }
    }

    unsafe fn set_priority(&self, priority: Priority) {
        let data = self.data.get();
        self.data.set((data & !1) | (priority as usize));
    }

    fn run(self: Pin<&mut Self>, thread: Pin<&Thread>) {
        unsafe {
            let callback: Callback = mem::transmute(self.data.get() & !1);
            callback(Pin::into_inner_unchecked(self), &*thread)
        }
    }
}

struct Batch {
    head: Option<NonNull<Runnable>>,
    tail: NonNull<Runnable>,
    size: usize,
}

impl From<Pin<&mut Runnable>> for Batch {
    fn from(runnable: Pin<&mut Runnable>) -> Self {
        let runnable = unsafe {
            let mut runnable = Pin::into_inner_unchecked(runnable);
            *runnable.next.get_mut() = ptr::null_mut();
            NonNull::from(runnable)
        };
        Self {
            head: Some(runnable),
            tail: runnable,
            size: 1,
        }
    }
}

impl Default for Batch {
    fn default() -> Self {
        Self::new()
    }
}

impl Batch {
    const fn new() -> Self {
        Self {
            head: None,
            tail: NonNull::dangling(),
            size: 0,
        }
    }

    fn len(&self) -> usize {
        self.size
    }

    fn push(&mut self, runnable: Pin<&mut Runnable>) {
        self.push_all(Self::from(runnable))
    }

    fn push_all(&mut self, other: Self) {
        if let Some(other_head) = other.head {
            if let Some(head) = self.head {
                unsafe { *self.tail.as_mut().next.get_mut() = other_head.as_ptr() };
                self.tail = other.tail;
                self.size += other.size;
            } else {
                *self = other;
            }
        }
    }

    fn pop(&mut self) -> Option<NonNull<Runnable>> {
        let mut runnable = self.head?;
        self.head = NonNull::new(unsafe { *runnable.as_mut().next.get_mut() });
        self.size -= 1;
        Some(runnable)
    }
}

struct GlobalQueue {
    _pinned: PhantomPinned,
    is_polling: AtomicBool,
    head: AtomicPtr<Runnable>,
    tail: Cell<NonNull<Runnable>>,
    stub: Runnable,
}

impl GlobalQueue {
    fn init(self: Pin<&mut Self>) {
        let mut_self = unsafe { Pin::into_inner_unchecked(self) };
        *mut_self = Self {
            _pinned: PhantomPinned,
            is_polling: AtomicBool::new(false),
            head: AtomicPtr::new(&mut mut_self.stub),
            tail: Cell::new(NonNull::from(&mut_self.stub)),
            stub: Runnable::new(Priority::default(), |_, _| {}),
        };
    }

    fn deinit(self: Pin<&mut Self>) {
        let stub_ptr = &self.stub as *const _ as *mut _;
        assert!(!self.is_polling.load(Ordering::Relaxed));
        assert_eq!(self.head.load(Ordering::Relaxed), stub_ptr);
        assert_eq!(self.tail.get(), NonNull::new(stub_ptr).unwrap());
    }

    fn push(&self, batch: Batch) {
        unsafe {
            if let Some(head) = batch.head {
                *batch.tail.as_mut().next.get_mut() = ptr::null_mut();
                let prev = self.head.swap(batch.tail.as_ptr(), Ordering::AcqRel);
                (*prev).next.store(head.as_ptr(), Ordering::Release);
            }
        }
    }

    fn try_poll(&self) -> Option<GlobalQueuePoller<'_>> {
        self.is_polling
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .ok()
            .map(|_| GlobalQueuePoller { queue: self })
    }
}

struct GlobalQueuePoller<'a> {
    queue: &'a GlobalQueue,
}

impl<'a> Drop for GlobalQueuePoller<'a> {
    fn drop(&mut self) {
        self.queue.is_polling.store(false, Ordering::Release);
    }
}

impl<'a> Iterator for GlobalQueuePoller<'a> {
    type Item = NonNull<Runnable>;

    fn next(&mut self) -> Option<Self::Item> {
        unsafe {
            let mut tail = self.queue.tail.get();
            let mut next = tail.as_ref().next.load(Ordering::Relaxed);
            compiler_fence(Ordering::Acquire);

            let stub = &self.queue.stub as *const _ as *mut _;
            if tail.as_ptr() == stub {
                tail = NonNull::new(next)?;
                self.queue.tail.set(tail);
                next = tail.as_ref().next.load(Ordering::Relaxed);
                compiler_fence(Ordering::Acquire);
            }

            if let Some(next) = NonNull::new(next) {
                self.queue.tail.set(next);
                return Some(tail);
            }

            let mut spin = 3;
            loop {
                let head = self.queue.head.load(Ordering::Relaxed);
                compiler_fence(Ordering::Acquire);
                if tail.as_ptr() == head {
                    break;
                } else if spin == 0 {
                    return None;
                } else {
                    spin -= 1;
                    std::thread::yield_now();
                }
            }
            
            self.queue.push(Batch::from(Pin::new_unchecked(&mut *stub)));

            next = tail.as_ref().next.load(Ordering::Relaxed);
            compiler_fence(Ordering::Acquire);
            self.queue.tail.set(NonNull::new(next)?);
            Some(tail)
        }
    }
}

struct LocalQueue {
    next: AtomicPtr<Runnable>,
    head: AtomicUsize,
    tail: AtomicUsize,
    buffer: [MaybeUninit<NonNull<Runnable>>; 256],
}

impl LocalQueue {
    fn new() -> Self {
        Self {
            next: AtomicPtr::default(),
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            buffer: unsafe { MaybeUninit::uninit().assume_init() },
        }
    }

    fn read(&self, index: usize) -> NonNull<Runnable> {
        unsafe {
            let masked = index % self.buffer.len();
            let value_ptr = self.buffer.get_unchecked(masked).as_ptr();
            ptr::read(value_ptr)
        }
    }

    fn write(&self, index: usize, value: NonNull<Runnable>) {
        unsafe {
            let masked = index % self.buffer.len();
            let value_ptr = self.buffer.get_unchecked(masked).as_ptr();
            ptr::write(value_ptr as *const _ as *mut _, value)
        }
    }

    fn push(&self, runnable: Pin<&mut Runnable>, overflow_queue: &GlobalQueue) {
        let priority = runnable.priority();
        let mut runnable = NonNull::from(unsafe { Pin::into_inner_unchecked(runnable) });

        if priority == Priority::Lifo {
            let old_next = self.next.swap(runnable.as_ptr(), Ordering::AcqRel);
            runnable = match NonNull::new(old_next) {
                Some(runnable) => runnable,
                None => return,
            };
        }

        let tail = self.tail.load(Ordering::Relaxed);
        let mut head = self.head.load(Ordering::Relaxed);
        loop {
            let size = tail.wrapping_sub(head);
            assert!(
                size <= self.buffer.len(),
                "push() with invalid local size of {}",
                size,
            );

            if size < self.buffer.len() {
                self.write(tail, runnable);
                self.tail.store(tail.wrapping_add(1), Ordering::Release);
                return;
            }
            
            let steal = self.buffer.len() / 2;
            if let Err(e) = self.head.compare_exchange_weak(
                head,
                head.wrapping_add(steal),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                spin_loop_hint();
                head = e;
                continue;
            }

            let (begin, end) = match priority {
                Priority::Fifo => (None, Some(runnable)),
                Priority::Lifo => (Some(runnable), None),
            };

            let batch = begin
                .iter()
                .chain((0..steal).map(|i| self.read(head.wrapping_add(i))))
                .chain(end.iter())
                .fold(Batch::new(), |mut batch, runnable| {
                    batch.push(unsafe { Pin::new_unchecked(runnable.as_mut()) });
                    batch
                });

            overflow_queue.push(batch);
            return;
        }
    }

    fn poll(&self) -> Option<NonNull<Runnable>> {
        let tail = self.tail.load(Ordering::Relaxed);
        let mut head = self.head.load(Ordering::Relaxed);

        while tail != head {
            let size = tail.wrapping_sub(head);
            assert!(
                size != 0 && size <= self.buffer.len(),
                "poll() with invalid local size of {}",
                size,
            );

            match self.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Some(self.read(head)),
                Err(e) => {
                    head = e;
                    spin_loop_hint();
                }
            }
        }

        None
    }

    fn try_steal_global(&self, target: &GlobalQueue) -> Option<NonNull<Runnable>> {
        let mut poller = target.try_poll()?;

        let first_runnable = poller.next()?;

        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Relaxed);
        let size = tail.wrapping_sub(head);
        assert!(
            size <= self.buffer.len(),
            "steal_global() with invalid local size of {}"
            size,
        );

        let new_tail = poller
            .take(self.buffer.len() - size)
            .fold(tail, |new_tail, runnable| {
                self.write(new_tail, runnable);
                new_tail.wrapping_add(1)
            });

        self.tail.store(new_tail, Ordering::Release);
        Some(first_runnable)
    }

    fn try_steal_local(&self, target: &LocalQueue, steal_next: bool) -> Option<NonNull<Runnable>> {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Relaxed);
        assert_eq!(
            tail,
            head,
            "steal_local() with local queue size of {}",
            tail.wrapping_sub(head),
        );

        let mut target_head = target.head.load(Ordering::Acquire);
        loop {
            let target_tail = target.tail.load(Ordering::Relaxed);
            let target_size = target_tail.wrapping_sub(target_head);
            assert!(
                target_size <= target.buffer.len(),
                "steal_local() with invalid target size of {}",
                target_size,
            );

            let steal = target_size - (target_size / 2);
            if steal == 0 {
                if steal_next {
                    if let Some(next) = NonNull::new(target.next.load(Ordering::Relaxed)) {
                        if let Ok(_) = target.next.compare_exchange_weak(
                            next.as_ptr(),
                            ptr::null_mut(),
                            Ordering::Relaxed,
                            Ordering::Relaxed,
                        ) {
                            compiler_fence(Ordering::Acquire);
                            return Some(next);
                        } else {
                            spin_loop_hint();
                            target_head = target.head.load(Ordering::Acquire);
                            continue;
                        }
                    }
                }
                return None;
            }

            let mut new_target_head = target_head;
            let mut target_input = (0..steal).map(|_| {
                let runnable = target.read(new_target_head);
                new_target_head = new_target_head.wrapping_add(1);
                runnable
            });

            let first_runnable = target_input.next();
            let new_tail = target_input.fold(tail, |new_tail, runnable| {
                self.write(new_tail, runnable);
                new_tail.wrapping_add(1)
            });

            match target.head.compare_exchange_weak(
                target_head,
                new_target_head,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    self.tail.store(new_tail, Ordering::Release);
                    return first_runnable;
                }
                Err(e) => {
                    spin_loop_hint();
                    target_head = e;
                }
            }
        }
    }
}
