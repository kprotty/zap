const std = @import("std");
const builtin = @import("builtin");

const Node = struct {
    workers: []
    const Worker = struct {
        pub threadlocal var current: ?*Worker = null;
    };
};