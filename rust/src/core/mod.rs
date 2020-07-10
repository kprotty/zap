mod node;
pub(crate) use node::ResumeResult;
pub use node::{Cluster, Node};

mod worker;
pub use worker::Worker;
pub(crate) use worker::WorkerRef;

mod thread;
pub(crate) use thread::ThreadState;
pub use thread::{Syscall, Thread, ThreadId};

mod task;
pub use task::{Batch, RunFn, Task};

use core::{
    marker::PhantomPinned,
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

    pub fn start(
        self: Pin<&mut Self>,
        primary_node_index: usize,
        primary_task: Pin<&mut Task>,
    ) -> Result<NonNull<Worker>, RunError> {
        let mut_self = unsafe { Pin::into_inner_unchecked(self) };

        let mut primary_node = None;
        for (index, node) in mut_self.node_cluster.iter().enumerate() {
            node.init();
            if index == primary_node_index {
                primary_node = Some(node);
            }
        }

        let primary_node = match primary_node.or_else(|| mut_self.node_cluster.iter().next()) {
            Some(node) => unsafe { Pin::into_inner_unchecked(node) },
            None => return Err(RunError::NoAvailableNodes),
        };

        let primary_worker = match primary_node.try_resume_some_worker() {
            Some(ResumeResult::Spawn(worker)) => worker,
            Some(ResumeResult::Resume(_)) => unreachable!(),
            _ => return Err(RunError::NoAvailableWorkers),
        };

        primary_node.push(Batch::from(primary_task));
        Ok(primary_worker)
    }

    pub fn finish<'a>(self: Pin<&'a mut Self>) -> impl Iterator<Item = NonNull<ThreadId>> + 'a {
        assert_eq!(self.nodes_active.load(Ordering::Relaxed), 0);

        (unsafe { Pin::into_inner_unchecked(self) })
            .node_cluster
            .iter()
            .map(|node| {
                let node = unsafe { Pin::into_inner_unchecked(node) };
                node.deinit();
                node.workers().iter().filter_map(|worker| {
                    let ptr = worker.ptr.load(Ordering::Acquire);
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
