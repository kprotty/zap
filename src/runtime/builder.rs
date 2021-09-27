use super::{pool::Pool, task::TaskFuture};
use std::{
    future::Future,
    pin::Pin,
    ptr,
    task::{Context, Poll, RawWaker, RawWakerVTable, Waker},
};

#[derive(Default)]
pub struct Builder {
    pub max_threads: Option<usize>,
    pub stack_size: Option<usize>,
}

impl Builder {
    pub fn new() -> Self {
        Self {
            max_threads: None,
            stack_size: None,
        }
    }

    pub fn max_threads(mut self, num_threads: usize) -> Self {
        self.max_threads = Some(num_threads);
        self
    }

    pub fn stack_size(mut self, stack_size: usize) -> Self {
        self.stack_size = Some(stack_size);
        self
    }

    pub fn block_on<F>(&self, future: F) -> F::Output
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        let pool = Pool::from_builder(self);
        let mut join_handle = TaskFuture::spawn(&pool, 0, future);

        unsafe {
            const PANIC_WAKER_VTABLE: RawWakerVTable = RawWakerVTable::new(
                |_| unreachable!("Waker::clone was called when unsupported"),
                |_| unreachable!("Waker::wake was called when unsupported"),
                |_| unreachable!("Waker::wake_by_ref was called when unsupported"),
                |_| {},
            );

            let waker = Waker::from_raw(RawWaker::new(ptr::null(), &PANIC_WAKER_VTABLE));
            let join_future = Pin::new_unchecked(&mut join_handle);
            let mut context = Context::from_waker(&waker);

            match join_future.poll(&mut context) {
                Poll::Ready(output) => output,
                Poll::Pending => unreachable!("Future did not complete after pool shutdown"),
            }
        }
    }
}
