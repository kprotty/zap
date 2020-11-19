const core = @import("./core.zig");
const Waker = core.Waker;

const Waiter = struct {

};

const Bucket = struct {
    lock: core.Lock = core.Lock{},
    waiters: Waiter.Queue = Waiter.Queue{},

    var buckets = [_]Bucket{Bucket{}} ** 256;

    fn get(address: usize) *Bucket {
        const bits = @typeInfo(usize).Int.bits;
        const shift = bits - @ctz(usize, buckets.len);
        const seed = @truncate(usize, 0x9E3779B97F4A7C15);

        const hash = (address %* seed) >> shift;
        const index = hash % buckets.len;
        return &buckets[index];
    }
};

// https://github.com/jstimpfle/rb3ptr/blob/master/rb3ptr.c
const Waiter = struct {
    left: ?*Waiter,
    right: ?*Waiter,
    weight: usize,
    prev: ?*Waiter,
    next: ?*Waiter,
    tail: ?*Waiter,
    address: usize,
    waker: Waker,

    const Queue = struct {
        
    };
};