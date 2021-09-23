use std::{
    hint::spin_loop,
    marker::PhantomPinned,
    mem,
    pin::Pin,
    ptr::{self, NonNull},
    sync::atomic::{AtomicPtr, AtomicUsize, Ordering},
};

#[derive(Default)]
pub struct Node {
    next: AtomicPtr<Self>,
    _pinned: PhantomPinned,
}

pub struct Popped {
    pub node: NonNull<Node>,
    pub pushed: usize,
}

pub struct List {
    pub head: NonNull<Node>,
    pub tail: NonNull<Node>,
}

pub struct Injector {
    stub: Node,
    head: AtomicPtr<Node>,
    tail: AtomicPtr<Node>,
}

impl Default for Injector {
    fn default() -> Self {
        Self {
            stub: Node {
                next: AtomicPtr::new(ptr::null_mut()),
                _pinned: PhantomPinned,
            },
            head: AtomicPtr::new(ptr::null_mut()),
            tail: AtomicPtr::new(ptr::null_mut()),
        }
    }
}

impl Injector {
    const IS_CONSUMING: NonNull<Node> = NonNull::<Node>::dangling();

    pub unsafe fn push(self: Pin<&Self>, list: List) {
        list.tail
            .as_ref()
            .next
            .store(ptr::null_mut(), Ordering::Relaxed);

        let tail = self.tail.swap(list.tail.as_ptr(), Ordering::AcqRel);
        let prev = NonNull::new(tail).unwrap_or(NonNull::from(&self.stub));

        prev.as_ref()
            .next
            .store(list.head.as_ptr(), Ordering::Release);
    }

    fn consume<'a>(self: Pin<&'a Self>) -> Option<impl Iterator<Item = NonNull<Node>> + 'a> {
        let tail = NonNull::new(self.tail.load(Ordering::Acquire));
        if tail.is_none() || tail == Some(NonNull::from(&self.stub)) {
            return None;
        }

        let is_consuming = Self::IS_CONSUMING.as_ptr();
        let head = self.head.swap(is_consuming, Ordering::Acquire);
        if head == is_consuming {
            return None;
        }

        struct Consumer<'a> {
            injector: Pin<&'a Injector>,
            head: NonNull<Node>,
        }

        impl<'a> Drop for Consumer<'a> {
            fn drop(&mut self) {
                assert_ne!(self.head, Injector::IS_CONSUMING);
                self.injector
                    .head
                    .store(self.head.as_ptr(), Ordering::Release);
            }
        }

        impl<'a> Iterator for Consumer<'a> {
            type Item = NonNull<Node>;

            fn next(&mut self) -> Option<Self::Item> {
                unsafe {
                    let stub = NonNull::from(&self.injector.stub);
                    if self.head == stub {
                        let next = self.head.as_ref().next.load(Ordering::Acquire);
                        self.head = NonNull::new(next)?;
                    }

                    let next = self.head.as_ref().next.load(Ordering::Acquire);
                    if let Some(next) = NonNull::new(next) {
                        return Some(mem::replace(&mut self.head, next));
                    }

                    let tail = self.injector.tail.load(Ordering::Acquire);
                    if Some(self.head) != NonNull::new(tail) {
                        return None;
                    }

                    self.injector.push(List {
                        head: stub,
                        tail: stub,
                    });

                    let next = self.head.as_ref().next.load(Ordering::Acquire);
                    let next = NonNull::new(next)?;
                    Some(mem::replace(&mut self.head, next))
                }
            }
        }

        Some(Consumer {
            injector: self,
            head: NonNull::new(head).unwrap_or(NonNull::from(&self.stub)),
        })
    }
}

pub struct Buffer {
    head: AtomicUsize,
    tail: AtomicUsize,
    array: [AtomicPtr<Node>; Self::CAPACITY],
}

impl Default for Buffer {
    fn default() -> Self {
        const EMPTY: AtomicPtr<Node> = AtomicPtr::new(ptr::null_mut());
        Self {
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            array: [EMPTY; Self::CAPACITY],
        }
    }
}

impl Buffer {
    const CAPACITY: usize = 256;

    fn write(&self, index: usize, node: NonNull<Node>) {
        let slot = &self.array[index % self.array.len()];
        slot.store(node.as_ptr(), Ordering::Relaxed)
    }

