use super::Worker;
use std::{marker::PhantomPinned, pin::Pin, ptr::NonNull, sync::atomic::AtomicPtr};

pub(crate) struct Runnable(pub(crate) unsafe fn(Pin<&mut Task>, Pin<&Worker>));

#[repr(align(2))]
pub(crate) struct Task {
    pub(crate) next: AtomicPtr<Self>,
    pub(crate) runnable: &'static Runnable,
    _pinned: PhantomPinned,
}

impl From<&'static Runnable> for Task {
    fn from(runnable: &'static Runnable) -> Self {
        Self {
            next: AtomicPtr::default(),
            runnable,
            _pinned: PhantomPinned,
        }
    }
}

#[derive(Default)]
pub(crate) struct Batch {
    pub(crate) head: Option<NonNull<Task>>,
    pub(crate) tail: Option<NonNull<Task>>,
}

impl From<Pin<&mut Task>> for Batch {
    fn from(task: Pin<&mut Task>) -> Self {
        let task = unsafe { task.get_unchecked_mut() };
        *task.next.get_mut() = std::ptr::null_mut();

        let task = Some(NonNull::from(task));
        Self {
            head: task,
            tail: task,
        }
    }
}

impl Batch {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn empty(&self) -> bool {
        self.head.is_none()
    }

    pub(crate) fn push(&mut self, batch: impl Into<Self>) {
        let batch: Self = batch.into();
        if let (Some(mut tail), Some(batch_head)) = (self.tail, batch.head) {
            unsafe { *tail.as_mut().next.get_mut() = batch_head.as_ptr() };
            self.tail = batch.tail;
        } else {
            *self = batch;
        }
    }

    pub(crate) fn pop(&mut self) -> Option<NonNull<Task>> {
        self.head.map(|mut task| {
            self.head = NonNull::new(unsafe { *task.as_mut().next.get_mut() });
            if self.head.is_none() {
                self.tail = None;
            }
            task
        })
    }
}
