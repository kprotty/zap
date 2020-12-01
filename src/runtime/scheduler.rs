use super::{ActiveList, Batch, IdleList, OwnedWorkerRef, UnboundedQueue, Worker};
use std::{
    convert::TryInto,
    marker::PhantomPinned,
    pin::Pin,
    sync::atomic::{AtomicU32, Ordering},
};

#[derive(Copy, Clone)]
enum State {
    Pending,
    Notified,
    Waking,
    WakerNotified,
    Shutdown,
}

#[derive(Copy, Clone)]
struct Counter {
    spawned: u16,
    idle: u16,
    state: State,
}

impl Counter {
    const MAX: u16 = (1 << 14) - 1;
}

impl From<u32> for Counter {
    fn from(value: u32) -> Self {
        Self {
            spawned: ((value >> (4 + 14)) & 0xffff).try_into().unwrap(),
            idle: ((value >> 4) & 0xffff).try_into().unwrap(),
            state: match value & 0b1111 {
                0 => State::Pending,
                1 => State::Notified,
                2 => State::Waking,
                3 => State::WakerNotified,
                4 => State::Shutdown,
                _ => unreachable!(),
            },
        }
    }
}

impl Into<u32> for Counter {
    fn into(self) -> u32 {
        let mut value = 0;
        value |= (self.idle << 4) as u32;
        value |= (self.spawned << (4 + 14)) as u32;
        value |= match self.state {
            State::Pending => 0,
            State::Notified => 1,
            State::Waking => 2,
            State::WakerNotified => 3,
            State::Shutdown => 4,
        };
        value
    }
}

#[repr(align(4))]
pub(crate) struct Scheduler {
    max_workers: u16,
    counter: AtomicU32,
    idle_workers: IdleList,
    pub(crate) active_workers: ActiveList,
    pub(crate) run_queue: UnboundedQueue,
    _pinned: PhantomPinned,
}

unsafe impl Send for Scheduler {}
unsafe impl Sync for Scheduler {}

impl Scheduler {
    pub(crate) fn new(max_workers: u16) -> Self {
        Self {
            max_workers,
            counter: AtomicU32::new(0),
            run_queue: UnboundedQueue::new(),
            idle_workers: IdleList::new(),
            active_workers: ActiveList::new(),
            _pinned: PhantomPinned,
        }
    }

    pub(crate) fn count_active_workers(self: Pin<&Self>) -> u16 {
        let counter = self.counter.load(Ordering::Relaxed);
        let Counter { spawned, idle, .. } = Counter::from(counter);
        debug_assert!(spawned >= idle);
        spawned - idle
    }

    pub(crate) fn schedule(self: Pin<&Self>, batch: impl Into<Batch>) {
        let batch: Batch = batch.into();
        if batch.empty() {
            return;
        }

        let run_queue = unsafe { Pin::new_unchecked(&self.run_queue) };
        run_queue.push(batch);
        self.notify(false);
    }

    pub(crate) fn notify(self: Pin<&Self>, is_waking: bool) -> bool {
        compile_error!("TODO: resumeWorker(is_waking): <resumed:bool>")
    }

    pub(crate) fn suspend(self: Pin<&Self>, worker: Pin<&Worker>) -> Option<bool> {
        compile_error!("TODO: suspendWorker(worker): <None:shutdown | Some(is_waking)>")
    }
}
