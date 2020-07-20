const std = @import("std");
const system = @import("../system.zig");

pub const AutoResetEvent = extern struct {
    state: State,
    cond: std.c.pthread_cond_t,
    mutex: std.c.pthread_mutex_t,

    const State = extern enum {
        empty,
        waiting,
        notified,
    };

    pub fn init(self: *AutoResetEvent) void {
        self.* = AutoResetEvent{
            .state = .empty,
            .cond = std.c.PTHREAD_COND_INITIALIZER,
            .mutex = std.c.PTHREAD_MUTEX_INITIALIZER,
        };
    }

    pub fn deinit(self: *AutoResetEvent) void {
        const err = if (std.builtin.os.tag == .dragonfly) std.os.EAGAIN else 0;

        const retc = std.c.pthread_cond_destroy(&self.cond);
        std.debug.assert(retc == 0 or retc == err);

        const retm = std.c.pthread_mutex_destroy(&self.mutex);
        std.debug.assert(retm == 0 or retm == err);
    }

    pub fn notify(self: *AutoResetEvent) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        switch (self.state) {
            .empty => {
                self.state = .notified;
            },
            .waiting => {
                self.state = .empty;
                std.debug.assert(std.c.pthread_cond_signal(&self.cond) == 0);
            },
            .notified => {}
        }
    }

    pub fn wait(self: *AutoResetEvent) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);

        switch (self.state) {
            .empty => {
                self.state = .waiting;
                while (self.state == .waiting) {
                    std.debug.assert(std.c.pthread_cond_wait(&self.cond, &self.mutex) == 0);
                }
            },
            .waiting => unreachable,
            .notified => {
                self.state = .empty;
            },
        }
    }
};