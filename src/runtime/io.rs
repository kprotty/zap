use std::{cell::UnsafeCell, time::Duration};

struct PollerInner {
    io_poller: mio::Poll,
    io_events: mio::Events,
}

pub struct Poller {
    inner: UnsafeCell<PollerInner>,
    io_waker: mio::Waker,
}

unsafe impl Send for Poller {}
unsafe impl Sync for Poller {}

impl Default for Poller {
    fn default() -> Self {
        let inner = PollerInner {
            io_poller: mio::Poll::new().expect("failed to create os poller"),
            io_events: mio::Events::with_capacity(1024),
        };

        let io_waker = mio::Waker::new(inner.io_poller.registry(), mio::Token(0))
            .expect("failed to create os notification waker");

        Self {
            inner: UnsafeCell::new(inner),
            io_waker,
        }
    }
}

impl Poller {
    pub fn notify(&self) {
        self.io_waker.wake().expect("failed to wake up os notifier")
    }

    pub unsafe fn poll(&self, notified: &mut bool, timeout: Option<Duration>) -> usize {
        let inner = &mut *self.inner.get();
        if let Err(_) = inner.io_poller.poll(&mut inner.io_events, timeout) {
            return 0;
        }

        let mut resumed = 0;
        for event in &inner.io_events {
            let token = event.token();
            if token == mio::Token(0) {
                *notified = true;
                continue;
            }

            // TODO: notify Registered and inc resumed if was pending
            resumed += 1;
        }

        resumed
    }
}
