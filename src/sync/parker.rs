use crate::time::Instant;
use std::{
    sync::atomic::{AtomicBool, Ordering},
    thread::{self, Thread},
};

pub(crate) struct Parker {
    thread: Option<Thread>,
    notified: AtomicBool,
}

unsafe impl Sync for Parker {}

impl Default for Parker {
    fn default() -> Self {
        Self::new()
    }
}

impl Parker {
    pub(crate) const fn new() -> Self {
        Self {
            thread: None,
            notified: AtomicBool::new(false),
        }
    }

    pub(crate) fn prepare(&mut self) {
        *self.notified.get_mut() = false;

        if self.thread.is_none() {
            self.thread = Some(thread::current());
        }
    }

    pub(crate) fn park(&self, deadline: Option<Instant>) -> bool {
        loop {
            if self.notified.load(Ordering::Acquire) {
                return true;
            }

            let deadline = match deadline {
                Some(deadline) => deadline,
                None => {
                    thread::park();
                    continue;
                }
            };

            let now = Instant::now();
            if now >= deadline {
                return false;
            }

            let timeout = deadline - now;
            thread::park_timeout(timeout);
        }
    }

    pub(crate) fn unpark(&self) {
        let thread = self
            .thread
            .as_ref()
            .expect("Parker::unpark() called before Parker::prepare()")
            .clone();

        self.notified.store(true, Ordering::Release);

        thread.unpark();
    }
}
