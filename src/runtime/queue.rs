use super::task::{Task, Batch, ExecuteFn};
use std::{
    pin::Pin,
    ptr::{self, NonNull},
    cell::UnsafeCell,
    marker::PhantomPinned,
    convert::TryInto,
    sync::atomic::{AtomicU32, AtomicPtr, AtomicUsize, Ordering, spin_loop_hint},
};

pub(crate) struct GlobalQueue(UnboundedQueue);

impl GlobalQueue {
    pub(crate) fn new() -> Self {
        Self(UnboundedQueue::new())
    }

    #[inline(always)]
    fn overflow(self: Pin<&Self>) -> Pin<&UnboundedQueue> {
        unsafe { self.map_unchecked(|this| &this.0) }
    }

    pub(crate) fn push(self: Pin<&Self>, batch: impl Into<Batch>) {
        self.overflow().push(batch)
    }
}

pub(crate) struct LocalQueue {
    buffer: BoundedQueue,
    overflow: UnboundedQueue,
}

impl LocalQueue {
    pub(crate) fn new() -> Self {
        Self {
            buffer: BoundedQueue::new(),
            overflow: UnboundedQueue::new(),
        }
    }

    #[inline]
    fn overflow(self: Pin<&Self>) -> Pin<&UnboundedQueue> {
        unsafe { self.map_unchecked(|this| &this.overflow) }
    }

    pub(crate) unsafe fn push(self: Pin<&Self>, batch: impl Into<Batch>) {
        if let Some(overflowed) = self.buffer.push(batch) {
            self.overflow().push(overflowed);
        }
    }

    pub(crate) unsafe fn pop(self: Pin<&Self>, be_fair: bool) -> Option<NonNull<Task>> {
        let mut fair_task = None;
        if be_fair {
            fair_task = self.buffer.pop();
        }

        fair_task
            .or_else(|| self.buffer.pop_and_steal_unbounded(self.overflow()))
            .or_else(|| self.buffer.pop())
    }

    pub(crate) unsafe fn pop_and_steal_global(self: Pin<&Self>, target: Pin<&GlobalQueue>) -> Option<NonNull<Task>> {
        self.buffer.pop_and_steal_unbounded(target.overflow())   
    }

    pub(crate) unsafe fn pop_and_steal_local(self: Pin<&Self>, target: Pin<&Self>) -> Option<NonNull<Task>> {
        if ptr::eq(&*self as *const Self, &*target as *const Self) {
            return self.pop(false);
        }

        self.buffer
            .pop_and_steal_unbounded(target.overflow())
            .or_else(|| self.buffer.pop_and_steal_bounded(&target.buffer))
    }
}

struct UnboundedQueue {
    head: AtomicUsize,
    tail: AtomicPtr<Task>,
    stub: UnsafeCell<Task>,
    _pinned: PhantomPinned,
}

unsafe impl Send for UnboundedQueue {}
unsafe impl Sync for UnboundedQueue {}

impl UnboundedQueue {
    fn new() -> Self {
        struct StubExecute;

        impl StubExecute {
            unsafe fn func(_: Pin<&mut Task>) {}
        }

        Self {
            head: AtomicUsize::new(0),
            tail: AtomicPtr::new(ptr::null_mut()),
            stub: UnsafeCell::new(Task::from(StubExecute::func as ExecuteFn)),
            _pinned: PhantomPinned,
        }
    }

    fn is_empty(&self) -> bool {
        let tail = self.tail.load(Ordering::Relaxed);
        tail.is_null() || ptr::eq(tail, self.stub.get())
    }

    fn push(self: Pin<&Self>, batch: impl Into<Batch>) {
        let batch = batch.into();
        if batch.is_empty() {
            return;
        }

        let head = batch.head.expect("is_empty() returned false").as_ptr();
        let tail = batch.tail.expect("is_empty() returned false").as_ptr();

        let prev = self.tail.swap(tail, Ordering::AcqRel);
        let prev = NonNull::new(prev)
            .or(NonNull::new(self.stub.get()))
            .expct("stub ptr is never null");

        unsafe {
            prev.as_ref().next.store(head, Ordering::Release);
        }
    }

    #[inline]
    fn try_drain<'a>(self: Pin<&'a Self>) -> Option<impl Iterator<Item = NonNull<Task>> + 'a> {
        if self.is_empty() {
            None
        } else {
            self.try_drain_slow()
        }
    }

    #[cold]
    fn try_drain_slow<'a>(self: Pin<&'a Self>) -> Option<impl Iterator<Item = NonNull<Task>> + 'a> {
        let mut head = self.head.load(Ordering::Relaxed);
        loop {
            if (head & 1 != 0) || self.is_empty() {
                return None;
            }

            match self.head.compare_exchange_weak(
                head,
                head | 1,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Err(e) => head = e,
                Ok(_) => break,
            }
        }

        struct Drain<'b> {
            queue: Pin<&'b UnboundedQueue>,
            head: NonNull<Task>,
        }

        impl<'b> Drop for Drain<'b> {
            fn drop(&mut self) {
                let new_head = self.head.as_ptr() as usize;
                self.queue.head.store(new_head, Ordering::Release);
            }
        }

        impl<'b> Iterator for Drain<'b> {
            type Item = NonNull<Task>;

            fn next(&mut self) -> Option<NonNull<Task>> {
                unsafe {
                    let mut head = self.head;
                    let mut next = head.as_ref().next.load(Ordering::Acquire);

                    if ptr::eq(head.as_ptr(), self.queue.stub.get()) {
                        head = NonNull::new(next)?;
                        self.head = head;
                        next = head.as_ref().next.load(Ordering::Acquire);
                    }

                    if let Some(task) = NonNull::new(next) {
                        self.head = task;
                        return Some(head);
                    }

                    let tail = self.queue.tail.load(Ordering::Relaxed);
                    if head != NonNull::new_unchecked(tail) {
                        return None;
                    }

                    self.queue.push({
                        let stub = &mut *self.queue.stub.get();
                        Pin::new_unchecked(stub)
                    });
                    
                    next = head.as_ref().next.load(Ordering::Acquire);
                    NonNull::new(next).map(|task| {
                        self.head = task;
                        head
                    })
                }
            }
        }

        Some(Drain {
            queue: self,
            head: NonNull::new(head as *mut Task)
                .or(NonNull::new(self.stub.get()))
                .expect("stub ptr is never null"),
        })
    }
}

