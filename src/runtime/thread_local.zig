// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");

pub fn ThreadLocalUsize(comptime UniqueKey: anytype) type {
    const is_apple_silicon = std.Target.current.isDarwin() and std.builtin.arch == .aarch64;

    // For normal platforms, we use the compilers built in "threadlocal" keyword.
    if (!is_apple_silicon) {
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

    // For Apple Silicon, LLD currently has some issues with it which prevents the threadlocal keyword from work correctly.
    // So for now we fallback to the OS provided thread local mechanics.
    return struct {
        const pthread_key_t = c_ulong;
        const pthread_once_t = extern struct {
            __sig: c_long = 0x30B1BCBA,
            __opaque: [4]u8 = [_]u8{ 0, 0, 0, 0 },
        };
        
        extern "c" fn pthread_once(o: *pthread_once_t, f: ?fn() callconv(.C) void) callconv(.C) c_int;
        extern "c" fn pthread_key_create(k: *pthread_key_t, d: ?fn(?*c_void) callconv(.C) void) callconv(.C) c_int;
        extern "c" fn pthread_setspecific(k: pthread_key_t, p: ?*c_void) callconv(.C) c_int;
        extern "c" fn pthread_getspecific(k: pthread_key_t) callconv(.C) ?*c_void;

        var tls_key: pthread_key_t = undefined;
        var tls_key_once: pthread_once_t = .{};

        fn tls_init() callconv(.C) void {
            std.debug.assert(pthread_key_create(&tls_key, null) == 0);
        }

        pub fn get() usize {
            std.debug.assert(pthread_once(&tls_key_once, tls_init) == 0);
            return @ptrToInt(pthread_getspecific(tls_key));
        }

        pub fn set(value: usize) void {
            std.debug.assert(pthread_once(&tls_key_once, tls_init) == 0);
            std.debug.assert(pthread_setspecific(tls_key, @intToPtr(?*c_void, value)) == 0);
        }
    };
}