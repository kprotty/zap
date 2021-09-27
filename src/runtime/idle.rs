use std::sync::{Condvar, Mutex};

#[derive(Default)]
pub struct IdleQueue {
    count: Mutex<usize>,
    cond: Condvar,
}

impl IdleQueue {
    pub fn wait(&self, validate: impl Fn() -> bool) {
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

    pub fn signal(&self) -> bool {
        let mut count = self.count.lock().unwrap();
        *count += 1;
        self.cond.notify_one();
        *count == 1
    }

    pub fn shutdown(&self) {
        let mut count = self.count.lock().unwrap();
        *count = usize::MAX;
        self.cond.notify_all();
    }
}
