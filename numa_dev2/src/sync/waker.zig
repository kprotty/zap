
pub const Waker = struct {
    emitFn: fn(*Waker, Event) void,

    pub const Event = enum {
        setup,
        wake,
    };
};