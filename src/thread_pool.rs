use std::{
    pin::Pin,
    num::NonZeroU32,
    cell::{Cell, UnsafeCell},
    ptr::{self, NonNull},
    future::Future,
    mem::{self, MaybeUninit},
    marker::{PhantomData, PhantomPinned},
    task::{Poll, Context, Waker, RawWaker, RawWakerVTable},
    sync::atomic::{AtomicU8, AtomicU32, AtomicUsize, AtomicPtr, Ordering},
};

pub fn block_on<F>(max_threads: u16, future: F) -> F::Output
where 
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{

}

struct Scheduler {
    sync: AtomicU32,
    injected: Queue,
}

impl Scheduler {
    fn notify(&self, is_waking: bool) {

    }

    fn wait(&self, mut is_waking: bool) -> Option<bool> {

    }

    fn register(&self, worker: Pin<&Worker>) {

    }

    fn unregister(&self, worker: Pin<&Worker>) {

    }
}


thread_local!(static ref CURRENT_WORKER: Option<NonNull<Worker>> = None);

struct Worker {
    scheduler: NonNull<Scheduler>,
    next: Cell<Option<NonNull<Self>>>,
    target: Cell<Option<NonNull<Self>>>,
    queue: Queue,
    buffer: Buffer,
    _pinned: PhantomPinned,
}

impl Worker {
    fn enter(scheduler: NonNull<Scheduler>) {
        let scheduler = unsafe { scheduler.as_ref() };
        let this = Self {
            scheduler: NonNull::from(scheduler),
            next: Cell::new(None),
            target: Cell::new(None),
            queue: Queue::new(),
            buffer: Buffer::new(),
            _pinned: PhantomPinned,
        };
        
        let this = unsafe { Pin::new_unchecked(&this) };
        scheduler.register(this.clone());

        let mut old_current = None;
        CURRENT_WORKER.with(|w| {
            old_current = *w;
            *w = NonNull::from(&*this);
        });

        while let Some(mut is_waking) = scheduler.wait(false) {
            while let Some((task, pushed)) = this.pop() {
                if pushed || is_waking {
                    scheduler.notify(is_waking);
                }

                is_waking = false;
                let task = unsafe { Pin::new_unchecked(task.as_ref()) };
                (task.vtable.poll_fn)(task)
            }
        }

        CURRENT_WORKER.with(|w| *w = old_current);
        scheduler.unregister(this);
    }

    fn push(task_ptr: NonNull<Task>) {
        let mut list = List {
            head: task,
            tail: task,
        };

        let worker = CURRENT_WORKER.with(|w| *w).expect("called outside of thread pool");
        if !worker.buffer.push(&mut list) {
            worker.queue.push(list);
        }

        unsafe {
            self.scheduler.as_ref().notify(false)
        }
    }

    fn pop(&self) -> Option<(NonNull<Task>, bool)> {
        if let Some(task) = self.buffer.pop() {
            Some((task, false))
        } else if let Some(task) = self.steal() {
            Some((task, true))
        } else {
            None
        }
    }

    #[cold]
    fn steal(&self) -> Option<NonNull<Task>> {
        if let Some(task) = self.buffer.consume(&self.queue) {
            return Some(task);
        }

        let scheduler = unsafe { self.scheduler.as_ref() };
        if let Some(task) = self.buffer.consume(&scheduler.injected) {
            return Some(task);
        }

        let num_workers = scheduler.sync.load(Ordering::Relaxed).into().spawned;
        for _ in 0..num_workers {
            let target = self.target.get().unwrap_or_else(|| {
                let workers = scheduler.workers.load(Ordering::Acquire);
                NonNull::new(workers).expect("stealing without scheduler workers")
            });
            
            let target = unsafe { target.as_ref() };
            self.target.set(target.next.get());

            if let Some(task) = self.buffer.consume(&self.queue) {
                return Some(task);
            } else if ptr::eq(target, self) {
                continue;
            } else if let Some(task) = self.buffer.steal(&target.buffer) {
                return Some(task);
            }
        }

        None
    }
}

struct List {
    head: NonNull<Task>,
    tail: NonNull<Task>,
}

struct Buffer {
    head: AtomicU32,
    tail: AtomicU32,
    array: [AtomicPtr<Task>; 256],
}