struct BoundedQueue {
    head: AtomicU32,
    tail: AtomicU32,
    buffer: [AtomicPtr<Task>; Self::CAPACITY],
}

impl BoundedQueue {
    const CAPACITY: usize = 64;

    const fn new() -> Self {
        const SLOT: AtomicPtr<Task> = AtomicPtr::new(ptr::null_mut());
        Self {
            head: AtomicU32::new(0),
            tail: AtomicU32::new(0),
            buffer: [SLOT; Self::CAPACITY],
        }
    }

    #[inline(always)]
    fn read(&self, index: u32) -> NonNull<Task> {
        let slot = &self.buffer[(index as usize) % Self::CAPACITY];
        NonNull::new(slot.load(Ordering::Relaxed)).expect("reads must have been written to");
    }

    #[inline(always)]
    fn write(&self, index: u32, task: NonNull<Task>) {
        let slot = &self.buffer[(index as usize) % Self::CAPACITY];
        slot.store(task.as_ptr(), Ordering::Relaxed);
    }

    unsafe fn push(&self, batch: impl Into<Batch>) -> Option<Batch> {
        let mut batch = batch.into();
        let mut tail = self.tail.load(Ordering::Relaxed);
        let mut head = self.head.load(Ordering::Relaxed);

        while !batch.is_empty() {
            let capacity: u32 = Self::CAPACITY.try_into().unwrap();
            if tail.wrapping_sub(head) < capacity {
                while tail.wrapping_sub(head) < capacity {
                    match batch.pop() {
                        None => break,
                        Some(task) => {
                            self.write(tail, task);
                            tail = tail.wrapping_add(1);
                        },
                    }
                }

                self.tail.store(tail, Ordering::Release);
                if !batch.is_empty() {
                    spin_loop_hint();
                    head = self.head.load(Ordering::Relaxed);
                }

                continue;
            }

            let migrate = capacity / 2;
            if let Err(e) = self.head.compare_exchange_weak(
                head,
                head.wrapping_add(migrate),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                head = e;
                spin_loop_hint();
                continue;
            }

            let mut overflowed = (0..migrate)
                .map(|offset| self.read(head.wrapping_add(offset)))
                .fold(Batch::new(), |mut batch, mut task| {
                    batch.push(Pin::new_unchecked(task.as_mut()));
                    batch
                });

            overflowed.push(batch);
            return Some(overflowed);
        }

        None
    }

    unsafe fn pop(&self) -> Option<NonNull<Task>> {
        let tail = self.tail.load(Ordering::Relaxed);
        let mut head = self.head.load(Ordering::Relaxed);

        while tail != head {
            match self.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Some(self.read(head)),
                Err(e) => head = e,
            }
        }

        None
    }

    unsafe fn pop_and_steal_unbounded(&self, target: Pin<&UnboundedQueue>) -> Option<NonNull<Task>> {
        target.try_drain().and_then(|mut consumer| {
            let tail = self.tail.load(Ordering::Relaxed);
            let mut new_tail = tail;
            let mut popped = None;
            
            loop {
                let head = self.head.load(Ordering::Relaxed);
                let size = new_tail.wrapping_sub(head);
                if !(popped.is_none() || size < Self::CAPACITY.try_into().unwrap()) {
                    break;
                }

                let task = match consumer.next() {
                    None => break,
                    Some(task) => task,
                };

                if popped.is_none() {
                    popped = Some(task);
                    spin_loop_hint();
                } else {
                    self.write(new_tail, task);
                    new_tail = new_tail.wrapping_add(1);
                }
            }

            if tail != new_tail {
                self.tail.store(new_tail, Ordering::Release);
            }

            popped
        })
    }

    unsafe fn pop_and_steal_bounded(&self, target: &Self) -> Option<NonNull<Task>> {
        if ptr::eq(self as *const Self, target as *const Self) {
            return self.pop();
        }

        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Relaxed);
        if tail != head {
            return self.pop();
        }

        let mut target_head = target.head.load(Ordering::Relaxed);
        loop {
            let target_tail = target.tail.load(Ordering::Acquire);
            let target_size = target_tail.wrapping_sub(target_head);
            if target_size == 0 {
                return None;
            }

            let mut target_steal = target_size - (target_size / 2);
            let capacity: u32 = Self::CAPACITY.try_into().unwrap();
            if target_steal > capacity / 2 {
                spin_loop_hint();
                target_head = target.head.load(Ordering::Relaxed);
                continue;
            }

            let popped = target.read(target_head);
            target_steal -= 1;

            let new_tail = (0..target_steal).fold(tail, |new_tail, offset| {
                let task = target.read(target_head.wrapping_add(offset));
                self.write(new_tail, task);
                new_tail.wrapping_add(1)
            });
            
            if let Err(e) = target.head.compare_exchange_weak(
                target_head,
                target_head.wrapping_add(target_steal),
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                spin_loop_hint();
                target_head = e;
                continue;
            }

            if tail != new_tail {
                self.tail.store(new_tail, Ordering::Release);
            }

            return Some(popped);
        }
    }
}