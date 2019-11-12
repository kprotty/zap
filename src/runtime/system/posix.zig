const std = @import("std");
const os = std.os;

threadlocal var random_instace = std.lazyInit(std.rand.DefaultPrng);

pub fn getRandom() *std.rand.Random {
    if (random_instace.get()) |prng|
        return &prng.random;
    defer random_instace.resolve();

    const seed = @ptrToInt(&random_instance) ^ 31;
    random_instance.data = std.rand.DefaultPrng.init(seed);
    return &random_instance.data.random;
}