pub use os::Once;

#[cfg(target_os = "windows")]
mod os {
    use std::{cell::UnsafeCell, ffi::c_void, ptr};

    #[link(name = "kernel32")]
    extern "system" {
        fn InitOnceExecuteOnce(
            init_once: *mut *mut c_void,
            init_fn: extern "C" fn(*mut *mut c_void, *mut c_void, *mut c_void) -> i32,
            parameter: *mut c_void,
            context: *mut c_void,
        ) -> i32;
    }

    pub struct Once {
        init_once: UnsafeCell<*mut c_void>,
    }

    unsafe impl Send for Once {}
    unsafe impl Sync for Once {}

    impl Once {
        pub const fn new() -> Self {
            Self {
                init_once: UnsafeCell::new(ptr::null_mut()),
            }
        }

        pub fn call_once<Func: FnOnce()>(&self, f: Func) {
            struct InitFn<F>(Option<F>);

            impl<F: FnOnce()> InitFn<F> {
                extern "C" fn init_fn(
                    _init_once: *mut *mut c_void,
                    param: *mut c_void,
                    _context: *mut c_void,
                ) -> i32 {
                    let this = unsafe { &mut *(param as *mut Self) };
                    (this.0.take().unwrap())();
                    0
                }
            }

            let mut init_fn = InitFn(Some(f));
            let result = unsafe {
                InitOnceExecuteOnce(
                    self.init_once.get(),
                    InitFn::<Func>::init_fn,
                    (&mut init_fn) as *mut InitFn<Func> as *mut c_void,
                    ptr::null_mut(),
                )
            };

            assert_eq!(0, result)
        }
    }
}

#[cfg(target_vendor = "apple")]
mod os {
    use std::cell::UnsafeCell;

    #[link(name = "c")]
    extern "C" {
        fn dispatch_once_f(
            once: *mut isize,
            context: *mut c_void,
            func: extern "C" fn(*mut c_void),
        );
    }

    pub struct Once {
        dispatch_once: UnsafeCell<isize>,
    }

    unsafe impl Send for Once {}
    unsafe impl Sync for Once {}

    impl Once {
        pub const fn new() -> Self {
            Self {
                dispatch_once: UnsafeCell::new(0),
            }
        }

