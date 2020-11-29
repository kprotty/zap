use super::{super::sync::Parker, BoundedQueue, Scheduler, Task, UnboundedQueue};
use std::{
    cell::{Cell, UnsafeCell},
    marker::PhantomPinned,
    ptr::NonNull,
    sync::atomic::{AtomicPtr, Ordering},
};

#[repr(align(4))]
pub(crate) struct Worker {
    pub(crate) parker: Parker,
    state: Cell<usize>,
    scheduler: NonNull<Scheduler>,
    run_queue: BoundedQueue,
    run_queue_lifo: AtomicPtr<Task>,
    run_queue_overflow: UnboundedQueue,
    pub(crate) idle_next: UnsafeCell<Option<NonNull<Self>>>,
    pub(crate) active_next: UnsafeCell<Option<NonNull<Self>>>,
    _pinned: PhantomPinned,
}
