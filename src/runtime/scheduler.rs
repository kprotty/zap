use super::{ActiveList, Batch, IdleList, IdleNode, UnboundedQueue, Worker};
use std::{
    cell::Cell,
    convert::TryInto,
    marker::PhantomPinned,
    num::{NonZeroU16, NonZeroUsize},
    pin::Pin,
    ptr::NonNull,
    sync::atomic::{AtomicU32, Ordering},
};

#[derive(Copy, Clone, Eq, PartialEq)]
enum State {
    Pending,
    Notified,
    Waking,
    WakerNotified,
    Shutdown,
}

#[derive(Copy, Clone)]
struct Counter {
    spawned: u16,
    idle: u16,
    state: State,
}

impl Counter {
    const MAX: u16 = (1 << 14) - 1;
}

impl From<u32> for Counter {
    fn from(value: u32) -> Self {
        Self {
            spawned: ((value >> (4 + 14)) & 0xffff).try_into().unwrap(),
            idle: ((value >> 4) & 0xffff).try_into().unwrap(),
            state: match value & 0b1111 {
                0 => State::Pending,
                1 => State::Notified,
                2 => State::Waking,
                3 => State::WakerNotified,
                4 => State::Shutdown,
                _ => unreachable!(),
            },
        }
    }
}

impl Into<u32> for Counter {
    fn into(self) -> u32 {
        let mut value = 0;
        value |= (self.idle << 4) as u32;
        value |= (self.spawned << (4 + 14)) as u32;
        value |= match self.state {
            State::Pending => 0,
            State::Notified => 1,
            State::Waking => 2,
            State::WakerNotified => 3,
            State::Shutdown => 4,
        };
        value
    }
}

#[repr(align(4))]
pub(crate) struct Scheduler {
    stack_size: usize,
    max_workers: u16,
    counter: AtomicU32,
    idle_workers: IdleList,
    active_workers: ActiveList,
    coordinator: Cell<Option<std::thread::Thread>>,
    pub(crate) run_queue: UnboundedQueue,
    _pinned: PhantomPinned,
}

unsafe impl Send for Scheduler {}
unsafe impl Sync for Scheduler {}

impl Scheduler {
    pub(crate) fn new(max_workers: NonZeroU16, stack_size: NonZeroUsize) -> Self {
        Self {
            stack_size: stack_size.get(),
            max_workers: max_workers.get().min(Counter::MAX),
            counter: AtomicU32::new(0),
            idle_workers: IdleList::new(),
            active_workers: ActiveList::new(),
            coordinator: Cell::new(None),
            run_queue: UnboundedQueue::new(),
            _pinned: PhantomPinned,
        }
    }

    pub(crate) fn count_active_workers(self: Pin<&Self>) -> u16 {
        let counter = self.counter.load(Ordering::Relaxed);
        let Counter { spawned, idle, .. } = counter.into();
        debug_assert!(spawned >= idle);
        spawned - idle
    }

