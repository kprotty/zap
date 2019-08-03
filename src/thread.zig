const builtin = @import("builtin");
const LazyInit = @import("sync.zig").LazyInit;
const ptrCast = @import("memory.zig").ptrCast;

const Backend = switch (builtin.os) {
    .windows => @import("windows/thread.zig"),
    else => @compileError("Platform not supported"),
};

pub const Id = Backend.Id;
pub const Handle = Backend.Handle;

/// The result of an error when spawning a new thread
pub const SpawnError = error {
    /// There was an unexpected error
    Unexpected,
    /// Not enough meomry to create the thread
    OutOfMemory,
    /// The limit of the amount of threads for the process has been reached
    TooManyThreads,
};

/// Spawn a thread to run a function and return the thread as a resource on success.
///     `function` the function to run. It has to take in the parameter and return a valid return type.
///         If the return type is an integer, it must be <= @sizeOf(usize) in memory.
///     `parameter` the parameter to pass into the function as context or state.
///         The parameter has to be <= @sizeOf(usize) as well. This means mostly integers and pointers are allowed.
///     `stack_size` the minimum of memory for the thread to use as stack space.
///         As this is **preferred**, the thread may or may not allocate more than specified.
///     returns a thread `Handle` which can be joined on to `wait` for completion.
pub inline fn spawn(comptime function: var, parameter: var, stack_size: usize) SpawnError!Handle {
    const ReturnType = @typeOf(function).ReturnType;
    const Parameter = @typeOf(parameter);
    const ParamSize = @sizeOf(Parameter);

    if (builtin.single_threaded)
        @compileError("Cant spawn threads in single-threaded mode");
    if (@ArgType(@typeOf(function), 0) != Parameter)
        @compileError("Function must take in typeof(parameter)");
    if (@sizeOf(Parameter) > @sizeOf(usize))
        @compileError("Parameter must be <= sizeof(usize)");
    if (@typeId(ReturnType) == .Int and @sizeOf(ReturnType) > @sizeOf(usize))
        @compileError("Function integer return type must be <= sizeof(usize)");

    const Wrapped = struct {
        fn Function(param: usize) usize {
            // memcpy convert usize into typeof(parameter)
            var real_param: Parameter = undefined;
            if (ParamSize > 0) {
                var param_arg = param;
                @memcpy(ptrCast([*]u8, &real_param), @ptrCast([*]const u8, &param_arg), ParamSize);
            }

            // then call the function and propagate the result if its an integer
            const result = function(real_param);
            return switch (@typeId(@typeOf(function).ReturnType)) {
                .Int => @intCast(usize, result),
                else => 0,
            };
        }
    };

    // memcpy convert parameter into usize
    var wrapped_param: usize = 0;
    if (ParamSize > 0) {
        var param_arg = parameter;
        @memcpy(ptrCast([*]u8, &wrapped_param), ptrCast([*]const u8, &param_arg), ParamSize);
    }

    // then call backend with normalized function (fn(usize) usize) and parameter (usize)
    return Backend.spawn(Wrapped.Function, wrapped_param, stack_size);
}

/// Error value when waiting for a thread to complete
pub const WaitError = error {
    /// The timeout was reached before the thread completed
    TimedOut,
    /// There was an unexpected error
    Unexpected,
};

/// Wait on a thread handle to complete execution.
///     `timeout_ms` the max number of milliseconds to block for, null if forever
///     returns a WaitError on error
pub inline fn wait(handle: Handle, timeout_ms: ?u32) WaitError!void {
    return Backend.wait(handle, timeout_ms);
}

/// Get the current thread id
pub inline fn currentId() Id {
    return Backend.currentId();
}

/// Get (and cache) the amount of logical cores in the CPU
pub inline fn cpuCount() usize {
    const Cache = struct {
        var cpu_count = LazyInit(usize, Backend.cpuCount).new();
    };
    return Cache.cpu_count.get().*;
}

test "threading" {
    const std = @import("std");
    std.debug.assert(cpuCount() > 0);

    const Sandbox = struct {
        var value: usize = 0;
        var not_main_thread = false;
        var other_thread_id: Id = undefined;

        export fn function(main_thread_id: Id) void {
            value = 1;
            other_thread_id = currentId();
            not_main_thread = main_thread_id != other_thread_id;
        }
    };

    var main_thread_id = currentId();
    std.debug.assert(Sandbox.value == 0);

    const other_thread = try spawn(Sandbox.function, main_thread_id, 64 * 1024);
    try wait(other_thread, 1000);
    std.debug.assert(Sandbox.value == 1);
    std.debug.assert(Sandbox.not_main_thread);
    std.debug.assert(Sandbox.other_thread_id != main_thread_id);
}