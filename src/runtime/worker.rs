use super::{IdleNode, ActiveNode, Batch, BoundedQueue, BoundedProducer, Scheduler, Task, UnboundedQueue};
use std::{
    cell::{Cell, UnsafeCell},
    marker::PhantomPinned,
    pin::Pin,
    ptr::NonNull,
    sync::atomic::{AtomicPtr, Ordering},
};

#[repr(align(4))]
pub(crate) struct Worker {
    idle_node: UnsafeCell<IdleNode>,
    active_node: UnsafeCell<ActiveNode>,
    sched_state: Cell<usize>,
    run_queue: BoundedQueue,
    run_queue_tick: Cell<usize>,
    run_queue_lifo: AtomicPtr<Task>,
    run_queue_overflow: UnboundedQueue,
    run_queue_next: Cell<Option<NonNull<Task>>>,
    _pinned: PhantomPinned,
}

unsafe impl Send for Worker {}
unsafe impl Sync for Worker {}

impl Worker {
    pub(crate) fn new(scheduler: Pin<&Scheduler>) -> Self {
        Self {
            idle_node: UnsafeCell::new(IdleNode::default()),
            active_node: UnsafeCell::new(ActiveNode::default()),
            sched_state: Cell::new(scheduler.as_ref() as usize),
            run_queue: BoundedQueue::new(),
            run_queue_tick: Cell::new(0),
            run_queue_lifo: AtomicPtr::default(),
            run_queue_overflow: UnboundedQueue::new(),
            run_queue_next: Cell::new(None),
            _pinned: PhantomPinned,
        }
    }

    /// Create a reference to the worker which represents primiary ownership of the worker.
    ///
    /// # SAFETY:
    ///
    /// The caller must ensure that only the worker's owning thread can create an OwnedWorkerRef
    pub(crate) unsafe fn owned_ref(self: Pin<&Self>) -> OwnedWorkerRef<'_> {
        OwnedWorkerRef {
            shared: self.shared_ref(),
            bounded: self.run_queue.producer(),
        }
    }

    /// Create a reference to the worker which represents access from outside the owner
    pub(crate) fn shared_ref(self: Pin<&Self>) -> SharedWorkerRef<'_> {
        SharedWorkerRef {
            worker: self,
            unbounded: Pin::new_unchecked(&self.run_queue_overflow),
        }
    }
}

pub(crate) struct SharedWorkerRef<'a> {
    worker: Pin<&'a Worker>,
    unbounded: Pin<&'a UnboundedQueue>,
}

impl<'a> SharedWorkerRef<'a> {
    pub(crate) fn worker(&self) -> Pin<&'a Worker> {
        self.worker
    }
}

pub(crate) struct OwnedWorkerRef<'a> {
    shared: SharedWorkerRef<'a>,
    bounded: BoundedProducer<'a>,
}

impl<'a> OwnedWorkerRef<'a> {
    pub(crate) fn run(&self) {
        compile_error!("TODO")
    }

    pub(crate) fn as_shared(&self) -> SharedWorkerRef<'a> {
        self.shared
    }

    fn worker(&self) -> Pin<&'a Worker> {
        self.as_shared().worker()
    }

    pub(crate) fn with_scheduler<F>(self: Pin<&Self>, f: impl FnOnce(Pin<&Scheduler>) -> F) -> F {
        // SAFETY: 
        // A valid Pin<&Scheduler> was stored at the creation of the Worker.
        // We're also the only one that can set or get the worker sched_state
        f(unsafe {
            let scheduler = (self.worker().sched_state.get() & !1) as *mut Scheduler;
            let scheduler = NonNull::new_unchecked(scheduler);
            Pin::new_unchecked(scheduler.as_ref())
        })
    }

    fn is_waking(&self) -> bool {
        self.worker().sched_state.get() & 1 != 0
    }

    fn set_waking(&self, is_waking: bool) {
        let sched_state = self.worker().sched_state.get() & !1;
        let is_waking = if is_waking { 1 } else { 0 };
        self.worker().sched_state.set(sched_state | is_waking);
    }

    /// Schedule a batch of tasks onto the worker using FIFO ordering.
    pub(crate) fn schedule(&self, batch: impl Into<Batch>) {
        self.schedule_many(batch.into(), false, false)
    }

    /// Schedule a task on the worker to be executed as soon as possible without synchronization.
    pub(crate) fn schedule_next(&self, task: Pin<&mut Task>) {
        self.schedule_many(Batch::from(task), true, false)
    }

    /// Schedule a task on the worker to execute before any FIFO scheduled tasks.
    pub(crate) fn schedule_lifo(&self, task: Pin<&mut Task>) {
        self.schedule_many(Batch::from(task), false, true)
    }

    fn schedule_many(&self, mut batch: Batch, use_next: bool, use_lifo: bool) {
        if batch.empty() {
            return;
        }

        if use_next {
            // SAFETY:
            // - run_queue_next is accessed only through an OwnedWorkerRef
            // - Only pinned Tasks are stored into run_queue_next
            // - replacing from run_queue_next transfers ownership of the pinned Task
            if let Some(old_next) = self.worker().run_queue_next.replace(batch.pop_front()) {
                batch.push_front(unsafe { Pin::new_unchecked(&mut *old_next.as_ptr()) });
            }

            // Don't wake up a thread if we're not pushing to a shared run_queue* resource.
            if batch.empty() {
                return;
            }
        }

        if use_lifo {
            let new_lifo = batch.pop_front().map(|p| p.as_ptr()).unwrap();
            let old_lifo = self.worker().run_queue_lifo.swap(new_lifo, Ordering::AcqRel);

            // SAFETY: The atomic swap ensures ownership, along with Batch ensuring pinning
            if let Some(old_lifo) = NonNull::new(old_lifo) {
                batch.push_front(unsafe { Pin::new_unchecked(&mut *old_lifo.as_ptr()) });
            }
        }

        if !batch.empty() {
            if let Some(overflowed) = self.bounded.push(batch) {
                self.as_shared().unbounded.push(overflowed);
            }
        }

        self.with_scheduler(|scheduler| {
            scheduler.notify();
        })
    }
}
