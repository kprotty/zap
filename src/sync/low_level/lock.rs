use std::cell::UnsafeCell;

pub struct Lock<T> {
    os_lock: os::Lock,
    value: UnsafeCell<T>,
}

unsafe impl<T: Send> Send for Lock<T> {}
unsafe impl<T: Send> Sync for Lock<T> {}

impl<T: Default> Default for Lock<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T> Lock<T> {
    pub const fn new(value: T) -> Self {
        Self {
            os_lock: os::Lock::new(),
            value: UnsafeCell::new(value),
        }
    }

    pub fn with<F>(&self, f: impl FnOnce(&mut T) -> F) -> F {
        unsafe {
            self.os_lock.acquire();
            let result = f(&mut *self.value.get());
            self.os_lock.release();
            result
        }
    }
}

#[cfg(target_os = "windows")]
mod os {
    use std::{cell::UnsafeCell, ffi::c_void, ptr};

    #[link(name = "kernel32")]
    extern "system" {
        fn AcquireSRWLockExclusive(p: *mut *mut c_void);
        fn ReleaseSRWLockExclusive(p: *mut *mut c_void);
    }

    pub struct Lock {
        srwlock: UnsafeCell<*mut c_void>,
    }

    unsafe impl Send for Lock {}
    unsafe impl Sync for Lock {}

    impl Lock {
        pub const fn new() -> Self {
            Self {
                srwlock: UnsafeCell::new(ptr::null_mut()),
            }
        }

        pub unsafe fn acquire(&self) {
            AcquireSRWLockExclusive(self.srwlock.get())
        }

        pub unsafe fn release(&self) {
            ReleaseSRWLockExclusive(self.srwlock.get())
        }
    }
}

#[cfg(target_vendor = "apple")]
mod os {
    use std::cell::UnsafeCell;

    #[link(name = "c")]
    extern "C" {
        fn os_unfair_lock_lock(p: *mut u32);
        fn os_unfair_lock_unlock(p: *mut u32);
    }

    pub struct Lock {
        oul: UnsafeCell<u32>,
    }

    unsafe impl Send for Lock {}
    unsafe impl Sync for Lock {}

    impl Lock {
        pub const fn new() -> Self {
            Self {
                oul: UnsafeCell::new(0),
            }
        }

        pub unsafe fn acquire(&self) {
            os_unfair_lock_lock(self.oul.get())
        }

        pub unsafe fn release(&self) {
            os_unfair_lock_unlock(self.oul.get())
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod os {
    use super::super::event::Futex;
    use std::{
        hint::spin_loop,
        sync::atomic::{AtomicI32, Ordering},
        thread,
    };

    const UNLOCKED: i32 = 0;
    const LOCKED: i32 = 1;
    const CONTENDED: i32 = 2;

    pub struct Lock {
        state: AtomicI32,
    }

    impl Lock {
        pub const fn new() -> Self {
            Self {
                state: AtomicI32::new(UNLOCKED),
            }
        }

        pub unsafe fn acquire(&self) {
            if let Err(_) = self.state.compare_exchange_weak(
                UNLOCKED,
                LOCKED,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                self.acquire_slow();
            }
        }

        #[cold]
        fn acquire_slow(&self) {
            let mut state = UNLOCKED;
            for spin in 0..=10 {
                if spin <= 3 {
                    (0..(1 << spin)).for_each(|_| spin_loop());
                } else {
                    thread::yield_now();
                }

                state = self.state.load(Ordering::Relaxed);
                match state {
                    UNLOCKED => match self.state.compare_exchange(
                        UNLOCKED,
                        LOCKED,
                        Ordering::Acquire,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => return,
                        Err(e) => state = e,
                    },
                    LOCKED => continue,
                    CONTENDED => break,
                    _ => unreachable!("invalid Lock state"),
                }
            }

            loop {
                while state != CONTENDED {
                    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
                    {
                        state = self.state.swap(CONTENDED, Ordering::Acquire);
                        if state == UNLOCKED {
                            return;
                        } else {
                            break;
                        }
                    }

                    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
                    {
                        match self.state.compare_exchange(
                            state,
                            CONTENDED,
                            match state {
                                UNLOCKED => Ordering::Acquire,
                                LOCKED => Ordering::Relaxed,
                                _ => unreachable!("invalid Lock state"),
                            },
                            Ordering::Relaxed,
                        ) {
                            Ok(UNLOCKED) => return,
                            Ok(LOCKED) => break,
                            Ok(_) => unreachable!("invalid Lock state"),
                            Err(e) => state = e,
                        }
                    }
                }

                unsafe { Futex::wait(&self.state, CONTENDED) };
                state = self.state.load(Ordering::Relaxed);
            }
        }

        pub unsafe fn release(&self) {
            match self.state.swap(UNLOCKED, Ordering::Release) {
                UNLOCKED => unreachable!("unlocked an unlocked Lock"),
                LOCKED => {}
                CONTENDED => Futex::wake(&self.state, 1),
                _ => unreachable!("invalid Lock state"),
            }
        }
    }
}

#[cfg(all(
    unix,
    not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))
))]
mod os {
    use super::super::AutoResetEvent;
    use std::{
        cell::Cell,
        hint::spin_loop,
        pin::Pin,
        ptr::NonNull,
        sync::atomic::{AtomicUsize, Ordering},
        thread,
    };

