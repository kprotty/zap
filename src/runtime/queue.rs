use super::task::{Batch, Task};
use std::{
    hint::spin_loop,
    pin::Pin,
    ptr::{self, NonNull},
    sync::atomic::{AtomicPtr, AtomicUsize, Ordering},
};

pub(crate) struct GlobalQueue {
    stack: AtomicPtr<Task>,
}

impl GlobalQueue {
    pub(crate) const fn new() -> Self {
        Self {
            stack: AtomicPtr::new(ptr::null_mut()),
        }
    }

    pub(crate) fn push(&self, batch: impl Into<Batch>) {
        let batch = batch.into();
        if batch.is_empty() {
            return;
        }

        self.push_batch(batch, false)
    }

    fn push_batch(&self, batch: Batch, is_owned: bool) {
        let head = batch.head.expect("batch should not be empty");
        let mut tail = batch.tail.expect("batch should not be empty");

        let mut stack = self.stack.load(Ordering::Relaxed);
        loop {
            unsafe { tail.as_mut().next.set(NonNull::new(stack)) };

            if is_owned && stack.is_null() {
                self.stack.store(head.as_ptr(), Ordering::Release);
                return;
            }

            match self.stack.compare_exchange_weak(
                stack,
                head.as_ptr(),
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Ok(_) => return,
                Err(e) => stack = e,
            }
        }
    }

    fn push_stack(&self, stack: NonNull<Task>) {
        assert!(self.stack.load(Ordering::Relaxed).is_null());
        self.stack.store(stack.as_ptr(), Ordering::Release);
    }

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    pub(crate) fn take_stack(&self) -> Option<NonNull<Task>> {
        let stack = self.stack.load(Ordering::Relaxed);
        if stack.is_null() {
            return None;
        }

        let stack = self.stack.swap(ptr::null_mut(), Ordering::Acquire);
        NonNull::new(stack)
    }

    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
    pub(crate) fn take_stack(&self) -> Option<NonNull<Task>> {
        let mut stack = self.stack.load(Ordering::Relaxed);
        loop {
            if stack.is_null() {
                return None;
            }

            match self.stack.compare_exchange_weak(
                stack,
                ptr::null_mut(),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => return NonNull::new(stack),
                Err(e) => {
                    spin_loop();
                    stack = e;
                }
            }
        }
    }
}

pub(crate) struct LocalQueue {
    head: AtomicUsize,
    tail: AtomicUsize,
    overflow: GlobalQueue,
    buffer: [AtomicPtr<Task>; Self::CAPACITY],
}

impl LocalQueue {
    const CAPACITY: usize = 128;

    pub(crate) const fn new() -> Self {
        const SLOT: AtomicPtr<Task> = AtomicPtr::new(ptr::null_mut());
        Self {
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            overflow: AtomicPtr::new(ptr::null_mut()),
            buffer: [SLOT; Self::CAPACITY],
        }
    }

    pub(crate) unsafe fn producer(&self) -> LocalQueueProducer<'_> {
        LocalQueueProducer { queue: self }
    }
}

pub(crate) struct LocalQueueProducer<'a> {
    queue: &'a LocalQueue,
}

impl<'a> LocalQueueProducer<'a> {
    fn push_buffer(&self, mut batch: Batch) -> Option<Batch> {
        let tail = self.queue.tail.load(Ordering::Relaxed);
        let head = self.queue.head.load(Ordering::Relaxed);

        let slots = self.queue.buffer.len() - tail.wrapping_sub(head);
        if batch.size <= slots {
            let new_tail = (0..slots)
                .zip(batch.drain())
                .fold(tail, |new_tail, (_, task)| {
                    let index = new_tail % self.queue.buffer.len();
                    self.queue.buffer[index].store(task.as_ptr(), Ordering::Relaxed);
                    new_tail.wrapping_add(1)
                });

            self.queue.tail.store(new_tail, Ordering::Release);
            return None;
        }

        let head = self.queue.head.swap(tail, Ordering::Acquire);
        let mut overflowed =
            (0..tail.wrapping_sub(head)).fold(Batch::new(), |mut overflow_batch, offset| {
                let index = head.wrapping_add(offset) % self.queue.buffer.len();
                let task = self.queue.buffer[index].load(Ordering::Relaxed);
                overflow_batch.push(unsafe { Pin::new_unchecked(&mut *task) });
                overflow_batch
            });

        overflowed.push(batch);
        return Some(overflowed);
    }

