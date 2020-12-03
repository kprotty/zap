use super::{ActiveNode, Batch, BoundedQueue, IdleNode, Scheduler, Task, UnboundedQueue};
use std::{
    cell::{Cell, UnsafeCell},
    marker::PhantomPinned,
    mem::size_of,
    num::NonZeroUsize,
    pin::Pin,
    ptr::null_mut,
    ptr::NonNull,
    sync::atomic::{AtomicPtr, Ordering},
};

#[repr(align(4))]
pub(crate) struct Worker {
    scheduler: NonNull<Scheduler>,
    run_queue: BoundedQueue,
    run_queue_tick: Cell<usize>,
    run_queue_prng: Cell<usize>,
    run_queue_lifo: AtomicPtr<Task>,
    run_queue_overflow: UnboundedQueue,
    run_queue_next: Cell<Option<NonNull<Task>>>,
    pub(crate) idle_node: UnsafeCell<IdleNode>,
    pub(crate) active_node: UnsafeCell<ActiveNode>,
    _pinned: PhantomPinned,
}

unsafe impl Send for Worker {}
unsafe impl Sync for Worker {}

impl Worker {
    pub(crate) fn new(scheduler: Pin<&Scheduler>, seed: NonZeroUsize) -> Self {
        Self {
            scheduler: NonNull::from(&*scheduler),
            run_queue: BoundedQueue::new(),
            run_queue_tick: Cell::new(seed.get()),
            run_queue_prng: Cell::new(seed.get()),
            run_queue_lifo: AtomicPtr::default(),
            run_queue_overflow: UnboundedQueue::new(),
            run_queue_next: Cell::new(None),
            idle_node: UnsafeCell::new(IdleNode::new()),
            active_node: UnsafeCell::new(ActiveNode::new()),
            _pinned: PhantomPinned,
        }
    }

    pub(crate) unsafe fn owned(self: Pin<&Worker>) -> OwnedWorkerRef<'_> {
        OwnedWorkerRef {
            worker: self,
            scheduler: Pin::new_unchecked(&*self.scheduler.as_ptr()),
        }
    }
}

pub(crate) struct OwnedWorkerRef<'a> {
    pub(crate) worker: Pin<&'a Worker>,
    pub(crate) scheduler: Pin<&'a Scheduler>,
}

impl<'a> OwnedWorkerRef<'a> {
    pub(crate) fn schedule(&mut self, use_next: bool, use_lifo: bool, tasks: impl Into<Batch>) {
        let mut batch: Batch = tasks.into();
        if batch.empty() {
            return;
        }

        if use_next {
            let new_next = batch.pop_front().unwrap();
            let old_next = self.worker.run_queue_next.replace(Some(new_next));

            if let Some(old_next) = old_next {
                let old_next = unsafe { Pin::new_unchecked(&mut *old_next.as_ptr()) };
                batch.push_front(old_next);
            }

            if batch.empty() {
                return;
            }
        }

        if use_lifo {
            let new_lifo = batch.pop_front().unwrap().as_ptr();

            let mut old_lifo = self.worker.run_queue_lifo.load(Ordering::Relaxed);
            if !old_lifo.is_null() {
                old_lifo = self.worker.run_queue_lifo.swap(new_lifo, Ordering::AcqRel);
            } else {
                self.worker
                    .run_queue_lifo
                    .store(new_lifo, Ordering::Release);
            }

            if !old_lifo.is_null() {
                let old_lifo = unsafe { Pin::new_unchecked(&mut *old_lifo) };
                batch.push_front(old_lifo);
            }
        }

        if !batch.empty() {
            let (mut run_queue, overflow_queue) = unsafe {
                (
                    self.worker.run_queue.producer(),
                    self.worker.map_unchecked(|w| &w.run_queue_overflow),
                )
            };

            if let Some(overflowed) = run_queue.push(batch) {
                overflow_queue.push(overflowed);
            }
        }

        self.scheduler.notify();
    }

