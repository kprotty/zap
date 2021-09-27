use super::super::sync::low_level::{AutoResetEvent, Lock};
use std::{cell::Cell, pin::Pin};

#[derive(Default)]
pub struct IdleNode {
    next: Cell<Option<usize>>,
    event: AutoResetEvent,
}

unsafe impl Send for IdleNode {}
unsafe impl Sync for IdleNode {}

pub trait IdleNodeProvider {
    fn with<T>(&self, index: usize, f: impl FnOnce(Pin<&IdleNode>) -> T) -> T;
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum IdleState {
    Empty,
    Waiting(usize),
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
    pub fn wait<P: IdleNodeProvider>(
        &self,
        node_provider: P,
        index: usize,
        validate: impl Fn() -> bool,
    ) {
        let is_waiting = self.state.with(|state| {
            if !validate() {
                return false;
            }

            match *state {
                IdleState::Empty => {
                    node_provider.with(index, |node| node.next.set(None));
                    *state = IdleState::Waiting(index);
                    true
                }
                IdleState::Waiting(old_index) => {
                    node_provider.with(index, |node| node.next.set(Some(old_index)));
                    *state = IdleState::Waiting(index);
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
            node_provider.with(index, |node| unsafe {
                Pin::map_unchecked(node, |node| &node.event).wait()
            })
        }
    }

    pub fn signal<P: IdleNodeProvider>(&self, node_provider: P) -> bool {
        self.state
            .with(|state| match *state {
                IdleState::Empty => {
                    *state = IdleState::Notified;
                    None
                }
                IdleState::Waiting(index) => {
                    *state = match node_provider.with(index, |node| node.next.get()) {
                        Some(new_index) => IdleState::Waiting(new_index),
                        None => IdleState::Empty,
                    };
                    Some(index)
                }
                IdleState::Notified => None,
                IdleState::Shutdown => None,
            })
            .map(|index| {
                node_provider.with(index, |node| unsafe {
                    Pin::map_unchecked(node, |node| &node.event).notify()
                })
            })
            .is_some()
    }

    pub fn shutdown<P: IdleNodeProvider>(&self, node_provider: P) {
        let mut state = self
            .state
            .with(|state| std::mem::replace(state, IdleState::Shutdown));

        while let IdleState::Waiting(index) = state {
            node_provider.with(index, |node| unsafe {
                state = match node.next.get() {
                    Some(new_index) => IdleState::Waiting(new_index),
                    None => IdleState::Empty,
                };
                Pin::map_unchecked(node, |node| &node.event).notify()
            })
        }
    }
}
