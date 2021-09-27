use super::super::sync::low_level::{AutoResetEvent, Lock};
use std::{cell::Cell, pin::Pin, ptr::NonNull};

struct IdleWaiter {
    next: Cell<Option<NonNull<Self>>>,
    event: AutoResetEvent,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum IdleState {
    Empty,
    Waiting(NonNull<IdleWaiter>),
    Notified,
    Shutdown,
}

unsafe impl Send for IdleState {}

impl Default for IdleState {
    fn default() -> Self {
        Self::Empty
    }
}

#[derive(Default)]
pub struct IdleQueue {
    state: Lock<IdleState>,
}

impl IdleQueue {
    pub fn wait(&self, validate: impl Fn() -> bool) {
        let waiter = IdleWaiter {
            next: Cell::new(None),
            event: AutoResetEvent::default(),
        };

        let waiter = unsafe { Pin::new_unchecked(&waiter) };
        let is_waiting = self.state.with(|state| {
            if !validate() {
                return false;
            }

            let ptr = NonNull::from(&*waiter);
            match *state {
                IdleState::Empty => {
                    *state = IdleState::Waiting(ptr);
                    true
                }
                IdleState::Waiting(head) => {
                    waiter.next.set(Some(head));
                    *state = IdleState::Waiting(ptr);
                    true
                }
                IdleState::Notified => {
                    *state = IdleState::Empty;
                    false
                }
                IdleState::Shutdown => false,
            }
        });

        if is_waiting {
            unsafe {
                Pin::map_unchecked(waiter, |w| &w.event).wait();
            }
        }
    }

    pub fn signal(&self) -> bool {
        self.state
            .with(|state| unsafe {
                match *state {
                    IdleState::Empty => {
                        *state = IdleState::Notified;
                        None
                    }
                    IdleState::Waiting(head) => {
                        *state = match head.as_ref().next.get() {
                            Some(new_head) => IdleState::Waiting(new_head),
                            None => IdleState::Empty,
                        };
                        Some(head)
                    }
                    IdleState::Notified => None,
                    IdleState::Shutdown => None,
                }
            })
            .map(|waiter| unsafe {
                Pin::new_unchecked(&waiter.as_ref().event).notify();
                true
            })
            .unwrap_or(false)
    }

    pub fn shutdown(&self) {
        let mut state = self
            .state
            .with(|state| std::mem::replace(state, IdleState::Shutdown));

        while let IdleState::Waiting(waiter) = state {
            unsafe {
                state = match waiter.as_ref().next.get() {
                    Some(new_waiter) => IdleState::Waiting(new_waiter),
                    None => IdleState::Empty,
                };
                Pin::new_unchecked(&waiter.as_ref().event).notify();
            }
        }
    }
}
