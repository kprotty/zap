use std::{
    cell::{Cell, UnsafeCell},
    pin::Pin,
    time::Instant,
};

pub(crate) struct Lock<T> {
    os_lock: os::OsLock,
    value: UnsafeCell<T>,
}

unsafe impl<T: Send> Send for Lock<T> {}
unsafe impl<T: Send> Sync for Lock<T> {}

impl<T> Lock<T> {
    pub(crate) const fn new(value: T) -> Self {
        Self {
            os_lock: os::OsLock::new(),
            value: UnsafeCell::new(value),
        }
    }

    pub(crate) fn try_with<F>(self: Pin<&Self>, f: impl FnOnce(&mut T) -> F) -> Option<F> {
        unsafe {
            let os_lock = self.map_unchecked(|this| &this.os_lock);
            let f = if os_lock.try_acquire() {
                Some(f(&mut *self.value.get()))
            } else {
                None
            };
            os_lock.release();
            f
        }
    }

    pub(crate) fn with<F>(self: Pin<&Self>, f: impl FnOnce(&mut T) -> F) -> F {
        unsafe {
            let os_lock = self.map_unchecked(|this| &this.os_lock);
            os_lock.acquire();
            let f = f(&mut *self.value.get());
            os_lock.release();
            f
        }
    }
}

#[derive(Copy, Clone, Eq, PartialEq)]
enum EventState {
    Empty,
    Waiting,
    Notified,
}

pub(crate) struct Event {
    state: Cell<EventState>,
    os_event_sync: os::OsEventSync,
}

unsafe impl Send for Event {}
unsafe impl Sync for Event {}

impl Event {
    pub(crate) const fn new() -> Self {
        Self {
            state: Cell::new(EventState::Empty),
            os_event_sync: os::OsEventSync::new(),
        }
    }

    #[inline(always)]
    fn sync(self: Pin<&Self>) -> Pin<&os::OsEventSync> {
        unsafe { self.map_unchecked(|this| &this.os_event_sync) }
    }

    pub(crate) fn notify(self: Pin<&Self>) {
        unsafe {
            self.sync().acquire();

            match self.state.replace(EventState::Notified) {
                EventState::Empty => {}
                EventState::Waiting => self.sync().signal(),
                EventState::Notified => unreachable!("Event::notify() called multiple times"),
            }

            self.sync().release();
        }
    }

    pub(crate) fn wait(self: Pin<&Self>) {
        assert!(self.wait_with(None))
    }

    pub(crate) fn wait_until(self: Pin<&Self>, deadline: Instant) -> bool {
        self.wait_with(Some(deadline))
    }

    fn wait_with(self: Pin<&Self>, deadline: Option<Instant>) -> bool {
        unsafe {
            self.sync().acquire();

            let mut waiting = true;
            match self.state.get() {
                EventState::Empty => self.state.set(EventState::Waiting),
                EventState::Waiting => unreachable!("Event::wait called by multiple threads"),
                EventState::Notified => waiting = false,
            }

            let mut timed_out = false;
            while waiting {
                match self.state.get() {
                    EventState::Empty => {
                        unreachable!("Event::wait() observed invalid internal state")
                    }
                    EventState::Waiting => {}
                    EventState::Notified => break,
                }

                let deadline = match deadline {
                    Some(deadline) => deadline,
                    None => {
                        self.sync().wait();
                        continue;
                    }
                };

                let now = Instant::now();
                if now < deadline {
                    self.sync().timed_wait(deadline - now);
                    continue;
                }

                timed_out = true;
                self.state.set(EventState::Empty);
                break;
            }

            self.sync().release();
            !timed_out
        }
    }
}

#[cfg(windows)]
#[allow(non_camel_case_types)]
mod os {
    use std::{cell::UnsafeCell, convert::TryInto, pin::Pin, time::Duration};

    type BOOL = i32;
    type BOOLEAN = u8;
    const FALSE: BOOL = 0;

    type DWORD = u32;
    type ULONG = u32;
    const INFINITE: DWORD = !0;
    const ERROR_TIMEOUT: DWORD = 1460;

