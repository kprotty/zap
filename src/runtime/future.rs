use super::{Runnable, Task, Worker};
use std::{
    any::Any,
    cell::UnsafeCell,
    future::Future,
    marker::{PhantomData, PhantomPinned},
    pin::Pin,
    ptr::{NonNull, drop_in_place},
    mem::{forget, MaybeUninit},
    sync::atomic::{AtomicUsize, Ordering},
    task::{Context, Poll, RawWaker, RawWakerVTable, Waker},
};

struct FutureVTable {
    runnable: Runnable,
    waker_clone: unsafe fn(NonNull<Task>),
    waker_wake: unsafe fn(NonNull<Task>, bool),
    waker_drop: unsafe fn(NonNull<Task>),
    join_poll: unsafe fn(NonNull<Task>, Pin<&JoinInner>, *mut ()),
    join_drop: unsafe fn(NonNull<Task>, Pin<&JoinInner>),
}

impl FutureVTable {
    unsafe fn from_task(task: NonNull<Task>) -> &'static Self {
        let runnable_offset = {
            let stub = Self {
                runnable: Runnable(|_, _| unreachable!()),
                waker_clone: |_| unreachable!(),
                waker_wake: |_, _| unreachable!(),
                waker_drop: |_| unreachable!(),
                join_poll: |_, _, _| unreachable!(),
                join_drop: |_, _| unreachable!(),
            };
            let base = &stub as *const _ as usize;
            let field = &stub.runnable as *const _ as usize;
            field - base
        };

        let field = task.as_ref().runnable as *const _ as usize;
        let base = field - runnable_offset;
        &*(base as *const Self)
    }

    unsafe fn waker_for(task: NonNull<Task>) -> Waker {
        unsafe fn waker_call(ptr: *const (), f: impl FnOnce(NonNull<Task>, &'static FutureVTable)) {
            let task = NonNull::new_unchecked(ptr as *mut Task);
            let vtable = FutureVTable::from_task(task);
            f(task, vtable)
        }

        static WAKER_VTABLE: RawWakerVTable = RawWakerVTable::new(
            |ptr| unsafe {
                waker_call(ptr, |task, vtable| (vtable.waker_clone)(task));
                RawWaker::new(ptr, &WAKER_VTABLE)
            },
            |ptr| unsafe {
                waker_call(ptr, |task, vtable| (vtable.waker_wake)(task, false));
            },
            |ptr| unsafe {
                waker_call(ptr, |task, vtable| (vtable.waker_wake)(task, true));
            },
            |ptr| unsafe {
                waker_call(ptr, |task, vtable| (vtable.waker_drop)(task));
            },
        );

        let ptr = &task as *const _ as *const ();
        let raw_waker = RawWaker::new(ptr, &WAKER_VTABLE);
        Waker::from_raw(raw_waker)
    }
}

type FutureError = Box<dyn Any + Send + Sync>;

struct FuturePending<F: Future> {
    task: UnsafeCell<Task>,
    future: UnsafeCell<MaybeUninit<F>>,
}

enum FutureData<F: Future> {
    Empty,
    Pending(FuturePending<F>),
    Ready(F::Output),
    Error(FutureError),
}

impl<F: Future> Drop for FutureData<F> {
    fn drop(&mut self) {
        match self {
            Self::Pending(ref pending) => unsafe {
                let mut maybe_fut = &mut *pending.future.get();
                drop_in_place(maybe_fut.as_mut_ptr());
            },
            _ => {},
        }
    }
}

pub(crate) struct FutureTask<F: Future> {
    ref_count: AtomicUsize,
    state: AtomicUsize,
    data: FutureData<F>,
    _pinned: PhantomPinned,
}

impl<F: Future> FutureTask<F> {
    const VTABLE: FutureVTable = FutureVTable {
        runnable: Runnable(Self::resume),
        waker_clone: Self::waker_clone,
        waker_wake: Self::waker_wake,
        waker_drop: Self::waker_drop,
        join_poll: Self::join_poll,
        join_drop: Self::join_drop,
    };

