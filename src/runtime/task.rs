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
        // SAFETY:
        // We have ownership over the task (&mut Task)
        // and it requires unsafe to create a Pin'd reference from it due to !Unpin.
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

    pub(crate) fn push_front(&mut self, batch: impl Into<Self>) {
        let batch: Self = batch.into();

        if let (Some(head), Some(mut batch_tail)) = (self.head, batch.tail) {
            // SAFETY: we have ownership of all tasks in both batches at this point.
            unsafe { *batch_tail.as_mut().next.get_mut() = head.as_ptr() };
            self.head = batch.head;
        } else {
            *self = batch;
        }
    }

    pub(crate) fn push_back(&mut self, batch: impl Into<Self>) {
        let batch: Self = batch.into();

        if let (Some(mut tail), Some(batch_head)) = (self.tail, batch.head) {
            // SAFETY: we have ownership of all tasks in both batches at this point.
            unsafe { *tail.as_mut().next.get_mut() = batch_head.as_ptr() };
            self.tail = batch.tail;
        } else {
            *self = batch;
        }
    }

    pub(crate) fn pop_front(&mut self) -> Option<NonNull<Task>> {
        self.head.map(|mut task| {
            // SAFETY: we have ownership of all tasks in the batch.
            self.head = NonNull::new(unsafe { *task.as_mut().next.get_mut() });
            if self.head.is_none() {
                self.tail = None;
            }
            task
        })
    }
}
