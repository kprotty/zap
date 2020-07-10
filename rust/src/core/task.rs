use super::Thread;
use core::{
    fmt, marker::PhantomPinned, mem::transmute, pin::Pin, ptr::NonNull, sync::atomic::AtomicUsize,
};

pub type RunFn = extern "C" fn(&mut Task, &Thread) -> Batch;

#[repr(C)]
pub struct Task {
    _pinned: PhantomPinned,
    pub(crate) next: AtomicUsize,
    data: usize,
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
            next: AtomicUsize::default(),
            data: run_fn as usize,
        }
    }

    pub fn run(&mut self, thread: &Thread) -> Batch {
        let run_fn: RunFn = unsafe { transmute(self.data) };
        (run_fn)(self, thread)
    }
}

#[repr(C)]
#[derive(Default)]
pub struct Batch {
    pub(crate) head: Option<NonNull<Task>>,
    pub(crate) tail: Option<NonNull<Task>>,
    size: usize,
}

impl fmt::Debug for Batch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Batch").field("size", &self.size).finish()
    }
}

impl From<Pin<&mut Task>> for Batch {
    fn from(task: Pin<&mut Task>) -> Self {
        let task = Some(NonNull::from(unsafe {
            let task = Pin::into_inner_unchecked(task);
            *task.next.get_mut() = 0;
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
                unsafe {
                    let head_ptr = batch_head.as_ptr() as usize;
                    *tail.as_mut().next.get_mut() = head_ptr;
                }
                self.tail = Some(tail);
                self.size += batch.size;
            } else {
                *self = batch;
            }
        }
    }

    pub fn pop(&mut self) -> Option<NonNull<Task>> {
        let mut task = self.head?;
        self.head = unsafe {
            let head_ptr = *task.as_mut().next.get_mut();
            NonNull::new(head_ptr as *mut _)
        };
        if self.head.is_none() {
            self.tail = None;
        }
        Some(task)
    }
}
