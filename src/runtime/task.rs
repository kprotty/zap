use crate::{
    runtime::Worker,
    sync::utils::{AtomicUsize, Ordering, spin_loop_hint},
};
use std::{
    pin::Pin,
    cell::Cell,
    mem::MaybeUninit,
    ptr::{self, NonNull},
    marker::PhantomPinned,
};

pub(crate) struct Runnable(unsafe fn(Pin<&mut Task>, Pin<&Worker>));

#[repr(C)]
pub(crate) struct Task {
    next: AtomicUsize,
    runnable: &'static Runnable,
    _pinned: PhantomPinned,
}

impl From<&'static Runnable> for Task {
    fn from(runnable: &'static Runnable) -> Self {
        Self {
            next: AtomicUsize::new(0),
            runnable,
            _pinned: PhantomPinned,
        }
    }
}

impl Task {
    #[inline]
    pub(crate) unsafe fn run(self: Pin<&mut Self>, worker: Pin<&Worker>) {
        let run_fn = self.runnable.0;
        (run_fn)(self, worker)
    }
}

pub(crate) struct Batch {
    head: Option<NonNull<Task>>,
    tail: NonNull<Task>,
}

impl Default for Batch {
    fn default() -> Self {
        Self {
            head: None,
            tail: NonNull::dangling(),
        }
    }
}

impl From<Pin<&mut Task>> for Batch {
    fn from(task: Pin<&mut Task>) -> Self {
        let task = unsafe { Pin::get_unchecked_mut(task) };
        task.next.with_mut(|next| *next = 0);

        let task = NonNull::from(task);
        Self {
            head: Some(task),
            tail: task,
        }
    }
}

impl Batch {
    pub(crate) fn empty(&self) -> bool {
        self.head.is_none()
    }

    pub(crate) fn push_back(&mut self, other: Self) {
        if let Some(_) = self.head {
            if let Some(other_head) = other.head {
                let tail = unsafe { &mut *self.tail.as_ptr() };
                tail.next.with_mut(|next| *next = other_head.as_ptr() as usize);
                self.tail = other.tail;
            }
        } else {
            *self = other;
        }
    }

    pub(crate) fn push_front(&mut self, other: Self) {
        if let Some(head) = self.head {
            if let Some(_) = other.head {
                let tail = unsafe { &mut *other.tail.as_ptr() };
                tail.next.with_mut(|next| *next = head.as_ptr() as usize);
                self.head = other.head;
            }
        } else {
            *self = other;
        }
    }

    pub(crate) fn pop_front(&mut self) -> Option<NonNull<Task>> {
        self.head.map(|head| {
            let task = unsafe { &mut *head.as_ptr() };
            self.head = NonNull::new(task.next.with_mut(|next| *next as *mut _));
            NonNull::from(task)
        })
    }

    pub(crate) fn drain(&mut self) -> BatchDrain<'_> {
        BatchDrain(self)
    }

    pub(crate) fn iter(&self) -> BatchIter<'_> {
        BatchIter {
            _batch: self,
            current: self.head,
        }
    }
}

pub(crate) struct BatchDrain<'a>(&'a mut Batch);

impl<'a> Iterator for BatchIter<'a> {
    type Item = NonNull<Task>;

    fn next(&mut self) -> Option<Self::Item> {
        self.0.pop_front()
    }
}

pub(crate) struct BatchIter<'a> {
    _batch: &'a Batch,
    current: Option<NonNull<Task>>,
}

impl<'a> Iterator for BatchIter<'a> {
    type Item = NonNull<Task>;

    fn next(&mut self) -> Option<Self::Item> {
        self.current.map(|task| {
            let task = unsafe { &mut *head.as_ptr() };
            self.current = NonNull::new(task.next.with_mut(|next| *next as *mut _));
            NonNull::from(task)
        })
    }
}

pub(crate) struct UnboundedQueue {
    is_popping: AtomicBool,
    head: AtomicUsize,
    tail: Cell<NonNull<Task>>,
    stub: UnsafeCell<Task>,
    _pinned: PhantomPinned,
}

