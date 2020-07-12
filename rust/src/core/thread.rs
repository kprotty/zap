use super::{Batch, Node, Priority, Task, Worker, WorkerRef, SuspendResult, ResumeResult};
use crate::sync::CachePadded;
use core::{
    cell::Cell,
    mem::MaybeUninit,
    num::NonZeroUsize,
    pin::Pin,
    ptr::{self, NonNull},
    marker::PhantomPinned,
    sync::atomic::{spin_loop_hint, AtomicUsize, Ordering},
};

#[repr(C, align(4))]
pub struct ThreadId;

#[derive(Debug)]
pub enum Syscall {
    Shutdown {
        id: Option<NonNull<ThreadId>>,
    },
    Spawn {
        worker: NonNull<Worker>,
        first_in_node: bool,
        first_in_cluster: bool,
    },
    Resume {
        thread: NonNull<Thread>,
        first_in_node: bool,
        first_in_cluster: bool,
    },
    Suspend {
        last_in_node: bool,
        last_in_cluster: bool,
    },
}

#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub(crate) enum ThreadState {
    Shutdown = 0,
    Suspended = 1,
    Waking = 2,
    Running = 3,
}

impl ThreadState {
    pub fn encode(self, tick: u8, rng: u16) -> u32 {
        ((self as u32) << 24) | ((tick as u32) << 16) | (rng as u32)
    }

    pub fn decode(state: u32) -> (Self, u8, u16) {
        (
            match state >> 24 {
                0 => Self::Shutdown,
                1 => Self::Suspended,
                2 => Self::Waking,
                3 => Self::Running,
                thread_state => unreachable!("invalid thread state {:?}", thread_state),
            },
            (state >> 16) as u8,
            state as u16,
        )
    }
}

#[repr(C)]
pub struct Thread {
    _pinned: PhantomPinned,
    pub(crate) state: Cell<u32>,
    pub(crate) worker: NonNull<Worker>,
    pub(crate) id: Cell<Option<NonNull<ThreadId>>>,
    pub(crate) next_index: Cell<Option<NonZeroUsize>>,
    node: NonNull<Node>,
    runq_head: CachePadded<AtomicUsize>,
    runq_tail: CachePadded<AtomicUsize>,
    runq_next: AtomicUsize,
    runq_buffer: CachePadded<[MaybeUninit<NonNull<Task>>; 256]>,
}

unsafe impl Sync for Thread {}

impl Thread {
    pub fn new(id: Option<NonNull<ThreadId>>, worker: NonNull<Worker>) -> Self {
        let node = unsafe {
            let ptr = worker.as_ref().ptr.load(Ordering::SeqCst);
            match WorkerRef::from(ptr) {
                WorkerRef::Node(node) => node,
                worker_ref => unreachable!("Invalid worker ptr on thread spawn {:?}", worker_ref),
            }
        };

        let rng = id.unwrap_or(NonNull::dangling()).as_ptr() as usize;
        let rng = rng ^ worker.as_ptr() as usize;
        let rng = ((rng * 31) >> 17) as u16;

        Self {
            _pinned: PhantomPinned,
            state: Cell::new(ThreadState::Waking.encode(0, rng)),
            worker,
            id: Cell::new(id),
            next_index: Cell::new(None),
            node,
            runq_head: CachePadded::new(AtomicUsize::new(0)),
            runq_tail: CachePadded::new(AtomicUsize::new(0)),
            runq_next: AtomicUsize::new(0),
            runq_buffer: CachePadded::new(unsafe { MaybeUninit::uninit().assume_init() }),
        }
    }

