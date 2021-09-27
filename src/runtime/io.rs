use super::{
    super::sync::low_level::Lock,
    pool::Pool,
    waker::{AtomicWaker, WakerUpdate},
};
use std::{
    cell::Cell,
    future::Future,
    io,
    marker::PhantomPinned,
    mem,
    pin::Pin,
    ptr::{self, NonNull},
    sync::{Arc, Once, atomic::{AtomicPtr, AtomicU8, Ordering}},
    task::{Context, Poll, Waker},
    time::Duration,
};

struct IoNode {
    next: Cell<Option<NonNull<Self>>>,
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
    unsafe fn alloc(next: Option<Pin<Box<Self>>>) -> Pin<Box<Self>> {
        const EMPTY_NODE: IoNode = IoNode {
            next: Cell::new(None),
            reader: AtomicWaker::new(),
            writer: AtomicWaker::new(),
            _pinned: PhantomPinned,
        };

        let block = Pin::into_inner_unchecked(Box::pin(Self {
            _next: Cell::new(next),
            nodes: [EMPTY_NODE; Self::BLOCK_COUNT],
        }));

        for index in 0..Self::BLOCK_COUNT {
            block.nodes[index].next.set(match index + 1 {
                Self::BLOCK_COUNT => None,
                next => Some(NonNull::from(&block.nodes[next])),
            });
        }

        Pin::new_unchecked(block)
    }
}

#[derive(Default)]
struct IoNodeCache {
    stack: Option<NonNull<IoNode>>,
    blocks: Option<Pin<Box<IoNodeBlock>>>,
}

unsafe impl Send for IoNodeCache {}
unsafe impl Sync for IoNodeCache {}

impl IoNodeCache {
    fn alloc(&mut self) -> NonNull<IoNode> {
        unsafe {
            let node = self.stack.unwrap_or_else(|| {
                let block = IoNodeBlock::alloc(self.blocks.take());
                let block = Pin::into_inner_unchecked(block);
                let node = NonNull::from(&block.nodes[0]);

                self.blocks = Some(Pin::new_unchecked(block));
                node
            });

            self.stack = node.as_ref().next.get();
            node
        }
    }

    unsafe fn dealloc(&mut self, node: NonNull<IoNode>) {
        node.as_ref().next.set(self.stack);
        self.stack = Some(node);
    }
}

struct IoPoller {
    io_poll: mio::Poll,
    io_events: mio::Events,
}

impl IoPoller {
    pub fn poll(&mut self, notified: &mut bool, timeout: Option<Duration>) {
        if let Err(_) = self.io_poll.poll(&mut self.io_events, timeout) {
            return;
        }

        for event in &self.io_events {
            let node = match NonNull::new(event.token().0 as *mut IoNode) {
                Some(node) => unsafe { &*node.as_ptr() },
                None => {
                    *notified = true;
                    continue;
                }
            };

            if event.is_writable() || event.is_write_closed() || event.is_error() {
                node.writer.wake();
            }

            if event.is_readable() || event.is_read_closed() || event.is_error() {
                node.reader.wake();
            }
        }
    }
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum IoNotify {
    Empty = 0,
    Waiting = 1,
    Notified = 2,
}

impl From<u8> for IoNotify {
    fn from(value: u8) -> Self {
        match value {
            0 => Self::Empty,
            1 => Self::Waiting,
            2 => Self::Notified,
            _ => unreachable!(),
        }
    }
}

struct IoDriverInner {
    io_notify: AtomicU8,
    io_waker: mio::Waker,
    io_registry: mio::Registry,
    io_poller: Lock<IoPoller>,
    io_node_cache: Lock<IoNodeCache>,
}

unsafe impl Send for IoDriverInner {}
unsafe impl Sync for IoDriverInner {}

impl Default for IoDriverInner {
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
            io_notify: AtomicU8::new(IoNotify::Empty as u8),
            io_waker,
            io_registry,
            io_poller: Lock::new(io_poller),
            io_node_cache: Lock::new(IoNodeCache::default()),
        }
    }
}

impl IoDriverInner {
    pub fn notify(&self) -> bool {
        self.io_notify
            .fetch_update(
                Ordering::Release,
                Ordering::Relaxed,
                |io_notify| match IoNotify::from(io_notify) {
                    IoNotify::Empty => Some(IoNotify::Notified as u8),
                    IoNotify::Waiting => Some(IoNotify::Notified as u8),
                    IoNotify::Notified => None,
                },
            )
            .map(IoNotify::from)
            .map(|io_notify| {
                io_notify == IoNotify::Waiting && {
                    self.io_waker.wake().expect("failed to wake up os notifier");
                    true
                }
            })
            .unwrap_or(false)
    }

