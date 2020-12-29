
pub const os_unfair_lock = u32;
pub const os_unfair_lock_t = *os_unfair_lock;
pub const OS_UNFAIR_LOCK_INIT: os_unfair_lock = 0;

pub extern "c" fn os_unfair_lock_lock(
    unfair_lock: os_unfair_lock_t,
) callconv(.C) void;

pub extern "c" fn os_unfair_lock_trylock(
    unfair_lock: os_unfair_lock_t,
) callconv(.C) bool;

pub extern "c" fn os_unfair_lock_unlock(
    unfair_lock: os_unfair_lock_t,
) callconv(.C) void;