unsafe impl Send for UnboundedQueue {}
unsafe impl Sync for UnboundedQueue {}

impl Default for UnboundedQueue {
    fn default() -> Self {
        const STUB_RUNNABLE: Runnable = Runnable(|_, _| {});

        Self {
            is_popping: AtomicBool::new(false),
            head: AtomicUsize::new(0),
            tail: Cell::new(NonNull::dangling()),
            stub: UnsafeCell::new(Task::from(&STUB_RUNNABLE)),
            _pinned: PhantomPinned,
        }
    }
}

impl UnboundedQueue {
    unsafe fn stub(&self) -> NonNull<Task> {
        self.stub.with(|stub_ptr| {
            NonNull::new_unchecked(stub_ptr as *mut _)
        })
    }

    pub(crate) unsafe fn init(self: Pin<&mut Self>) {
        let stub_ptr = self.stub();
        self.head.with_mut(|head| *head = stub_ptr.as_ptr() as usize);
        self.tail = Cell::new(stub_ptr);
    }

    pub(crate) unsafe fn push(self: Pin<&Self>, batch: Batch) {
        let head = match batch.head {
            Some(head) => head.as_ptr(),
            None => return,
        };

        let prev = self.head.swap(batch.tail.as_ptr() as usize, Ordering::AcqRel);
        let prev = NonNull::new_unchecked(prev as *mut Task);
        prev.as_ref().next.store(head as usize, Ordering::Release);
    }

    pub(crate) unsafe fn try_pop(self: Pin<&Self>) -> Option<UnboundedIter<'_>> {
        let head = self.head.load(Ordering::Acquire);
        let head = NonNull::new_unchecked(head as *mut Task);

        let stub = self.stub().as_ptr();
        if head == stub {
            return None;
        }

        if self.is_popping.swap(true, Ordering::Acquire) {
            return None;
        }

        Some(UnboundedIter(self))
    }
}

pub(crate) struct UnboundedIter<'a>(Pin<&'a UnboundedQueue>);

impl<'a> Drop for UnboundedIter<'a> {
    fn drop(&mut self) {
        self.0.is_popping.store(false, Ordering::Release);
    }
}

impl<'a> Iterator for UnboundedIter<'a> {
    type Item = NonNull<Task>;

    fn next(&mut self) -> Option<Self::Item> {
        unsafe {
            let mut tail = self.0.tail.get();
            let mut next = NonNull::new(tail.as_ref().next.load(Ordering::Acquire) as *mut Task);

            if tail == self.0.stub() {
                tail = next?;
                self.0.tail.set(tail);
                next = NonNull::new(tail.as_ref().next.load(Ordering::Acquire) as *mut Task);
            }

            if let Some(new_tail) = next {
                self.0.tail.set(new_tail);
                return Some(tail);
            }

            let head = self.0.head.load(Ordering::Acquire);
            if tail == NonNull::new_unchecked(head as *mut Task) {
                return None;
            }
            
            let stub = &mut *self.0.stub().as_ptr();
            let stub = Pin::new_unchecked(stub);
            self.0.push(stub.into());

            next = NonNull::new(tail.as_ref().next.load(Ordering::Acquire) as *mut Task);
            if let Some(new_tail) = next {
                self.0.tail.set(new_tail);
                return Some(tail);
            }

            return None;
        }
    }
}

pub(crate) struct BoundedQueue {
    head: AtomicUsize,
    tail: AtomicUsize,
    buffer: [AtomicUsize; Self::CAPACITY],
}

impl Default for BoundedQueue {
    fn default() -> Self {
        Self {
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            buffer: unsafe {
                let mut buffer: MaybeUninit<[AtomicUsize; Self::CAPACITY]> = MaybeUninit::uninit();
                for i in 0..Self::CAPACITY {
                    let task_ptr = (buffer.as_mut_ptr() as *mut AtomicUsize).add(i);
                    ptr::write(task_ptr, AtomicUsize::new(0));
                }
                buffer.assume_init()
            },
        }
    }
}

impl BoundedQueue {
    const CAPACITY: usize = 256;

