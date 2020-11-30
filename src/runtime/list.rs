use crate::sync::Parker;
use std::{
    pin::Pin,
    ptr::NonNull,
    marker::{PhantomData, PhantomPinned},
    sync::atomic::{AtomicPtr, AtomicUsize, Ordering},
};

#[derive(Default)]
pub(crate) struct ActiveNode {
    next: Cell<Option<NonNull<Self>>>,
    _pinned: PhantomPinned,
}

#[derive(Default)]
pub(crate) struct ActiveList {
    head: AtomicPtr<ActiveNode>,
}

impl ActiveList {
    pub(crate) fn push(&self, active_node: Pin<&mut ActiveNode>) {
        // SAFETY: we own the active_node and pin guarantees it wont be dropped after.
        let active_node: &ActiveNode = unsafe { active_node.get_unchecked_mut() };
        let mut head = self.head.load(Ordering::Relaxed);
        loop {

            active_node.next.set(NonNull::new(head));

            match self.head.compare_exchange_weak(
                head,
                active_node as *const _ as *mut _,
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Err(e) => head = e,
                Ok(_) => return,
            }
        }
    }

    pub(crate) fn iter(&self) -> ActiveIter<'_> {
        ActiveIter {
            _lifetime: PhantomData,
            node: NonNull::new(self.head.load(Ordering::Acquire)),
        }
    }
}

pub(crate) struct ActiveIter<'a> {
    _lifetime: PhantomData<&'a ()>,
    node: Option<NonNull<ActiveNode>>,
}

impl<'a> Iterator for ActiveIter<'a> {
    type Item = &'a ActiveNode;

    fn next(&mut self) -> Option<Self::Item> {
        // SAFETY: pin guarantees this to be valid until its removed.
        let node = unsafe { &*self.0?.as_ptr() };
        self.0 = node.next.get();
        Some(node)
    }
}

const IDLE_EMPTY: usize = 0;
const IDLE_WAKING: usize = 1;
const IDLE_SHUTDOWN: usize = 2;
const IDLE_NOTIFIED: usize = 4;
const IDLE_WAITING: usize = !(IDLE_WAKING | IDLE_SHUTDOWN | IDLE_NOTIFIED);

#[repr(align(8))]
#[derive(Default)]
pub(crate) struct IdleNode {
    prev: Cell<Option<NonNull<Self>>>,
    next: Cell<Option<NonNull<Self>>>,
    tail: Cell<Option<NonNull<Self>>>,
    parker: Parker,
    _pinned: PhantomPinned,
}

#[derive(Default)]
pub(crate) struct IdleList {
    state: AtomicUsize,
}

impl IdleList {
    /// Wait for a notification on the idle list using the given idle node
    pub(crate) fn wait(&self, idle_node: Pin<&mut IdleNode>) {
        // SAFETY: we own the active_node and pin guarantees it wont be dropped after.
        let idle_node: &IdleNode = unsafe {
            let idle_node = idle_node.get_unchecked_mut();
            idle_node.parker.prepare();
            idle_node
        };
        
        let mut state = self.state.load(Ordering::Relaxed);
        loop {
            // Dont add more idle nodes to the queue if its shutdown
            if state & IDLE_SHUTDOWN != 0 {
                return;
            }

            // If a notification token was left over, consume it and treat that as an unpark request
            if state & IDLE_NOTIFIED != 0 {
                match self.state.compare_exchange_weak(
                    state,
                    state & !IDLE_NOTIFIED,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => return,
                    Err(e) => state = e,
                }
                continue;
            }

            // Prepare to add the idle node to the idle list.
            // The first node in the list will set it's `tail` field to itself.
            // This is important for the notify() thread to find what IdleNode to unpark.
            let head = NonNull::new((state & IDLE_WAITING) as *mut IdleNode);
            idle_node.next.set(head);
            idle_node.prev.set(None);
            idle_node.tail.set(match head {
                Some(_) => None,
                None => NonNull::from(idle_node),
            });

            if let Err(e) = self.state.compare_exchange_weak(
                state,
                idle_node as *const _ as usize,
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                state = e;
                continue;
            }

            let timed_out = !idle_node.parker.park(None);
            debug_assert!(!timed_out);
            return;
        }
    }

