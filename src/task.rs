use super::{
    pool::{Pool, PoolEvent},
    queue::Node,
    waker::AtomicWaker,
    worker::{Worker, WorkerRef},
};

use std::{
    cell::UnsafeCell,
    future::Future,
    marker::PhantomData,
    mem::{self, MaybeUninit},
    pin::Pin,
    ptr::{self, NonNull},
    sync::{
        atomic::{AtomicU8, AtomicUsize, Ordering},
        Arc,
    },
    task::{Context, Poll, RawWaker, RawWakerVTable, Waker},
};

pub struct Task {
    pub node: Node,
    pub vtable: &'static TaskVTable,
}

impl Task {
    pub fn from_node(node: NonNull<Node>) -> NonNull<Task> {
        let node_offset = unsafe {
            let stub = MaybeUninit::<Self>::uninit();
            let base_ptr = stub.as_ptr();
            let field_ptr = ptr::addr_of!((*(base_ptr)).node);
            (field_ptr as usize) - (base_ptr as usize)
        };

        let self_offset = (node.as_ptr() as usize) - node_offset;
        let self_ptr = NonNull::new(self_offset as *mut Self);
        self_ptr.expect("invalid Task ptr for container_of")
    }
}

pub struct TaskVTable {
    clone_fn: unsafe fn(NonNull<Task>),
    drop_fn: unsafe fn(NonNull<Task>),
    wake_fn: unsafe fn(NonNull<Task>, bool),
    pub poll_fn: unsafe fn(NonNull<Task>, &WorkerRef),
    join_fn: unsafe fn(NonNull<Task>, Option<(&Waker, *mut ())>) -> bool,
}

enum TaskData<F: Future> {
    Polling(F),
    Ready(F::Output),
    Joined,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum TaskState {
    Idle = 0,
    Scheduled = 1,
    Running = 2,
    Notified = 3,
    Ready = 4,
}

impl From<u8> for TaskState {
    fn from(value: u8) -> Self {
        match value {
            0 => Self::Idle,
            1 => Self::Scheduled,
            2 => Self::Running,
            3 => Self::Notified,
            4 => Self::Ready,
            _ => unreachable!("invalid TaskState"),
        }
    }
}

pub struct TaskFuture<F: Future> {
    task: Task,
    pool: Arc<Pool>,
    ref_count: AtomicUsize,
    data: UnsafeCell<TaskData<F>>,
    state: AtomicU8,
    waker: AtomicWaker,
}

impl<F: Future> TaskFuture<F> {
    const TASK_VTABLE: TaskVTable = TaskVTable {
        clone_fn: Self::on_clone,
        drop_fn: Self::on_drop,
        wake_fn: Self::on_wake,
        poll_fn: Self::on_poll,
        join_fn: Self::on_join,
    };

    pub fn spawn(future: F, worker_ref: &WorkerRef) -> JoinHandle<F::Output> {
        let pool = &worker_ref.pool;
        let worker_index = worker_ref.index;

        let this_ptr = NonNull::<Self>::from(Box::leak(Box::new(Self {
            task: Task {
                node: Node::default(),
                vtable: &Self::TASK_VTABLE,
            },
            pool: Arc::clone(pool),
            ref_count: AtomicUsize::new(2),
            data: UnsafeCell::new(TaskData::Polling(future)),
            state: AtomicU8::new(TaskState::Scheduled as u8),
            waker: AtomicWaker::default(),
        })));

        unsafe {
            let task = NonNull::from(&this_ptr.as_ref().task);

            pool.mark_task_begin();
            pool.emit(PoolEvent::TaskSpawned { worker_index, task });

            let be_fair = false;
            pool.schedule(Some(worker_index), task, be_fair);

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
            let field_ptr = ptr::addr_of!((*(base_ptr)).task);
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
        Self::with(task, |this| {
            let ref_count = this.ref_count.fetch_add(1, Ordering::Relaxed);
            assert_ne!(ref_count, usize::MAX);
            assert_ne!(ref_count, 0);
        })
    }

    unsafe fn on_drop(task: NonNull<Task>) {
        let dealloc = Self::with(task, |this| {
            let ref_count = this.ref_count.fetch_sub(1, Ordering::AcqRel);
            assert_ne!(ref_count, 0);
            ref_count == 1
        });

        if dealloc {
            Self::with(task, |this| {
                let state: TaskState = this.state.load(Ordering::Relaxed).into();
                assert_eq!(state, TaskState::Ready);
                assert!(this.waker.awoken());
            });

            let self_ptr = Self::from_task(task);
            mem::drop(Box::from_raw(self_ptr.as_ptr()));
        }
    }

    unsafe fn on_wake(task: NonNull<Task>, also_drop: bool) {
        let schedule = match Self::with(task, |this| {
            this.state
                .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |state| {
                    match state.into() {
                        TaskState::Running => Some(TaskState::Notified as u8),
                        TaskState::Idle => Some(TaskState::Scheduled as u8),
                        _ => None,
                    }
                })
                .map(TaskState::from)
        }) {
            Ok(TaskState::Running) => false,
            Ok(TaskState::Idle) => true,
            Ok(_) => unreachable!(),
            _ => false,
        };

        if schedule {
            let be_fair = false;
            match Worker::with_current(|worker_ref| {
                worker_ref
                    .pool
                    .schedule(Some(worker_ref.index), task, be_fair)
            }) {
                Ok(_) => {}
                Err(_) => Self::with(task, |this| this.pool.schedule(None, task, be_fair)),
            }
        }

        if also_drop {
            Self::on_drop(task);
        }
    }

