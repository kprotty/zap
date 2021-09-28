use super::{AtomicWaker, AutoResetEvent, Lock, WakerUpdate};
use std::{
    cell::Cell,
    future::Future,
    marker::PhantomPinned,
    pin::Pin,
    ptr::NonNull,
    task::{Context, Poll, RawWaker, RawWakerVTable, Waker},
};

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct WaitToken(pub usize);

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct WakeToken(pub usize);

struct WaitNode {
    key: usize,
    key_prev: Cell<Option<NonNull<Self>>>,
    key_next: Cell<Option<NonNull<Self>>>,
    prev: Cell<Option<NonNull<Self>>>,
    next: Cell<Option<NonNull<Self>>>,
    tail: Cell<Option<NonNull<Self>>>,
    inserted: Cell<bool>,
    token: Cell<WaitToken>,
    waker: AtomicWaker,
    _pinned: PhantomPinned,
}

struct WaitListIter {
    current: Option<NonNull<WaitNode>>,
}

impl Iterator for WaitListIter {
    type Item = NonNull<WaitNode>;

    fn next(&mut self) -> Option<Self::Item> {
        let node = self.current?;
        self.current = unsafe { node.as_ref().next.get() };
        Some(node)
    }
}

struct WaitList<'a> {
    bucket: &'a mut WaitBucket,
    key: usize,
    key_prev: Option<NonNull<WaitNode>>,
    head: Option<NonNull<WaitNode>>,
}

impl<'a> WaitList<'a> {
    fn iter(&self) -> WaitListIter {
        WaitListIter { current: self.head }
    }

    fn is_empty(&self) -> bool {
        self.head.is_none()
    }

    unsafe fn insert(&mut self, node: NonNull<WaitNode>) {
        assert_eq!(node.as_ref().key, self.key);
        assert!(!node.as_ref().inserted.get());

        node.as_ref().next.set(None);
        node.as_ref().inserted.set(true);

        if let Some(head) = self.head {
            let tail = head.as_ref().tail.get().expect("head without tail");
            tail.as_ref().next.set(Some(node));
            node.as_ref().prev.set(Some(tail));
            head.as_ref().tail.set(Some(node));
        } else {
            node.as_ref().prev.set(None);
            node.as_ref().tail.set(Some(node));
            node.as_ref().key_next.set(None);
            node.as_ref().key_prev.set(self.key_prev);

            self.head = Some(node);
            if let Some(key_prev) = self.key_prev {
                key_prev.as_ref().key_next.set(Some(node));
            } else {
                self.bucket.root = Some(node);
            }
        }
    }

    unsafe fn try_remove(&mut self, node: NonNull<WaitNode>) -> bool {
        assert_eq!(node.as_ref().key, self.key);
        if !node.as_ref().inserted.replace(false) {
            return false;
        }

        let head = self.head.expect("node inserted but queue is empty");
        let prev = node.as_ref().prev.get();
        let next = node.as_ref().next.get();

        if let Some(prev) = prev {
            assert_ne!(node, head);
            prev.as_ref().next.set(next);
            if let Some(next) = next {
                next.as_ref().prev.set(Some(prev));
            } else {
                assert_eq!(Some(node), head.as_ref().tail.get());
                head.as_ref().tail.set(Some(prev));
            }
            return true;
        }

        assert_eq!(head, node);
        self.head = next;

        let head = next;
        let key_prev = node.as_ref().key_prev.get();
        let key_next = node.as_ref().key_next.get();

        if let Some(new_head) = head {
            assert_eq!(self.key, new_head.as_ref().key);
            new_head.as_ref().tail.set(node.as_ref().tail.get());
            new_head.as_ref().key_prev.set(key_prev);
            new_head.as_ref().key_next.set(key_next);
        }

        if let Some(key_next) = key_next {
            assert_ne!(self.key, key_next.as_ref().key);
            key_next.as_ref().key_prev.set(head.or(key_prev));
        }
        if let Some(key_prev) = key_prev {
            assert_ne!(self.key, key_prev.as_ref().key);
            key_prev.as_ref().key_next.set(head.or(key_next));
        } else {
            assert_eq!(self.bucket.root, Some(node));
            self.bucket.root = head.or(key_next);
        }

        true
    }
}

struct WaitBucket {
    root: Option<NonNull<WaitNode>>,
}

impl WaitBucket {
    const fn new() -> Self {
        Self { root: None }
    }

    pub fn list_for(&mut self, key: usize) -> WaitList<'_> {
        let mut head = self.root;
        let mut key_prev = None;

        while let Some(waiter) = head {
            let waiter = unsafe { waiter.as_ref() };
            if waiter.key == key {
                break;
            }

            key_prev = head;
            head = waiter.key_next.get();
        }

        WaitList {
            bucket: self,
            key,
            key_prev,
            head,
        }
    }
}

pub struct WaitQueue {
    bucket: Lock<WaitBucket>,
}

impl WaitQueue {
    pub const fn new() -> Self {
        Self {
            bucket: Lock::new(WaitBucket::new()),
        }
    }