    type PVOID = *mut u8;
    const NULL: PVOID = std::ptr::null_mut();

    #[repr(C)]
    struct SRWLOCK(PVOID);
    const SRWLOCK_INIT: SRWLOCK = SRWLOCK(NULL);

    #[repr(C)]
    struct CONDITION_VARIABLE(PVOID);
    const CONDITION_VARIABLE_INIT: CONDITION_VARIABLE = CONDITION_VARIABLE(NULL);

    extern "system" {
        fn GetLastError() -> DWORD;
        fn TryAcquireSRWLockExclusive(lock: *mut SRWLOCK) -> BOOLEAN;
        fn AcquireSRWLockExclusive(lock: *mut SRWLOCK);
        fn ReleaseSRWLockExclusive(lock: *mut SRWLOCK);
        fn WakeConditionVariable(cond: *mut CONDITION_VARIABLE);
        fn SleepConditionVariableSRW(
            cond: *mut CONDITION_VARIABLE,
            lock: *mut SRWLOCK,
            millis: DWORD,
            flags: ULONG,
        ) -> BOOL;
    }

    pub(crate) struct OsLock(UnsafeCell<SRWLOCK>);

    impl OsLock {
        pub(crate) const fn new() -> Self {
            Self(UnsafeCell::new(SRWLOCK_INIT))
        }

        pub(crate) unsafe fn try_acquire(self: Pin<&Self>) -> bool {
            TryAcquireSRWLockExclusive(self.0.get()) != 0
        }

        pub(crate) unsafe fn acquire(self: Pin<&Self>) {
            AcquireSRWLockExclusive(self.0.get())
        }

        pub(crate) unsafe fn release(self: Pin<&Self>) {
            ReleaseSRWLockExclusive(self.0.get())
        }
    }

    pub(crate) struct OsEventSync {
        lock: UnsafeCell<SRWLOCK>,
        cond: UnsafeCell<CONDITION_VARIABLE>,
    }

    impl OsEventSync {
        pub const fn new() -> Self {
            Self {
                lock: UnsafeCell::new(SRWLOCK_INIT),
                cond: UnsafeCell::new(CONDITION_VARIABLE_INIT),
            }
        }

        pub(crate) unsafe fn acquire(self: Pin<&Self>) {
            AcquireSRWLockExclusive(self.lock.get())
        }

        pub(crate) unsafe fn release(self: Pin<&Self>) {
            ReleaseSRWLockExclusive(self.lock.get())
        }

        pub(crate) unsafe fn signal(self: Pin<&Self>) {
            WakeConditionVariable(self.cond.get())
        }

        pub(crate) unsafe fn wait(self: Pin<&Self>) {
            assert_ne!(
                FALSE,
                SleepConditionVariableSRW(self.cond.get(), self.lock.get(), INFINITE, 0)
            );
        }

        pub(crate) unsafe fn timed_wait(self: Pin<&Self>, duration: Duration) {
            let timeout_ms: DWORD = duration.as_millis().try_into().ok().unwrap_or(INFINITE);
            let status = SleepConditionVariableSRW(self.cond.get(), self.lock.get(), timeout_ms, 0);
            if status == FALSE {
                assert_eq!(ERROR_TIMEOUT, GetLastError());
            }
        }
    }
}

#[cfg(unix)]
mod os {
    use std::{cell::UnsafeCell, pin::Pin, time::Duration};

    pub(crate) use self::os_lock::OsLock;

    #[cfg(target_vendor = "apple")]
    mod os_lock {
        use std::{cell::UnsafeCell, pin::Pin};

        #[repr(C)]
        #[allow(non_camel_case_types)]
        struct os_unfair_lock_s(u32);

        extern "C" {
            fn os_unfair_lock_trylock(lock: *mut os_unfair_lock_s) -> bool;
            fn os_unfair_lock_lock(lock: *mut os_unfair_lock_s);
            fn os_unfair_lock_unlock(lock: *mut os_unfair_lock_s);
        }

