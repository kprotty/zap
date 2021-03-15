use super::{
    queue::{GlobalQueue, LocalQueue},
    task::Task,
    time::DelayQueue,
};
use std::{
    cell::UnsafeCell, collections::VecDeque, num::NonZeroUsize, pin::Pin, sync::{Mutex, Arc, atomic::AtomicUsize},
};

struct Pool {
    state: AtomicUsize,
    idle: Mutex<VecDeque<usize>>,
    workers: Pin<Box<[Worker]>>,
    run_queue: GlobalQueue,
}

impl Pool {
    pub fn new(num_workers: NonZeroUsize) -> Self {}
}

struct Worker {
    state: AtomicUsize,
    run_queue: LocalQueue,
    local_queue: GlobalQueue,
    delay_queue: DelayQueue,
}

struct Context {
    pool: Arc<Pool>,
    worker: usize,
    xorshift: usize,
    local: Option<NonNull<Task>>,
}

impl Context {
    fn rand(&mut self) -> usize {
        let shifts = match std::mem::size_of::<usize>() {
            8 => (13, 7, 17),
            4 => (13, 17, 5),
            _ => unreachable!("platform not supported"),
        };

        self.xorshift ^= self.xorshift << shifts.0;
        self.xorshift ^= self.xorshift >> shifts.1;
        self.xorshift ^= self.xorshift << shifts.2;
        self.xorshift
    }

    fn poll(&mut self) -> Option<(NonNull<Task>, bool)> {
        if let Some(task) = self.poll_local() {
            return Some((task, false));
        }

        
    }

    fn poll_local(&mut self) -> Option<(NonNull<Task>, bool)> {
        if let  = self.

        if let Some(task) = self.local.take() {
            self.local = unsafe { task.as_mut().next.get() };
            return Some((task, false));
        }

        if let Some(task) = self.pool.workers[self.worker].local_queue.take_stack() {
            self.local = unsafe { task.as_mut().next.get() };
            return Some((task, false));
        }

        self.pool.workers[self.worker].run_queue.pop()
    }
}
