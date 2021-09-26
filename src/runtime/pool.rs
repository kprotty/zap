use super::{
    builder::Builder,
    idle::{IdleNode, IdleNodeProvider, IdleQueue},
    io::IoDriver,
    task::Task,
    worker::Worker,
};
use std::{
    mem,
    num::NonZeroUsize,
    pin::Pin,
    ptr::NonNull,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
};

#[allow(unused)]
#[derive(Debug)]
pub enum PoolEvent {
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

        (self.idle << (Self::COUNT_BITS + 4))
            | (self.spawned << 4)
            | (if self.notified { 0b100 } else { 0 })
            | match self.status {
                SyncStatus::Pending => 0b00,
                SyncStatus::Waking => 0b01,
                SyncStatus::Signaled => 0b10,
            }
    }
}

#[repr(align(8))]
pub struct Pool {
    sync: AtomicUsize,
    pending: AtomicUsize,
    injecting: AtomicUsize,
    idle_queue: IdleQueue,
    stack_size: Option<NonZeroUsize>,
    pub io_driver: IoDriver,
    pub workers: Pin<Box<[Worker]>>,
}

impl<'a> IdleNodeProvider for &'a Pool {
    fn with_node<T>(&self, index: usize, f: impl FnOnce(Pin<&IdleNode>) -> T) -> T {
        let idle_node = &self.workers()[index].idle_node;
        f(unsafe { Pin::new_unchecked(idle_node) })
    }
}

impl Pool {
    pub fn from_builder(builder: &Builder) -> Arc<Pool> {
        let num_threads = builder
            .max_threads
            .map(|threads| threads.get())
            .unwrap_or(0)
            .min(SyncState::COUNT_MASK)
            .max(1);

        Arc::new(Self {
            sync: AtomicUsize::new(0),
            pending: AtomicUsize::new(0),
            injecting: AtomicUsize::new(0),
            idle_queue: IdleQueue::default(),
            stack_size: builder.stack_size,
            io_driver: IoDriver::default(),
            workers: (0..num_threads)
                .map(|_| Worker::default())
                .collect::<Box<[Worker]>>()
                .into(),
        })
    }

    pub fn workers(&self) -> &[Worker] {
        &self.workers[..]
    }

    pub fn emit(&self, event: PoolEvent) {
        // TODO: Add custom tracing/handling here
        mem::drop(event)
    }

    pub fn next_inject_index(&self) -> usize {
        self.injecting.fetch_add(1, Ordering::Relaxed) % self.workers.len()
    }

    pub fn mark_task_begin(&self) {
        let pending = self.pending.fetch_add(1, Ordering::Relaxed);
        assert_ne!(pending, usize::MAX);
    }

    pub fn mark_task_end(&self) {
        let pending = self.pending.fetch_sub(1, Ordering::AcqRel);
        assert_ne!(pending, 0);

        if pending == 1 {
            self.workers_shutdown();
        }
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
                    return self.workers_notify();
                }

                if sync.spawned >= self.workers.len() {
                    return;
                }

                // Run the first worker using the caller's thread
                let worker_index = sync.spawned;
                if worker_index == 0 {
                    return self.with_worker(worker_index);
                }

                // Create a ThreadBuilder to spawn a worker thread
                let mut builder =
                    std::thread::Builder::new().name(String::from("zap-worker-thread"));
                if let Some(stack_size) = self.stack_size {
                    builder = builder.stack_size(stack_size.get());
                }

                let pool = Arc::clone(self);
                let join_handle = builder
                    .spawn(move || pool.with_worker(worker_index))
                    .expect("Failed to spawn a worker thread");

                mem::drop(join_handle);
                return;
            }
        }
    }

    #[cold]
    pub fn wait(self: &Arc<Self>, index: usize, mut is_waking: bool) -> Option<bool> {
        let mut is_idle = false;
        let result = loop {
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
                    break Some(is_waking || state.status == SyncStatus::Signaled);
                }

                assert!(!is_idle);
                is_idle = true;
                is_waking = false;

                self.emit(PoolEvent::WorkerIdling {
                    worker_index: index,
                });
            }

            match self.pending.load(Ordering::SeqCst) {
                0 => break None,
                _ => self.workers_wait(index),
            }
        };

        if is_idle {
            self.emit(PoolEvent::WorkerScheduled {
                worker_index: index,
            });
        }

        result
    }

    #[cold]
    fn workers_wait(&self, index: usize) {
        if self.io_driver.poll(None) {
            return;
        }

        self.idle_queue.wait(self, index, || {
            let sync: SyncState = self.sync.load(Ordering::Relaxed).into();
            !sync.notified
        });
    }

    #[cold]
    fn workers_notify(&self) {
        if !self.idle_queue.signal(self) {
            let _ = self.io_driver.notify();
        }
    }

    #[cold]
    fn workers_shutdown(&self) {
        let _ = self.io_driver.notify();
        self.idle_queue.shutdown(self)
    }
}