    pub fn poll(&self, timeout: Option<Duration>) -> bool {
        self.io_poller
            .try_with(|io_poller| {
                let mut notified = false;
                if let Some(Duration::ZERO) = timeout {
                    io_poller.poll(&mut notified, timeout);
                    return true;
                }

                let io_notify: IoNotify = self.io_notify.load(Ordering::Acquire).into();
                if io_notify == IoNotify::Notified {
                    self.io_notify
                        .store(IoNotify::Empty as u8, Ordering::Relaxed);
                    return true;
                }

                if let Err(io_notify) = self.io_notify.compare_exchange(
                    IoNotify::Empty as u8,
                    IoNotify::Waiting as u8,
                    Ordering::Acquire,
                    Ordering::Acquire,
                ) {
                    let io_notify: IoNotify = io_notify.into();
                    assert_eq!(io_notify, IoNotify::Notified);
                    self.io_notify
                        .store(IoNotify::Empty as u8, Ordering::Relaxed);
                    return true;
                }

                io_poller.poll(&mut notified, timeout);

                if let Err(io_notify) = self.io_notify.compare_exchange(
                    IoNotify::Waiting as u8,
                    IoNotify::Empty as u8,
                    Ordering::Release,
                    Ordering::Relaxed,
                ) {
                    let io_notify: IoNotify = io_notify.into();
                    assert_eq!(io_notify, IoNotify::Notified);
                    self.io_notify
                        .store(IoNotify::Empty as u8, Ordering::Relaxed);
                    while !notified {
                        io_poller.poll(&mut notified, None);
                    }
                }

                true
            })
            .unwrap_or(false)
    }
}

pub struct IoDriver {
    inner: AtomicPtr<IoDriverInner>,
    once: Once,
}

impl Default for IoDriver {
    fn default() -> Self {
        Self {
            inner: AtomicPtr::new(ptr::null_mut()),
            once: Once::new(),
        }
    }
}

impl Drop for IoDriver {
    fn drop(&mut self) {
        if let Some(inner_ptr) = NonNull::new(self.inner.load(Ordering::Acquire)) {
            mem::drop(unsafe { Box::from_raw(inner_ptr.as_ptr()) });
        }
    }
}

impl IoDriver {
    pub fn notify(&self) -> bool {
        self.with_inner(|inner| inner.notify()).unwrap_or(false)
    }

    pub fn poll(&self, timeout: Option<Duration>) -> bool {
        self.with_inner(|inner| inner.poll(timeout)).unwrap_or(false)
    }

    fn with_inner<T>(&self, f: impl FnOnce(&IoDriverInner) -> T) -> Option<T> {
        NonNull::new(self.inner.load(Ordering::Acquire))
            .map(|inner_ptr| f(unsafe { inner_ptr.as_ref() }))
    }

    fn get_inner(&self) -> &IoDriverInner {
        self.once.call_once(|| {
            let inner = Box::into_raw(Box::new(IoDriverInner::default()));
            self.inner.store(inner, Ordering::Release);
        });

        unsafe {
            &*self.inner.load(Ordering::Acquire)
        }
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
    io_driver: Arc<IoDriver>,
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
            self.detach_io(IoKind::Read);
            self.detach_io(IoKind::Write);

            let io_driver = self.io_driver.as_ref().get_inner();
            let _ = io_driver.io_registry.deregister(&mut self.io_source);
            io_driver
                .io_node_cache
                .with(|cache| cache.dealloc(self.io_node));
        }
    }
}

impl<S: mio::event::Source> IoSource<S> {
    pub fn new(mut source: S) -> Self {
        Pool::with_current(|pool, _index| {
            let inner = pool.io_driver.get_inner();
            let node = inner.io_node_cache.with(|cache| cache.alloc());

            inner.io_registry
                .register(
                    &mut source,
                    mio::Token(node.as_ptr() as usize),
                    mio::Interest::READABLE | mio::Interest::WRITABLE,
                )
                .expect("failed to register I/O source");

            Self {
                io_source: source,
                io_node: node,
                io_driver: pool.io_driver.clone(),
            }
        })
        .expect("IoSource::new() called outside the runtime")
    }

    fn to_waker(&self, kind: IoKind) -> &AtomicWaker {
        unsafe {
            match kind {
                IoKind::Read => &self.io_node.as_ref().reader,
                IoKind::Write => &self.io_node.as_ref().writer,
            }
        }
    }

    pub unsafe fn poll_io<T>(
        &self,
        kind: IoKind,
        waker: &Waker,
        mut yield_now: impl FnMut() -> bool,
        mut do_io: impl FnMut() -> io::Result<T>,
    ) -> Poll<io::Result<T>> {
        let io_waker = self.to_waker(kind);
        loop {
            match io_waker.update(Some(waker)) {
                WakerUpdate::New => return Poll::Pending,
                WakerUpdate::Replaced => return Poll::Pending,
                WakerUpdate::Notified => {}
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
        let io_waker = self.to_waker(kind);
        io_waker.update(None);
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
