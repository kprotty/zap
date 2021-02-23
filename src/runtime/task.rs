use std::{
    ptr::{NonNull, self},
    pin::Pin,
    marker::PhantomPinned,
    sync::atomic::{AtomicPtr, Ordering},
};

#[derive(Copy, Clone, Eq, PartialEq, Ord, PartialOrd, Debug)]
pub(crate) enum Priority {
    Low = 0,
    Normal = 1,
    High = 2,
    Handoff = 3,
}

impl Priority {
    pub(crate) const COUNT: usize = 3;

    pub(crate) fn as_index(&self) -> usize {
        match self {
            Self::Handoff | Self::High => 0,
            Self::Normal => 1,
            Self::Low => 2,
        }
    }
}

pub(crate) type ExecuteFn = unsafe fn(Pin<&mut Task>);

pub(crate) struct Task {
    pub(crate) next: AtomicPtr<Self>,
    callback: ExecuteFn,
    _pinned: PhantomPinned,
}

impl From<ExecuteFn> for Task {
    fn from(callback: ExecuteFn) -> Self {
        Self {
            next: AtomicPtr::new(ptr::null_mut()),
            callback,
            _pinned: PhantomPinned,
        }
    }
}

pub(crate) struct Batch {
    pub(crate) head: Option<NonNull<Task>>,
    pub(crate) tail: Option<NonNull<Task>>,
}

impl From<Pin<&mut Task>> for Batch {
    fn from(task: Pin<&mut Task>) -> Self {
        let task = unsafe {
            let task = Pin::get_unchecked_mut(task);
            *task.next.get_mut() = ptr::null_mut();
            Some(NonNull::new_unchecked(task))
        };
        Self {
            head: task,
            tail: task,
        }
    }
}

impl Batch {
    pub(crate) const fn new() -> Self {
        Self {
            head: None,
            tail: None,
        }
    }

    pub(crate) const fn is_empty(&self) -> bool {
        self.head.is_none()
    }

    pub(crate) fn push(&mut self, batch: impl Into<Self>) {
        if self.is_empty() {
            *self = batch;
        } else if let Some(batch_head) = batch.head {
            let tail_ref = unsafe { self.tail.expect("is_empty() is false").as_mut() };
            *tail_ref.next.get_mut() = batch_head.as_ptr();
            self.tail = batch.tail;
        }
    }

    pub(crate) fn push_front(&mut self, batch: impl Into<Self>) {
        if self.is_empty() {
            *self = batch;
        } else if let Some(batch_head) = batch.head {
            let tail_ref = unsafe { batch.tail.expect("is_empty() is false").as_mut() };
            *tail_ref.next.get_mut() = self.head.expect("is_empty() is false").as_ptr();
            self.head = batch_head;
        }
    }

    pub(crate) fn pop(&mut self) -> Option<NonNull<Task>> {
        self.head.map(|mut task| unsafe {
            self.head = NonNull::new(*task.as_mut().next.get_mut());
            task
        })
    }
}