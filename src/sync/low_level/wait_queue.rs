use super::{Lock, AtomicWaker};
use std::{
    cell::Cell,
    ptr::NonNull,
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

    unsafe fn insert(&mut self, node: NonNull<WaitNode>) {
        assert_eq!(node.key, self.key);
        assert!(!node.inserted.get());
        
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
                next.as_ref().prev.set(prev);
            } else {
                assert_eq!(node, head.as_ref().tail.get());
                assert!(prev.is_some());
                head.as_ref().tail.set(prev);
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
    pub fn list_for(&mut self, key: usize) -> WaitList<'_> {
        let mut head = self.root;
        let mut key_prev = None;

        while let Some(waiter) = head {
            let (wait_key, wait_key_next) = unsafe {
                (waiter.as_ref().key, waiter.as_ref.key_next.get())
            };

            if wait_key == key {
                break;
            }

            key_prev = Some(waiter);
            head = wait_key_next;
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

    pub async fn wait<V, C>(&self, key: usize, validate: V, cancelled: C) -> Option<WakeToken> 
    where
        V: FnOnce() -> Option<WaitToken>,
        C: FnOnce(WaitToken, bool),
    {
        struct WaitFuture<'a, 'b, C: FnOnce(WaitToken, bool)> {
            node: Option<Pin<&'a WaitNode>>,
            queue: &'b WaitQueue,
            cancelled: Option<C>,
        }

        impl<'a, 'b, C: FnOnce(WaitToken, bool)> WaitFuture<'a, 'b, C> {
            #[cold]
            fn drop_slow(&self, node: Pin<&'a WaitNode>) {
                self.queue.bucket.with(|bucket| {
                    
                })
            }
        }

        impl<'a, 'b, C: FnOnce(WaitToken, bool)> Drop for WaitFuture<'a, 'b, C> {
            fn drop(&mut self) {
                if let Some(node) = self.node {
                    self.drop_slow(node);
                }
            }
        }

        impl<'a, 'b, C: FnOnce(WaitToken, bool)> Future for WaitFuture<'a, 'b, C> {
            type Output = WakeToken;

            fn poll(self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {

            }
        }
    }

    pub fn wake(&self, key: usize, mut filter: impl FnMut(WaitToken, bool) -> Option<WakeToken>) {

    }
}