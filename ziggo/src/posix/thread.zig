const std = @import("std");
const Node = @import("./node.zig").Node;

pub const Thread = struct {
    pub const Affinity = switch (std.builtin.os.tag) {
        .linux => @import("../linux/thread.zig").Thread.Affinity,
        else => struct {
            num_threads: usize,

            pub fn getCount(self: Affinity) usize {
                return self.num_threads;
            }

            pub fn bindCurrentThread(self: Affinity) void {
                // TODO: thread affinity for posix systems
            }
        },
    };

    pub const Handle = std.c.pthread_t;

    pub fn getCurrentHandle() ?Handle {
        return null; // no need to return std.c.pthread_self() since not pthread_join()'ing
    }

    pub fn spawn(
        node: *Node,
        max_stack_size: usize,
        parameter: var,
        comptime entryFn: var,
    ) ?Handle {
        const Parameter = @TypeOf(parameter);
        const Wrapper = struct {
            fn entry(arg: ?*c_void) callconv(.C) ?*c_void {
                const param = @ptrCast(Parameter, @alignCast(@alignOf(Parameter), arg));
                _ = @call(.{}, entryFn, .{param});
                return null;
            }
        };

        var attr: std.c.pthread_attr_t = undefined;
        if (std.c.pthread_attr_init(&attr) != 0)
            return null;
        defer std.debug.assert(std.c.pthread_attr_destroy(&attr) == 0);

        
        var stack_size = std.math.max(max_stack_size, PTHREAD_STACK_MIN);
        stack_size = std.mem.alignForward(stack_size, std.mem.page_size);
        std.debug.assert(pthread_attr_setstacksize(&attr, stack_size) == 0);

        // detached so doesnt need to be joined
        std.debug.assert(pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED) == 0);

        var handle: Handle = undefined;
        const err = std.c.pthread_create(
            &handle,
            &attr,
            Wrapper.entry,
            @ptrCast(*c_void, parameter),
        );
        if (err == 0)
            return handle;
        return null;
    }

    pub fn join(handle: Handle) void {
        // Nothing since detached
    }
};

const PTHREAD_CREATE_JOINABLE = 0;
const PTHREAD_CREATE_DETACHED = 1;
const PTHREAD_STACK_MIN = 16 * 1024;

extern "c" fn pthread_attr_setstacksize(
    attr: *std.c.pthread_attr_t,
    stack_size: usize,
) callconv(.C) c_int;

extern "c" fn pthread_attr_setdetachstate(
    attr: *std.c.pthread_attr_t,
    detach_state: c_int,
) callconv(.C) c_int;