    fn read(&self, index: usize) -> NonNull<Node> {
        let slot = &self.array[index % self.array.len()];
        let node = NonNull::new(slot.load(Ordering::Relaxed));
        node.expect("invalid node read from Buffer")
    }

    pub unsafe fn push(&self, node: NonNull<Node>, overflow_injector: Pin<&Injector>) {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Relaxed);

        let size = tail.wrapping_sub(head);
        assert!(size <= self.array.len());

        if size < self.array.len() {
            self.write(tail, node);
            self.tail.store(tail.wrapping_add(1), Ordering::Release);
            return;
        }

        let migrate = size / 2;
        if let Err(head) = self.head.compare_exchange(
            head,
            head.wrapping_add(migrate),
            Ordering::Acquire,
            Ordering::Relaxed,
        ) {
            let size = tail.wrapping_sub(head);
            assert!(size <= self.array.len());

            self.write(tail, node);
            self.tail.store(tail.wrapping_add(1), Ordering::Release);
            return;
        }

        let first = self.read(head);
        let last = (1..(migrate + 1)).fold(first, |last, offset| {
            let next = match offset {
                _ if offset == migrate => node,
                _ => self.read(head.wrapping_add(offset)),
            };
            unsafe { last.as_ref().next.store(next.as_ptr(), Ordering::Relaxed) };
            next
        });

        overflow_injector.push(List {
            head: first,
            tail: last,
        })
    }

    pub fn pop(&self) -> Option<Popped> {
        let mut head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Relaxed);

        loop {
            let size = tail.wrapping_sub(head);
            assert!(size <= self.array.len());

            if size == 0 {
                return None;
            }

            match self.head.compare_exchange_weak(
                head,
                head.wrapping_add(1),
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Err(new_head) => head = new_head,
                Ok(_) => {
                    return Some(Popped {
                        node: self.read(head),
                        pushed: 0,
                    })
                }
            };
        }
    }

    pub fn steal(&self, buffer: &Self) -> Option<Popped> {
        loop {
            let buffer_head = buffer.head.load(Ordering::Acquire);
            let buffer_tail = buffer.tail.load(Ordering::Acquire);

            let buffer_size = buffer_tail.wrapping_sub(buffer_head);
            if buffer_size == 0 {
                return None;
            }

            if buffer_size > buffer.array.len() {
                spin_loop();
                continue;
            }

            let buffer_steal = buffer_size - (buffer_size / 2);
            assert_ne!(buffer_steal, 0);

            let head = self.head.load(Ordering::Relaxed);
            let tail = self.tail.load(Ordering::Relaxed);
            let size = tail.wrapping_sub(head);
            assert_eq!(size, 0);

            let new_tail = (0..buffer_steal).fold(tail, |new_tail, offset| {
                let node = buffer.read(buffer_head.wrapping_add(offset));
                self.write(new_tail, node);
                new_tail.wrapping_add(1)
            });

            if let Err(_) = buffer.head.compare_exchange(
                buffer_head,
                buffer_head.wrapping_add(buffer_steal),
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                spin_loop();
                continue;
            }

            let new_tail = new_tail.wrapping_sub(1);
            if new_tail != tail {
                self.tail.store(new_tail, Ordering::Release);
            }

            return Some(Popped {
                node: self.read(new_tail),
                pushed: new_tail.wrapping_sub(tail),
            });
        }
    }

    pub fn consume(&self, injector: Pin<&Injector>) -> Option<Popped> {
        injector.consume().and_then(|mut consumer| {
            consumer.next().map(|consumed| {
                let head = self.head.load(Ordering::Relaxed);
                let tail = self.tail.load(Ordering::Relaxed);

                let size = tail.wrapping_sub(head);
                assert!(size <= self.array.len());

                let new_tail =
                    consumer
                        .take(self.array.len() - size)
                        .fold(tail, |new_tail, node| {
                            self.write(new_tail, node);
                            new_tail.wrapping_add(1)
                        });

                if new_tail != tail {
                    self.tail.store(new_tail, Ordering::Release);
                }

                Popped {
                    node: consumed,
                    pushed: new_tail.wrapping_sub(tail),
                }
            })
        })
    }
}