        pub fn call_once<Func: FnOnce()>(&self, f: Func) {
            struct InitFn<F>(Option<F>);

            impl<F: FnOnce()> InitFn<F> {
                extern "C" fn init_fn(param: *mut c_void) {
                    let this = unsafe { &mut *(param as *mut Self) };
                    (this.0.take().unwrap())();
                    0
                }
            }

            let mut init_fn = InitFn(Some(f));
            unsafe {
                dispatch_once(
                    self.dispatch_once.get(),
                    InitFn::<Func>::init_fn,
                    (&mut init_fn) as *mut InitFn<Func> as *mut c_void,
                )
            }
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

    const UNINIT: i32 = 0;
    const CALLING: i32 = 1;
    const WAITING: i32 = 2;
    const CALLED: i32 = 3;

    pub struct Once {
        state: AtomicI32,
    }

    impl Once {
        pub const fn new() -> Self {
            Self {
                state: AtomicI32::new(UNINIT),
            }
        }

        #[inline]
        pub fn call_once(&self, f: impl FnOnce()) {
            match self.state.load(Ordering::Acquire) {
                CALLED => {}
                _ => self.call_once_slow(f),
            }
        }

        #[cold]
        fn call_once_slow(&self, f: impl FnOnce()) {
            let mut state = match self.state.compare_exchange(
                UNINIT,
                CALLING,
                Ordering::Acquire,
                Ordering::Acquire,
            ) {
                Err(e) => e,
                Ok(_) => {
                    f();
                    return match self.state.swap(CALLED, Ordering::Release) {
                        UNINIT => unreachable!("Once calling while uninit"),
                        CALLING => {}
                        WAITING => unsafe { Futex::wake(&self.state, i32::MAX) },
                        CALLED => unreachable!("Once called when already called"),
                        _ => unreachable!("invalid Once state"),
                    };
                }
            };

            for spin in 0..=10 {
                if spin <= 3 {
                    (0..(1 << spin)).for_each(|_| spin_loop());
                } else {
                    thread::yield_now();
                }

                state = self.state.load(Ordering::Acquire);
                match state {
                    UNINIT => unreachable!("Once thread waiting while uninit"),
                    CALLING => continue,
                    WAITING => break,
                    CALLED => return,
                    _ => unreachable!("invalid Once state"),
                }
            }

            if state == CALLING {
                match self.state.compare_exchange(
                    CALLING,
                    WAITING,
                    Ordering::Acquire,
                    Ordering::Acquire,
                ) {
                    Ok(_) => {}
                    Err(CALLED) => return,
                    Err(WAITING) => {}
                    Err(_) => unreachable!("invalid Once state"),
                }
            }

            while state == WAITING {
                unsafe { Futex::wait(&self.state, WAITING) };
                state = self.state.load(Ordering::Acquire);
            }

            assert_eq!(state, CALLED);
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

    #[repr(align(4))]
    struct Waiter {
        next: Cell<Option<NonNull<Self>>>,
        event: AutoResetEvent,
    }

    const UNINIT: usize = 0;
    const CALLING: usize = 1;
    const WAITING: usize = 2;
    const CALLED: usize = 3;
    const WAIT_MASK: usize = !0b11usize;

    pub struct Once {
        state: AtomicUsize,
    }

    impl Once {
        pub const fn new() -> Self {
            Self {
                state: AtomicUsize::new(UNINIT),
            }
        }

        #[inline]
        pub fn call_once(&self, f: impl FnOnce()) {
            match self.state.load(Ordering::Acquire) {
                CALLED => {}
                _ => self.call_once_slow(f),
            }
        }

        #[cold]
        fn call_once_slow(&self, f: impl FnOnce()) {
            let mut state = match self.state.compare_exchange(
                UNINIT,
                CALLING,
                Ordering::Acquire,
                Ordering::Acquire,
            ) {
                Err(e) => e,
                Ok(_) => {
                    f();

                    let state = self.state.swap(CALLED, Ordering::AcqRel);
                    let mut waiters = NonNull::new((state & WAIT_MASK) as *mut Waiter);
                    while let Some(waiter) = waiters {
                        unsafe {
                            waiters = waiter.as_ref().next.get();
                            Pin::new_unchecked(&waiter.as_ref().event).notify();
                            // ^ potential dangling ref but std::sync::Once has this too & its unclear to fix it.
                        }
                    }

                    return;
                }
            };

            for spin in 0..=10 {
                if spin <= 3 {
                    (0..(1 << spin)).for_each(|_| spin_loop());
                } else {
                    thread::yield_now();
                }

                state = self.state.load(Ordering::Acquire);
                match state & 0b11 {
                    UNINIT => unreachable!("Once thread waiting while uninit"),
                    CALLING => continue,
                    WAITING => break,
                    CALLED => return,
                    _ => unreachable!("invalid Once state"),
                }
            }

            let waiter = Waiter {
                next: Cell::new(None),
                event: AutoResetEvent::default(),
            };

            let waiter = unsafe { Pin::new_unchecked(&waiter) };
            while state != CALLED {
                waiter
                    .next
                    .set(NonNull::new((state & WAIT_MASK) as *mut Waiter));

                if let Err(e) = self.state.compare_exchange_weak(
                    state,
                    (&*waiter as *const Waiter as usize) | WAITING,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    state = e;
                    continue;
                }

                unsafe { Pin::map_unchecked(waiter, |w| &w.event).wait() };
                state = self.state.load(Ordering::Acquire);
                break;
            }

            assert_eq!(state, CALLED);
        }
    }
}