    unsafe fn waker_clone(task: NonNull<Task>) {
        Self::from_task(task).waker_clone_inner()
    }

    unsafe fn waker_wake(task: NonNull<Task>, by_ref: bool) {
        Self::from_task(task).waker_wake_inner(by_ref)
    }

    unsafe fn waker_drop(task: NonNull<Task>) {
        Self::from_task(task).waker_drop_inner()
    }

    unsafe fn join_poll(task: NonNull<Task>, inner: Pin<&JoinInner>, poll: *mut ()) {
        let poll = &mut *(poll as *mut Option<Poll<Result<F::Output, FutureError>>>);
        *poll = Some(Self::from_task(task).join_poll_inner(inner));
    }

    unsafe fn join_drop(task: NonNull<Task>, inner: Pin<&JoinInner>) {
        Self::from_task(task).join_drop_inner(inner)
    }

    unsafe fn from_task<'a>(task: NonNull<Task>) -> Pin<&'a Self> {
        let task_offset = {
            let stub = Self {
                ref_count: AtomicUsize::new(0),
                state: AtomicUsize::new(0),
                data: FutureData::Pending(FuturePending {
                    task: UnsafeCell::new(Task::from(&Runnable(|_, _| {}))),
                    future: UnsafeCell::new(MaybeUninit::uninit()),
                }),
                _pinned: PhantomPinned,
            };
            let stub = Pin::new_unchecked(&stub);
            let base = &*stub as *const _ as usize;
            let field = match stub.data {
                FutureData::Pending(ref pending) => pending.task.get() as usize,
                _ => unreachable!(),
            };
            forget(stub);
            field - base
        };

        let field = task.as_ptr() as usize;
        let base = field - task_offset;
        Pin::new_unchecked(&*(base as *const Self))
    }

    unsafe fn resume(task: Pin<&mut Task>, worker: Pin<&Worker>) {
        compile_error!("TODO")
    }

    fn waker_clone_inner(self: Pin<&Self>) {
        compile_error!("TODO")
    }

    fn waker_wake_inner(self: Pin<&Self>, by_ref: bool) {
        compile_error!("TODO")
    }

    fn waker_drop_inner(self: Pin<&Self>) {
        compile_error!("TODO")
    }

    fn join_poll_inner(
        self: Pin<&Self>,
        inner: Pin<&JoinInner>,
    ) -> Poll<Result<F::Output, FutureError>> {
        compile_error!("TODO")
    }

    fn join_drop_inner(self: Pin<&Self>, inner: Pin<&JoinInner>) {
        compile_error!("TODO")
    }
}

enum JoinWaker {
    Empty,
    Waiting(Waker),
    Cancelling(std::thread::Thread),
}

struct JoinInner {
    task: NonNull<Task>,
    state: AtomicUsize,
    waker: UnsafeCell<JoinWaker>,
    _pinned: PhantomPinned,
}

pub struct JoinHandle<T> {
    inner: JoinInner,
    _pinned: PhantomPinned,
    _phantom: PhantomData<T>,
}

impl<T> Drop for JoinHandle<T> {
    fn drop(&mut self) {
        unsafe {
            let inner = Pin::new_unchecked(&self.inner);
            let vtable = FutureVTable::from_task(self.inner.task);
            (vtable.join_drop)(self.inner.task, inner)
        }
    }
}

impl<T> Future for JoinHandle<T> {
    type Output = Result<T, FutureError>;

    fn poll(self: Pin<&mut Self>, _ctx: &mut Context<'_>) -> Poll<Self::Output> {
        unsafe {
            let inner = Pin::new_unchecked(&self.inner);
            let vtable = FutureVTable::from_task(self.inner.task);

            let mut poll: Option<Poll<Self::Output>> = None;
            (vtable.join_poll)(self.inner.task, inner, (&mut poll) as *mut _ as *mut _);

            poll.expect("FutureVTable::join_poll() did not fill in poll result")
        }
    }
}
