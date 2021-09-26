use super::super::sync::low_level::AutoResetEvent;
use std::{
    pin::Pin,
    sync::atomic::{AtomicUsize, Ordering},
};

#[derive(Default)]
pub struct IdleNode {
    state: AtomicUsize,
    event: AutoResetEvent,
}

pub trait IdleNodeProvider {
    fn with_node<T>(&self, index: usize, f: impl FnOnce(Pin<&IdleNode>) -> T) -> T;
}

#[derive(Copy, Clone, Debug)]
enum IdleIndex {
    Empty,
    Waiting(usize),
    Notified,
    Shutdown,
}

#[derive(Copy, Clone, Debug)]
struct IdleState {
    aba: usize,
    index: IdleIndex,
}

impl IdleState {
    const BITS: u32 = usize::BITS / 2;
    const MASK: usize = (1 << Self::BITS) - 1;

    const INDEX_SHUTDOWN: usize = Self::MASK;
    const INDEX_NOTIFIED: usize = Self::MASK - 1;
    const INDEX_MAX: usize = (Self::MASK - 2) - 1;
}

impl From<usize> for IdleState {
    fn from(value: usize) -> Self {
        Self {
            aba: value >> Self::BITS,
            index: match value & Self::MASK {
                Self::INDEX_SHUTDOWN => IdleIndex::Shutdown,
                Self::INDEX_NOTIFIED => IdleIndex::Notified,
                0 => IdleIndex::Empty,
                index => IdleIndex::Waiting(index - 1),
            },
        }
    }
}

impl Into<usize> for IdleState {
    fn into(self) -> usize {
        ((self.aba & Self::MASK) << Self::BITS)
            | match self.index {
                IdleIndex::Shutdown => Self::INDEX_SHUTDOWN,
                IdleIndex::Notified => Self::INDEX_NOTIFIED,
                IdleIndex::Empty => 0,
                IdleIndex::Waiting(index) => {
                    assert!(index <= Self::INDEX_MAX);
                    index + 1
                }
            }
    }
}

#[derive(Default)]
pub struct IdleQueue {
    state: AtomicUsize,
}

impl IdleQueue {
    pub fn wait<P: IdleNodeProvider>(
        &self,
        node_provider: P,
        index: usize,
        validate: impl Fn() -> bool,
    ) {
        let _ = self
            .state
            .fetch_update(Ordering::Acquire, Ordering::Relaxed, |state| {
                let mut state: IdleState = state.into();
                if !validate() {
                    return None;
                }

                state.index = match state.index {
                    IdleIndex::Shutdown => return None,
                    IdleIndex::Notified => IdleIndex::Empty,
                    _ => node_provider.with_node(index, |node| {
                        state.aba += 1;
                        node.state.store(state.into(), Ordering::Relaxed);
                        IdleIndex::Waiting(index)
                    }),
                };

                Some(state.into())
            })
            .map(IdleState::from)
            .map(|state| match state.index {
                IdleIndex::Notified => {}
                IdleIndex::Shutdown => unreachable!(),
                _ => node_provider.with_node(index, |node| unsafe {
                    Pin::map_unchecked(node, |node| &node.event).wait()
                }),
            });
    }

    pub fn signal<P: IdleNodeProvider>(&self, node_provider: P) {
        let _ = self
            .state
            .fetch_update(Ordering::Release, Ordering::Relaxed, |state| {
                let mut state: IdleState = state.into();
                state.index = match state.index {
                    IdleIndex::Shutdown => return None,
                    IdleIndex::Notified => return None,
                    IdleIndex::Empty => IdleIndex::Notified,
                    IdleIndex::Waiting(index) => node_provider
                        .with_node(index, |node| {
                            let state: IdleState = node.state.load(Ordering::Relaxed).into();
                            state.index
                        }),
                };
                Some(state.into())
            })
            .map(IdleState::from)
            .map(|state| match state.index {
                IdleIndex::Waiting(index) => {
                    node_provider.with_node(index, |node| unsafe {
                        Pin::map_unchecked(node, |node| &node.event).notify()
                    })
                }
                IdleIndex::Notified => {}
                _ => unreachable!(),
            });
    }

    pub fn shutdown<P: IdleNodeProvider>(&self, node_provider: P) {
        let mut state = IdleState {
            aba: 0,
            index: IdleIndex::Shutdown,
        };

        state = self.state.swap(state.into(), Ordering::AcqRel).into();

        while let IdleIndex::Waiting(index) = state.index {
            node_provider.with_node(index, |node| unsafe {
                state = node.state.load(Ordering::Relaxed).into();
                Pin::map_unchecked(node, |node| &node.event).notify()
            })
        }
    }
}
