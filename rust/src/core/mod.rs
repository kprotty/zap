mod node;
pub use node::{Cluster, Node};
pub(crate) use node::{ResumeResult, SuspendResult};

mod worker;
pub use worker::Worker;
pub(crate) use worker::WorkerRef;

mod thread;
pub(crate) use thread::ThreadState;
pub use thread::{Syscall, Thread, ThreadId};

mod task;
pub use task::{Batch, Priority, RunFn, Task};

use core::{
    marker::PhantomPinned,
    num::NonZeroUsize,
    pin::Pin,
    ptr::NonNull,
    sync::atomic::{AtomicUsize, Ordering},
};

#[derive(Debug)]
pub enum RunError {
    NoAvailableNodes,
    NoAvailableWorkers,
}

#[derive(Debug)]
pub struct Scheduler {
    _pinned: PhantomPinned,
    node_cluster: Cluster,
    nodes_active: AtomicUsize,
}

impl Scheduler {
    pub fn new(node_cluster: Cluster) -> Self {
        Self {
            _pinned: PhantomPinned,
            node_cluster,
            nodes_active: AtomicUsize::new(0),
        }
    }

    pub unsafe fn start(
        self: Pin<&mut Self>,
        primary_node_index: usize,
        primary_task: Pin<&mut Task>,
    ) -> Result<NonNull<Worker>, RunError> {
        let mut_self = Pin::into_inner_unchecked(self);

        let mut primary_node = None;
        for (index, node) in mut_self.node_cluster.iter().enumerate() {
            node.init();
            if index == primary_node_index {
                primary_node = Some(node);
            }
        }

        let primary_node = match primary_node.or_else(|| mut_self.node_cluster.iter().next()) {
            Some(node) => Pin::into_inner_unchecked(node),
            None => return Err(RunError::NoAvailableNodes),
        };

        let primary_worker = match primary_node.try_resume_some_worker() {
            Some(ResumeResult::Spawn {
                worker,
                first_in_node: true,
                first_in_cluster: true,
            }) => worker,
            Some(ResumeResult::Spawn { .. }) => unreachable!(),
            Some(ResumeResult::Resume { .. }) => unreachable!(),
            _ => return Err(RunError::NoAvailableWorkers),
        };

        primary_node.push(Batch::from(primary_task));
        Ok(primary_worker)
    }

    pub unsafe fn shutdown(self: Pin<&Self>) -> impl Iterator<Item = NonNull<Thread>> {
        ShutdownThreadIter {
            count: self.node_cluster.len(),
            idle_threads: None,
            node: self
                .node_cluster
                .iter()
                .next()
                .map(|node| NonNull::from(Pin::into_inner_unchecked(node))),
        }
    }

    pub unsafe fn finish<'a>(
        self: Pin<&'a mut Self>,
    ) -> impl Iterator<Item = NonNull<ThreadId>> + 'a {
        assert_eq!(self.nodes_active.load(Ordering::SeqCst), 0);

        Pin::into_inner_unchecked(self)
            .node_cluster
            .iter()
            .map(|node| {
                let node = Pin::into_inner_unchecked(node);
                node.deinit();
                node.workers().iter().filter_map(|worker| {
                    let ptr = worker.ptr.load(Ordering::SeqCst);
                    match WorkerRef::from(ptr) {
                        WorkerRef::Worker(_) => None,
                        WorkerRef::ThreadId(tid) => tid,
                        WorkerRef::Node(_) => {
                            unreachable!("Worker being spawned on scheduler finish")
                        }
                        WorkerRef::Thread(_) => {
                            unreachable!("Worker still running on scheduler finish")
                        }
                    }
                })
            })
            .flatten()
    }
}

struct ShutdownThreadIter {
    count: usize,
    idle_threads: Option<NonZeroUsize>,
    node: Option<NonNull<Node>>,
}

impl Iterator for ShutdownThreadIter {
    type Item = NonNull<Thread>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if self.count == 0 {
                return None;
            }

            if let Some(thread_ptr) = self.idle_threads {
                let thread = unsafe { &*(thread_ptr.get() as *const Thread) };
                self.idle_threads = thread.next_index.get();
                return Some(NonNull::from(thread));
            }

            if let Some(this_node) = self.node {
                unsafe {
                    self.node = this_node.as_ref().next;
                    if let Some(new_node) = self.node {
                        self.idle_threads = new_node.as_ref().shutdown();
                        self.count -= 1;
                    } else {
                        self.count = 0;
                    }
                    continue;
                }
            }

            return None;
        }
    }
}
