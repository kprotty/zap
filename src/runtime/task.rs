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