    pub unsafe fn run(self: Pin<&Self>) -> Syscall {
        loop {
            let (state, mut tick, mut rng) = ThreadState::decode(self.state.get());
            let node = self.node.as_ref();

            assert_ne!(
                state,
                ThreadState::Suspended,
                "Thread::run() when suspended",
            );

            if state == ThreadState::Shutdown {
                let tail = self.runq_tail.load(Ordering::SeqCst);
                let head = self.runq_head.load(Ordering::SeqCst);
                let next = self.runq_next.load(Ordering::SeqCst);
                assert_eq!(next, 0, "Thread runq_next not empty on shutdown");
                assert_eq!(tail, head, "Thread runq not empty {} on shutdown", tail.wrapping_sub(head));
                return Syscall::Shutdown { id: self.id.get() };
            }

            if let Some(mut task) = self
                .next_index
                .get()
                .and_then(|index| NonNull::<Task>::new(index.get() as *mut Task))
                .or_else(|| {
                    let (next_task, new_rng) = self.poll(tick, rng, node);
                    self.state.set(state.encode(tick, new_rng));
                    rng = new_rng;
                    next_task
                })
            {
                if state == ThreadState::Running {
                    tick = tick.wrapping_add(1);
                }
                self.state.set(ThreadState::Running.encode(tick, rng));

                if state == ThreadState::Waking {
                    match node.stop_waking() {
                        Some(ResumeResult::Resume {
                            thread,
                            first_in_node,
                            first_in_cluster,
                        }) => {
                            self.next_index.set(NonZeroUsize::new(task.as_ptr() as usize));
                            return Syscall::Resume { thread, first_in_node, first_in_cluster };
                        }
                        Some(ResumeResult::Spawn {
                            worker,
                            first_in_node,
                            first_in_cluster,
                        }) => {
                            self.next_index.set(NonZeroUsize::new(task.as_ptr() as usize));
                            return Syscall::Spawn { worker, first_in_node, first_in_cluster };
                        }
                        _ => {},
                    }
                }
                
                let batch = Task::run(task, &*self);
                
                self.next_index.set(batch
                    .pop()
                    .and_then(|task| NonZeroUsize::new(task.as_ptr() as usize))
                );

                if batch.len() != 0 {
                    self.push(node, batch);
                    match node.try_resume_some_worker() {
                        Some(ResumeResult::Resume {
                            thread,
                            first_in_node,
                            first_in_cluster,
                        }) => {
                            return Syscall::Resume { thread, first_in_node, first_in_cluster };
                        }
                        Some(ResumeResult::Spawn {
                            worker,
                            first_in_node,
                            first_in_cluster,
                        }) => {
                            return Syscall::Spawn { worker, first_in_node, first_in_cluster };
                        }
                        _ => {}
                    }
                }

                continue;
            }

            match node.suspend_worker(&*self) {
                SuspendResult::Notified => {},
                SuspendResult::Suspended {
                    last_in_node,
                    last_in_cluster,
                } => return Syscall::Suspend { last_in_node, last_in_cluster },
            }
        }
    }

    fn poll(&self, tick: u8, mut rng: u16, node: &Node) -> (Option<NonNull<Task>>, u16) {
        if tick % 61 == 0 {
            if let Some(task) = self.poll_global(node) {
                return (Some(task), rng);
            }
        }

        if let Some(task) = self.poll_local() {
            return (Some(task), rng);
        }

        for steal_attempts in 0..4 {
            let steal_next = steal_attempts > 2;

            for target_node in node.iter_nodes() {
                if let Some(task) = self.poll_global(&*target_node) {
                    return (Some(task), rng);
                }

                let workers = target_node.workers();
                let mut index = {
                    rng ^= rng << 7;
                    rng ^= rng >> 9;
                    rng ^= rng << 8;
                    (rng as usize) % workers.len()
                };

                for _ in 0..workers.len() {
                    let ptr = workers[index].ptr.load(Ordering::SeqCst);
                    index += 1;
                    if index == workers.len() {
                        index = 0;
                    }

                    match WorkerRef::from(ptr) {
                        WorkerRef::Node(_) | WorkerRef::Worker(_) => {}
                        WorkerRef::ThreadId(_) => {
                            unreachable!("Thread::poll() when other worker is shutting down");
                        }
                        WorkerRef::Thread(thread) => {
                            if (thread.as_ptr() as usize) == (self as *const _ as usize) {
                                continue;
                            }

                            let target_thread = unsafe { thread.as_ref() };
                            if let Some(task) = self.poll_steal(target_thread, steal_next) {
                                return (Some(task), rng);
                            }
                        }
                    }
                }
            }
        }

        (None, rng)
    }

    fn poll_global(&self, target: &Node) -> Option<NonNull<Task>> {
        let mut node_poller = target.try_acquire_polling()?;

        let next_task = node_poller.next()?;

        let tail = self.runq_tail.load(Ordering::SeqCst);
        let head = self.runq_head.load(Ordering::SeqCst);
        let runq_size = tail.wrapping_sub(head);
        assert!(runq_size <= self.runq_buffer.len());

        let new_tail = core::iter::repeat_with(|| node_poller.next())
            .filter_map(|task| task)
            .take(self.runq_buffer.len() - runq_size)
            .fold(tail, |tail, task| unsafe {
                self.write_buffer(tail, task);
                tail.wrapping_add(1)
            });

        self.runq_tail.store(new_tail, Ordering::SeqCst);
        Some(next_task)
    }

