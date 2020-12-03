use super::{Task, Runnable};
use std::{
    any::Any,
    future::Future,
    pin::Pin,
    cell::UnsafeCell,
    marker::{PhantomPinned, PhantomData},
    task::{Waker, RawWaker, RawWakerVTable, Poll, Context},
    sync::atomic::{AtomicUsize, Ordering},
};

type FutureError = Box<dyn Any + Send + Sync>;

#[repr(C, usize)]
enum FutureData<F: Future> {
    Empty,
    Pending(F),
    Ready(F::Output),
    Error(FutureError),
}

struct FutureVTable<T> {
    runnable: Runnable,
    waker_clone: unsafe fn(Pin<&Task>),
    waker_wake: unsafe fn(Pin<&Task>, bool),
    waker_drop: unsafe fn(Pin<&Task>),
    join_handle_poll: unsafe fn(Pin<&Task>, Pin<&JoinHandle<T>>) -> Poll<T, FutureError>,
    join_handle_drop: unsafe fn(Pin<&Task>, Pin<&JoinHandle<T>>),
}

impl<T> FutureVTable<T> {
    unsafe fn from_task(task: NonNull<Task>) -> &'static Self {
        let runnable_offset = {
            let stub = Self {
                runnable: Runnable(|_, _| unreachable!()),
                waker_clone: |_| unreachable!(),
                waker_wake: |_, _| unreachable!(),
                waker_drop: |_| unreachable!(),
                join_handle_poll: |_, _| unreachable!(),
                join_handle_drop: |_, _| unreachable!(),
            };
            let base = &stub as *const _ as usize;
            let field = &stub.runnable as *const _ as usize;
            field - base
        };
        
        let field = task.as_ref().runnable as *const _ as usize;
        let base = field - runnable_offset;
        &*(base as *const Self)
    }

    fn waker(task: NonNull<Task>) -> Waker {
        unsafe fn waker_call<F>(ptr: *const (), f: impl FnOnce(Pin<&Task>, &'static Self) -> F) -> F {
            let task = NonNull::new_unchecked(ptr as *mut Task);
            let vtable = Self::from_task(task);
            f(Pin::new_unchecked(task.as_ref()), vtable)
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

        let ptr = task.as_ptr() as *const ();
        let raw_waker = RawWaker::new(ptr, &WAKER_VTABLE);
        Waker::from_raw(raw_waker)
    }
}

pub(crate) struct FutureTask<F: Future> {
    ref_count: AtomicUsize,
    task: UnsafeCell<Task>,
    data: FutureData<F>,
}

impl<F: Future> FutureTask<F> {
    unsafe fn from_task(task: Pin<&Task>) -> Pin<&Self> {
        let task_offset = {
            let stub = Self {
                ref_count: AtomicUsize::new(0),
                task: UnsafeCell::new(Task::from(&Runnable(|_, _| {}))),
                data: FutureData::<F>::Empty,
            };
            let base = &stub as *const _ as usize;
            let field = stub.task.get() as *const _ as usize;
            field - base
        };
        
        let field = &*task as *const _ as usize;
        let base = field - task_offset;
        &*(base as *const Self)
    }
}

enum JoinWaker {
    Empty,
    Waiting(Waker),
    Cancelling(std::thread::Thread),
}

pub struct JoinHandle<T> {
    task: NonNull<Task>,
    state: AtomicUsize,
    waker: UnsafeCell<JoinWaker>,
    _phantom: PhantomData<T>,
}

impl<T> Drop for JoinHandle<T> {
    fn drop(&mut self) {
        unsafe {
            let vtable = FutureVTable::from_task(self.task);
            (vtable.join_handle_drop)(
                Pin::new_unchecked(self.task.as_ref()),
                Pin::new_unchecked(self),
            );
        }
    }
}

impl<T> Future for JoinHandle<T> {
    type Output = Result<T, FutureError>;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        unsafe {
            let vtable = FutureVTable::from_task(self.task);
            (vtable.join_handle_poll)(
                Pin::new_unchecked(self.task.as_ref()),
                Pin::new_unchecked(self),
            )
        }
    }
}