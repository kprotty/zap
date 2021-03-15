use std::{cell::Cell, marker::PhantomPinned, pin::Pin, ptr::NonNull};

pub(crate) type ExecuteFn = unsafe fn(Pin<&mut Task>);

pub(crate) struct Task {
    pub(crate) next: Cell<Option<NonNull<Self>>>,
    callback: ExecuteFn,
    _pinned: PhantomPinned,
}

impl From<ExecuteFn> for Task {
    fn from(callback: ExecuteFn) -> Self {
        Self {
            next: Cell::new(None),
            callback,
            _pinned: PhantomPinned,
        }
    }
}

pub(crate) struct Batch {
    pub(crate) head: Option<NonNull<Task>>,
    pub(crate) tail: Option<NonNull<Task>>,
    pub(crate) size: usize,
}

impl From<Pin<&mut Task>> for Batch {
    fn from(task: Pin<&mut Task>) -> Self {
        let task = unsafe {
            let task = Pin::get_unchecked_mut(task);
            task.next.set(None);
            Some(NonNull::new_unchecked(task))
        };
        Self {
            head: task,
            tail: task,
            size: 1,
        }
    }
}

impl Batch {
    pub(crate) const fn new() -> Self {
        Self {
            head: None,
            tail: None,
            size: 0,
        }
    }

    pub(crate) const fn is_empty(&self) -> bool {
        self.head.is_none()
    }

    pub(crate) fn push(&mut self, batch: impl Into<Self>) {
        let batch = batch.into();
        if batch.is_empty() {
            return;
        }

        if self.is_empty() {
            *self = batch;
        } else {
            let mut tail_ptr = self.tail.expect("invalid batch state");
            unsafe { tail_ptr.as_mut().next.set(batch.head) };
            self.tail = batch.tail;
            self.size += batch.size;
        }
    }

    pub(crate) fn push_front(&mut self, batch: impl Into<Self>) {
        let batch = batch.into();
        if batch.is_empty() {
            return;
        }

        if self.is_empty() {
            *self = batch;
        } else {
            let mut tail_ptr = batch.tail.expect("invalid batch state");
            unsafe { tail_ptr.as_mut().next.set(self.head) };
            self.head = batch.head;
            self.size += batch.size;
        }
    }

    pub(crate) fn pop(&mut self) -> Option<NonNull<Task>> {
        self.head.map(|mut task| unsafe {
            self.head = task.as_mut().next.get();
            self.size -= 1;
            task
        })
    }

    pub(crate) fn drain<'a>(&'a mut self) -> impl Iterator<Item = NonNull<Task>> + 'a {
        struct Drain<'b>(&'b mut Batch);

        impl<'b> Iterator for Drain<'b> {
            type Item = NonNull<Task>;

            fn next(&mut self) -> Option<Self::Item> {
                self.0.pop()
            }
        }

        Drain(self)
    }
}
