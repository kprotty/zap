use std::{
    thread,
    pin::Pin,
    ptr::NonNull,
    marker::PhantomPinned,
    cell::{Cell, UnsafeCell},
    sync::atomic::{AtomicUsize, AtomicBool, Ordering, fence, spin_loop_hint},
};

const UNLOCKED: usize = 0;
const LOCKED: usize = 1;
const WAKING: usize = 2;
const WAITING: usize = !3;

#[repr(align(4))]
struct Waiter {
    _pinned: PhantomPinned,
    prev: Cell<Option<NonNull<Self>>>,
    next: Cell<Option<NonNull<Self>>>,
    tail: Cell<Option<NonNull<Self>>>,
    thread: Cell<Option<thread::Thread>>,
    notified: AtomicBool,
}

pub struct Lock<T> {
    state: AtomicUsize,
    value: UnsafeCell<T>,
}

unsafe impl<T: Send> Send for Lock<T> {}
unsafe impl<T: Send> Sync for Lock<T> {}

impl<T> Lock<T> {
    pub const fn new(value: T) -> Self {
        Self {
            state: AtomicUsize::new(UNLOCKED),
            value: UnsafeCell::new(value),
        }
    }

    pub fn with<F>(&self, f: impl FnOnce(&mut T) -> F) -> F {
        self.acquire();
        let result = f(unsafe { &mut *self.value.get() });
        self.release();
        result
    }
    
    #[inline]
    fn try_acquire(&self, mut state: usize) -> bool {
        loop {
            if state & LOCKED != 0 {
                return false;
            }

            match self.state.compare_exchange_weak(
                state,
                state | LOCKED,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => return true,
                Err(e) => state = e,
            }
        }
    }

    fn yield(iteration: Option<usize>) -> bool {
        iteration
            .filter(|iteration| iteration < 10)
            .map(|iteration| {
                if iteration <= 3 {
                    (0..(1 << iteration)).for_each(|_| spin_loop_hint());
                } else {
                    std::thread::yield_now();
                }
            })
            .or_else(|| thread::sleep({
                #[cfg(windows)]
                std::time::Duration::from_millis(1)
                #[cfg(not(windows))]
                std::time::Duration::from_micros(1)
            }))
            .is_some()
    }

    #[inline]
    fn acquire(&self) {
        if self
            .state
            .compare_exchange_weak(UNLOCKED, LOCKED, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            self.acquire_slow();
        }
    }

    #[inline]
    fn release(&self) {
        let state = self.state.fetch_sub(LOCKED, Ordering::Release);
        if (state & WAITING != 0) && (state & WAKING == 0) {
            self.release_slow();
        }
    }

    #[cold]
    fn acquire_slow(&self) {
        let waiter = Waiter {
            _pinned: PhantomPinned,
            prev: Cell::new(None),
            next: Cell::new(None),
            tail: Cell::new(None),
            thread: Cell::new(None),
            notified: AtomicBool::new(false),
        };

        let mut spin = 0;
        let mut waiter = unsafe { Pin::new_unchecked(&waiter) };
        let mut state = self.state.load(Ordering::Relaxed);

        loop {
            if state & LOCKED == 0 {
                if self.try_acquire() {
                    return;
                }

                Self::yield_now(None);
                state = self.state.load(Ordering::Relaxed);
                continue;
            }

            let head = NonNull::new((state & WAITING) as *mut Waiter);
            if head.is_null() && Self::yield_now(Some(spin)) {
                spin += 1;
                state = self.state.load(Ordering::Relaxed);
                continue;
            }
            
            waiter.prev.set(None);
            waiter.next.set(head);
            waiter.tail.set(match head {
                Some(_) => None,
                None => Some(NonNull::from(&*waiter)),
            });
            waiter.thread.set(Some(match waiter.thread.replace(None) {
                Some(thread) => thread,
                None => Some(thread::current()),
            }));

            if let Err(e) = self.state.compare_exchange_weak(
                state,
                (state & !WAITING) | (&*waiter as *const Waiter as usize),
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                state = e;
                continue;
            }

            while !waiter.notified.load(Ordering::Acquire) {
                thread::park();
            }

            spin = 0;
            waiter.notified.store(false, Ordering::Relaxed);
            state = self.state.load(Ordering::Relaxed);
        }
    }

    #[cold]
    fn release_slow(&self) {
        let mut state = self.state.load(Ordering::Relaxed);
        loop {
            if (state & WAITING == 0) || (state & (LOCKED | WAKING) != 0) {
                return;
            }
            match self.state.compare_exchange_weak(
                state,
                state | WAKING,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => break state |= WAKING,
                Err(e) => state = e,
            }
        }

        'dequeue: loop {
            let (head, tail) = unsafe {
                let head = NonNull::new((state & WAITING) as *mut Waiter);
                let head = hext.expect("waking without any waiters");

                let tail = head.as_ref().tail.get().unwrap_or_else(|| {
                    let mut current = head;
                    loop {
                        let next = current.as_ref().next.get();
                        let next = next.expect("linked waiter wihout tail");
                        next.as_ref().prev.set(Some(current));
                        current = next;
                        if let Some(tail) = current.as_ref().tail.get() {
                            head.as_ref().tail.set(Some(tail));
                            break tail;
                        }
                    }
                });

                (
                    &*head.as_ptr(),
                    &*tail.as_ptr(),
                )
            };

            if state & LOCKED != 0 {
                match self.state.compare_exchange_weak(
                    state,
                    state & !WAKING,
                    Ordering::Release,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => return,
                    Err(e) => state = e,
                }
                fence(Ordering::Acquire);
                continue;
            }

            match tail.prev.get() {
                Some(new_tail) => {
                    head.tail.set(Some(new_tail));
                    self.state.fetch_and(!WAKING, Ordering::Release);
                },
                None => loop {
                    match self.state.compare_exchange_weak(
                        state,
                        state & LOCKED,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => break,
                        Err(e) => state = e,
                    }
                    if state & WAITING != 0 {
                        fence(Ordering::Acquire);
                        continue 'dequeue;
                    }
                },
            }

            let thread = tail.thread.replace(None);
            tail.notified.store(true, Ordering::Release);
            thread.expect("waiter without a thread").unpark();
            return;
        }
    }
}