    fn poll_local(&self) -> Option<NonNull<Task>> {
        let mut next = self.runq_next.load(Ordering::SeqCst);
        while let Some(next_task) = NonNull::new(next as *mut Task) {
            match self.runq_next.compare_exchange_weak(
                next,
                0,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return Some(next_task),
                Err(e) => next = e,
            }
        }

        let mut head = self.runq_head.load(Ordering::SeqCst);
        let tail = self.runq_tail.load(Ordering::SeqCst);
        while tail != head {
            match self.runq_head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return Some(unsafe { self.read_buffer(head) }),
                Err(e) => {
                    spin_loop_hint();
                    head = e
                }
            }
        }

        None
    }

    fn poll_steal(&self, target: &Thread, steal_next: bool) -> Option<NonNull<Task>> {
        let head = self.runq_head.load(Ordering::SeqCst);
        let tail = self.runq_tail.load(Ordering::SeqCst);
        assert_eq!(
            tail,
            head,
            "Invalid runq size on steal {}",
            tail.wrapping_sub(head)
        );

        let mut target_head = target.runq_head.load(Ordering::SeqCst);
        loop {
            let target_tail = target.runq_tail.load(Ordering::SeqCst);

            let steal = target_tail.wrapping_sub(target_tail);
            let steal = steal - (steal / 2);
            if steal == 0 {
                if steal_next {
                    let target_next = target.runq_next.load(Ordering::SeqCst);
                    if let Some(next_task) = NonNull::new(target_next as *mut Task) {
                        match target.runq_next.compare_exchange_weak(
                            target_next,
                            0,
                            Ordering::SeqCst,
                            Ordering::SeqCst,
                        ) {
                            Ok(_) => return Some(next_task),
                            Err(_) => continue,
                        }
                    }
                }
                return None;
            }

            let steal = steal - 1;
            let next_task = unsafe {
                let first_task = target.read_buffer(target_head);
                for offset in 0..steal {
                    let task = target.read_buffer(target_head.wrapping_add(offset + 1));
                    self.write_buffer(tail.wrapping_add(offset), task);
                }
                first_task
            };

            match target.runq_head.compare_exchange_weak(
                target_head,
                target_head.wrapping_add(steal),
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => {
                    self.runq_tail
                        .store(tail.wrapping_add(steal), Ordering::SeqCst);
                    return Some(next_task);
                }
                Err(e) => {
                    spin_loop_hint();
                    target_head = e;
                }
            }
        }
    }

    fn push(&self, node: &Node, mut batch: Batch) {
        if batch.len() > 1 {
            return node.push(batch);
        }

        let (mut task, _) = batch
            .head_tail
            .expect("Thread::push() with empty batch");

        unsafe {
            if task.as_ref().priority() == Priority::Lifo {
                match self
                    .runq_next
                    .swap(task.as_ptr() as usize, Ordering::SeqCst)
                {
                    0 => return,
                    ptr => task = NonNull::from(&*(ptr as *mut Task)),
                }
            }

            let mut head = self.runq_head.load(Ordering::SeqCst);
            let tail = self.runq_tail.load(Ordering::SeqCst);
            loop {
                if tail.wrapping_sub(head) < self.runq_buffer.len() {
                    self.write_buffer(tail, task);
                    self.runq_tail
                        .store(tail.wrapping_add(1), Ordering::SeqCst);
                    return;
                }

                let steal = self.runq_buffer.len() / 2;
                if let Err(e) = self.runq_head.compare_exchange_weak(
                    head,
                    head.wrapping_add(steal),
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                ) {
                    spin_loop_hint();
                    head = e;
                    continue;
                }

                for offset in 0..steal {
                    let mut task = self.read_buffer(head.wrapping_add(offset));
                    batch.push(Pin::new_unchecked(task.as_mut()));
                }

                node.push(batch);
                return;
            }
        }
    }

    unsafe fn read_buffer(&self, index: usize) -> NonNull<Task> {
        let buffer_slot = &self.runq_buffer[index % self.runq_buffer.len()];
        ptr::read(buffer_slot.as_ptr())
    }

    unsafe fn write_buffer(&self, index: usize, task: NonNull<Task>) {
        let buffer_slot = &self.runq_buffer[index % self.runq_buffer.len()];
        ptr::write(buffer_slot.as_ptr() as *mut NonNull<Task>, task);
    }
}
