use super::Worker;
use std::{
    any::Any,
    pin::Pin,
    cell::Cell,
    ptr::NonNull,
    marker::PhantomPinned,
    future::Future,
    mem::{size_of, align_of},
    sync::atomic::{AtomicUsize, Ordering},
};

struct Runnable {
    run: unsafe fn(Pin<&mut Task>, Pin<&Worker>),
}

#[repr(C)]
pub struct Task {
    _pinned: PhantomPinned,
    next: Cell<Option<NonNull<Self>>>,
    runnable: &'static Runnable,
}

impl Task {
    #[inline]
    pub unsafe fn run(self: Pin<&mut Self>, worker: Pin<&Worker>) {
        let run_fn = self.runnable.run;
        (run_fn)(self, worker)
    } 
}

type FutureError = Box<dyn Any + Send + 'static>;

#[repr(C, usize)]
enum FutureData<F: Future> {
    Pending(F),
    Ready(F::Output),
    Error(FutureError),
}

#[repr(C)]
pub struct FutureTask<F: Future> {
    task: Task,
    ref_count: AtomicUsize,
    data: FutureData<F>,
}