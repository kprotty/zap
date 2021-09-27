use super::{
    pool::Pool,
    waker::{AtomicWaker, WakerState, WakerUpdate},
};
use std::{
    cell::{Cell, UnsafeCell},
    future::Future,
    io,
    marker::PhantomPinned,
    mem,
    pin::Pin,
    ptr::{self, NonNull},
    sync::atomic::{AtomicPtr, AtomicUsize, Ordering},
    task::{Context, Poll, Waker},
    time::Duration,
};

struct IoNode {
    next: Cell<Option<NonNull<Self>>>,
    cache: Cell<Option<NonNull<IoNodeCache>>>,
    reader: AtomicWaker,
    writer: AtomicWaker,
    _pinned: PhantomPinned,
}

struct IoNodeBlock {
    _next: Cell<Option<Pin<Box<Self>>>>,
    nodes: [IoNode; Self::BLOCK_COUNT],
}

impl IoNodeBlock {
    const BLOCK_HEADER: usize = mem::size_of::<Cell<Option<Pin<Box<Self>>>>>();
    const BLOCK_COUNT: usize = ((64 * 1024) - Self::BLOCK_HEADER) / mem::size_of::<IoNode>();
}

impl IoNodeBlock {
    unsafe fn alloc(cache: &IoNodeCache, next: Option<Pin<Box<Self>>>) -> Pin<Box<Self>> {
        const EMPTY_NODE: IoNode = IoNode {
            next: Cell::new(None),
            cache: Cell::new(None),
            reader: AtomicWaker::new(),
            writer: AtomicWaker::new(),
            _pinned: PhantomPinned,
        };

        let block = Pin::into_inner_unchecked(Box::pin(Self {
            _next: Cell::new(next),
            nodes: [EMPTY_NODE; Self::BLOCK_COUNT],
        }));

        for index in 0..Self::BLOCK_COUNT {
            block.nodes[index].cache.set(Some(NonNull::from(cache)));
            block.nodes[index].next.set(match index + 1 {
                Self::BLOCK_COUNT => None,
                next => Some(NonNull::from(&block.nodes[next])),
            });
        }

        Pin::new_unchecked(block)
    }
}

#[derive(Default)]
struct IoNodeCacheInner {
    stack: Option<NonNull<IoNode>>,
    blocks: Option<Pin<Box<IoNodeBlock>>>,
}

#[derive(Default)]
pub struct IoNodeCache {
    free: AtomicPtr<IoNode>,
    inner: UnsafeCell<IoNodeCacheInner>,
}

unsafe impl Send for IoNodeCache {}
unsafe impl Sync for IoNodeCache {}

impl IoNodeCache {
    unsafe fn alloc(&self) -> NonNull<IoNode> {
        let inner = &mut *self.inner.get();
        let node = inner.stack.unwrap_or_else(|| {
            if !self.free.load(Ordering::Relaxed).is_null() {
                let free = self.free.swap(ptr::null_mut(), Ordering::Acquire);
                return NonNull::new(free).expect("free list was empty");
            }

            let block = IoNodeBlock::alloc(self, inner.blocks.take());
            let block = Pin::into_inner_unchecked(block);
            let node = NonNull::from(&block.nodes[0]);

            inner.blocks = Some(Pin::new_unchecked(block));
            node
        });

        inner.stack = node.as_ref().next.get();
        node
    }

    unsafe fn dealloc(&self, node: NonNull<IoNode>) {
        let mut free = self.free.load(Ordering::Relaxed);
        loop {
            node.as_ref().next.set(NonNull::new(free));
            match self.free.compare_exchange_weak(
                free,
                node.as_ptr(),
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Ok(_) => return,
                Err(e) => free = e,
            }
        }
    }
}

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
            let node = match NonNull::new(event.token().0 as *mut IoNode) {
                Some(node) => unsafe { &*node.as_ptr() },
                None => {
                    *notified = true;
                    continue;
                }
            };

            if event.is_writable() || event.is_write_closed() || event.is_error() {
                if node.writer.wake() == WakerState::Ready {
                    resumed += 1;
                }
            }

            if event.is_readable() || event.is_read_closed() || event.is_error() {
                if node.reader.wake() == WakerState::Ready {
                    resumed += 1;
                }
            }
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

impl IoState {
    const MAX_PENDING: usize = usize::MAX >> 2;
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
        assert!(self.pending <= Self::MAX_PENDING);
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
    fn prepare_pending(&self) {
        let mut state = IoState {
            pending: 1,
            status: IoStatus::Empty,
        };

        state = self
            .io_state
            .fetch_add(state.into(), Ordering::SeqCst)
            .into();

        assert_ne!(state.pending, IoState::MAX_PENDING);
    }

    fn cancel_pending(&self) {
        let mut state = IoState {
            pending: 1,
            status: IoStatus::Empty,
        };

        state = self
            .io_state
            .fetch_sub(state.into(), Ordering::SeqCst)
            .into();

        assert_ne!(state.pending, 0);
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

                self.io_state
                    .fetch_update(Ordering::Release, Ordering::Relaxed, |io_state| {
                        let mut io_state: IoState = io_state.into();
                        assert_ne!(io_state.status, IoStatus::Empty);

                        if io_state.status == IoStatus::Notified {
                            while !notified {
                                resumed += do_poll(&mut notified, None);
                            }
                        } else {
                            assert_eq!(
                                io_state.status,
                                match timeout {
                                    Some(Duration::ZERO) => IoStatus::Polling,
                                    _ => IoStatus::Waiting,
                                }
                            );
                        }

                        assert!(io_state.pending >= resumed);
                        io_state.pending -= resumed;

                        io_state.status = IoStatus::Empty;
                        Some(io_state.into())
                    })
            })
            .is_ok()
    }
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum IoKind {
    Read,
    Write,
}

