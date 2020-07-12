use super::{Task, Priority, Thread, Batch};
use core::{
    future::Future,
    marker::PhantomPinned,
    sync::atomic::{AtomicUsize, Ordering},
};

#[cfg(feature = "std")]
type FutureError = Box<dyn std::any::Any + Sized + 'static>;

#[cfg(not(feature = "std"))]
type FutureError = ();

#[repr(C, usize)]
enum FutureState<F: Future> {
    Pending(F),
    Ready(F::Output),
    Error(FutureError),
}

#[derive(Copy, Clone, Eq, PartialEq, Debug)]
enum ResumeState {
    Suspended = 0,
    Resumed = 1,
    Notified = 2,
    Completed = 3,
}

struct ResumeContext {
    thread: NonNull<Thread>,
    batch: Batch,
}

#[repr(C)]
pub struct FutureTask<F: Future> {
    _pinned: PhantomPinned,
    task: Task,
    state: FutureState<F>,
}

impl<F: Future> FutureTask<F> {
    pub fn new(priority: Priority, future: F) -> Self {
        Self {
            _pinned: PhantomPinned,
            task: Task::new(priority, Self::resume),
            state: FutureState::Pending(future),
        }
    }

    unsafe fn state_ref(&self) -> &AtomicUsize {
        &*(&self.state as *const _ as *const AtomicUsize)
    }

    extern fn resume(task: *mut Task, thread: *const Thread) -> Batch {
        let this = &*(task as *const Self);
        let state_ref = this.state_ref();
        let thread = NonNull::from(thread as *mut Thread);
        
        loop {
            
            let mut state = state_ref.load(Ordering::SeqCst);
            loop {

            }
        }
    }
}