    pub(crate) fn workers<'a>(self: Pin<&'a Self>) -> impl Iterator<Item = Pin<&'a Worker>> + 'a {
        // SAFETY:
        // This materializes Pin<&Worker>s from Pin<&ActiveNode> using offsetof magic.
        // This is safe due to only `active_node`s from workers being present in the scheduler's ActiveList.
        unsafe {
            (&*NonNull::from(&*self).as_ptr())
                .active_workers
                .iter()
                .map(move |active_node| {
                    let node_offset = {
                        let stub = Worker::new(self, NonZeroUsize::new_unchecked(0));
                        let stub = Pin::new_unchecked(&stub);
                        let node_ptr = stub.active_node.get() as usize;
                        let worker_ptr = &*stub as *const _ as usize;
                        node_ptr - worker_ptr
                    };

                    let node_ptr = &*active_node as *const _ as usize;
                    let worker_ptr = node_ptr - node_offset;
                    Pin::new_unchecked(&*(worker_ptr as *const Worker))
                })
        }
    }

    fn run_worker(self: Pin<&Self>, spawn_id: u16) {
        unsafe {
            let mut is_waking = true;
            let is_coordinator = spawn_id == 0;
            let seed = NonZeroUsize::new((spawn_id + 1) as usize).unwrap();

            let worker = Worker::new(self, seed);
            let worker = Pin::new_unchecked(&worker);
            let owned_worker = worker.owned();

            self.active_workers.push({
                let active_node_ptr = owned_worker.worker.active_node.get();
                Pin::new_unchecked(&mut *active_node_ptr)
            });

            loop {
                if let Some(task) = owned_worker.poll() {
                    // If we find a task while we're waking, then we're no longer waking anymore.
                    // When transitioning out, we attempt to move the waking state to another Worker.
                    // The new waking worker will poll for tasks, possibly find work, and wake another Worker.
                    //
                    // This handoff of the waking state helps acts as a throttling mechanism for thread park/unpark
                    // to prevent thundering herd issues on contention when work stealing.
                    if is_waking {
                        self.notify_inner(is_waking);
                        is_waking = false;
                    }

                    (task.runnable.0)(task, worker);
                    continue;
                }

                match self.suspend(is_waking, is_coordinator, {
                    let idle_node_ptr = owned_worker.worker.idle_node.get();
                    Pin::new_unchecked(&mut *idle_node_ptr)
                }) {
                    Some(waking) => is_waking = waking,
                    None => break,
                }
            }
        }
    }

    pub(crate) fn schedule(self: Pin<&Self>, batch: impl Into<Batch>) {
        let batch: Batch = batch.into();
        if batch.empty() {
            return;
        }

        let run_queue = unsafe { Pin::new_unchecked(&self.run_queue) };
        run_queue.push(batch);
        self.notify();
    }

    pub(crate) fn notify(self: Pin<&Self>) {
        self.notify_inner(false);
    }

    fn notify_inner(self: Pin<&Self>, mut is_waking: bool) -> bool {
        let max_workers = self.max_workers;
        let mut remaining_attempts = 3;
        let mut counter: Counter = self.counter.load(Ordering::Relaxed).into();

        loop {
            if counter.state == State::Shutdown {
                return false;
            }

            let can_wake = counter.idle > 0 || counter.spawned < max_workers;
            if can_wake
                && ((is_waking && remaining_attempts > 0)
                    || (!is_waking && counter.state == State::Pending))
            {
                let mut new_counter = counter;
                new_counter.state = State::Waking;
                if counter.idle > 0 {
                    new_counter.idle -= 1;
                } else {
                    new_counter.spawned += 1;
                }

                if let Err(e) = self.counter.compare_exchange_weak(
                    counter.into(),
                    new_counter.into(),
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    counter = e.into();
                    continue;
                }

                if counter.idle > 0 {
                    self.idle_workers.notify();
                    return true;
                }

                if counter.spawned == 0 {
                    self.run_worker(counter.spawned);
                    return true;
                }

                let scheduler = &*self as *const _ as usize;
                if std::thread::Builder::new()
                    .stack_size(self.stack_size)
                    .spawn(move || unsafe {
                        let scheduler = scheduler as *const Scheduler;
                        let scheduler = Pin::new_unchecked(&*scheduler);
                        scheduler.run_worker(counter.spawned)
                    })
                    .is_ok()
                {
                    return true;
                }

                is_waking = true;
                remaining_attempts -= 1;
                counter = {
                    counter = Counter::from(0);
                    counter.spawned = 1;
                    self.counter
                        .fetch_sub(counter.into(), Ordering::Relaxed)
                        .into()
                };
                continue;
            }

            let mut new_counter = counter;
            new_counter.state = if is_waking && can_wake {
                State::Pending
            } else if is_waking || counter.state == State::Pending {
                State::Notified
            } else if counter.state == State::Waking {
                State::WakerNotified
            } else {
                return false;
            };

            match self.counter.compare_exchange_weak(
                counter.into(),
                new_counter.into(),
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Err(e) => counter = e.into(),
                Ok(_) => return true,
            }
        }
    }

    fn suspend(
        self: Pin<&Self>,
        is_waking: bool,
        is_coordinator: bool,
        idle_node: Pin<&mut IdleNode>,
    ) -> Option<bool> {
        let max_workers = self.max_workers;
        let mut counter: Counter = self.counter.load(Ordering::Relaxed).into();

        loop {
            let can_wake = counter.idle > 0 || counter.spawned < max_workers;
            let (is_shutdown, is_notified) = match counter.state {
                State::Shutdown => (true, false),
                State::Notified => (false, true),
                State::WakerNotified => (false, is_waking),
                _ => (false, false),
            };

            let mut new_counter = counter;
            if is_shutdown {
                new_counter.spawned -= 1;
            } else if is_notified {
                new_counter.state = if is_waking {
                    State::Waking
                } else {
                    State::Pending
                };
            } else {
                new_counter.state = if can_wake {
                    State::Pending
                } else {
                    State::Notified
                };
                new_counter.idle += 1;
            }

            if is_shutdown && is_coordinator {
                self.coordinator.set(Some(
                    self.coordinator
                        .replace(None)
                        .unwrap_or_else(|| std::thread::current()),
                ));
            }

            if let Err(e) = self.counter.compare_exchange_weak(
                counter.into(),
                new_counter.into(),
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                counter = e.into();
                continue;
            }

            if is_notified {
                return Some(is_waking);
            }

            if !is_shutdown {
                self.idle_workers.wait(idle_node);
                return Some(true);
            }

            if new_counter.spawned == 0 {
                self.coordinator
                    .replace(None)
                    .expect("scheduler shutting down without a coordinator")
                    .unpark();
            }

            if is_coordinator {
                loop {
                    counter = self.counter.load(Ordering::Acquire).into();
                    match counter.spawned {
                        0 => break,
                        _ => std::thread::park(),
                    }
                }
            }

            return None;
        }
    }
}
