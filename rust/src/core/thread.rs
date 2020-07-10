use super::Worker;
use core::{cell::Cell, num::NonZeroUsize, ptr::NonNull};

#[repr(C, align(4))]
pub struct ThreadId;

#[derive(Debug)]
pub enum Syscall {}

#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub(crate) enum ThreadState {
    Shutdown,
    Suspended,
    Waking,
    Running,
}

#[repr(C)]
pub struct Thread {
    pub(crate) worker: NonNull<Worker>,
    pub(crate) state: Cell<ThreadState>,
    pub(crate) id: Cell<Option<NonNull<ThreadId>>>,
    pub(crate) next_index: Cell<Option<NonZeroUsize>>,
}

unsafe impl Sync for Thread {}
