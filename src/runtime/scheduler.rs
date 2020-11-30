use super::{ActiveStack, IdleStack};
use std::{
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
    counter: AtomicU32,
    idle_stack: IdleStack,
    active_stack: ActiveStack,
    _pinned: PhantomPinned,
}

unsafe impl Send for Scheduler {}
unsafe impl Sync for Scheduler {}

impl Scheduler {
    pub(crate) fn notify(&self) {
        self.notify_when(false);
    }

    pub(crate) fn notify_waking(&self) {
        self.notify_when(true);
    }

    fn notify_when(&self, is_waking: bool) {
        compile_error!("TODO")
    }
}
