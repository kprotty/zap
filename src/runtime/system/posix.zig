const system = @import("./system.zig");

pub extern "C" fn usleep(us: c_uint) callconv(.C) c_int;
pub extern "c" fn sched_yield() callconv(.C) c_int;

pub extern "c" fn gettimeofday(
    noalias tv: ?*system.timeval,
    noalias tz: ?*system.timeval,
) callconv(.C) c_int;

pub extern "c" fn pthread_attr_init(a: ?*system.pthread_attr_t) callconv(.C) c_int;
pub extern "c" fn pthread_attr_destroy(a: ?*system.pthread_attr_t) callconv(.C) c_int;
pub extern "c" fn pthread_attr_setstacksize(a: ?*system.pthread_attr_t, s: usize) callconv(.C) c_int;
pub extern "c" fn pthread_attr_setdetachstate(a: ?*system.pthread_attr_t, d: c_int) callconv(.C) c_int;

pub extern "c" fn pthread_create(
    noalias t: ?*system.pthread_t,
    noalias a: ?*system.pthread_attr_t,
    f: fn(?*c_void) callconv(.C) ?*c_void,
    noalias p: ?*c_void,
) callconv(.C) c_int;

pub extern "c" fn pthread_mutex_init(
    noalias m: ?*system.pthread_mutex_t,
    noalias a: ?*system.pthread_mutexattr_t,
) callconv(.C) c_int;
pub extern "c" fn pthread_mutex_destroy(m: ?*system.pthread_mutex_t) callconv(.C) c_int;
pub extern "c" fn pthread_mutex_lock(m: ?*system.pthread_mutex_t) callconv(.C) c_int;
pub extern "c" fn pthread_mutex_unlock(m: ?*system.pthread_mutex_t) callconv(.C) c_int;

pub extern "c" fn pthread_cond_init(
    noalias c: ?*system.pthread_cond_t,
    noalias a: ?*system.pthread_condattr_t,
) callconv(.C) c_int;
pub extern "c" fn pthread_cond_destroy(c: ?*system.pthread_cond_t) callconv(.C) c_int;
pub extern "c" fn pthread_cond_signal(c: ?*system.pthread_cond_t) callconv(.C) c_int;
pub extern "c" fn pthread_cond_wait(
    noalias c: ?*system.pthread_cond_t,
    noalias m: ?*system.pthread_mutex_t,
) callconv(.C) c_int;
pub extern "c" fn pthread_cond_timedwait(
    noalias c: ?*system.pthread_cond_t,
    noalias m: ?*system.pthread_mutex_t,
    noalias t: ?*const system.timespec_t,
) callconv(.C) c_int;