impl Buffer {
    fn new() -> Self {
        const TASK: AtomicPtr<Task> = AtomicPtr::new(ptr::null_mut());
        Self {
            head: AtomicU32::new(0),
            tail: AtomicU32::new(0),
            array: [TASK; 256],
        }
    }

    fn push(&self, list: &mut List) -> Result<(), ()> {
        let mut tail = self.tail.load(Ordering::Relaxed);
        let mut head = self.head.load(Ordering::Relaxed);

        loop {
            let size = tail.wrapping_sub(head);
            assert!(size <= self.array.len());

            if size < self.array.len() {
                let mut head = Some(list.head);
                for _ in 0..(self.array.len() - size) {
                    let node = match head {
                        None => break,
                        Some(node) => node,
                    };

                    head = unsafe { node.as_ref().next.get() };
                    self.array[tail % self.array.len()].store(node.as_ptr(), Ordering::Relaxed);
                    tail = tail.wrapping_add(1);
                }

                self.tail.store(tail, Ordering::Release);
                list.head = match head {
                    None => return Ok(()),
                    Some(head) => head,
                };

                spin_loop_hint();
                head = self.head.load(Ordering::Relaxed);
                continue;
            }
            
            let migrate = size / 2;
            if let Err(e) = self.head.compare_exchange_weak(
                head,
                head.wrapping_add(migrate),
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                head = e;
                continue;
            }
            
            let first = self.array[head % self.array.len()].load(Ordering::Relaxed);
            let mut last = first;

            for i in 0..migrate {
                head = head.wrapping_add(1);
                let next = self.array[head % self.array.len()].load(Ordering::Relaxed);
                unsafe { (*last).next.set(NonNull::new(next)) };
                last = next;
            }

            unsafe { (*last).next.set(list.head) };
            list.head = NonNull::new(first).unwrap();
            return Err(());
        }
    }

    fn pop(&self) -> Option<NonNull<Task>> {
        let tail = self.tail.load(Ordering::Relaxed);
        let mut head = self.head.load(Ordering::Relaxed);

        loop {
            let size = tail.wrapping_sub(head);
            assert!(size <= self.array.len());
            if size == 0 {
                return None;
            }

            if let Err(e) = self.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                head = e;
                continue;
            }

            let node_ptr = self.array[head % self.array.len()].load(Ordering::Relaxed);
            let node_ptr = NonNull::new(node_ptr).expect("popped invalid node");
            return Some(node_ptr);
        }
    }

    fn steal(&self, target: &Self) -> Option<NonNull<Task>> {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Relaxed);
        assert_eq!(tail, head, "non-empty local queue when stealing");

        loop {
            let target_head = target.head.load(Ordering::Acquire);
            let target_tail = target.tail.load(Ordering::Acquire);

            let target_size = target_tail.wrapping_sub(target_head);
            if target_size > target.array.len() {
                spin_loop_hint();
                continue;
            }
            
            let target_steal = target_size - (target_size / 2);
            if target_steal == 0 {
                return None;
            }

            for i in (0..target_steal) {
                let node = target.array[target_head.wrapping_add(i) % target.array.len()].load(Ordering::Relaxed);
                self.array[tail.wrapping_add(i) % self.array.len()].store(node, Ordering::Relaxed);
            }

            if let Err(_) = target.head.compare_exchange(
                target_head,
                target_head.wrapping_add(target_steal),
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                spin_loop_hint();
                continue;
            }
            
            let target_steal = target_steal - 1;
            let node = self.array[tail.wrapping_add(target_steal) % self.array.len()].load(Ordering::Relaxed);

            self.tail.store(tail.wrapping_add(target_steal), Ordering::Release);
            return Some(NonNull::new(node).expect("stole and invalid node"));
        }
    }

    fn consume(&self, target: &Queue) -> Option<NonNull<Task>> {
        queue.consume().and_then(|mut consumer| {
            consumer.next().map(|stole| {
                let tail = self.tail.load(Ordering::Relaxed);
                let head = self.head.load(Ordering::Relaxed);
                assert_eq!(tail, head, "non-empty local queue when stealing");

                let new_tail = consumer.take(self.array.len()).fold(tail, |node, new_tail| {
                    self.array[new_tail % self.array.len()].store(node, Ordering::Relaxed);
                    new_tail.wrapping_add(1)
                });

                self.tail.store(new_tail, Ordering::Release);
                stole
            })
        })
    }
}

struct Queue {
    stack: AtomicUsize,
    cache: Cell<Option<NonNull<Task>>>,
}

