const zap = @import("../../zap.zig");
const target = zap.runtime.target;

const pthread_type_t = extern struct {
    _opaque: [64]u8 align(16) = undefined,
};

pub const pthread_attr_t = pthread_type_t;

pub extern "c" fn pthread_attr_init(a: ?*pthread_attr_t) callconv(.C) c_int;
pub extern "c" fn pthread_attr_destroy(a: ?*pthread_attr_t) callconv(.C) c_int;
pub extern "c" fn pthread_attr_setstacksize(a: ?*pthread_attr_t, s: usize) callconv(.C) c_int;
pub extern "c" fn pthread_attr_setdetachstate(a: ?*pthread_attr_t, d: c_int) callconv(.C) c_int;

pub const pthread_t = usize;

pub extern "c" fn pthread_create(
    noalias t: ?*pthread_t,
    noalias a: ?*pthread_attr_t,
    f: fn(?*c_void) callconv(.C) ?*c_void,
    noalias p: ?*c_void,
) callconv(.C) c_int;

pub const pthread_mutex_t = pthread_type_t;
pub const pthread_mutexattr_t = pthread_type_t;

pub extern "c" fn pthread_mutex_init(noalias m: ?*pthread_mutex_t, noalias a: ?*pthread_mutexattr_t) callconv(.C) c_int;
pub extern "c" fn pthread_mutex_destroy(m: ?*pthread_mutex_t) callconv(.C) c_int;
pub extern "c" fn pthread_mutex_lock(m: ?*pthread_mutex_t) callconv(.C) c_int;
pub extern "c" fn pthread_mutex_unlock(m: ?*pthread_mutex_t) callconv(.C) c_int;

pub const pthread_cond_t = pthread_type_t;
pub const pthread_condattr_t = pthread_type_t;

pub extern "c" fn pthread_cond_init(noalias c: ?*pthread_cond_t, noalias a: ?*pthread_condattr_t) callconv(.C) c_int;
pub extern "c" fn pthread_cond_destroy(c: ?*pthread_cond_t) callconv(.C) c_int;
pub extern "c" fn pthread_cond_signal(c: ?*pthread_cond_t) callconv(.C) c_int;
pub extern "c" fn pthread_cond_wait(noalias c: ?*pthread_cond_t, noalias m: ?*pthread_mutex_t) callconv(.C) c_int;
pub extern "c" fn pthread_cond_timedwait(
    noalias c: ?*pthread_cond_t,
    noalias m: ?*pthread_mutex_t,
    noalias t: ?*const timespec_t,
) callconv(.C) c_int;