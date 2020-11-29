use super::Worker;
use std::{
    pin::Pin,
    ptr::NonNull,
    sync::atomic::{spin_loop_hint, AtomicPtr, AtomicUsize, Ordering},
};

#[derive(Default)]
pub(crate) struct ActiveStack {
    head: AtomicPtr<Worker>,
}

impl ActiveStack {
    pub(crate) unsafe fn push(&self, worker: Pin<&Worker>) {
        let mut head = self.head.load(Ordering::Relaxed);
        loop {
            *worker.active_next.get() = NonNull::new(head);

            match self.head.compare_exchange_weak(
                head,
                &*worker as *const _ as *mut _,
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Err(e) => head = e,
                Ok(_) => return,
            }
        }
    }

    pub(crate) unsafe fn iter(&self) -> ActiveIter {
        let head = self.head.load(Ordering::Acquire);
        ActiveIter(NonNull::new(head))
    }
}

pub(crate) struct ActiveIter(Option<NonNull<Worker>>);

impl Iterator for ActiveIter {
    type Item = NonNull<Worker>;

    fn next(&mut self) -> Option<Self::Item> {
        unsafe {
            let worker = self.0?;
            self.0 = *worker.as_ref().active_next.get();
            Some(worker)
        }
    }
}

const IDLE_EMPTY: usize = 0;
const IDLE_NOTIFIED: usize = 1;
const IDLE_SHUTDOWN: usize = 2;

#[derive(Default)]
pub(crate) struct IdleStack {
    state: AtomicUsize,
}

impl IdleStack {
    pub(crate) unsafe fn wait(&self, worker: Pin<&Worker>) {
        let mut state = self.state.load(Ordering::Relaxed);

        loop {
            let new_state = match state {
                IDLE_SHUTDOWN => return,
                IDLE_NOTIFIED => IDLE_EMPTY,
                _ => {
                    *worker.idle_next.get() = NonNull::new(state as *mut Worker);
                    worker.parker.prepare();
                    (&*worker) as *const _ as usize
                }
            };

            match self.state.compare_exchange_weak(
                state,
                new_state,
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Err(e) => state = e,
                Ok(IDLE_NOTIFIED) => return,
                Ok(_) => return worker.parker.park(),
            }
        }
    }

    pub(crate) unsafe fn notify(&self) {
        let mut state = self.state.load(Ordering::Acquire);

        loop {
            let new_state = match state {
                IDLE_EMPTY => IDLE_NOTIFIED,
                IDLE_NOTIFIED | IDLE_SHUTDOWN => return,
                _ => {
                    let worker = &*(state as *mut Worker);
                    (*worker.idle_next.get())
                        .map(|p| p.as_ptr() as usize)
                        .unwrap_or(0)
                }
            };

            match self.state.compare_exchange_weak(
                state,
                new_state,
                Ordering::Acquire,
                Ordering::Acquire,
            ) {
                Err(e) => state = e,
                Ok(IDLE_EMPTY) => return,
                Ok(_) => return (&*(state as *const Worker)).parker.unpark(),
            }
        }
    }

    pub(crate) fn shutdown(&self) {
        let mut workers = match self.state.swap(IDLE_SHUTDOWN, Ordering::AcqRel) {
            IDLE_NOTIFIED | IDLE_SHUTDOWN => return,
            state => NonNull::new(state as *mut Worker),
        };

        while let Some(worker) = workers {
            unsafe {
                workers = *worker.as_ref().idle_next.get();
                worker.as_ref().parker.unpark();
            }
        }
    }
}