        pub(crate) struct OsLock(UnsafeCell<os_unfair_lock_s>);

        impl OsLock {
            pub(crate) const fn new() -> Self {
                Self(UnsafeCell::new(os_unfair_lock_s(0)))
            }

            pub(crate) unsafe fn try_acquire(self: Pin<&Self>) -> bool {
                os_unfair_lock_trylock(self.0.get())
            }

            pub(crate) unsafe fn acquire(self: Pin<&Self>) {
                os_unfair_lock_lock(self.0.get())
            }

            pub(crate) unsafe fn release(self: Pin<&Self>) {
                os_unfair_lock_unlock(self.0.get())
            }
        }
    }

    #[cfg(not(target_vendor = "apple"))]
    mod os_lock {
        use std::{cell::UnsafeCell, marker::PhantomPinned, pin::Pin};

        pub(crate) struct OsLock {
            mutex: UnsafeCell<libc::pthread_mutex_t>,
            _pinned: PhantomPinned,
        }

        impl Drop for OsLock {
            fn drop(&mut self) {
                let rc = unsafe { libc::pthread_mutex_destroy(self.mutex.get()) };
                assert!(rc == 0 || rc == libc::EINVAL);
            }
        }

        impl OsLock {
            pub(crate) const fn new() -> Self {
                Self(UnsafeCell::new(libc::PTHREAD_MUTEX_INITIALIZER))
            }

            pub(crate) unsafe fn try_acquire(self: Pin<&Self>) -> bool {
                libc::pthread_mutex_trylock(self.0.get()) == 0
            }

            pub(crate) unsafe fn acquire(self: Pin<&Self>) {
                assert_eq!(0, libc::pthread_mutex_lock(self.0.get()));
            }

            pub(crate) unsafe fn release(self: Pin<&Self>) {
                assert_eq!(0, libc::pthread_mutex_unlock(self.0.get()));
            }
        }
    }

    pub(crate) struct OsEventSync {
        mutex: UnsafeCell<libc::pthread_mutex_t>,
        cond: UnsafeCell<libc::pthread_cond_t>,
    }

    impl OsEventSync {
        pub const fn new() -> Self {
            Self {
                mutex: UnsafeCell::new(libc::PTHREAD_MUTEX_INITIALIZER),
                cond: UnsafeCell::new(libc::PTHREAD_COND_INITIALIZER),
            }
        }

        pub(crate) unsafe fn acquire(self: Pin<&Self>) {
            assert_eq!(0, libc::pthread_mutex_lock(self.mutex.get()));
        }

        pub(crate) unsafe fn release(self: Pin<&Self>) {
            assert_eq!(0, libc::pthread_mutex_unlock(self.mutex.get()));
        }

        pub(crate) unsafe fn signal(self: Pin<&Self>) {
            assert_eq!(0, libc::pthread_cond_signal(self.cond.get()));
        }

        pub(crate) unsafe fn wait(self: Pin<&Self>) {
            assert_eq!(
                0,
                libc::pthread_cond_wait(self.cond.get(), self.mutex.get())
            );
        }

        pub(crate) unsafe fn timed_wait(self: Pin<&Self>, duration: Duration) {
            let mut timespec = Duration::from_nanos(Self::timestamp())
                .checked_add(duration)
                .and_then(|duration| {
                    duration
                        .as_secs()
                        .try_into::<libc::time_t>()
                        .ok()
                        .map(|seconds| libc::timespec {
                            tv_sec: seconds,
                            tv_nsec: duration
                                .subsec_nanos()
                                .try_into()
                                .expect("typeof(tv_nsec) isn't posix compliant"),
                        })
                })
                .unwrap_or_else(|| libc::timespec {
                    tv_sec: libc::time_t::MAX,
                    tv_nsec: 1_000_000_000 - 1,
                });

            let rc = libc::pthread_cond_timedwait(self.cond.get(), self.mutex.get(), &timespec);
            assert!(rc == 0 || rc == libc::ETIMEDOUT);
        }
    }
}