    unsafe fn on_poll(task: NonNull<Task>, worker_ref: &WorkerRef) {
        let pool = &worker_ref.pool;
        let worker_index = worker_ref.index;

        let poll_result = Self::with(task, |this| {
            let state: TaskState = this.state.load(Ordering::Relaxed).into();
            match state {
                TaskState::Scheduled | TaskState::Notified => {}
                TaskState::Idle => unreachable!("polling task when idle"),
                TaskState::Running => unreachable!("polling task when already running"),
                TaskState::Ready => unreachable!("polling task when already completed"),
            }

            pool.emit(PoolEvent::TaskPolling { worker_index, task });
            this.state
                .store(TaskState::Running as u8, Ordering::Relaxed);

            let poll_result = this.poll_future();
            pool.emit(PoolEvent::TaskPolled { worker_index, task });
            poll_result
        });

        let poll_output = match poll_result {
            Poll::Ready(output) => output,
            Poll::Pending => {
                let become_idle = Self::with(task, |this| {
                    this.state
                        .compare_exchange(
                            TaskState::Running as u8,
                            TaskState::Idle as u8,
                            Ordering::AcqRel,
                            Ordering::Relaxed,
                        )
                        .map(TaskState::from)
                        .map_err(TaskState::from)
                });

                return match become_idle {
                    Ok(_) => pool.emit(PoolEvent::TaskIdling { worker_index, task }),
                    Err(TaskState::Notified) => {
                        let be_fair = true;
                        pool.schedule(Some(worker_index), task, be_fair)
                    }
                    Err(state) => {
                        unreachable!("invalid task state {:?} transitioning from idle", state)
                    }
                };
            }
        };

        Self::with(task, |this| {
            match mem::replace(&mut *this.data.get(), TaskData::Ready(poll_output)) {
                TaskData::Polling(future) => mem::drop(future),
                TaskData::Ready(_) => unreachable!("TaskData already had an output value"),
                TaskData::Joined => unreachable!("TaskData already joind when setting output"),
            }

            this.state.store(TaskState::Ready as u8, Ordering::Release);

            this.waker.wake();
            assert!(this.waker.awoken());
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

    unsafe fn on_join(task: NonNull<Task>, context: Option<(&Waker, *mut ())>) -> bool {
        let waker_ref = context.map(|c| c.0);
        let output_ptr = context.and_then(|c| NonNull::new(c.1 as *mut F::Output));

        let updated_waker = Self::with(task, |this| this.waker.update(waker_ref));

        if updated_waker && waker_ref.is_some() {
            return true;
        }

        if let Some(output_ptr) = output_ptr {
            Self::with(task, |this| {
                let state: TaskState = this.state.load(Ordering::Acquire).into();
                assert_eq!(state, TaskState::Ready);

                match mem::replace(&mut *this.data.get(), TaskData::Joined) {
                    TaskData::Polling(_) => unreachable!("TaskData joined while still polling"),
                    TaskData::Ready(output) => ptr::write(output_ptr.as_ptr(), output),
                    TaskData::Joined => unreachable!("TaskData already joined when joining"),
                }
            });
        }

        Self::on_drop(task);
        false
    }
}

pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    Worker::with_current(|worker_ref| TaskFuture::spawn(future, worker_ref))
        .unwrap_or_else(|_| unreachable!("spawn() was called outside of the runtime"))
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
            if (vtable.join_fn)(task, Some(join_context)) {
                return Poll::Pending;
            }

            mut_self.task = None;
            Poll::Ready(output.assume_init())
        }
    }
}
