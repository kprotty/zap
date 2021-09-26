use super::{
    pool::{Pool, PoolEvent},
    waker::AtomicWaker,
};
use std::{
    cell::UnsafeCell,
    future::Future,
    marker::{PhantomData, PhantomPinned},
    mem::{self, MaybeUninit},
    pin::Pin,
    ptr::{self, NonNull},
    sync::{
        atomic::{AtomicPtr, AtomicUsize, Ordering},
        Arc,
    },
    task::{Context, Poll, RawWaker, RawWakerVTable, Waker},
};

pub struct Task {
    pub next: AtomicPtr<Self>,
    pub vtable: &'static TaskVTable,
    pub _pinned: PhantomPinned,
}

pub struct TaskVTable {
    pub clone_fn: unsafe fn(NonNull<Task>),
    pub drop_fn: unsafe fn(NonNull<Task>),
    pub wake_fn: unsafe fn(NonNull<Task>, bool),
    pub poll_fn: unsafe fn(NonNull<Task>, &Arc<Pool>, usize),
    pub join_fn: unsafe fn(NonNull<Task>, Option<(&Waker, *mut ())>) -> Poll<()>,
}

enum TaskData<F: Future> {
    Polling(F),
    Ready(F::Output),
    Joined,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum TaskStatus {
    Idle = 0,
    Scheduled = 1,
    Running = 2,
    Notified = 3,
    Ready = 4,
}

impl From<usize> for TaskStatus {
    fn from(value: usize) -> Self {
        match value {
            0 => Self::Idle,
            1 => Self::Scheduled,
            2 => Self::Running,
            3 => Self::Notified,
            4 => Self::Ready,
            _ => unreachable!("invalid TaskStatus"),
        }
    }
}

#[derive(Copy, Clone, Debug)]
struct TaskState {
    pool: Option<NonNull<Pool>>,
    status: TaskStatus,
}

impl From<usize> for TaskState {
    fn from(value: usize) -> Self {
        Self {
            pool: NonNull::new((value & !0b111usize) as *mut Pool),
            status: TaskStatus::from(value & 0b111),
        }
    }
}

impl Into<usize> for TaskState {
    fn into(self) -> usize {
        let pool = self.pool.map(|p| p.as_ptr() as usize).unwrap_or(0);
        let status = self.status as usize;
        pool | status
    }
}

pub struct TaskFuture<F: Future> {
    task: Task,
    waker: AtomicWaker,
    state: AtomicUsize,
    data: UnsafeCell<TaskData<F>>,
}

impl<F: Future> Drop for TaskFuture<F> {
    fn drop(&mut self) {
        let state: TaskState = self.state.load(Ordering::Relaxed).into();
        assert_eq!(state.status, TaskStatus::Ready);
        assert_eq!(state.pool, None);
    }
}

impl<F: Future> TaskFuture<F> {
    const TASK_VTABLE: TaskVTable = TaskVTable {
        clone_fn: Self::on_clone,
        drop_fn: Self::on_drop,
        wake_fn: Self::on_wake,
        poll_fn: Self::on_poll,
        join_fn: Self::on_join,
    };

    pub fn spawn(pool: &Arc<Pool>, worker_index: usize, future: F) -> JoinHandle<F::Output> {
        let this = Arc::pin(Self {
            task: Task {
                next: AtomicPtr::new(ptr::null_mut()),
                vtable: &Self::TASK_VTABLE,
                _pinned: PhantomPinned,
            },
            waker: AtomicWaker::default(),
            state: AtomicUsize::new(
                TaskState {
                    pool: Some(NonNull::from(pool.as_ref())),
                    status: TaskStatus::Scheduled,
                }
                .into(),
            ),
            data: UnsafeCell::new(TaskData::Polling(future)),
        });

        unsafe {
            let this = Pin::into_inner_unchecked(this);
            let task = NonNull::from(&this.task);
            mem::forget(this.clone()); // keep a reference for JoinHandle
            mem::forget(this); // keep a reference for ourselves

            pool.mark_task_begin();
            pool.emit(PoolEvent::TaskSpawned { worker_index, task });
            pool.push(Some(worker_index), task, false);

            JoinHandle {
                task: Some(task),
                _phantom: PhantomData,
            }
        }
    }

    unsafe fn from_task(task: NonNull<Task>) -> NonNull<Self> {
        let task_offset = {
            let stub = MaybeUninit::<Self>::uninit();
            let base_ptr = stub.as_ptr();
            let field_ptr = ptr::addr_of!((*base_ptr).task);
            (field_ptr as usize) - (base_ptr as usize)
        };

        let self_offset = (task.as_ptr() as usize) - task_offset;
        let self_ptr = NonNull::new(self_offset as *mut Self);
        self_ptr.expect("invalid Task ptr for container_of")
    }

