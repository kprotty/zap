
#[cfg(feature = "loom")]
pub(crate) use loom::{
    alloc,
    thread,
    cell::UnsafeCell,
    sync::atomic::{AtomicUsize, Ordering, fence, spin_loop_hint},
};

#[cfg(not(feature = "loom"))]
pub(crate) use not_loom::*;

#[cfg(not(feature = "loom"))]
mod not_loom {
    pub(crate) use std::{
        alloc,
        thread,
        cell::UnsafeCell as StdUnsafeCell,
        sync::atomic::{AtomicUsize as StdAtomicUsize, Ordering, fence, spin_loop_hint},
    };
    
    pub(crate) struct UnsafeCell<T>(StdUnsafeCell<T>);

    impl<T> UnsafeCell<T> {
        pub(crate) fn new(value: T) -> Self {
            Self(StdUnsafeCell::new(value))
        }

        pub(crate) fn with<F>(&self, f: impl FnOnce(*const T) -> F) -> F {
            f(self.0.get())
        }
    }

    pub(crate) struct AtomicUsize(StdUnsafeCell<StdAtomicUsize>);

    impl AtomicUsize {
        pub(crate) fn new(value: usize) -> Self {
            Self(StdUnsafeCell::new(StdAtomicUsize::new(value)))
        }

        pub(crate) unsafe fn unsync_load(&self) -> usize {
            *(*self.0.get()).get_mut()
        }

        pub(crate) fn with_mut<F>(&mut self, f: impl FnOnce(&mut usize) -> F) -> F {
            f(unsafe { (*self.0.get()).get_mut() })
        }
    }

    impl std::os::Deref for AtomicUsize {
        type Target = StdAtomicUsize;

        fn deref(&self) -> &Self::Target {
            unsafe { &*self.0.get() }
        }
    }

    impl std::os::DerefMut for AtomicUsize {
        fn deref_mut(&mut self) -> &mut Self::Target {
            unsafe { &mut *self.0.get() }
        }
    }
}
