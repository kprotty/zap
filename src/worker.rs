use super::{
    pool::{Pool, PoolEvent},
    queue::{Buffer, Injector, Popped as QueuePopped},
    task::Task,
};

use std::{cell::RefCell, mem, pin::Pin, ptr::NonNull, rc::Rc, sync::Arc};

struct Popped {
    task: NonNull<Task>,
    pushed: usize,
}

impl From<QueuePopped> for Popped {
    fn from(queue_popped: QueuePopped) -> Self {
        Self {
            task: Task::from_node(queue_popped.node),
            pushed: queue_popped.pushed,
        }
    }
}

#[derive(Default)]
pub struct Worker {
    pub buffer: Buffer,
    pub injector: Injector,
}

impl Worker {
    fn with_thread_local<T>(f: impl FnOnce(&mut Option<Rc<WorkerRef>>) -> T) -> T {
        thread_local!(static TLS_WORKER_REF: RefCell<Option<Rc<WorkerRef>>> = RefCell::new(None));
        TLS_WORKER_REF.with(|tls_worker_ref| f(&mut *tls_worker_ref.borrow_mut()))
    }

    pub fn with_current<T>(f: impl FnOnce(&WorkerRef) -> T) -> Result<T, ()> {
        match Self::with_thread_local(|tls_worker_ref| {
            tls_worker_ref.as_ref().map(|w| Rc::clone(w))
        }) {
            Some(worker_ref) => Ok(f(&*worker_ref)),
            None => Err(()),
        }
    }

    pub fn run(worker_ref: WorkerRef) {
        let worker_ref = Rc::new(worker_ref);

        let old_worker_ref = Self::with_thread_local(|tls_worker_ref| {
            mem::replace(tls_worker_ref, Some(Rc::clone(&worker_ref)))
        });

        worker_ref.execute();

        Self::with_thread_local(|tls_worker_ref| {
            *tls_worker_ref = old_worker_ref;
        })
    }
}

pub struct WorkerRef {
    pub pool: Arc<Pool>,
    pub index: usize,
}

impl WorkerRef {
    fn execute(&self) {
        let mut tick: usize = 0;
        let mut is_waking = false;
        let mut xorshift = 0xdeadbeef + self.index;

        self.pool.emit(PoolEvent::WorkerSpawned {
            worker_index: self.index,
        });

        while let Some(waking) = self.pool.wait(self.index, is_waking) {
            is_waking = waking;

            while let Some(popped) = {
                let be_fair = tick % 64 == 0;
                self.pop(&mut xorshift, be_fair)
            } {
                if is_waking || popped.pushed > 0 {
                    self.pool.notify(is_waking);
                    is_waking = false;
                }

                let task = popped.task;
                self.pool.emit(PoolEvent::TaskScheduled {
                    worker_index: self.index,
                    task,
                });

                tick = tick.wrapping_add(1);
                unsafe {
                    let vtable = task.as_ref().vtable;
                    (vtable.poll_fn)(task, self)
                }
            }
        }

        self.pool.emit(PoolEvent::WorkerShutdown {
            worker_index: self.index,
        });
    }

    fn pop(&self, xorshift: &mut usize, be_fair: bool) -> Option<Popped> {
        if be_fair {
            if let Some(popped) = self.consume(self.index) {
                return Some(popped);
            }
        }

        self.pop_local().or_else(|| self.pop_shared(xorshift))
    }

    fn pop_local(&self) -> Option<Popped> {
        self.pool.workers[self.index]
            .buffer
            .pop()
            .map(Popped::from)
            .map(|popped| {
                self.pool.emit(PoolEvent::WorkerPopped {
                    worker_index: self.index,
                    task: popped.task,
                });

                popped
            })
    }

    #[cold]
    fn pop_shared(&self, xorshift: &mut usize) -> Option<Popped> {
        if let Some(popped) = self.consume(self.index) {
            return Some(popped);
        }

        let shifts = match usize::BITS {
            32 => (13, 17, 5),
            64 => (13, 7, 17),
            _ => unreachable!("architecture unsupported"),
        };

        let mut rng = *xorshift;
        rng ^= rng << shifts.0;
        rng ^= rng >> shifts.1;
        rng ^= rng << shifts.2;
        *xorshift = rng;

        let num_workers = self.pool.workers.len();
        (0..num_workers)
            .cycle()
            .skip(rng % num_workers)
            .take(num_workers)
            .map(|steal_index| {
                self.consume(steal_index).or_else(|| match steal_index {
                    _ if steal_index == self.index => None,
                    _ => self.steal(steal_index),
                })
            })
            .filter_map(|popped| popped)
            .next()
    }

    #[cold]
    fn consume(&self, target_index: usize) -> Option<Popped> {
        self.pool.workers[self.index]
            .buffer
            .consume(unsafe { Pin::new_unchecked(&self.pool.workers[target_index].injector) })
            .map(Popped::from)
            .map(|popped| {
                self.pool.emit(PoolEvent::WorkerStole {
                    worker_index: self.index,
                    target_index,
                    count: popped.pushed + 1,
                });

                self.pool.emit(PoolEvent::WorkerPopped {
                    worker_index: self.index,
                    task: popped.task,
                });

                popped
            })
    }

    #[cold]
    fn steal(&self, target_index: usize) -> Option<Popped> {
        assert_ne!(self.index, target_index);
        self.pool.workers[self.index]
            .buffer
            .steal(&self.pool.workers[target_index].buffer)
            .map(Popped::from)
            .map(|popped| {
                self.pool.emit(PoolEvent::WorkerStole {
                    worker_index: self.index,
                    target_index,
                    count: popped.pushed + 1,
                });

                self.pool.emit(PoolEvent::WorkerPopped {
                    worker_index: self.index,
                    task: popped.task,
                });

                popped
            })
    }
}