    const UNLOCKED: usize = 0;
    const LOCKED: usize = 0b01;
    const WAKING: usize = 0b10;
    const WAITING: usize = !(LOCKED | WAKING);

    #[repr(align(4))]
    struct Waiter {
        prev: Cell<Option<NonNull<Self>>>,
        next: Cell<Option<NonNull<Self>>>,
        tail: Cell<Option<NonNull<Self>>>,
        event: AutoResetEvent,
    }

    pub struct Lock {
        state: AtomicUsize,
    }

    impl Lock {
        pub const fn new() -> Self {
            Self {
                state: AtomicUsize::new(UNLOCKED),
            }
        }

        pub unsafe fn acquire(&self) {
            if let Err(_) = self.state.compare_exchange_weak(
                UNLOCKED,
                LOCKED,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                self.acquire_slow();
            }
        }

        #[cold]
        fn acquire_slow(&self) {
            let waiter = Waiter {
                prev: Cell::new(None),
                next: Cell::new(None),
                tail: Cell::new(None),
                event: AutoResetEvent::default(),
            };

            let mut spin = 0;
            let waiter = unsafe { Pin::new_unchecked(&waiter) };
            let mut state = self.state.load(Ordering::Relaxed);

            loop {
                if state & LOCKED == 0 {
                    match self.state.compare_exchange_weak(
                        state,
                        state | LOCKED,
                        Ordering::Acquire,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => return,
                        Err(e) => state = e,
                    }
                    continue;
                }

                let head = NonNull::new((state & WAITING) as *mut Waiter);
                if head.is_none() && spin <= 10 {
                    spin += 1;
                    if spin <= 3 {
                        (0..(1 << spin)).for_each(|_| spin_loop());
                    } else {
                        thread::yield_now();
                    }
                    state = self.state.load(Ordering::Relaxed);
                    continue;
                }

                waiter.prev.set(None);
                waiter.next.set(head);
                waiter.tail.set(match head {
                    None => Some(NonNull::from(&*waiter)),
                    Some(_) => None,
                });

                if let Err(e) = self.state.compare_exchange_weak(
                    state,
                    (&*waiter as *const _ as usize) | (state & !WAITING),
                    Ordering::Release,
                    Ordering::Relaxed,
                ) {
                    state = e;
                    continue;
                }

                unsafe {
                    Pin::new_unchecked(&waiter.event).wait();
                    state = self.state.load(Ordering::Relaxed);
                    spin = 0;
                }
            }
        }

        pub unsafe fn release(&self) {
            let state = self.state.fetch_sub(LOCKED, Ordering::Release);
            assert_ne!(state & LOCKED, 0);

            if (state & WAITING != 0) && (state & WAKING == 0) {
                self.release_slow();
            }
        }

        #[cold]
        fn release_slow(&self) {
            let mut state = self.state.load(Ordering::Relaxed);
            loop {
                if (state & WAITING == 0) || (state & (WAKING | LOCKED) != 0) {
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
                let head = NonNull::new((state & WAITING) as *mut Waiter)
                    .expect("thread waking Lock without a head Waiter node");

                let tail = unsafe {
                    head.as_ref().tail.get().unwrap_or_else(|| {
                        let mut current = head;
                        loop {
                            let next = current.as_ref().next.get();
                            let next = next.expect("Waiter queued without tail and next");
                            next.as_ref().prev.set(Some(current));
                            current = next;

                            if let Some(tail) = current.as_ref().tail.get() {
                                head.as_ref().tail.set(Some(tail));
                                break tail;
                            }
                        }
                    })
                };

                if state & LOCKED != 0 {
                    match self.state.compare_exchange_weak(
                        state,
                        state & !WAKING,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    ) {
                        Ok(_) => return,
                        Err(e) => state = e,
                    }
                    continue;
                }

                match unsafe { tail.as_ref().prev.get() } {
                    Some(new_tail) => {
                        unsafe { head.as_ref().tail.set(Some(new_tail)) };
                        state = self.state.fetch_sub(WAKING, Ordering::Release);
                        assert_ne!(state & WAKING, 0);
                    }
                    None => loop {
                        match self.state.compare_exchange_weak(
                            state,
                            state & LOCKED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        ) {
                            Ok(_) => break,
                            Err(e) => {
                                state = e;
                                if state & WAITING != 0 {
                                    continue 'dequeue;
                                }
                            }
                        }
                    },
                }

                return unsafe {
                    let event = &tail.as_ref().event;
                    let event = Pin::new_unchecked(event);
                    event.notify()
                };
            }
        }
    }
}
