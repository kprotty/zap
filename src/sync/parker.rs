use std::{
    cell::{Cell, UnsafeCell},
    sync::atomic::{AtomicBool, Ordering},
    thread::{self, Thread},
};

pub(crate) struct Parker {
    thread: Cell<Option<Thread>>,
    notified: UnsafeCell<AtomicBool>,
}

unsafe impl Sync for Parker {}

impl Parker {
    pub(crate) fn new() -> Self {
        Self {
            thread: Cell::new(None),
            notified: UnsafeCell::new(AtomicBool::new(false)),
        }
    }

    pub(crate) unsafe fn prepare(&self) {
        *(&mut *self.notified.get()).get_mut() = false;

        let thread = self.thread.replace(None);
        let thread = thread.unwrap_or_else(|| thread::current());
        self.thread.set(Some(thread));
    }

    pub(crate) unsafe fn park(&self) {
        let notified = &*self.notified.get();
        while !notified.load(Ordering::Acquire) {
            thread::park();
        }
    }

    pub(crate) unsafe fn unpark(&self) {
        let thread = self
            .thread
            .replace(None)
            .expect("Parker without associated thread");
        self.thread.set(Some(thread.clone()));

        let notified = &*self.notified.get();
        notified.store(true, Ordering::Release);

        thread.unpark()
    }
}