    unsafe fn with<T>(task: NonNull<Task>, f: impl FnOnce(Pin<&Self>) -> T) -> T {
        let self_ptr = Self::from_task(task);
        f(Pin::new_unchecked(self_ptr.as_ref()))
    }

    unsafe fn on_clone(task: NonNull<Task>) {
        let this = Arc::from_raw(task.as_ptr());
        mem::forget(this.clone());
        mem::forget(this)
    }

    unsafe fn on_drop(task: NonNull<Task>) {
        let this = Arc::from_raw(task.as_ptr());
        mem::drop(this)
    }

    unsafe fn on_wake(task: NonNull<Task>, also_drop: bool) {
        let pool_ptr = match Self::with(task, |this| {
            this.state
                .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |state| {
                    let mut state: TaskState = state.into();
                    if state.status != TaskStatus::Ready {
                        assert_ne!(state.pool, None);
                    }

                    state.status = match state.status {
                        TaskStatus::Running => TaskStatus::Notified,
                        TaskStatus::Idle => TaskStatus::Scheduled,
                        _ => return None,
                    };
                    Some(state.into())
                })
                .map(TaskState::from)
        }) {
            Err(_) => None,
            Ok(state) => match state.status {
                TaskStatus::Running => None,
                TaskStatus::Idle => state.pool,
                status => unreachable!("invalid task status when waking {:?}", status),
            },
        };

        let be_fair = false;
        if let Some(pool_ptr) = pool_ptr {
            Pool::with_current(|pool, index| {
                // We're inside the pool, schedule from a worker thread
                pool.push(Some(index), task, be_fair)
            })
            .unwrap_or_else(|| {
                // We're outside the pool, schedule to a random worker thread.
                //
                // If we transitioned from TaskStatus::Idle to TaskStatus::Scheduled,
                // then the Pool must still be alive since the TaskFuture hasn't completed yet (Ready).
                //
                // This means it should be safe to deref the pool from here,
                // but we have to be careful not to drop the Arc<Pool> since it was never cloned.
                let pool = Arc::from_raw(pool_ptr.as_ptr());
                pool.push(None, task, be_fair);
                mem::forget(pool);
            });
        }

        if also_drop {
            Self::on_drop(task);
        }
    }

    unsafe fn on_poll(task: NonNull<Task>, pool: &Arc<Pool>, worker_index: usize) {
        let pool_ptr = NonNull::from(pool.as_ref());

        let poll_result = Self::with(task, |this| {
            let mut state: TaskState = this.state.load(Ordering::Relaxed).into();
            match state.status {
                TaskStatus::Scheduled | TaskStatus::Notified => {}
                TaskStatus::Idle => unreachable!("polling task when idle"),
                TaskStatus::Running => unreachable!("polling task when already running"),
                TaskStatus::Ready => unreachable!("polling task when already completed"),
            }

            assert_eq!(state.pool, Some(pool_ptr));
            state.status = TaskStatus::Running;
            this.state.store(state.into(), Ordering::Relaxed);

            pool.emit(PoolEvent::TaskPolling { worker_index, task });
            let poll_result = this.poll_future();
            pool.emit(PoolEvent::TaskPolled { worker_index, task });

            poll_result
        });

        let poll_output = match poll_result {
            Poll::Ready(output) => output,
            Poll::Pending => {
                match Self::with(task, |this| {
                    let current_state = TaskState {
                        pool: Some(pool_ptr),
                        status: TaskStatus::Running,
                    };

                    let new_state = TaskState {
                        pool: Some(pool_ptr),
                        status: TaskStatus::Idle,
                    };

                    this.state
                        .compare_exchange(
                            current_state.into(),
                            new_state.into(),
                            Ordering::AcqRel,
                            Ordering::Relaxed,
                        )
                        .map_err(TaskState::from)
                }) {
                    Ok(_) => {
                        return pool.emit(PoolEvent::TaskIdling { worker_index, task });
                    }
                    Err(state) => {
                        assert_eq!(state.pool, Some(pool_ptr));
                        assert_eq!(state.status, TaskStatus::Notified);
                        return pool.push(Some(worker_index), task, false);
                    }
                }
            }
        };

        Self::with(task, |this| {
            match mem::replace(&mut *this.data.get(), TaskData::Ready(poll_output)) {
                TaskData::Polling(future) => mem::drop(future),
                TaskData::Ready(_) => unreachable!("TaskData already had an output value"),
                TaskData::Joined => unreachable!("TaskData already joind when setting output"),
            }

            let new_state = TaskState {
                pool: None,
                status: TaskStatus::Ready,
            };

            this.state.store(new_state.into(), Ordering::Release);
            this.waker.wake();
        });

        pool.mark_task_end();
        pool.emit(PoolEvent::TaskShutdown { worker_index, task });
        Self::on_drop(task)
    }

