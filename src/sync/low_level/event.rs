pub use os::AutoResetEvent;

#[cfg_attr(
    any(target_os = "linux", target_os = "android", target_vendor = "apple"),
    allow(unused)
)]
mod mutex_cond {
    use std::{cell::UnsafeCell, mem, pin::Pin};

    pub trait MutexCond: Default {
        unsafe fn lock(self: Pin<&Self>);
        unsafe fn unlock(self: Pin<&Self>);
        unsafe fn wait(self: Pin<&Self>);
        unsafe fn signal(self: Pin<&Self>);
    }

    #[derive(Copy, Clone, Debug, Eq, PartialEq)]
    enum MutexCondState {
        Empty,
        Waiting,
        Notified,
    }

    pub struct MutexCondAutoResetEvent<MC> {
        mutex_cond: MC,
        state: UnsafeCell<MutexCondState>,
    }

    impl<MC: MutexCond> Default for MutexCondAutoResetEvent<MC> {
        fn default() -> Self {
            Self {
                mutex_cond: MC::default(),
                state: UnsafeCell::new(MutexCondState::Empty),
            }
        }
    }

    impl<MC: MutexCond> MutexCondAutoResetEvent<MC> {
        fn with_lock<F>(self: Pin<&Self>, f: impl FnOnce(&Self) -> F) -> F {
            unsafe {
                let this = Pin::into_inner_unchecked(self);
                Pin::new_unchecked(&this.mutex_cond).lock();
                let result = f(this);
                Pin::new_unchecked(&this.mutex_cond).unlock();
                result
            }
        }

        pub fn wait(self: Pin<&Self>) {
            self.with_lock(|this| unsafe {
                let mut is_waiting = false;
                while {
                    let state = &mut *this.state.get();
                    match *state {
                        MutexCondState::Empty if !is_waiting => {
                            *state = MutexCondState::Waiting;
                            is_waiting = true;
                            true
                        }
                        MutexCondState::Empty => {
                            unreachable!("thread waiting with invalid state")
                        }
                        MutexCondState::Waiting if is_waiting => true,
                        MutexCondState::Waiting => {
                            unreachable!("multple threads waiting on same AutoResetEvent")
                        }
                        MutexCondState::Notified => {
                            *state = MutexCondState::Empty;
                            false
                        }
                    }
                } {
                    Pin::new_unchecked(&this.mutex_cond).wait();
                }
            })
        }

        pub fn notify(self: Pin<&Self>) {
            self.with_lock(|this| unsafe {
                match mem::replace(&mut *this.state.get(), MutexCondState::Notified) {
                    MutexCondState::Empty => {}
                    MutexCondState::Waiting => Pin::new_unchecked(&this.mutex_cond).signal(),
                    MutexCondState::Notified => {
                        unreachable!("AutoResetEvent notified multiple times")
                    }
                }
            })
        }
    }
}

#[cfg(target_os = "windows")]
mod os {
    use std::{cell::UnsafeCell, ffi::c_void, ptr};

    #[link(name = "kernel32")]
    extern "system" {
        fn AcquireSRWLockExclusive(lock: *mut *mut c_void);
        fn ReleaseSRWLockExclusive(lock: *mut *mut c_void);
        fn WakeConditionVariable(cond: *mut *mut c_void);
        fn SleepConditionVariableSRW(
            cond: *mut *mut c_void,
            lock: *mut *mut c_void,
            millis: u32,
            flags: u32,
        ) -> i32;
    }

    pub type AutoResetEvent = super::mutex_cond::MutexCondAutoResetEvent<SRWMutexCond>;

    pub struct SRWMutexCond {
        srwlock: UnsafeCell<*mut c_void>,
        cond: UnsafeCell<*mut c_void>,
    }

    unsafe impl Send for SRWMutexCond {}
    unsafe impl Sync for SRWMutexCond {}

    impl super::mutex_cond::MutexCond for SRWMutexCond {
        unsafe fn lock(self: Pin<&Self>) {
            AcquireSRWLockExclusive(self.srwlock.get())
        }

        unsafe fn unlock(self: Pin<&Self>) {
            ReleaseSRWLockExclusive(self.srwlock.get())
        }

        unsafe fn wait(self: Pin<&Self>) {
            SleepConditionVariableSRW(self.cond.get(), self.srwlock.get(), u32::MAX, 0)
        }

        unsafe fn signal(self: Pin<&Self>) {
            WakeConditionVariable(self.cond.get())
        }
    }
}

#[cfg(target_vendor = "apple")]
mod os {
    use std::{ffi::c_void, pin::Pin};

