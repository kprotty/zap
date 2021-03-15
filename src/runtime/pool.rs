use super::{
    queue::{GlobalQueue, LocalQueue},
    task::{Batch, Priority},
};
use std::{cell::UnsafeCell, pin::Pin, sync::atomic::AtomicUsize};

struct Pool {
    state: AtomicUsize,
    workers: Pin<Box<[Worker]>>,
    run_queues: [GlobalQueue; Priority::COUNT],
}

impl Pool {}

struct Worker {
    state: AtomicUsize,
    run_next: UnsafeCell<Batch>,
    run_queues: [LocalQueue; Priority::COUNT],
}
