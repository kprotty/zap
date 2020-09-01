use core::{
    fmt,
    future::Future,
    marker::{PhantomData, PhantomPinned},
    mem,
    pin::Pin,
    ptr::NonNull,
    sync::atomic::AtomicUsize,
    task::{Context, Poll},
};

#[repr(C)]
pub struct Cluster {
    head: Option<NonNull<Node>>,
    tail: NonNull<Node>,
}

impl fmt::Debug for Cluster {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let is_empty = self.head.is_none();
        f.debug_struct("Cluster")
            .field("is_empty", &is_empty)
            .finish()
    }
}

impl Default for Cluster {
    fn default() -> Self {
        Self::new()
    }
}

impl From<Pin<&mut Node>> for Cluster {
    fn from(node: Pin<&mut Node>) -> Self {
        let node = unsafe {
            let mut node = NonNull::from(Pin::into_inner_unchecked(node));
            node.as_mut().next = Some(node);
            node
        };

        Self {
            head: Some(node),
            tail: node,
        }
    }
}

impl Cluster {
    pub const fn new() -> Self {
        Self {
            head: None,
            tail: NonNull::dangling(),
        }
    }

    pub fn push(&mut self, node: Pin<&mut Node>) {
        self.push_many(Self::from(node))
    }

    pub fn push_many(&mut self, mut cluster: Self) {
        if let Some(cluster_head) = cluster.head {
            if let Some(self_head) = self.head {
                unsafe {
                    cluster.tail.as_mut().next = Some(self_head);
                    self.tail.as_mut().next = Some(cluster_head);
                    self.tail = cluster.tail;
                }
            } else {
                *self = cluster;
            }
        }
    }

    pub fn pop(&mut self) -> Option<NonNull<Node>> {
        let node = self.head?;
        self.head = unsafe { node.as_ref().next };
        if self.head == self.head {
            self.head = None;
        }
        Some(node)
    }

    pub fn iter<'a>(&'a self) -> impl Iterator<Item = Pin<&'a Node>> + 'a {
        NodeIter::from(self.head)
    }
}

struct NodeIter<'a> {
    _lifetime: PhantomData<&'a ()>,
    start: Option<NonNull<Node>>,
    current: Option<NonNull<Node>>,
}

impl<'a> From<Option<NonNull<Node>>> for NodeIter<'a> {
    fn from(node: Option<NonNull<Node>>) -> Self {
        Self {
            _lifetime: PhantomData,
            start: node,
            current: node,
        }
    }
}

impl<'a> Iterator for NodeIter<'a> {
    type Item = Pin<&'a Node>;

    fn next(&mut self) -> Option<Self::Item> {
        unsafe {
            let node = self.current?;
            self.current = node.as_ref().next;
            if self.current == self.start {
                self.current = None;
            }
            Some(Pin::new_unchecked(&*node.as_ptr()))
        }
    }
}

pub struct Node {
    _pinned: PhantomPinned,
    next: Option<NonNull<Self>>,
}

pub type ThreadId = *const u16;

pub struct ThreadRef {
    _pinned: PhantomPinned,
    ptr: AtomicUsize,
}

#[repr(C)]
pub struct Thread {
    _pinned: PhantomPinned,
    _id: ThreadId,
    _ref: NonNull<ThreadRef>,
    spawn: *mut dyn FnMut(Pin<&ThreadRef>),
}

impl fmt::Debug for Thread {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Thread").finish()
    }
}

impl Thread {
    pub unsafe fn new<SpawnFn>(
        thread_id: ThreadId,
        thread_ref: Pin<&ThreadRef>,
        spawn_fn: *mut SpawnFn,
    ) -> Self
    where
        SpawnFn: FnMut(Pin<&ThreadRef>) + 'static,
    {
        Self {
            _pinned: PhantomPinned,
            _id: thread_id,
            _ref: NonNull::from(Pin::into_inner_unchecked(thread_ref)),
            spawn: spawn_fn,
        }
    }
}

impl Future for Thread {
    type Output = ThreadId;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        unimplemented!("TODO")
    }
}