    pub(crate) fn poll(&self) -> Option<Pin<&'a mut Task>> {
        let tick = self.worker.run_queue_tick.get();
        self.poll_task(tick).map(|task| {
            self.worker.run_queue_tick.set(tick.wrapping_add(1));
            unsafe { Pin::new_unchecked(&mut *task.as_ptr()) }
        })
    }

    fn poll_task(&self, tick: usize) -> Option<NonNull<Task>> {
        let (mut run_queue, overflow_queue, shared_queue) = unsafe {
            (
                self.worker.run_queue.producer(),
                self.worker.map_unchecked(|w| &w.run_queue_overflow),
                self.scheduler.map_unchecked(|s| &s.run_queue),
            )
        };

        // Check the scheduler run queue once in a long while to avoid global starvation
        if tick % 131 == 0 {
            if let Some(task) = run_queue.pop_and_steal(shared_queue) {
                return Some(task);
            }
        }

        // Check the overflow queue once in a while to avoid local starvation
        if tick % 61 == 0 {
            if let Some(task) = run_queue.pop_and_steal(overflow_queue) {
                return Some(task);
            }
        }

        // Check the NEXT slot before anything else (but after fairness checks)
        if let Some(task) = self.worker.run_queue_next.replace(None) {
            return Some(task);
        }

        // Check the LIFO slot before the FIFO queues underneath
        if let Some(task) = {
            let lifo_slot = &self.worker.run_queue_lifo;
            let mut lifo = lifo_slot.load(Ordering::Relaxed);
            if !lifo.is_null() {
                lifo = lifo_slot.swap(null_mut(), Ordering::Acquire);
            }
            NonNull::new(lifo)
        } {
            return Some(task);
        }

        // Check the worker's FIFO run queue for tasks (the common path).
        if let Some(task) = run_queue.pop() {
            return Some(task);
        }

        // Check the worker's overflow queue for tasks
        if let Some(task) = run_queue.pop_and_steal(overflow_queue) {
            return Some(task);
        }

        // There are no tasks local to the worker.
        // Check the scheduler's shared queue for tasks
        if let Some(task) = run_queue.pop_and_steal(shared_queue) {
            return Some(task);
        }

        let num_workers = {
            let active_workers = self.scheduler.count_active_workers();
            debug_assert!(active_workers > 0);
            active_workers as usize
        };

        // Create a cyclic iterator of all the observable active workers in the scheduler.
        // Then skip a random amount for the starting point in order to reduce contention.
        let mut worker_iter = self.scheduler.workers();
        let mut workers = (0..)
            .map(|_| {
                worker_iter.next().unwrap_or_else(|| {
                    worker_iter = self.scheduler.workers();
                    worker_iter.next().expect("no workers when stealing")
                })
            })
            .skip({
                // Xorshift PRNG which supports most architectures
                let (a, b, c) = match size_of::<usize>() {
                    8 => (13, 7, 17),
                    4 => (13, 17, 5),
                    2 => (7, 9, 8),
                    _ => unreachable!("platform not supported"),
                };
                let mut prng = self.worker.run_queue_prng.get();
                prng ^= prng << a;
                prng ^= prng >> b;
                prng ^= prng << c;
                self.worker.run_queue_prng.set(prng);
                prng % num_workers
            })
            .take(num_workers);

        while let Some(target_worker) = workers.next() {
            // Don't steal from ourselves
            if NonNull::from(&*target_worker) == NonNull::from(&*self.worker) {
                continue;
            }

            // Try to steal from the target worker's run queue first
            if let Some(task) = run_queue.pop_and_steal(&target_worker.run_queue) {
                return Some(task);
            }

            // Then try to steal from the target worker's overflow queue
            if let Some(task) = run_queue
                .pop_and_steal(unsafe { target_worker.map_unchecked(|w| &w.run_queue_overflow) })
            {
                return Some(task);
            }

            // As a last-resort, try to steal from the target worker's LIFO task slot.
            if let Some(task) = {
                let lifo_slot = &target_worker.run_queue_lifo;
                let mut lifo = lifo_slot.load(Ordering::Relaxed);

                if !lifo.is_null() {
                    // We really don't want to steal from a worker's LIFO slot
                    // as the primary purpose of it is to improve task cache locality.
                    //
                    // So we try to yield a bit in order to give the worker's thread some time to use the LIFO slot.
                    // On windows, we just yield instead of sleeping due to its large timer granularity
                    if cfg!(windows) {
                        std::thread::yield_now();
                    } else {
                        std::thread::sleep(std::time::Duration::from_micros(1));
                    }

                    // Recheck the lifo slot again in order to avoid the synchronized swap operation.
                    lifo = lifo_slot.load(Ordering::Relaxed);
                    if !lifo.is_null() {
                        lifo = lifo_slot.swap(null_mut(), Ordering::Acquire);
                    }
                }

                NonNull::new(lifo)
            } {
                return Some(task);
            }
        }

        // As a last-resort, check the scheduler's run queue again to see if any tasks were added while stealing.
        if let Some(task) = run_queue.pop_and_steal(shared_queue) {
            return Some(task);
        }

        // No tasks were immediately observable by the worker :(
        None
    }
}
