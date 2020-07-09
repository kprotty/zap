use super::{
    Thread,
    ThreadId,
    Worker,
    WorkerRef,
};
use core::{
    pin::Pin,
    ptr::NonNull,
    sync::atomic::Ordering,
    marker::{PhantomData, PhantomPinned},
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
    #[inline]
    pub const fn new() -> Self {
        Self {
            head: None,
            tail: None,
            size: 0,
        }
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.size
    }

    #[inline]
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

#[repr(C, align(4))]
pub struct Node {
    _pinned: PhantomPinned,
    next: Option<NonNull<Self>>,
    workers_ptr: Option<NonNull<Worker>>,
    workers_len: usize,
}

impl Node {
    #[inline]
    pub fn iter<'a>(&'a self) -> impl Iterator<Item = Pin<&'a Node>> + 'a {
        NodeIter::from(Some(NonNull::from(self)))
    }

    #[inline]
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

    #[inline]
    pub(crate) fn workers<'a>(&'a self) -> &'a [Worker] {
        let mut len = self.workers_len;
        let ptr = self
            .workers_ptr
            .unwrap_or_else(|| {
                len = 0;
                NonNull::dangling()
            })
            .as_ptr();
        unsafe { core::slice::from_raw_parts(ptr, len) }
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
