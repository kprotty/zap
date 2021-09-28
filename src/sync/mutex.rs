use super::low_level::{Spin, WaitQueue, WaitToken, WakeToken};
use std::{
    cell::UnsafeCell,
    fmt,
    ops::{Deref, DerefMut},
    sync::atomic::{AtomicU8, Ordering},
};

const UNLOCKED: u8 = 0;
const LOCKED: u8 = 1;
const CONTENDED: u8 = 2;

pub struct Mutex<T> {
    state: AtomicU8,
    queue: WaitQueue,
    value: UnsafeCell<T>,
}

unsafe impl<T: Send> Send for Mutex<T> {}
unsafe impl<T: Send> Sync for Mutex<T> {}

impl<T> AsMut<T> for Mutex<T> {
    fn as_mut(&mut self) -> &mut T {
        unsafe { &mut *self.value.get() }
    }
}

impl<T: Default> Default for Mutex<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T: fmt::Debug> fmt::Debug for Mutex<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.try_lock() {
            Some(guard) => f.debug_struct("Mutex").field("data", &&*guard).finish(),
            None => f
                .debug_struct("Mutex")
                .field("data", &&*"<locked>")
                .finish(),
        }
    }
}

impl<T> Mutex<T> {
    pub const fn new(value: T) -> Self {
        Self {
            state: AtomicU8::new(UNLOCKED),
            queue: WaitQueue::new(),
            value: UnsafeCell::new(value),
        }
    }

    pub fn into_inner(self) -> T {
        self.value.into_inner()
    }

    pub fn is_locked(&self) -> bool {
        self.state.load(Ordering::Acquire) != UNLOCKED
    }

    pub fn try_lock(&self) -> Option<MutexGuard<'_, T>> {
        self.state
            .compare_exchange(UNLOCKED, LOCKED, Ordering::Acquire, Ordering::Relaxed)
            .map(|_| MutexGuard { mutex: self })
            .ok()
    }

    pub async fn lock(&self) -> MutexGuard<'_, T> {
        if let Err(_) =
            self.state
                .compare_exchange_weak(UNLOCKED, LOCKED, Ordering::Acquire, Ordering::Relaxed)
        {
            self.lock_slow().await;
        }
        MutexGuard { mutex: self }
    }

    #[cold]
    async fn lock_slow(&self) {
        let mut state = UNLOCKED;
        let mut spin = Spin::default();

        while spin.yield_now() {
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
                            _ => unreachable!("invalid Mutex state"),
                        },
                        Ordering::Relaxed,
                    ) {
                        Ok(UNLOCKED) => return,
                        Ok(LOCKED) => break,
                        Ok(_) => unreachable!("invalid Mutex state"),
                        Err(e) => state = e,
                    }
                }
            }

            let validate = || match self.state.load(Ordering::Relaxed) {
                UNLOCKED | LOCKED => None,
                CONTENDED => Some(WaitToken(0)),
                _ => unreachable!("invalid Mutex state"),
            };

            let cancelled = |_, has_more: bool| {
                if !has_more {
                    let _ = self.state.compare_exchange(
                        CONTENDED,
                        LOCKED,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    );
                }
            };

            self.queue.wait(0, validate, cancelled).await;
            state = self.state.load(Ordering::Relaxed);
        }
    }

    #[inline]
    fn unlock(&self) {
        match self.state.swap(UNLOCKED, Ordering::Release) {
            UNLOCKED => unreachable!("unlocked an unlocked mutex"),
            LOCKED => {}
            CONTENDED => self.queue.notify(0, WakeToken(0), 1, |_| {}),
            _ => unreachable!("invalid Mutex state"),
        }
    }
}

pub struct MutexGuard<'a, T> {
    mutex: &'a Mutex<T>,
}

impl<'a, T> Drop for MutexGuard<'a, T> {
    fn drop(&mut self) {
        self.mutex.unlock()
    }
}

impl<'a, T> Deref for MutexGuard<'a, T> {
    type Target = T;

    fn deref(&self) -> &T {
        unsafe { &*self.mutex.value.get() }
    }
}

impl<'a, T> DerefMut for MutexGuard<'a, T> {
    fn deref_mut(&mut self) -> &mut T {
        unsafe { &mut *self.mutex.value.get() }
    }
}

impl<'a, T: fmt::Debug> fmt::Debug for MutexGuard<'a, T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&**self, f)
    }
}

impl<'a, T: fmt::Display> fmt::Display for MutexGuard<'a, T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        (**self).fmt(f)
    }
}
