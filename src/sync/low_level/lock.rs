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
            AcquireSRWLockExclusive(self.srwlock.get())
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
    use std::{
        hint::spin_loop,
        ptr,
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

                unsafe { Self::futex_wait(&self.state, CONTENDED) };
                state = self.state.load(Ordering::Relaxed);
            }
        }

        pub unsafe fn release(&self) {
            match self.state.swap(UNLOCKED, Ordering::Release) {
                UNLOCKED => unreachable!("unlocked an unlocked Lock"),
                LOCKED => {}
                CONTENDED => Self::futex_wake(&self.state, 1),
                _ => unreachable!("invalid Lock state"),
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
mod os {}
