// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

pub fn ThreadLocalUsize(comptime UniqueKey: anytype) type {
    // For Apple Silicon, LLD currently has some issues with it which prevents the threadlocal keyword from work correctly.
    // So for now we fallback to the OS provided thread local mechanics.
    const is_apple_silicon = std.builtin.os.tag == .macos and std.builtin.arch == .aarch64;
    if (is_apple_silicon) {
        return struct {
            const dispatch_once_t = usize;
            const dispatch_function_t = fn (?*c_void) callconv(.C) void;
            extern fn dispatch_once_f(
                predicate: *dispatch_once_t,
                context: ?*c_void,
                function: dispatch_function_t,
            ) void;

            const pthread_key_t = c_ulong;
            extern "c" fn pthread_key_create(k: *pthread_key_t, d: ?fn (?*c_void) callconv(.C) void) callconv(.C) c_int;
            extern "c" fn pthread_setspecific(k: pthread_key_t, p: ?*c_void) callconv(.C) c_int;
            extern "c" fn pthread_getspecific(k: pthread_key_t) callconv(.C) ?*c_void;

            var tls_key: pthread_key_t = 0;
            var tls_key_once: dispatch_once_t = 0;

            fn tls_key_init(_: ?*c_void) callconv(.C) void {
                std.debug.assert(pthread_key_create(&tls_key, null) == 0);
            }

            pub fn get() usize {
                dispatch_once_f(&tls_key_once, null, tls_key_init);
                return @ptrToInt(pthread_getspecific(tls_key));
            }

            pub fn set(value: usize) void {
                dispatch_once_f(&tls_key_once, null, tls_key_init);
                std.debug.assert(pthread_setspecific(tls_key, @intToPtr(?*c_void, value)) == 0);
            }
        };
    }

    // For normal platforms, we use the compilers built in "threadlocal" keyword.
    return struct {
        threadlocal var tls_value: usize = 0;

        pub fn get() usize {
            return tls_value;
        }

        pub fn set(value: usize) void {
            tls_value = value;
        }
    };
}
