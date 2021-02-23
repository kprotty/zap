use super::sync::{Lock, Event};
use std::{
    sync::atomic::{AtomicUsize, Ordering},
};

#[derive(Copy, Clone, Eq, PartialEq)]
pub(crate) enum CounterState {
    Pending = 0,
    Waking = 1,
    Signaled = 2,
    Shutdown = 3,
}

#[derive(Copy, Clone, Eq, PartialEq)]
pub(crate) struct Counter {
    pub(crate) state: CounterState,
    pub(crate) waiting: bool,
    pub(crate) notified: bool,
    pub(crate) spawned: usize,
}

impl Into<usize> for Counter {
    fn into(self) -> usize {
        let mut value = self.state as usize;
        value |= (self.waiting as usize) << 2;
        value |= (self.notified as usize) << 3;
        value |= self.spawned << 4;
        value
    }
}

impl From<usize> for Counter {
    fn from(value: usize) -> Self {
        Self {
            state: match value & 0b11 {
                0 => CounterState::Pending,
                1 => CounterState::Waking,
                2 => CounterState::Signaled,
                3 => CounterState::Shutdown,
                _ => unreachable!(),
            },
            waiting: value & (1 << 2) != 0,
            notified: value & (1 << 3) != 0,
            spawned: value >> 4,
        }
    }
}

#[derive(Copy, Clone, Eq, PartialEq)]
pub(crate) enum Notify {
    Spawn,
    Resume,
}

#[derive(Copy, Clone, Eq, PartialEq)]
pub(crate) enum Suspend {
    Wait,
    Resumed,
    Notified,
}

pub(crate) struct Idle {
    counter: AtomicUsize,
}

impl Idle {
    pub const fn new() -> Self {
        Self {
            counter: AtomicUsize::new(0),
        }
    }

    pub fn notify(&self, is_waking: bool) {
        let mut counter = Counter::from(self.counter.load(Ordering::Relaxed));

        loop {
            if counter.state == CounterState::Shutdown {
                return None;
            }

            
        }
    }
}