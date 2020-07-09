#![no_std]
#![cfg_attr(feature = "nightly", feature(doc_cfg))]

#[cfg(feature = "core")]
#[cfg_attr(feature = "nightly", doc(cfg(feature = "core")))]
pub mod core;

#[cfg(feature = "sync")]
#[cfg_attr(feature = "nightly", doc(cfg(feature = "sync")))]
pub mod sync;

#[cfg(feature = "rt")]
#[cfg_attr(feature = "nightly", doc(cfg(feature = "rt")))]
pub mod runtime;
