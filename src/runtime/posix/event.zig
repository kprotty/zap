const std = @import("std");

pub const Event = struct {
    state: State,
    cond: pthread_cond_t,
    mutex: pthread_mutex_t,

    const State = enum {
        empty,
        waiting,
        notified,
    };

    pub fn init(noalias self: *Event) void {
        self.state = .empty;
        std.debug.assert(pthread_cond_init(&self.cond) == 0);
        std.debug.assert(pthread_mutex_init(&self.mutex) == 0);
    }

    pub fn deinit(noalias self: *Event) void {
        std.debug.assert(self.state == .empty);
        std.debug.assert(pthread_cond_destroy(&self.cond) == 0);
        std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);
    }

    pub fn notify(noalias self: *Event) void {
        std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

        switch (self.state) {
            .empty => {
                self.state = .notified;
            },
            .waiting => {
                self.state = .empty;
                std.debug.assert(pthread_cond_signal(&self.cond) == 0);
            },
            .notified => {
                std.debug.panic("Event.notify() when already notified", .{});
            },
        }
    }

    pub fn wait(noalias self: *Event) void {
        std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

        switch (self.state) {
            .empty => {
                self.state = .waiting;
                while (self.state == .waiting) {
                    std.debug.assert(pthread_cond_wait(&self.cond, &self.mutex) == 0);
                }
            },
            .waiting => {
                std.debug.panic("Event.wait() when already waiting", .{});
            },
            .notified => {
                self.state = .empty;
            }
        }
    }

    const pthread_cond_t = pthread_type_t;
    const pthread_mutex_t = pthread_type_t;
    const pthread_type_t = extern struct {
        _opaque: [64]u8 align(16),
    };

    extern "c" fn pthread_cond_init(
        noalias cond: *pthread_cond_t, 
    ) callconv(.C) c_int;

    extern "c" fn pthread_cond_destroy(
        noalias cond: *pthread_cond_t, 
    ) callconv(.C) c_int;

    extern "c" fn pthread_cond_signal(
        noalias cond: *pthread_cond_t, 
    ) callconv(.C) c_int;

    extern "c" fn pthread_cond_wait(
        noalias cond: *pthread_cond_t,
        noalias mutex: *pthread_mutex_t, 
    ) callconv(.C) c_int;

    extern "c" fn pthread_mutex_init(
        noalias cond: *pthread_cond_t, 
    ) callconv(.C) c_int;

    extern "c" fn pthread_mutex_destroy(
        noalias mutex: *pthread_mutex_t, 
    ) callconv(.C) c_int;

    extern "c" fn pthread_mutex_lock(
        noalias mutex: *pthread_mutex_t, 
    ) callconv(.C) c_int;

    extern "c" fn pthread_mutex_unlock(
        noalias mutex: *pthread_mutex_t, 
    ) callconv(.C) c_int;
};