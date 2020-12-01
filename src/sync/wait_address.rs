use super::Lock;
use crate::time::Instant;
use std::{
    ptr::NonNull,
    num::NonZeroU16,
    task::Waker,
};

struct WaitBucket {
    root: Lock<usize>,
}

impl WaitBucket {
    fn acquire(address: usize) -> LockGuard<&'static, usize> {
        
    }
}

enum WaitRoot {
    Node(NonNull<WaitNode>),
    Prng(NonZeroU16),
    Empty,
}

struct WaitTree {
    guard: LockGuard<&'static, usize>,
    root: WaitRoot,
}

impl Drop for WaitTree {
    fn drop(&mut self) {

    }
}

impl WaitTree {
    fn iter(&mut self, address: usize) -> WaitList<'_> {

    }

    fn insert(&mut self, address: usize, node: Pin<&mut WaitNode>) {

    }

    fn remove(&mut self, node: Pin<&mut WaitNode>) {

    }
}

struct WaitList<'a> {
    tree: &'a mut WaitTree,
    node: Option<NonNull<WaitNode>>,
}

impl<'a> Iterator for WaitList<'a> {
    type Item = WaitNodeRef<'a>;

    fn next(&mut self) -> Option<Self::Item> {

    }
}

struct WaitNodeRef<'a> {
    list: &'a mut WaitList<'a>,
    node: Pin<&'a mut WaitNode>,
}

impl<'a> AsMut<WaitNode> for WaitNodeRef<'a> {
    fn as_mut(&mut self) -> &mut WaitNode {
        unsafe { self.node.into_inner_unchecked() }
    }
}

impl<'a> WaitNodeRef<'a> {
    fn remove(&mut self) {
        self.list.tree.remove(self.node)
    }
}

struct WaitNode {
    address: usize,
    prev: Option<NonNull<Self>>,
    next: Option<NonNull<Self>>,
    tail: NonNull<Self>,
    parent_color: usize,
    children: [Option<NonNull<Self>>; 2],
    prng: NonZeroU16,
    times_out: Option<Instant>,
    waker: Waker,
    _pinned: PhantomPinned,
}