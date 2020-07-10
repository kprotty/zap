use super::Thread;
use core::{
    fmt,
    pin::Pin,
    ptr::NonNull,
    marker::PhantomPinned,
};

pub type RunFn = extern "C" fn(&mut Task, &Thread) -> Batch;

#[repr(C)]
pub struct Task {
    _pinned: PhantomPinned,
    next: Option<NonNull<Self>>,
    run_fn: RunFn,
}

impl From<RunFn> for Task {
    fn from(run_fn: RunFn) -> Self {
        Self::new(run_fn)
    }
}

impl Task {
    pub fn new(run_fn: RunFn) -> Self {
        Self {
            _pinned: PhantomPinned,
            next: None,
            run_fn,
        }
    }
    
    pub fn run(&mut self, thread: &Thread) -> Batch {
        (self.run_fn)(self, thread)
    }
}

#[repr(C)]
#[derive(Default)]
pub struct Batch {
    head: Option<NonNull<Task>>,
    tail: Option<NonNull<Task>>,
    size: usize,
}

impl fmt::Debug for Batch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Batch")
            .field("size", &self.size)
            .finish()
    }
}

impl From<Pin<&mut Task>> for Batch {
    fn from(task: Pin<&mut Task>) -> Self {
        let task = Some(NonNull::from(unsafe {
            let task = Pin::into_inner_unchecked(task);
            task.next = None;
            task
        }));

        Self {
            head: task,
            tail: task,
            size: 1,
        }
    }
}

impl Batch {
    pub const fn new() -> Self {
        Self {
            head: None,
            tail: None,
            size: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.size
    }

    pub fn push(&mut self, task: Pin<&mut Task>) {
        self.push_many(Self::from(task))
    }

    pub fn push_many(&mut self, batch: Self) {
        if let Some(batch_head) = batch.head {
            if let Some(mut tail) = self.tail {
                unsafe { tail.as_mut().next = Some(batch_head); }
                self.tail = Some(tail);
                self.size += batch.size;
            } else {
                *self = batch;
            }
        }
    }

    pub fn pop(&mut self) -> Option<NonNull<Task>> {
        let task = self.head?;
        self.head = unsafe { task.as_ref().next };
        if self.head.is_none() {
            self.tail = None;
        }
        Some(task)
    }
}