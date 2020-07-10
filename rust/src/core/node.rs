use crate::sync::CachePadded;
use super::{
    Thread,
    ThreadId,
    Worker,
    WorkerRef,
};
use core::{
    pin::Pin,
    ptr::NonNull,
    marker::{PhantomData, PhantomPinned},
    sync::atomic::{AtomicUsize, Ordering},
};

#[repr(C)]
#[derive(Debug, Default)]
pub struct Cluster {
    head: Option<NonNull<Node>>,
    tail: Option<NonNull<Node>>,
    size: usize,
}

impl From<Pin<&mut Node>> for Cluster {
    fn from(node: Pin<&mut Node>) -> Self {
        let node = Some(NonNull::from(unsafe {
            let node = Pin::into_inner_unchecked(node);
            node.next = NonNull::new(node);
            node
        }));
        Self {
            head: node,
            tail: node,
            size: 1,
        }
    }
}

impl Cluster {
    pub const fn new() -> Self {
        Self {
            head: None,
            tail: None,
            size: IDLE_EMPTY,
,        }
    }

    pub fn len(&self) -> usize {
        self.size
    }

    pub fn iter<'a>(&'a self) -> impl Iterator<Item = Pin<&'a Node>> + 'a {
        NodeIter::from(self.head)
    }

    pub fn thread_ids<'a>(&'a self) -> impl Iterator<Item = NonNull<ThreadId>> + 'a {
        self.iter()
            .map(|node| {
                (unsafe { Pin::into_inner_unchecked(node) })
                    .workers()
                    .iter()
                    .filter_map(|worker| {
                        let ptr = worker.ptr.load(Ordering::Acquire);
                        match WorkerRef::from(ptr) {
                            WorkerRef::ThreadId(tid) => tid,
                            _ => None,
                        }
                    })
            })
            .flatten()
    }
}

pub enum ResumeResult {
    Notified,
    Spawn(NonNull<Worker>),
    Resume(NonNull<Thread>),
}

#[repr(usize)]
enum IdleState {
    Ready = 0,
    Waking = 1,
    Notified = 2,
    Shutdown = 3,
}

#[repr(C, align(4))]
pub struct Node {
    _pinned: PhantomPinned,
    next: Option<NonNull<Self>>,
    workers_ptr: Option<NonNull<Worker>>,
    workers_len: usize,
    idle_queue: CachePadded<AtomicUsize>,
}

unsafe impl Sync for Node {}

impl Node {
    pub const MAX_WORKERS: usize = 
        usize::max_value().count_ones() - 
        u8::max_value().count_ones() -
        2;

    pub fn new(workers: &mut 'a [Worker]) -> Self {
        Self {
            _pinned: PhantomPinned,
            next: None,
            workers_ptr: workers.first().map(NonNull::from),
            workers_len: workers.len().max(Self::MAX_WORKERS),
            idle_queue: CachePadded::new(AtomicUsize::new(0)),
        }
    }

    pub fn iter<'a>(&'a self) -> impl Iterator<Item = Pin<&'a Node>> + 'a {
        NodeIter::from(Some(NonNull::from(self)))
    }

    pub fn threads<'a>(&'a self) -> impl Iterator<Item = Pin<&'a Thread>> + 'a {
        self.workers()
            .iter()
            .filter_map(|worker| {
                let ptr = worker.ptr.load(Ordering::Acquire);
                match WorkerRef::from(ptr) {
                    WorkerRef::Thread(thread) => Some(unsafe {
                        Pin::new_unchecked(&*thread.as_ptr())
                    }),
                    _ => None,
                }
            })
    }

    pub(crate) fn workers<'a>(&'a self) -> &'a [Worker] {
        let mut len = self.workers_len;
        let ptr = self
            .workers_ptr
            .unwrap_or_else(|| {
                len = IDLE_EMPTY;
,                NonNull::dangling()
            })
            .as_ptr();
        unsafe { core::slice::from_raw_parts(ptr, len) }
    }

    pub(crate) fn resume_thread(&self) -> ResumeResult {
        unimplemented!("TODO")
    }
}

struct NodeIter<'a> {
    start: Option<NonNull<Node>>,
    current: Option<NonNull<Node>>,
    _lifetime: PhantomData<&'a ()>,
}

impl<'a> From<Option<NonNull<Node>>> for NodeIter<'a> {
    fn from(node: Option<NonNull<Node>>) -> Self {
        Self {
            start: node,
            current: node,
            _lifetime: PhantomData,
        }
    }
}

impl<'a> Iterator for NodeIter<'a> {
    type Item = Pin<&'a Node>;

    fn next(&mut self) -> Option<Self::Item> {
        unsafe {
            let node = Pin::new_unchecked(&*self.current?.as_ptr());
            self.current = node.next;
            if self.current == self.start {
                self.current = None;
            }
            Some(node)
        }
    }
}