    unsafe fn poll_future(&self) -> Poll<F::Output> {
        unsafe fn waker_vtable(ptr: *const (), f: impl FnOnce(&'static TaskVTable, NonNull<Task>)) {
            let task_ptr = ptr as *const Task as *mut Task;
            let task = NonNull::new(task_ptr).expect("invalid task ptr for Waker");
            let vtable = task.as_ref().vtable;
            f(vtable, task)
        }

        const WAKER_VTABLE: RawWakerVTable = RawWakerVTable::new(
            |ptr| unsafe {
                waker_vtable(ptr, |vtable, task| (vtable.clone_fn)(task));
                RawWaker::new(ptr, &WAKER_VTABLE)
            },
            |ptr| unsafe { waker_vtable(ptr, |vtable, task| (vtable.wake_fn)(task, true)) },
            |ptr| unsafe { waker_vtable(ptr, |vtable, task| (vtable.wake_fn)(task, false)) },
            |ptr| unsafe { waker_vtable(ptr, |vtable, task| (vtable.drop_fn)(task)) },
        );

        let ptr = NonNull::from(&self.task).as_ptr() as *const ();
        let raw_waker = RawWaker::new(ptr, &WAKER_VTABLE);
        let waker = Waker::from_raw(raw_waker);

        let poll_output = match &mut *self.data.get() {
            TaskData::Polling(ref mut future) => {
                let mut context = Context::from_waker(&waker);
                Pin::new_unchecked(future).poll(&mut context)
            }
            TaskData::Ready(_) => unreachable!("TaskData polled when already ready"),
            TaskData::Joined => unreachable!("TaskData polled when already joined"),
        };

        mem::forget(waker); // don't drop since we didn't clone it
        poll_output
    }

    unsafe fn on_join(task: NonNull<Task>, context: Option<(&Waker, *mut ())>) -> Poll<()> {
        let waker_ref = context.map(|c| c.0);
        let output_ptr = context
            .and_then(|c| NonNull::new(c.1))
            .map(|p| p.cast::<F::Output>());

        let updated_waker = Self::with(task, |this| this.waker.update(waker_ref));

        if updated_waker && waker_ref.is_some() {
            return Poll::Pending;
        }

        if let Some(output_ptr) = output_ptr {
            Self::with(task, |this| {
                let state: TaskState = this.state.load(Ordering::Acquire).into();
                assert_eq!(state.status, TaskStatus::Ready);
                assert_eq!(state.pool, None);

                match mem::replace(&mut *this.data.get(), TaskData::Joined) {
                    TaskData::Polling(_) => unreachable!("TaskData joined while still polling"),
                    TaskData::Ready(output) => ptr::write(output_ptr.as_ptr(), output),
                    TaskData::Joined => unreachable!("TaskData already joined when joining"),
                }
            });
        }

        Self::on_drop(task);
        Poll::Ready(())
    }
}

pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    Pool::with_current(|pool, worker_index| TaskFuture::spawn(pool, worker_index, future))
        .unwrap_or_else(|| unreachable!("spawn() called outside of thread pool"))
}

pub struct JoinHandle<T> {
    task: Option<NonNull<Task>>,
    _phantom: PhantomData<T>,
}

unsafe impl<T: Send> Send for JoinHandle<T> {}

impl<T> Drop for JoinHandle<T> {
    fn drop(&mut self) {
        if let Some(task) = self.task {
            unsafe {
                let vtable = task.as_ref().vtable;
                let _ = (vtable.join_fn)(task, None);
            }
        }
    }
}

impl<T> Future for JoinHandle<T> {
    type Output = T;

    fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
        unsafe {
            let mut_self = Pin::get_unchecked_mut(self);
            let task = mut_self.task.expect("JoinHandle polled after completion");

            let mut output = MaybeUninit::<T>::uninit();
            let join_context = (ctx.waker(), output.as_mut_ptr() as *mut ());

            let vtable = task.as_ref().vtable;
            if let Poll::Pending = (vtable.join_fn)(task, Some(join_context)) {
                return Poll::Pending;
            }

            mut_self.task = None;
            Poll::Ready(output.assume_init())
        }
    }
}