    /// Notify the idle list, possibly waking an idle node reference in the process.
    pub(crate) fn notify(&self) {
        let mut state = self.state.load(Ordering::Relaxed);
        loop {
            if state & (IDLE_NOTIFIED | IDLE_SHUTDOWN) != 0 {
                return;
            }

            let head = match NonNull::new((state & IDLE_WAITING) as *mut IdleNode) {
                Some(node) => node,
                None => match self.state.compare_exchange_weak(
                    state,
                    (state & IDLE_WAKING) | IDLE_NOTIFIED,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => return,
                    Err(e) => {
                        state = e;
                        continue;
                    }
                }
            };

            if state & IDLE_WAKING != 0 {
                return;
            }

            // TODO: pontential use-case for Consume memory ordering
            match self.state.compare_exchange_weak(
                state,
                state | IDLE_WAKING,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Err(e) => state = e,
                Ok(_) => break state |= IDLE_WAKING,
            }
        }

        unsafe {
            loop {
                // Scan the list of nodes starting from the head to find the tail.
                // While scanning, we link them to their previous node to make it doubly-linked.
                // Once the tail is found, it is cached at the current head to amortize future lookups.
                let head = NonNull::new_unchecked((state & IDLE_WAITING) as *mut IdleNode);
                let tail = head.as_ref().tail.get().unwrap_or_else(|| {
                    let mut current = head;
                    loop {
                        let next = current.as_ref().next.get();
                        let next = next.expect("invalid IdleNode link");
                        next.as_ref().prev.set(Some(current));
                        current = next;
                        if let Some(tail) = current.as_ref().tail.get() {
                            head.as_ref().tail.set(Some(tail));
                            break tail;
                        }
                    }
                });

                // Check if a shutdown signal was received.
                // If so, then we should unpark all the idle nodes rather than just the tail.
                // No new nodes will be pushed onto the queue and the shutdown thread will not touch the existing ones.
                if state & IDLE_SHUTDOWN != 0 {
                    let mut idle_nodes = Some(head);
                    loop {
                        let idle_node = match idle_nodes {
                            Some(node) => &*node.as_ptr(),
                            None => return,
                        };
                        head = idle_node.next.get();
                        idle_node.parker.unpark();
                    }
                }
                
                // Dequeue the tail node in order to wake it up.
                // Also zero-out the node list if the tail was the last node.
                let new_tail = tail.as_ref().prev.get();
                let mut new_state = state & !IDLE_WAKING;
                match new_tail {
                    Some(new_tail) => head.as_ref().tail.set(Some(new_tail)),
                    None => new_state &= !IDLE_WAITING,
                }
                
                // Try to mark the idle list as "not waking" and dequeue the tail.
                // If we tail, we need to undo our dequeue operation from above.
                if let Err(e) =  self.state.compare_exchange_weak(
                    state,
                    new_state,
                    Ordering::Release,
                    Ordering::Relaxed,
                ) {
                    head.as_ref().tail.set(Some(tail));
                    state = e;
                    continue;
                }

                // We succesfully dequeued the tail from the idle list
                // so now we can unpark it.
                tail.as_ref().parker.unpark();
                return;
            }
        }
    }

    pub(crate) fn shutdown(&self) {
        let mut state = self.state.load(Ordering::Relaxed);
        loop {
            if state & IDLE_SHUTDOWN != 0 {
                return;
            }

            match self.state.compare_exchange_weak(
                state,
                state | IDLE_SHUTDOWN,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(e) => state = e,
            }
        }

        if state & IDLE_WAKING != 0 {
            return;
        }

        let mut idle_nodes = NonNull::new((state & IDLE_WAITING) as *mut IdleNode);
        while let Some(idle_node) = idle_nodes {
            let idle_node = unsafe { idle_node.as_ref() };
            idle_nodes = idle_node.next.get();
            idle_node.parker.unpark();
        }
    }
}
