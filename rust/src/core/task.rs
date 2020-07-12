use super::Thread;
use core::{
    fmt,
    marker::PhantomPinned,
    mem,
    pin::Pin,
    ptr::{self, NonNull},
    sync::atomic::AtomicUsize,
};

pub type RunFn = extern "C" fn(&mut Task, &Thread) -> Batch;

#[derive(Copy, Clone, Debug, Eq, PartialEq, Hash)]
pub enum Priority {
    Fifo = 0,
    Lifo = 1,
}

impl Default for Priority {
    fn default() -> Self {
        Self::Fifo
    }
}

#[repr(C)]
pub struct Task {
    _pinned: PhantomPinned,
    pub(crate) next: AtomicUsize,
    data: usize,
}

impl From<RunFn> for Task {
    fn from(run_fn: RunFn) -> Self {
        Self::new(Priority::default(), run_fn)
    }
}

impl Task {
    pub fn new(priority: Priority, run_fn: RunFn) -> Self {
        assert!(mem::align_of::<RunFn>() > 1);
        Self {
            _pinned: PhantomPinned,
            next: AtomicUsize::default(),
            data: (run_fn as usize) | (priority as usize),
        }
    }

    pub fn priority(&self) -> Priority {
        match self.data & 1 {
            0 => Priority::Fifo,
            1 => Priority::Lifo,
            _ => unreachable!(),
        }
    }

    pub fn run(&mut self, thread: &Thread) -> Batch {
        let run_fn: RunFn = unsafe { mem::transmute(self.data & !1usize) };
        (run_fn)(self, thread)
    }
}

#[repr(C)]
#[derive(Default)]
pub struct Batch {
    pub(crate) head_tail: Option<(NonNull<Task>, NonNull<Task>)>,
    size: usize,
}

impl fmt::Debug for Batch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Batch").field("size", &self.size).finish()
    }
}

impl From<Pin<&mut Task>> for Batch {
    fn from(task: Pin<&mut Task>) -> Self {
        let task = NonNull::from(unsafe {
            let task = Pin::into_inner_unchecked(task);
            *task.next.get_mut() = 0;
            task
        });

        Self {
            head_tail: Some((task, task)),
            size: 1,
        }
    }
}

impl Batch {
    pub const fn new() -> Self {
        Self {
            head_tail: None,
            size: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.size
    }

    pub fn push(&mut self, task: Pin<&mut Task>) {
        self.push_many(Self::from(task))
    }

    pub fn push_many(&mut self, other: Self) {
        if let Some((other_head, other_tail)) = other.head_tail {
            unsafe {
                if let Some((head, mut tail)) = self.head_tail {
                    *tail.as_mut().next.get_mut() = other_head.as_ptr() as usize;
                    self.head_tail = Some((head, other_tail));
                    self.size += other.size;
                } else {
                    ptr::write(self, other);
                }
            }
        }
    }

    pub fn pop(&mut self) -> Option<NonNull<Task>> {
        unsafe {
            let (mut head, tail) = self.head_tail?;
            let new_head = mem::replace(head.as_mut().next.get_mut(), 0);
            self.head_tail = NonNull::new(new_head as *mut Task)
                .map(|new_head| (new_head, tail));
            self.size -= 1;
            Some(head)
        }
    }
}
