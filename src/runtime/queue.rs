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

        let head = batch.head.expect("is_empty() check said this was safe");
        let mut tail = batch.tail.expect("is_empty() check said this was safe");

        let mut stack = self.stack.load(Ordering::Relaxed);
        loop {
            unsafe { tail.as_mut().next.set(NonNull::new(stack)) };
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
}

pub(crate) struct LocalQueue {
    head: AtomicUsize,
    tail: AtomicUsize,
    overflow: AtomicPtr<Task>,
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
    fn push_buffer(queue: &LocalQueue, mut batch: Batch) -> Option<Batch> {
        let mut tail = queue.tail.load(Ordering::Relaxed);
        let mut head = queue.head.load(Ordering::Relaxed);
        loop {
            let slots = queue.buffer.len() - tail.wrapping_sub(head);
            if slots > 0 {
                tail = (0..slots).zip(batch.drain()).fold(tail, |tail, (_, task)| {
                    let index = tail % queue.buffer.len();
                    queue.buffer[index].store(task.as_ptr(), Ordering::Relaxed);
                    tail.wrapping_add(1)
                });

                queue.tail.store(tail, Ordering::Release);
                if batch.is_empty() {
                    return None;
                }

                spin_loop();
                head = queue.head.load(Ordering::Relaxed);
                continue;
            }

            if let Err(e) =
                queue
                    .head
                    .compare_exchange_weak(head, tail, Ordering::Acquire, Ordering::Relaxed)
            {
                spin_loop();
                head = e;
                continue;
            }

            let mut overflowed = (0..queue.buffer.len()).fold(Batch::new(), |mut batch, offset| {
                let index = head.wrapping_add(offset) % queue.buffer.len();
                let task = queue.buffer[index].load(Ordering::Relaxed);
                batch.push(unsafe { Pin::new_unchecked(&mut *task) });
                batch
            });

            overflowed.push(batch);
            return Some(overflowed);
        }
    }

    fn pop_buffer(queue: &LocalQueue) -> Option<NonNull<Task>> {
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

            if let Err(_) =
                queue
                    .head
                    .compare_exchange(head, tail, Ordering::AcqRel, Ordering::Relaxed)
            {
                spin_loop();
                task = None;
            }
        }

        queue.tail.store(tail, Ordering::Release);
        task
    }

    fn steal_buffer(queue: &LocalQueue) -> Option<NonNull<Task>> {
        loop {
            let head = queue.head.load(Ordering::Acquire);
            let tail = queue.tail.load(Ordering::Acquire);
            if head == tail && head != tail.wrapping_sub(1) {
                return None;
            }

            let index = head % queue.buffer.len();
            let task = queue.buffer[index].load(Ordering::Relaxed);
            match queue.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                Ok(_) => return NonNull::new(task),
                Err(_) => spin_loop(),
            }
        }
    }

    fn push_overflow(queue: &LocalQueue, batch: Batch) {
        let Batch { head, tail } = batch;
        let head = head.expect("this batch shouldn't be empty");
        let mut tail = tail.expect("this batch shouldn't be empty");

        let mut overflow = queue.overflow.load(Ordering::Relaxed);
        loop {
            unsafe { tail.as_mut().next.set(NonNull::new(overflow)) };

            if overflow.is_null() {
                queue.overflow.store(head.as_ptr(), Ordering::Release);
                return;
            }

            match queue.overflow.compare_exchange_weak(
                overflow,
                head.as_ptr(),
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Ok(_) => return,
                Err(e) => {
                    spin_loop();
                    overflow = e;
                }
            }
        }
    }

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    fn take_overflow(queue: &LocalQueue) -> Option<NonNull<Task>> {
        let overflow = queue.overflow.load(Ordering::Relaxed);
        if overflow.is_null() {
            return None;
        }

        let overflow = queue.overflow.swap(ptr::null_mut(), Ordering::Acquire);
        NonNull::new(overflow)
    }

    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
    fn take_overflow(queue: &LocalQueue) -> Option<NonNull<Task>> {
        let mut overflow = queue.overflow.load(Ordering::Relaxed);
        loop {
            if overflow.is_null() {
                return None;
            }

            match queue.overflow.compare_exchange_weak(
                overflow,
                ptr::null_mut(),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => return NonNull::new(overflow),
                Err(e) => {
                    spin_loop();
                    overflow = e;
                }
            }
        }
    }

    fn pop_and_steal_overflow(
        queue: &LocalQueue,
        target: &LocalQueue,
    ) -> Option<(NonNull<Task>, bool)> {
        let mut first_task = Self::take_overflow(target)?;
        let mut overflowed = unsafe { first_task.as_mut().next.get() };

        let tail = queue.tail.load(Ordering::Relaxed);
        let new_tail = (0..queue.buffer.len())
            .zip(std::iter::from_fn(|| unsafe {
                let mut task = overflowed?;
                overflowed = task.as_mut().next.get();
                Some(task)
            }))
            .fold(tail, |tail, (_, task)| {
                let index = tail % queue.buffer.len();
                queue.buffer[index].store(task.as_ptr(), Ordering::Relaxed);
                tail.wrapping_add(1)
            });

        if new_tail != tail {
            queue.tail.store(new_tail, Ordering::Release);
        }

        if let Some(overflowed) = overflowed {
            queue.overflow.store(overflowed.as_ptr(), Ordering::Release);
        }

        Some((first_task, overflowed.is_some()))
    }

    pub(crate) fn push(&mut self, batch: impl Into<Batch>) {
        let batch = batch.into();
        if batch.is_empty() {
            return;
        }

        if let Some(overflowed) = Self::push_buffer(self.queue, batch) {
            Self::push_overflow(self.queue, overflowed);
        }
    }

    pub(crate) fn pop(&mut self) -> Option<(NonNull<Task>, bool)> {
        Self::pop_buffer(self.queue)
            .map(|task| (task, false))
            .or_else(|| Self::pop_and_steal_overflow(self.queue, self.queue))
    }

    pub(crate) fn pop_and_steal(&mut self, target: &LocalQueue) -> Option<(NonNull<Task>, bool)> {
        Self::steal_buffer(target)
            .map(|task| (task, false))
            .or_else(|| Self::pop_and_steal_overflow(self.queue, target))
    }
}
