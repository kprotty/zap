use super::pool::Pool;
use std::{
    cell::UnsafeCell,
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};

struct IoPoller {
    io_poll: mio::Poll,
    io_events: mio::Events,
}

impl IoPoller {
    pub fn poll(&mut self, notified: &mut bool, timeout: Option<Duration>) -> usize {
        if let Err(_) = self.io_poll.poll(&mut self.io_events, timeout) {
            return 0;
        }

        let mut resumed = 0;
        for event in &self.io_events {
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

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum IoStatus {
    Empty,
    Polling,
    Waiting,
    Notified,
}

#[derive(Copy, Clone, Debug)]
struct IoState {
    pending: usize,
    status: IoStatus,
}

impl From<usize> for IoState {
    fn from(value: usize) -> Self {
        Self {
            pending: value >> 2,
            status: match value & 0b11 {
                0 => IoStatus::Empty,
                1 => IoStatus::Polling,
                2 => IoStatus::Waiting,
                3 => IoStatus::Notified,
                _ => unreachable!(),
            },
        }
    }
}

impl Into<usize> for IoState {
    fn into(self) -> usize {
        assert!(self.pending <= usize::MAX >> 2);
        (self.pending << 2)
            | match self.status {
                IoStatus::Empty => 0,
                IoStatus::Polling => 1,
                IoStatus::Waiting => 2,
                IoStatus::Notified => 3,
            }
    }
}

pub struct IoDriver {
    io_state: AtomicUsize,
    io_waker: mio::Waker,
    io_registry: mio::Registry,
    io_poller: UnsafeCell<IoPoller>,
}

unsafe impl Send for IoDriver {}
unsafe impl Sync for IoDriver {}

impl Default for IoDriver {
    fn default() -> Self {
        let io_poller = IoPoller {
            io_poll: mio::Poll::new().expect("failed to create os poller"),
            io_events: mio::Events::with_capacity(1024),
        };

        let io_registry = io_poller
            .io_poll
            .registry()
            .try_clone()
            .expect("failed to clone os-poll registration");

        let io_waker = mio::Waker::new(&io_registry, mio::Token(0))
            .expect("failed to create os notification waker");

        Self {
            io_state: AtomicUsize::new(0),
            io_waker,
            io_registry,
            io_poller: UnsafeCell::new(io_poller),
        }
    }
}

impl IoDriver {
    pub fn with_current<T>(f: impl FnOnce(&IoDriver) -> T) -> Option<T> {
        Pool::with_current(|pool, _index| f(&pool.io_driver))
    }

    pub fn notify(&self) -> bool {
        self.io_state
            .fetch_update(Ordering::Release, Ordering::Relaxed, |io_state| {
                let mut io_state: IoState = io_state.into();
                if io_state.pending == 0 {
                    return None;
                }

                io_state.status = match io_state.status {
                    IoStatus::Waiting => IoStatus::Notified,
                    _ => return None,
                };

                Some(io_state.into())
            })
            .map(|_| self.io_waker.wake().expect("failed to wake up os notifier"))
            .is_ok()
    }

    pub fn poll(&self, timeout: Option<Duration>) -> bool {
        self.io_state
            .fetch_update(Ordering::Acquire, Ordering::Relaxed, |io_state| {
                let mut io_state: IoState = io_state.into();
                if io_state.pending == 0 {
                    return None;
                }

                io_state.status = match io_state.status {
                    IoStatus::Empty => match timeout {
                        Some(Duration::ZERO) => IoStatus::Polling,
                        _ => IoStatus::Waiting,
                    },
                    _ => return None,
                };

                Some(io_state.into())
            })
            .and_then(|_| {
                let do_poll = |notified: &mut bool, timeout: Option<Duration>| -> usize {
                    let io_poller = unsafe { &mut *self.io_poller.get() };
                    io_poller.poll(notified, timeout)
                };

                let mut notified = false;
                let mut resumed = do_poll(&mut notified, timeout);
                assert_eq!(notified, false);

                self.io_state
                    .fetch_update(Ordering::Release, Ordering::Relaxed, |io_state| {
                        let mut io_state: IoState = io_state.into();
                        assert_ne!(io_state.status, IoStatus::Empty);

                        if io_state.status == IoStatus::Notified {
                            while !notified {
                                resumed += do_poll(&mut notified, None);
                            }
                        }

                        assert!(io_state.pending >= resumed);
                        assert_eq!(
                            io_state.status,
                            match timeout {
                                Some(Duration::ZERO) => IoStatus::Polling,
                                _ => IoStatus::Waiting,
                            }
                        );

                        io_state.pending -= resumed;
                        io_state.status = IoStatus::Empty;
                        Some(io_state.into())
                    })
            })
            .is_ok()
    }
}