pub struct IoSource<S: mio::event::Source> {
    io_source: S,
    io_node: NonNull<IoNode>,
    io_driver: NonNull<IoDriver>,
}

unsafe impl<S: mio::event::Source + Send> Send for IoSource<S> {}
unsafe impl<S: mio::event::Source + Sync> Sync for IoSource<S> {}

impl<S: mio::event::Source> AsRef<S> for IoSource<S> {
    fn as_ref(&self) -> &S {
        &self.io_source
    }
}

impl<S: mio::event::Source> Drop for IoSource<S> {
    fn drop(&mut self) {
        unsafe {
            let io_node = self.io_node.as_ref();
            let io_driver = self.io_driver.as_ref();

            self.detach_io(IoKind::Read);
            self.detach_io(IoKind::Write);
            let _ = io_driver.io_registry.deregister(&mut self.io_source);

            io_node
                .cache
                .get()
                .expect("IoNode without an IoNodeCache")
                .as_ref()
                .dealloc(self.io_node)
        }
    }
}

impl<S: mio::event::Source> IoSource<S> {
    pub fn new(mut source: S) -> Self {
        Pool::with_current(|pool, index| {
            let node = unsafe { pool.workers()[index].io_node_cache.alloc() };

            pool.io_driver
                .io_registry
                .register(
                    &mut source,
                    mio::Token(node.as_ptr() as usize),
                    mio::Interest::READABLE | mio::Interest::WRITABLE,
                )
                .expect("failed to register I/O source");

            Self {
                io_source: source,
                io_node: node,
                io_driver: NonNull::from(&pool.io_driver),
            }
        })
        .expect("IoSource::new() called outside the runtime")
    }

    fn unpack(&self, kind: IoKind) -> (&IoDriver, &AtomicWaker) {
        unsafe {
            let io_driver = self.io_driver.as_ref();
            let io_waker = match kind {
                IoKind::Read => &self.io_node.as_ref().reader,
                IoKind::Write => &self.io_node.as_ref().writer,
            };
            (io_driver, io_waker)
        }
    }

    pub unsafe fn poll_io<T>(
        &self,
        kind: IoKind,
        waker: &Waker,
        mut yield_now: impl FnMut() -> bool,
        mut do_io: impl FnMut() -> io::Result<T>,
    ) -> Poll<io::Result<T>> {
        let (io_driver, io_waker) = self.unpack(kind);
        loop {
            io_driver.prepare_pending();
            match io_waker.update(Some(waker)) {
                WakerUpdate::New => return Poll::Pending,
                WakerUpdate::Replaced => {
                    io_driver.cancel_pending();
                    return Poll::Pending;
                }
                WakerUpdate::Notified => {
                    io_driver.cancel_pending();
                }
            }

            if yield_now() {
                waker.wake_by_ref();
                return Poll::Pending;
            }

            loop {
                match do_io() {
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        io_waker.reset();
                        break;
                    }
                    result => return Poll::Ready(result),
                }
            }
        }
    }

    pub unsafe fn detach_io(&self, kind: IoKind) {
        let (io_driver, io_waker) = self.unpack(kind);
        if io_waker.update(None) == WakerUpdate::Replaced {
            io_driver.cancel_pending();
        }
    }

    pub unsafe fn wait_for<'a>(&'a self, kind: IoKind) -> impl Future<Output = ()> + 'a {
        struct WaitFor<'a, S: mio::event::Source> {
            source: Option<&'a IoSource<S>>,
            kind: IoKind,
        }

        impl<'a, S: mio::event::Source> Drop for WaitFor<'a, S> {
            fn drop(&mut self) {
                if let Some(source) = self.source.take() {
                    unsafe {
                        source.detach_io(self.kind);
                    }
                }
            }
        }

        impl<'a, S: mio::event::Source> Future for WaitFor<'a, S> {
            type Output = ();

            fn poll(mut self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
                let source = self.source.expect("wait_for polled after completion");
                let polled = unsafe { source.poll_io(self.kind, ctx.waker(), || false, || Ok(())) };

                match polled {
                    Poll::Pending => Poll::Pending,
                    Poll::Ready(Err(_)) => unreachable!(),
                    Poll::Ready(Ok(_)) => {
                        self.source = None;
                        Poll::Ready(())
                    }
                }
            }
        }

        WaitFor {
            source: Some(self),
            kind,
        }
    }
}

#[derive(Default)]
pub struct IoFairness {
    tick: u8,
}

impl IoFairness {
    pub unsafe fn poll_io<T, S: mio::event::Source>(
        &mut self,
        source: &IoSource<S>,
        kind: IoKind,
        waker: &Waker,
        do_io: impl FnMut() -> io::Result<T>,
    ) -> Poll<io::Result<T>> {
        let yield_now = || {
            let tick = self.tick;
            self.tick = tick.wrapping_add(1);
            match tick {
                0 => false,
                _ => tick % 128 == 0,
            }
        };

        source.poll_io(kind, waker, yield_now, do_io)
    }
}
