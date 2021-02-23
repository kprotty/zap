

struct Pool {
    workers: Pin<Box<[Worker]>>,
    run_queues: [GlobalQueue; Priority::COUNT],
}


struct Worker {
    tick: Cell<u16>,
    xorshift: Cell<u16>,
    run_next: UnsafeCell<Batch>,
    run_queues: [LocalQueue; Priority::COUNT],
}

impl Worker {
    unsafe fn schedule(self: Pin<&Self>, priority: Priority, batch: impl Into<Batch>) {
        let batch = batch.into();
        if batch.is_empty() {
            return;
        }

        match priority {
            Priority::Handoff => (&mut *self.run_next.get()).push(batch),
            p => self.run_queues[p.as_index()].push(batch),
        }

        pool.notify();
    }

    unsafe fn poll(self: Pin<&Self>, pool: Pin<&Pool>) -> Option<NonNull<Task>> {
        let tick = self.tick.get();
        self.tick.set(tick.wrapping_add(1));

        if tick % 257 == 0 {
            if let Some(task) = self.poll_steal(pool, None) {
                return Some(task);
            }
        }
        
        if tick % 127 == 0 {
            if let Some(task) = self.poll_global(pool, None) {
                return Some(task);
            }
        }

        let polled_shared = tick % 61 == 0;
        if polled_shared {
            if let Some(task) = self.poll_shared(true) {
                return Some(task);
            }
        }

        let polled_resource = tick % 31 == 0; 
        if polled_resource {
            if let Some(task) = self.poll_resource() {
                return Some(task);
            }
        }

        if let Some(task) = (&mut *self.run_next.get()).pop() {
            return task;
        }

        if !polled_resource {
            if let Some(task) = self.poll_resource() {
                return Some(task);
            }
        }

        if !polled_shared {
            if let Some(task) = self.poll_shared(false) {
                return Some(task);
            }
        }

        for attempt in 0..4 {
            if let Some(task) = self.poll_global(pool, Some(attempt)) {
                return Some(task);
            }

            if let Some(task) = self.poll_steal(pool, Some(attempt)) {
                return Some(task);
            }
        }

        if let Some(task) = self.poll_global(pool, Some(attempt)) {
            return Some(task);
        }

        None
    }

    fn poll_shared(self: Pin<&Self>, be_fair: bool) -> Option<NonNull<Task>> {
        Self::priority_poll_order(be_fair)
            .iter()
            .filter_map(|priority| unsafe {
                self.run_queues[priority.as_index()].pop(be_fair)
            })
            .next()
    }

    fn poll_global(self: Pin<&Self>, pool: Pin<&Pool>, attempt: Option<u8>) -> Option<NonNull<Task>> {
        self.priority_steal_order(attempt)
            .iter()
            .filter_map(|priority| unsafe {
                let our_queue = self.map_unchecked(|this| &this.run_queues[priority.as_index()]);
                let target_queue = pool.map_unchecked(|p| &p.run_queues[priority.as_index()]);
                our_queue.pop_and_steal_global(target_queue)
            })
            .next()
    }

    fn poll_steal(self: Pin<&Self>, pool: Pin<&Pool>, attempt: Option<u8>) -> Option<NonNull<Task>> {
        let num_workers = pool.workers.len();
        (0..num_workers)
            .cycle()
            .skip({
                let mut xorshift = worker.xorshift.get();
                xorshift ^= xorshift << 7;
                xorshift ^= xorshift >> 9;
                xorshift ^= xorshift << 8;
                worker.xorshift.set(xorshift);
                (xorshift as usize) % num_workers
            })
            .take(num_workers)
            .filter_map(|worker_index| {
                let worker = Pin::new_unchecked(&pool.workers[worker_index]);
                if ptr::eq(&*self as *const Self, &*worker as *const Self) {
                    None
                } else {
                    Some(worker)
                }
            })
            .filter_map(|worker| {
                Self::priority_steal_order(attempt)
                    .iter()
                    .filter_map(|priority| {
                        let our_queue = self.map_unchecked(|this| &this.run_queues[priority.as_index()]);
                        let target_queue = worker.map_unchecked(|w| &w.run_queues[priority.as_index()]);
                        our_queue.pop_and_steal_local(target_queue)
                    })
                    .next()
            })
            .next()
    }  

    fn priority_steal_order(attempt: Option<u8>) -> &'static [Priority] {
        match attempt {
            Some(0) => &[Priority::High],
            Some(1) => &[Priority::High, Priority::Normal],
            _ => Self::priority_poll_order(attempt.is_none()),
        }
    }

    fn priority_poll_order(be_fair: bool) -> &'static [Priority] {
        if be_fair {
            &[Priority::Low, Priority::Normal, Priority::High]
        } else {
            &[Priority::High, Priority::Normal, Priority::Low]
        }
    }
}