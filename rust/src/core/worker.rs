use super::{Node, Thread, ThreadId};
use core::{ptr::NonNull, sync::atomic::AtomicUsize};

#[repr(C, align(4))]
pub struct Worker {
    pub(crate) ptr: AtomicUsize,
}

#[derive(Debug)]
pub(crate) enum WorkerRef {
    Worker(Option<NonNull<Worker>>),
    Node(NonNull<Node>),
    Thread(NonNull<Thread>),
    ThreadId(Option<NonNull<ThreadId>>),
}

impl Into<usize> for WorkerRef {
    fn into(self) -> usize {
        match self {
            Self::Worker(ptr) => ptr.map(|p| p.as_ptr() as usize).unwrap_or(0) | 0,
            Self::Node(ptr) => (ptr.as_ptr() as usize) | 1,
            Self::Thread(ptr) => (ptr.as_ptr() as usize) | 2,
            Self::ThreadId(ptr) => ptr.map(|p| p.as_ptr() as usize).unwrap_or(0) | 3,
        }
    }
}

impl From<usize> for WorkerRef {
    fn from(tagged_ptr: usize) -> Self {
        let ptr = tagged_ptr & !0b11usize;
        match tagged_ptr & 0b11 {
            0 => Self::Worker(NonNull::new(ptr as *mut _)),
            1 => Self::Node(NonNull::new(ptr as *mut _).expect("null Node pointer in WorkerRef")),
            2 => {
                Self::Thread(NonNull::new(ptr as *mut _).expect("null Thread pointer in WorkerRef"))
            }
            3 => Self::ThreadId(NonNull::new(ptr as *mut _)),
            _ => unreachable!(),
        }
    }
}