#[derive(Copy, Clone, Debug, Hash, Eq, PartialEq)]
pub enum Priority {
    Fifo = 0,
    Lifo = 1,
}

impl Default for Priority {
    fn default() -> Self {
        Self::Fifo
    }
}

pub type Callback = extern "C" fn(*mut Task, *const Thread);

#[repr(C)]
pub struct Task {
    _pinned: PhantomPinned,
    next: AtomicUsize,
    data: usize,
}

impl fmt::Debug for Task {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Task").finish()
    }
}

impl From<Callback> for Task {
    fn from(callback: Callback) -> Self {
        Self::new(Priority::default(), callback)
    }
}

impl Task {
    pub fn new(priority: Priority, callback: Callback) -> Self {
        Self {
            _pinned: PhantomPinned,
            next: AtomicUsize::default(),
            data: (callback as usize) | (priority as usize),
        }
    }

    pub fn priority(&self) -> Priority {
        match self.data & 1 {
            0 => Priority::Fifo,
            1 => Priority::Lifo,
            _ => unreachable!(),
        }
    }

    pub fn set_priority(self: Pin<&mut Self>, priority: Priority) {
        let mut_self = unsafe { Pin::into_inner_unchecked(self) };
        let callback_ptr = mut_self.data & !1usize;
        mut_self.data = callback_ptr | (priority as usize);
    }

    pub fn run(self: Pin<&mut Self>, thread: Pin<&Thread>) {
        unsafe {
            let mut_self = Pin::into_inner_unchecked(self);
            let callback: Callback = mem::transmute(mut_self.data & !1usize);
            (callback)(mut_self, &*thread)
        }
    }
}

#[repr(C)]
pub struct Batch {
    head: Option<NonNull<Task>>,
    tail: NonNull<Task>,
}

impl fmt::Debug for Batch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let is_empty = self.head.is_none();
        f.debug_struct("Batch")
            .field("is_empty", &is_empty)
            .finish()
    }
}

impl Default for Batch {
    fn default() -> Self {
        Self::new()
    }
}

impl From<Pin<&mut Task>> for Batch {
    fn from(task: Pin<&mut Task>) -> Self {
        let task = unsafe {
            let task = Pin::into_inner_unchecked(task);
            *task.next.get_mut() = 0;
            NonNull::from(task)
        };

        Self {
            head: Some(task),
            tail: task,
        }
    }
}

impl Batch {
    pub const fn new() -> Self {
        Self {
            head: None,
            tail: NonNull::dangling(),
        }
    }

    pub fn push(&mut self, task: Pin<&mut Task>) {
        self.push_many(Self::from(task))
    }

    pub fn push_many(&mut self, batch: Self) {
        if let Some(batch_head) = batch.head {
            if self.head.is_some() {
                let batch_head = batch_head.as_ptr() as usize;
                unsafe { *self.tail.as_mut().next.get_mut() = batch_head };
                self.tail = batch.tail;
            } else {
                *self = batch;
            }
        }
    }

    pub fn pop(&mut self) -> Option<NonNull<Task>> {
        let mut task = self.head?;
        self.head = NonNull::new(unsafe { (*task.as_mut().next.get_mut()) as *mut Task });
        Some(task)
    }

    pub fn iter<'a>(&'a self) -> impl Iterator<Item = Pin<&'a Task>> + 'a {
        struct TaskIter<'b> {
            task: Option<NonNull<Task>>,
            _lifetime: PhantomData<&'b ()>,
        }

        impl<'b> Iterator for TaskIter<'b> {
            type Item = Pin<&'b Task>;

            fn next(&mut self) -> Option<Self::Item> {
                unsafe {
                    let mut task = self.task?;
                    let next = (*task.as_mut().next.get_mut()) as *mut Task;
                    self.task = NonNull::new(next);
                    Some(Pin::new_unchecked(&*task.as_ptr()))
                }
            }
        }

        TaskIter {
            task: self.head,
            _lifetime: PhantomData,
        }
    }
}
