use super::super::sync::low_level::AutoResetEvent;
use std::{
    pin::Pin,
    sync::{Mutex, Condvar},
};

#[derive(Default)]
pub struct IdleNode {
    _event: AutoResetEvent,
}

pub trait IdleNodeProvider {
    fn with_node<T>(&self, index: usize, f: impl FnOnce(Pin<&IdleNode>) -> T) -> T;
}

#[derive(Default)]
pub struct IdleQueue {
    count: Mutex<usize>,
    cond: Condvar,
}

impl IdleQueue {
    pub fn wait<P: IdleNodeProvider>(
        &self,
        _node_provider: P,
        _index: usize,
        validate: impl Fn() -> bool,
    ) {
        let mut count = self.count.lock().unwrap();
        loop {
            if !validate() {
                return;
            }

            if *count > 0 {
                *count -= 1;
                return;
            }

            count = self.cond.wait(count).unwrap();
        }
    }

    pub fn signal<P: IdleNodeProvider>(&self, _node_provider: P) -> bool {
        let mut count = self.count.lock().unwrap();
        *count += 1;
        self.cond.notify_one();
        *count == 1
    }

    pub fn shutdown<P: IdleNodeProvider>(&self, _node_provider: P) {
        let mut count = self.count.lock().unwrap();
        *count = usize::MAX;
        self.cond.notify_all();
    }
}