    #[cold]
    pub async fn wait<V, C>(&self, key: usize, validate: V, cancelled: C) -> Option<WakeToken>
    where
        V: FnOnce() -> Option<WaitToken>,
        C: FnOnce(WaitToken, bool) + Unpin,
    {
        struct WaitFuture<'a, 'b, C: FnOnce(WaitToken, bool)> {
            node: Option<Pin<&'a WaitNode>>,
            queue: &'b WaitQueue,
            cancelled: Option<C>,
        }

        impl<'a, 'b, C: FnOnce(WaitToken, bool)> WaitFuture<'a, 'b, C> {
            #[cold]
            fn drop_slow(&mut self, node: Pin<&'a WaitNode>) {
                if node.waker.is_notified() {
                    return;
                }

                let removed = self.queue.bucket.with(|bucket| unsafe {
                    let mut list = bucket.list_for(node.key);
                    if !list.try_remove(NonNull::from(&*node)) {
                        return false;
                    }

                    let cancelled = self.cancelled.take().unwrap();
                    cancelled(node.token.get(), !list.is_empty());
                    true
                });

                if !removed {
                    Self::wait_for_wake(node)
                }
            }

            #[cold]
            fn wait_for_wake(node: Pin<&'a WaitNode>) {
                const EVENT_VTABLE: RawWakerVTable = RawWakerVTable::new(
                    |ptr| RawWaker::new(ptr, &EVENT_VTABLE),
                    |ptr| unsafe {
                        let event = &*(ptr as *const AutoResetEvent);
                        Pin::new_unchecked(event).notify();
                        // ^ potentially dangling reference but
                        // rust stdlib does this too & theres no obvious fix
                    },
                    |_ptr| unreachable!("wake_by_ref() was called waiting for WaitNode"),
                    |_ptr| {},
                );

                unsafe {
                    let event = AutoResetEvent::default();
                    let event = Pin::new_unchecked(&event);

                    let ptr = &*event as *const AutoResetEvent as *const ();
                    let raw_waker = RawWaker::new(ptr, &EVENT_VTABLE);
                    let waker = Waker::from_raw(raw_waker);

                    match node.waker.update(Some(&waker)) {
                        WakerUpdate::New => {
                            unreachable!("waker with event when not already waiting")
                        }
                        WakerUpdate::Replaced => event.wait(),
                        WakerUpdate::Notified => {}
                    }
                }
            }
        }

        impl<'a, 'b, C: FnOnce(WaitToken, bool)> Drop for WaitFuture<'a, 'b, C> {
            fn drop(&mut self) {
                if let Some(node) = self.node {
                    self.drop_slow(node);
                }
            }
        }

        impl<'a, 'b, C: FnOnce(WaitToken, bool) + Unpin> Future for WaitFuture<'a, 'b, C> {
            type Output = WakeToken;

            fn poll(mut self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
                let node = self
                    .node
                    .take()
                    .expect("WaitFuture polled after completion");

                if node.waker.update(Some(ctx.waker())) == WakerUpdate::Notified {
                    return Poll::Ready(WakeToken(node.token.get().0));
                }

                self.node = Some(node);
                Poll::Pending
            }
        }

        let node = WaitNode {
            key,
            key_prev: Cell::new(None),
            key_next: Cell::new(None),
            prev: Cell::new(None),
            next: Cell::new(None),
            tail: Cell::new(None),
            inserted: Cell::new(false),
            token: Cell::new(WaitToken(0)),
            waker: AtomicWaker::default(),
            _pinned: PhantomPinned,
        };

        unsafe {
            let node = Pin::new_unchecked(&node);
            let is_waiting = self.bucket.with(|bucket| {
                match validate() {
                    Some(token) => node.token.set(token),
                    None => return false,
                }

                let mut list = bucket.list_for(key);
                list.insert(NonNull::from(&*node));
                true
            });

            if !is_waiting {
                return None;
            }

            let wait_future = WaitFuture {
                node: Some(node),
                queue: self,
                cancelled: Some(cancelled),
            };

            Some(wait_future.await)
        }
    }

    #[cold]
    pub fn wake(
        &self,
        key: usize,
        mut filter: impl FnMut(WaitToken) -> Option<WakeToken>,
        before_wake: impl FnOnce(bool),
    ) {
        let mut nodes = self.bucket.with(|bucket| {
            let mut unparked = None;
            let mut list = bucket.list_for(key);

            for node in list.iter() {
                let node = unsafe { Pin::new_unchecked(node.as_ref()) };
                match filter(node.token.get()) {
                    Some(token) => node.token.set(WaitToken(token.0)),
                    None => break,
                }

                let node_ptr = NonNull::from(&*node);
                assert!(unsafe { list.try_remove(node_ptr) });

                node.next.set(unparked);
                unparked = Some(node_ptr);
            }

            before_wake(!list.is_empty());
            unparked
        });

        while let Some(node) = nodes {
            unsafe {
                nodes = node.as_ref().next.get();
                node.as_ref().waker.wake();
                // ^ potentially dangling reference but
                // rust stdlib does this too & theres no obvious fix
            }
        }
    }

    #[cold]
    pub fn notify(
        &self,
        key: usize,
        token: WakeToken,
        mut count: usize,
        before_wake: impl FnOnce(bool),
    ) {
        let filter = |_| match count {
            0 => None,
            _ => {
                count -= 1;
                Some(token)
            }
        };

        self.wake(key, filter, before_wake)
    }
}