impl Queue {
    fn new() -> Self {

    }

    unsafe fn push(&self, list: List) {

    }

    unsafe fn consume(&self) -> Option<impl Iterator<Item = NonNull<Task>>> {

    }
}

#[repr(align(4))]
struct Task {
    next: Cell<Option<NonNull<Self>>>,
    vtable: &'static TaskVTable,
    _pinned: PhantomPinned,
}

struct TaskVTable {
    poll_fn: fn(task: Pin<&Task>),
    wake_fn: fn(task: Pin<&Task>),
    drop_fn: fn(task: Pin<&Task>),
    join_fn: fn(task: Pin<&Task>, waker: &Waker, result: *mut ()) -> bool,
    detach_fn: fn(task: Pin<&Task>), 
}

const TASK_RUNNING: u8 = 0;
const TASK_NOTIFIED: u8 = 1;
const TASK_SCHEDULED: u8 = 2;
const TASK_COMPLETED: u8 = 3;

const WAKER_EMPTY: u8 = 0;
const WAKER_READY: u8 = 1;
const WAKER_UPDATING: u8 = 2;
const WAKER_NOTIFIED: u8 = 3;

enum TaskData<F: Future> {
    Polling(F),
    Ready(F::Output),
}

struct TaskFuture<F: Future> {
    data: UnsafeCell<TaskData<F>>,
    task: Task,
    state: AtomicU8,
    ref_count: AtomicUsize,
    waker: UnsafeCell<Some<Waker>>,
}

impl<F: Future> TaskFuture<F> {
    const VTABLE: TaskVTable = TaskVTable {
        poll_fn: Self::on_poll,
        wake_fn: Self::on_wake,
        drop_fn: Self::on_drop,
        join_fn: Self::on_join,
        detach_fn: Self::on_detach,
    };
    
    fn spawn(future: F) -> JoinHandle<F::Output> {
        let boxed = Box::pin(Self {
            data: UnsafeCell::new(TaskData::Polling(future)),
            task: Task {
                next: Cell::new(None),
                vtable: &Self::VTABLE,
            },
            state: AtomicUsize::new(TASK_SCHEDULED | (WAKER_EMPTY << 2)),
            ref_count: AtomicUsize::new(2),
            waker: UnsafeCell::new(None),
        });
        
        let task = NonNull::from(&boxed.task);
        let join_handle = JoinHandle<F::Output> {
            task: Some(task.clone()),
            _phantom: PhantomData,
        };
        
        mem::forget(boxed); // dont dealloc at end of scope
        Worker::schedule(task);

        join_handle
    }

    unsafe fn from_task(task: Pin<&Task>) -> Pin<&Self> {
        let task_offset = {
            let stub = MaybeUninit::<Self>::uninit();
            let base_ptr = stub.as_ptr();
            let field_ptr = ptr::addr_of!((*base_ptr).task);
            (field_ptr as usize) - (base_ptr as usize)
        };

        let task_ptr = (&*task) as *const Task as usize;
        let self_ptr = (task_ptr - task_offset);
        Pin::new_unchecked(&*(self_ptr as *const Self))
    }

    fn on_poll(task: Pin<&Task>) {

    }

    fn on_wake(task: Pin<&Task>) {

    }

    fn on_drop(task: Pin<&Task>) {

    }

    fn on_join(task: Pin<&Task>, waker: &Waker, result: *mut ()) -> bool {
        let this = Self::from_task(task);

    }

    fn on_detach(task: Pin<&Task>) {
        let this = Self::from_task(task);

    }
}

pub struct JoinHandle<T> {
    task: Option<NonNull<Task>>,
    _phantom: PhantomData<T>,
}

impl<T> Drop for JoinHandle<T> {
    fn drop(&mut self) {
        if let Some(task) = self.task {
            let task = unsafe { Pin::new_unchecked(task.as_ref()) };
            (task.vtable.detach_fn)(task)
        }
    }
}

impl<T> Future for JoinHandle<T> {
    type Output = T;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        let task = self.task.expect("JoinHandle polled after completion");
        let task = unsafe { Pin::new_unchecked(task.as_ref()) };

        let mut result = MaybeUninit::unint();
        if !(task.vtable.join_fn)(task, ctx.waker(), result.as_mut_ptr() as *mut ()) {
            return Poll::Pending;
        }

        self.task = None;
        Poll::Ready(unsafe { result.assume_init() })
    }
}