    unsafe fn write_buffer(&self, index: usize, task: NonNull<Task>) {
        let task_ptr = self.buffer.get_unchecked(index % Self::CAPACITY);
        task_ptr.store(task, Ordering::Relaxed)
    }

    unsafe fn read_buffer(&self, index: usize, is_racy: bool) -> NonNull<Task> {
        let task_ptr = self.buffer.get_unchecked(index % Self::CAPACITY);
        NonNull::new_unchecked(match is_racy {
            true => task_ptr.load(Ordering::Relaxed) as *mut Task,
            _ => task_ptr.unsync_load() as *mut Task,
        })
    }
    
    pub(crate) unsafe fn push(&self, mut batch: Batch) -> Option<Batch> {
        let mut tail = self.tail.unsync_load();
        let mut head = self.head.load(Ordering::Relaxed);

        loop {
            if batch.empty() {
                return None;
            }

            let remaining = Self::CAPACITY - tail.wrapping_sub(head);
            if remaining > 0 {
                for task in batch.drain().take(remaining) {
                    self.write_buffer(tail, task);
                    tail = tail.wrapping_add(1);
                }

                self.tail.store(tail, Ordering::Release);
                head = self.head.load(Ordering::Relaxed);
                continue;
            }
            
            if let Err(e) = self.head.compare_exchange_weak(
                head,
                tail,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                head = e;
                continue;
            }
            
            let migrated = Self::CAPACITY / 2;
            let migrated_index = tail.wrapping_sub(migrated);

            let overflowed = (0..migrated)
                .map(|index| {
                    let index = migrated_index.wrapping_add(index);
                    self.read_buffer(index, false)
                })
                .fold(Batch::default(), |mut batch, task| {
                    let task = Pin::new_unchecked(task.as_mut());
                    batch.push(task);
                    batch
                });

            std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::Acquire);
            for index in migrated {
                let task = self.read_buffer(head.wrapping_add(index), false);
                self.write_buffer(migrated_index.wrapping_add(index), task);
            }

            self.tail.store(tail.wrapping_add(migrated), Ordering::Release);
            batch.push_front(overflowed);
            return Some(batch);
        }
    }

    pub(crate) unsafe fn pop(&self) -> Option<NonNull<Task>> {
        let mut tail = self.tail.unsync_load();
        let mut head = self.head.load(Ordering::Relaxed);

        loop {
            if tail == head {
                return None;
            }

            if let Err(e) = self.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                head = e;
                continue;
            }

            let task = self.read_buffer(head, false);
            return Some(task);
        }
    }

    pub(crate) unsafe fn try_steal(&self, target: &Self) -> Option<NonNull<Task>> {
        if NonNull::from(self) == NonNull::from(target) {
            return self.pop();
        }

        let tail = self.tail.unsync_load();
        let head = self.head.load(Ordering::Relaxed);
        if tail != head {
            return self.pop();
        }

        let mut target_head = target.head.load(Ordering::Relaxed);
        loop {
            let mut target_tail = target.tail.load(Ordering::Acquire);
            let target_size = target_tail.wrapping_sub(target_head);

            let mut steal = target_size - (target_size / 2);
            if steal == 0 {
                return None;
            }

            if steal > Self::CAPACITY / 2 {
                spin_loop_hint();
                target_head = target.head.load(Ordering::Relaxed);
                continue;
            }
            
            let mut new_target_head = target_head;
            let mut target_tasks = (0 .. steal).map(|_| {
                let task = target.read_buffer(new_target_head, true);
                new_target_head.wrapping_add(1);
                task
            });

            let first_task = target_tasks.next();
            let new_tail = target_tasks.fold(tail, |new_tail, task| {
                self.write_buffer(new_tail, task);
                new_tail.wrapping_add(1)
            });

            if let Err(e) = target.head.compare_exchange_weak(
                target_head,
                new_target_head,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                target_head = e;
                continue;
            }

            if tail != new_tail {
                self.tail.store(new_tail, Ordering::Release);
            }

            return first_task;
        }
    }
}