mod node;
pub use node::{Cluster, Node};

mod worker;
pub use worker::Worker;
pub(crate) use worker::WorkerRef;

mod thread;
pub use thread::{Thread, Syscall, ThreadId};

mod task;
pub use task::{Batch, RunFn, Task};

use core::{
    pin::Pin,
    ptr::NonNull,
    sync::atomic::AtomicUsize,
};

#[derive(Debug)]
pub enum RunError {}

#[derive(Debug)]
pub struct Scheduler {
    nodes_active: AtomicUsize,
    node_cluster: Cluster,
}

impl Scheduler {
    pub fn run(
        &mut self,
        _node_cluster: Cluster,
        _primary_node_index: usize,
        _primary_task: Pin<&mut Task>,
    ) -> Result<NonNull<Worker>, RunError> {
        unimplemented!("TODO")
    }
}