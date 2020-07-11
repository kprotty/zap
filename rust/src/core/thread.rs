use super::{Worker, WorkerRef, Node, Task};
use crate::sync::CachePadded;
use core::{
    pin::Pin,
    cell::Cell,
    num::NonZeroUsize,
    ptr::NonNull,
    sync::atomic::{AtomicUsize, Ordering},
    mem::MaybeUninit,
};

#[repr(C, align(4))]
pub struct ThreadId;

#[derive(Debug)]
pub enum Syscall {}

#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub(crate) enum ThreadState {
    Shutdown = 0,
    Suspended = 1,
    Waking = 2,
    Running = 3,
}

impl ThreadState {
    pub fn encode(self, tick: u8, rng: u16) -> u32 {
        ((self as u32) << 24)
            | ((tick as u32) << 16)
            | (rng as u32)
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
    pub fn new(
        id: Option<NonNull<ThreadId>>,
        worker: NonNull<Worker>,
    ) -> Self {
        let node = unsafe {
            let ptr = worker.as_ref().ptr.load(Ordering::Acquire);
            match WorkerRef::from(ptr) {
                WorkerRef::Node(node) => node,
                worker_ref => unreachable!("Invalid worker ptr on thread spawn {:?}", worker_ref),
            }
        };

        let rng = id.unwrap_or(NonNull::dangling()).as_ptr() as usize;
        let rng = rng ^ worker.as_ptr() as usize;
        let rng = ((rng * 31) >> 17) as u16;

        Self {
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

    pub fn run(
        self: Pin<&Self>,
        failed_syscall: Option<Syscall>,
    ) -> Syscall {
        unimplemented!("TODO")
    }

    fn poll(
        &self,
        tick: u8,
        mut rng: u16,
        node: &Node,
    ) -> (Option<NonNull<Task>>, u16) {
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
                    let ptr = workers[index].ptr.load(Ordering::Acquire);
                    index += 1;
                    if index == workers.len() {
                        index = 0;
                    }

                    match WorkerRef::from(ptr) {
                        WorkerRef::Node(_) |
                        WorkerRef::Worker(_) => {},
                        WorkerRef::ThreadId(_) => {
                            unreachable!("Thread::poll() when other worker is shutting down");
                        },
                        WorkerRef::Thread(thread) => {
                            if (thread.as_ptr() as usize) == (self as *const _ as usize) {
                                continue;
                            }

                            let target_thread = unsafe { thread.as_ref() };
                            if let Some(task) = self.poll_steal(target_thread, steal_next) {
                                return (Some(task), rng);
                            } 
                        },
                    }
                }
            }
        }

        (None, rng)
    }

    fn poll_global(&self, target: &Node) -> Option<NonNull<Task>> {
        let mut node_poller = target.try_acquire_polling()?;
        unimplemented!("TODO")
    }

    fn poll_local(&self) -> Option<NonNull<Task>> {
        unimplemented!("TODO")
    }

    fn poll_steal(&self, target: &Thread, steal_next: bool) -> Option<NonNull<Task>> {
        unimplemented!("TODO")
    }
}


