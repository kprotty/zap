use super::{
    builder::Builder,
    queue::List,
    task::Task,
    worker::{Worker, WorkerRef},
};
use std::{
    mem,
    num::NonZeroUsize,
    pin::Pin,
    ptr::NonNull,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Condvar, Mutex,
    },
};

#[allow(unused)]
#[derive(Debug)]
pub(crate) enum PoolEvent {
    TaskSpawned {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskIdling {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskScheduled {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskPolling {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskPolled {
        worker_index: usize,
        task: NonNull<Task>,
    },
    TaskShutdown {
        worker_index: usize,
        task: NonNull<Task>,
    },
    WorkerSpawned {
        worker_index: usize,
    },
    WorkerPushed {
        worker_index: usize,
        task: NonNull<Task>,
    },
    WorkerPopped {
        worker_index: usize,
        task: NonNull<Task>,
    },
    WorkerStole {
        worker_index: usize,
        target_index: usize,
        count: usize,
    },
    WorkerIdling {
        worker_index: usize,
    },
    WorkerScheduled {
        worker_index: usize,
    },
    WorkerShutdown {
        worker_index: usize,
    },
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum SyncStatus {
    Pending,
    Waking,
    Signaled,
}

#[derive(Copy, Clone, Debug)]
struct SyncState {
    status: SyncStatus,
    notified: bool,
    spawned: usize,
    idle: usize,
}

impl SyncState {
    const COUNT_BITS: u32 = (usize::BITS - 4) / 2;
    const COUNT_MASK: usize = (1 << Self::COUNT_BITS) - 1;
}

impl From<usize> for SyncState {
    fn from(value: usize) -> Self {
        Self {
            status: match value & 0b11 {
                0b00 => SyncStatus::Pending,
                0b01 => SyncStatus::Waking,
                0b10 => SyncStatus::Signaled,
                _ => unreachable!("invalid sync-status"),
            },
            notified: value & 0b100 != 0,
            spawned: (value >> 4) & Self::COUNT_MASK,
            idle: (value >> (Self::COUNT_BITS + 4)) & Self::COUNT_MASK,
        }
    }
}

impl Into<usize> for SyncState {
    fn into(self) -> usize {
        assert!(self.idle <= Self::COUNT_MASK);
        assert!(self.spawned <= Self::COUNT_MASK);

        let mut value = 0;
        value |= self.idle << (Self::COUNT_BITS + 4);
        value |= self.spawned << 4;

        if self.notified {
            value |= 0b100;
        }

        value
            | match self.status {
                SyncStatus::Pending => 0b00,
                SyncStatus::Waking => 0b01,
                SyncStatus::Signaled => 0b10,
            }
    }
}

pub struct Pool {
    idle_cond: Condvar,
    idle_sema: Mutex<usize>,
    stack_size: Option<NonZeroUsize>,
    sync: AtomicUsize,
    pending: AtomicUsize,
    injecting: AtomicUsize,
    pub workers: Box<[Worker]>,
}

impl Pool {
    pub fn from_builder(builder: &Builder) -> Arc<Pool> {
        let num_threads = builder
            .max_threads
            .map(|t| t.get())
            .unwrap_or(0)
            .min(SyncState::COUNT_MASK)
            .max(1);

        Arc::new(Self {
            idle_cond: Condvar::new(),
            idle_sema: Mutex::new(0),
            stack_size: builder.stack_size,
            sync: AtomicUsize::new(0),
            pending: AtomicUsize::new(0),
            injecting: AtomicUsize::new(0),
            workers: (0..num_threads)
                .map(|_| Worker::default())
                .collect::<Vec<_>>()
                .into_boxed_slice(),
        })
    }

    pub(crate) fn emit(self: &Arc<Self>, event: PoolEvent) {
        // TODO: Add custom tracing/handling here
        mem::drop(event)
    }

    pub fn mark_task_begin(self: &Arc<Self>) {
        let pending = self.pending.fetch_add(1, Ordering::Relaxed);
        assert_ne!(pending, usize::MAX);
    }

    pub fn mark_task_end(self: &Arc<Self>) {
        let pending = self.pending.fetch_sub(1, Ordering::AcqRel);
        assert_ne!(pending, 0);

        if pending == 1 {
            self.idle_post(self.workers.len());
        }
    }

    pub unsafe fn schedule(
        self: &Arc<Self>,
        worker_index: Option<usize>,
        task: NonNull<Task>,
        mut be_fair: bool,
    ) {
        let node = NonNull::from(&task.as_ref().node);
        let list = List {
            head: node,
            tail: node,
        };

        let index = worker_index.unwrap_or_else(|| {
            be_fair = true;
            let inject_index = self.injecting.fetch_add(1, Ordering::Relaxed);
            inject_index % self.workers.len()
        });

        let injector = Pin::new_unchecked(&self.workers[index].injector);
        if be_fair {
            injector.push(list);
        } else {
            self.workers[index].buffer.push(node, injector);
        }

        if let Some(worker_index) = worker_index {
            self.emit(PoolEvent::WorkerPushed { worker_index, task });
        }

        let is_waking = false;
        self.notify(is_waking)
    }

    #[cold]
    pub fn notify(self: &Arc<Self>, is_waking: bool) {
        let result = self
            .sync
            .fetch_update(Ordering::Release, Ordering::Relaxed, |state| {
                let mut state: SyncState = state.into();
                assert!(state.idle <= state.spawned);
                if is_waking {
                    assert_eq!(state.status, SyncStatus::Waking);
                }

                let can_wake = is_waking || state.status == SyncStatus::Pending;
                if can_wake && state.idle > 0 {
                    state.status = SyncStatus::Signaled;
                } else if can_wake && state.spawned < self.workers.len() {
                    state.status = SyncStatus::Signaled;
                    state.spawned += 1;
                } else if is_waking {
                    state.status = SyncStatus::Pending;
                } else if state.notified {
                    return None;
                }

                state.notified = true;
                Some(state.into())
            });

        if let Ok(sync) = result.map(SyncState::from) {
            if is_waking || sync.status == SyncStatus::Pending {
                if sync.idle > 0 {
                    return self.idle_post(1);
                }

                if sync.spawned >= self.workers.len() {
                    return;
                }

                let worker_ref = WorkerRef {
                    pool: Arc::clone(self),
                    index: sync.spawned,
                };

                // Run the first worker using the caller's thread
                if worker_ref.index == 0 {
                    return Worker::run(worker_ref);
                }

                // Create a ThreadBuilder to spawn a worker thread
                let mut builder = std::thread::Builder::new().name(String::from("zap-worker"));
                if let Some(stack_size) = self.stack_size {
                    builder = builder.stack_size(stack_size.get());
                }

                let join_handle = builder
                    .spawn(move || Worker::run(worker_ref))
                    .expect("Failed to spawn a worker thread");

                mem::drop(join_handle);
                return;
            }
        }
    }

    #[cold]
    pub fn wait(self: &Arc<Self>, worker_index: usize, mut is_waking: bool) -> Option<bool> {
        let mut is_idle = false;
        loop {
            let result = self
                .sync
                .fetch_update(Ordering::Acquire, Ordering::Relaxed, |state| {
                    let mut state: SyncState = state.into();
                    if is_waking {
                        assert_eq!(state.status, SyncStatus::Waking);
                    }

                    assert!(state.idle <= state.spawned);
                    if !is_idle {
                        assert!(state.idle < state.spawned);
                    }

                    if state.notified {
                        if state.status == SyncStatus::Signaled {
                            state.status = SyncStatus::Waking;
                        }
                        if is_idle {
                            state.idle -= 1;
                        }
                    } else if !is_idle {
                        state.idle += 1;
                        if is_waking {
                            state.status = SyncStatus::Pending;
                        }
                    } else {
                        return None;
                    }

                    state.notified = false;
                    Some(state.into())
                });

            if let Ok(state) = result.map(SyncState::from) {
                if state.notified {
                    return Some(is_waking || state.status == SyncStatus::Signaled);
                }

                assert!(!is_idle);
                is_idle = true;
                is_waking = false;
            }

            match self.pending.load(Ordering::SeqCst) {
                0 => return None,
                _ => self.idle_wait(worker_index),
            }
        }
    }

    #[cold]
    fn idle_wait(self: &Arc<Self>, worker_index: usize) {
        self.emit(PoolEvent::WorkerIdling { worker_index });

        {
            let mut idle_sema = self.idle_sema.lock().unwrap();
            while *idle_sema == 0 {
                idle_sema = self.idle_cond.wait(idle_sema).unwrap();
            }
            *idle_sema -= 1;
        }

        self.emit(PoolEvent::WorkerScheduled { worker_index });
    }

    #[cold]
    fn idle_post(self: &Arc<Self>, waiting: usize) {
        let mut idle_sema = self.idle_sema.lock().unwrap();
        *idle_sema = idle_sema
            .checked_add(waiting)
            .expect("idle semaphore count overflowed");

        match waiting {
            1 => self.idle_cond.notify_one(),
            _ => self.idle_cond.notify_all(),
        }
    }
}
