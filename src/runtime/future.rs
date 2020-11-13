use super::{Task, Runnable};
use std::{
    pin::Pin,
    any::Any,
    future::Future,
    sync::atomic::{AtomicUsize, Ordering},
    task::{Waker, RawWaker, RawWakerVTable, Poll, Context},
};

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