    #[link(name = "c")]
    extern "C" {
        fn dispatch_release(object: *mut c_void);
        fn dispatch_semaphore_create(value: isize) -> *mut c_void;
        fn dispatch_semaphore_signal(semaphore: *mut c_void) -> isize;
        fn dispatch_semaphore_wait(semaphore: *mut c_void, timeout: u64) -> isize;
    }

    pub struct AutoResetEvent {
        semaphore: *mut c_void,
    }

    impl Drop for AutoResetEvent {
        fn drop(&mut self) {
            unsafe { dispatch_release(self.semaphore) };
        }
    }

    impl Default for AutoResetEvent {
        fn default() -> Self {
            Self {
                semaphore: unsafe { dispatch_semaphore_create(0) },
            }
        }
    }

    impl AutoResetEvent {
        pub fn wait(self: Pin<&Self>) {
            let _ = unsafe { dispatch_semaphore_wait(self.semaphore, u64::MAX) };
        }

        pub fn notify(self: Pin<&Self>) {
            let _ = unsafe { dispatch_semaphore_signal(self.semaphore) };
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod os {
    use std::{pin::Pin, ptr, sync::atomic::{AtomicI32, Ordering}};

    const EMPTY: i32 = 0;
    const WAITING: i32 = 1;
    const NOTIFIED: i32 = 2;

    pub struct AutoResetEvent {
        state: AtomicI32,
    }

    impl Default for AutoResetEvent {
        fn default() -> Self {
            Self {
                state: AtomicI32::new(EMPTY),
            }
        }
    }

    impl AutoResetEvent {
        pub fn wait(self: Pin<&Self>) {
            match self.state.compare_exchange(
                EMPTY,
                WAITING,
                Ordering::Acquire,
                Ordering::Acquire,
            ) {
                Ok(_) => {},
                Err(NOTIFIED) => return,
                Err(_) => unreachable!("invalid AutoResetEvent state")
            }

            loop {
                unsafe { Self::futex_wait(&self.state, WAITING) };
                match self.state.load(Ordering::Acquire) {
                    EMPTY => unreachable!("AutoResetEvent waiting while empty"),
                    WAITING => continue,
                    NOTIFIED => return,
                    _ => unreachable!("invalid AutoResetEvent state"),
                }
            }
        }

        pub fn notify(self: Pin<&Self>) {
            match self.state.swap(NOTIFIED, Ordering::Release) {
                EMPTY => {},
                WAITING => unsafe { Self::futex_wake(&self.state, 1) },
                NOTIFIED => unreachable!("AutoResetEvent notified multiple times"),
                _ => unreachable!("invalid AutoResetEvent state"),
            }
        }

        #[cold]
        unsafe fn futex_wait(ptr: &AtomicI32, value: i32) {
            let _ = libc::syscall(
                libc::SYS_futex,
                ptr,
                libc::FUTEX_WAIT | libc::FUTEX_PRIVATE_FLAG,
                value,
                ptr::null::<libc::timespec>(),
            );
        }

        #[cold]
        unsafe fn futex_wake(ptr: &AtomicI32, waiters: i32) {
            let _ = libc::syscall(
                libc::SYS_futex,
                ptr,
                libc::FUTEX_WAIT | libc::FUTEX_PRIVATE_FLAG,
                waiters,
            );
        }
    }
}

#[cfg(all(
    unix,
    not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))
))]
mod os {
    use std::{cell::UnsafeCell, marker::PhantomPinned, pin::Pin, ptr};

    pub type AutoResetEvent = super::mutex_cond::MutexCondAutoResetEvent<PosixMutexCond>;

    pub struct PosixMutexCond {
        mutex: UnsafeCell<libc::pthread_mutex_t>,
        cond: UnsafeCell<libc::pthread_cond_t>,
        _pinned: PhantomPinned,
    }

    unsafe impl Send for PosixMutexCond {}
    unsafe impl Sync for PosixMutexCond {}

    impl super::mutex_cond::MutexCond for PosixMutexCond {
        unsafe fn lock(self: Pin<&Self>) {
            let this = Pin::into_inner_unchecked(self);
            assert_eq!(0, libc::pthread_mutex_lock(this.mutex.get()))
        }

        unsafe fn unlock(self: Pin<&Self>) {
            let this = Pin::into_inner_unchecked(self);
            assert_eq!(0, libc::pthread_mutex_unlock(this.mutex.get()))
        }

        unsafe fn wait(self: Pin<&Self>) {
            let this = Pin::into_inner_unchecked(self);
            assert_eq!(
                0,
                libc::pthread_cond_wait(this.cond.get(), this.mutex.get(), ptr::null(),)
            )
        }

        unsafe fn signal(self: Pin<&Self>) {
            let this = Pin::into_inner_unchecked(self);
            assert_eq!(0, libc::pthread_cond_signal(this.cond.get()))
        }
    }
}