    fn pop_buffer(&self) -> Option<NonNull<Task>> {
        let tail = queue.tail.load(Ordering::Relaxed);
        let head = queue.head.load(Ordering::Relaxed);
        if tail == head {
            return None;
        }

        queue.tail.swap(tail.wrapping_sub(1), Ordering::Acquire);
        let head = queue.head.load(Ordering::Relaxed);

        let mut task = None;
        if tail != head {
            let index = tail.wrapping_sub(1) % queue.buffer.len();
            task = NonNull::new(queue.buffer[index].load(Ordering::Relaxed));
            if head != tail.wrapping_sub(1) {
                return task;
            }

            if queue
                .head
                .compare_exchange(head, tail, Ordering::AcqRel, Ordering::Relaxed)
                .is_err()
            {
                spin_loop();
                task = None;
            }
        }

        queue.tail.store(tail, Ordering::Release);
        task
    }

    fn steal_buffer(&self) -> Option<NonNull<Task>> {
        let mut head = queue.head.load(Ordering::Acquire);
        loop {
            let tail = queue.tail.load(Ordering::Acquire);
            if head == tail || head == tail.wrapping_sub(1) {
                return None;
            }

            let index = head % queue.buffer.len();
            let task = queue.buffer[index].load(Ordering::Relaxed);
            match queue.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return NonNull::new(task),
                Err(e) => {
                    spin_loop();
                    head = e;
                }
            }
        }
    }

    fn fill_buffer(&self, stack: NonNull<Task>) -> Option<NonNull<Task>> {
        let mut stack = Some(stack);
        let tail = self.queue.tail.load(Ordering::Relaxed);
        let head = self.queue.head.load(Ordering::Relaxed);

        let slots = self.queue.buffer.len() - tail.wrapping_sub(head);
        let new_tail = (0..slots)
            .zip(std::iter::from_fn(|| unsafe {
                let mut task = stack?;
                stack = task.as_mut().next.get();
                Some(task)
            }))
            .fold(tail, |tail, (_, task)| {
                let index = tail % self.queue.buffer.len();
                self.queue.buffer[index].store(task.as_ptr(), Ordering::Relaxed);
                tail.wrapping_add(1)
            });

        if new_tail != tail {
            self.queue.tail.store(new_tail, Ordering::Release);
        }

        stack
    }

    pub(crate) fn push(&mut self, batch: impl Into<Batch>) {
        let batch = batch.into();
        if batch.is_empty() {
            return;
        }

        if let Some(overflowed) = self.push_buffer(batch) {
            self.overflow.push_batch(overflowed, true);
        }
    }

    pub(crate) fn pop(&mut self) -> Option<(NonNull<Task>, bool)> {
        self.pop_buffer()
            .map(|task| (task, false))
            .or_else(|| self.pop_and_steal_global(&self.overflow))
    }

    pub(crate) fn pop_and_steal_local(
        &mut self,
        target: &LocalQueue,
    ) -> Option<(NonNull<Task>, bool)> {
        target
            .steal_buffer()
            .map(|task| (task, false))
            .or_else(|| self.pop_and_steal_global(&target.overflow))
    }

    pub(crate) fn pop_and_steal_global(
        &self,
        target: &GlobalQueue,
    ) -> Option<(NonNull<Task>, bool)> {
        let mut task = target.take_stack()?;
        let mut stack = unsafe { task.as_mut().next.get() };

        let did_push = stack.is_some();
        if let Some(left_over) = stack.and_then(|s| self.fill_buffer(s)) {
            self.overflow.push_stack(left_over);
        }

        Some((task, did_push))
    }
}
