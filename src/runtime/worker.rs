use super::{
    pool::{Pool, PoolEvent},
    queue::{Buffer, Injector, List, Popped},
    task::Task,
};
use std::{
    cell::RefCell, mem, pin::Pin, ptr::NonNull, rc::Rc, sync::atomic::Ordering, sync::Arc,
    time::Duration,
};

#[derive(Default)]
pub struct Worker {
    injector: Injector,
    buffer: Buffer,
}

impl Pool {
    fn with_thread_local<T>(f: impl FnOnce(&mut Option<Rc<(Arc<Self>, usize)>>) -> T) -> T {
        thread_local!(static POOL_REF: RefCell<Option<Rc<(Arc<Pool>, usize)>>> = RefCell::new(None));
        POOL_REF.with(|pool_ref| f(&mut *pool_ref.borrow_mut()))
    }

    pub fn with_worker(self: &Arc<Self>, index: usize) {
        let old_pool_ref = Self::with_thread_local(|pool_ref| {
            let new_pool_ref = Rc::new((Arc::clone(self), index));
            mem::replace(pool_ref, Some(new_pool_ref))
        });

        self.run(index);

        Self::with_thread_local(|pool_ref| {
            *pool_ref = old_pool_ref;
        })
    }

    pub fn with_current<T>(f: impl FnOnce(&Arc<Self>, usize) -> T) -> Option<T> {
        Self::with_thread_local(|pool_ref| pool_ref.as_ref().map(|p| Rc::clone(p)))
            .map(|pool_ref| f(&pool_ref.0, pool_ref.1))
    }

    pub fn run(self: &Arc<Self>, index: usize) {
        let mut tick: usize = 0;
        let mut is_waking = false;
        let mut xorshift = 0xdeadbeef + index;

        self.emit(PoolEvent::WorkerSpawned {
            worker_index: index,
        });

        while let Some(waking) = self.wait(index, is_waking) {
            is_waking = waking;

            while let Some(popped) = {
                let be_fair = tick % 64 == 0;
                self.pop(index, &mut xorshift, be_fair)
            } {
                if is_waking || popped.pushed > 0 {
                    self.notify(is_waking);
                    is_waking = false;
                }

                let task = popped.task;
                self.emit(PoolEvent::TaskScheduled {
                    worker_index: index,
                    task,
                });

                tick = tick.wrapping_add(1);
                unsafe {
                    let vtable = task.as_ref().vtable;
                    (vtable.poll_fn)(task, self, index)
                }
            }
        }

        self.emit(PoolEvent::WorkerShutdown {
            worker_index: index,
        });
    }

    pub unsafe fn push(
        self: &Arc<Self>,
        index: Option<usize>,
        task: NonNull<Task>,
        mut be_fair: bool,
    ) {
        let index = index.unwrap_or_else(|| {
            be_fair = true;
            let inject_index = self.injecting.fetch_add(1, Ordering::Relaxed);
            inject_index % self.workers.len()
        });

        let injector = Pin::new_unchecked(&self.workers[index].injector);
        if be_fair {
            injector.push(List {
                head: task,
                tail: task,
            });
        } else {
            self.workers[index].buffer.push(task, injector);
        }

        self.emit(PoolEvent::WorkerPushed {
            worker_index: index,
            task,
        });

        let is_waking = false;
        self.notify(is_waking)
    }

    fn pop(self: &Arc<Self>, index: usize, xorshift: &mut usize, be_fair: bool) -> Option<Popped> {
        let popped = match be_fair {
            true => self.pop_queues(index).or_else(|| self.pop_local(index)),
            _ => self.pop_local(index).or_else(|| self.pop_queues(index)),
        };

        popped.or_else(|| self.pop_shared(index, xorshift))
    }

    fn pop_local(self: &Arc<Self>, index: usize) -> Option<Popped> {
        // TODO: add worker-local injector consume here

        self.workers[index].buffer.pop().map(|popped| {
            self.emit(PoolEvent::WorkerPopped {
                worker_index: index,
                task: popped.task,
            });

            popped
        })
    }

    fn pop_queues(self: &Arc<Self>, index: usize) -> Option<Popped> {
        if let Some(popped) = self.consume(index, index) {
            return Some(popped);
        }

        match self.io_poll(Some(Duration::ZERO)) {
            Some(n) if n > 0 => self.pop_local(index).or_else(|| self.consume(index, index)),
            _ => None,
        }
    }

    #[cold]
    fn pop_shared(self: &Arc<Self>, index: usize, xorshift: &mut usize) -> Option<Popped> {
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

        (0..self.workers.len())
            .cycle()
            .skip(rng % self.workers.len())
            .take(self.workers.len())
            .map(|steal_index| {
                self.consume(index, steal_index)
                    .or_else(|| match steal_index {
                        _ if steal_index == index => None,
                        _ => self.steal(index, steal_index),
                    })
            })
            .filter_map(|popped| popped)
            .next()
    }

    #[cold]
    fn consume(self: &Arc<Self>, index: usize, target_index: usize) -> Option<Popped> {
        self.workers[index]
            .buffer
            .consume(unsafe { Pin::new_unchecked(&self.workers[target_index].injector) })
            .map(|popped| {
                self.emit(PoolEvent::WorkerStole {
                    worker_index: index,
                    target_index,
                    count: popped.pushed + 1,
                });

                self.emit(PoolEvent::WorkerPopped {
                    worker_index: index,
                    task: popped.task,
                });

                popped
            })
    }

    #[cold]
    fn steal(self: &Arc<Self>, index: usize, target_index: usize) -> Option<Popped> {
        assert_ne!(index, target_index);
        self.workers[index]
            .buffer
            .steal(&self.workers[target_index].buffer)
            .map(|popped| {
                self.emit(PoolEvent::WorkerStole {
                    worker_index: index,
                    target_index,
                    count: popped.pushed + 1,
                });

                self.emit(PoolEvent::WorkerPopped {
                    worker_index: index,
                    task: popped.task,
                });

                popped
            })
    }
}
