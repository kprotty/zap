const std = @import("std");
const builtin = @import("builtin");

pub const Futex = switch (builtin.os) {
    .macosx,
    .tvos,
    .ios,
    .watchos,
    .netbsd,
    .openbsd,
    .freebsd,
    .kfreebsd,
    .dragonfly,
    .haiku,
    .hermit,
    .solaris,
    .minix,
    .fuchsia,
    .emscripten => if (builtin.link_libc) PosixFutex else SpinFutex,
    .linux => if (builtin.link_libc) PosixFutex else LinuxFutex,
    .windows => WindowsFutex,
    else => SpinFutex,
};

const SpinFutex = struct {
    pub fn init() SpinFutex {
        return SpinFutex{};
    }
    pub fn deinit(self: *SpinFutex) void {}

    pub fn wake(self: *SpinFutex, ptr: *const u32) void {}

    pub fn wait(self: *SpinFutex, ptr: *const u32, expected: u32) void {
        var backoff = SpinLock.Backoff.init();
        while (@atomicLoad(u32, ptr, .Monotonic) == expected)
            backoff.yield();
    }
};

const LinuxFutex = struct {
    const linux = std.os.linux;

    pub fn init() LinuxFutex {
        return LinuxFutex{};
    }
    pub fn deinit(self: *LinuxFutex) void {}

    pub fn wake(self: *LinuxFutex, ptr: *const u32) void {
        const rc = linux.futex_wake(@ptrCast(*const i32, ptr), linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
        assert(linux.getErrno(rc) == 0);
    }

    pub fn wait(self: *LinuxFutex, ptr: *const u32, expected: u32) void {
        const value = @intCast(i32, expected);
        while (@atomicLoad(u32, ptr, .Monotonic) == expected) {
            const rc = linux.futex_wait(@ptrCast(*const i32, ptr), linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, value, null);
            switch (linux.getErrno(rc)) {
                0, linux.EAGAIN => return,
                linux.EINTR => continue,
                linux.EINVAL => unreachable,
                else => unreachable,
            }
        }
    }
};

const WindowsFutex = struct {
    waiters: u32,

    pub fn init() WindowsFutex {
        return WindowsFutex{ .waiters = 0 };
    }
    pub fn deinit(self: *WindowsFutex) void {}

    pub fn wake(self: *WindowsFutex, ptr: *const u32) void {
        switch (Backend.get().*) {
            .WaitAddress => |*backend| backend.wake(ptr, &self.waiters),
            .KeyedEvent => |*backend| backend.wake(ptr, &self.waiters),
        }
    }

    pub fn wait(self: *WindowsFutex, ptr: *const u32, expected: u32) void {
        switch (Backend.get().*) {
            .WaitAddress => |*backend| backend.wait(ptr, expected, &self.waiters),
            .KeyedEvent => |*backend| backend.wait(ptr, expected, &self.waiters),
        }
    }

    const Backend = union(enum) {
        WaitAddress: WaitAddress,
        KeyedEvent: KeyedEvent,

        const windows = std.os.windows;
        var backend = std.lazyInit(Backend);

        fn get() *const Backend {
            return backend.get() orelse {
                // Statically linking to the KeyedEvent functions should mean its supported.
                // TODO: Maybe add a CreateSemaphore backend for systems older than Windows XP ?
                backend.data = WaitAddress.init() 
                    orelse KeyedEvent.init()
                    orelse unreachable; 
                backend.resolve();
                return &backend.data;
            };
        }

        const WaitAddress = struct {
            extern "kernel32" stdcallcc fn GetModuleHandleA(lpModuleName: ?[*]const windows.CHAR) ?windows.HMODULE;
            extern "kernel32" stdcallcc fn LoadLibraryA(lpLibFileName: [*]const windows.CHAR) ?windows.HMODULE;

            WakeByAddressSingle: stdcallcc fn(Address: *const c_void) void,
            WaitOnAddress: stdcallcc fn (
                Address: *const c_void,
                CompareAddress: *const c_void,
                AddressSize: windows.SIZE_T,
                dwMilliseconds: windows.DWORD,
            ) windows.BOOL,

            fn init() ?Backend {
                const dll_name = c"api-ms-win-core-synch-l1-2-0";
                const dll = GetModuleHandleA(dll_name) or LoadLibraryA(dll_name) orelse return null;

                var self: WaitAddress = undefined;
                const WaitOnAddress = windows.kernel32.GetProcAddress(dll, c"WaitOnAddress") orelse return null;
                self.WaitOnAddress = @intToPtr(@typeOf(self.WaitOnAddress), @ptrToInt(WaitOnAddress));
                const WakeByAddressSingle = windows.kernel32.GetProcAddress(dll, c"WakeByAddressSingle") orelse return null;
                self.WakeByAddressSingle = @intToPtr(@typeOf(self.WakeByAddressSingle), @ptrToInt(WakeByAddressSingle));
                return Backend{ .WaitAddress = self };
            }

            fn wake(self: WaitAddress, ptr: *const u32, waiters: *u32) void {
                const addr = @ptrCast(*const c_void, ptr);
                self.WakeByAddressSingle(addr);
            }

            fn wait(self: WaitAddress, ptr: *const u32, expected: u32, waiters: *u32) void {
                var compare = expected;
                const addr = @ptrCast(*const c_void, ptr);
                const cmp = @ptrCast(*const c_void, &compare);
                while (@atomicLoad(u32, ptr, .Monotonic) == expected)
                    _ = self.WaitOnAddress(addr, cmp, @sizeOf(u32), windows.INFINITE);
            }
        };

        const KeyedEvent = struct {
            handle: windows.HANDLE,

            extern "NtDll" stdcallcc fn NtCreateKeyedEvent(
                KeyedEventHandle: *windows.HANDLE,
                DesiredAccess: windows.ACCESS_MASK,
                ObjectAttributes: ?windows.PVOID,
                Flags: windows.ULONG,
            ) windows.NTSTATUS;
            extern "NtDll" stdcallcc fn NtWaitForKeyedEvent(
                EventHandle: windows.HANDLE,
                Key: *const c_void,
                Alertable: windows.BOOLEAN,
                Timeout: ?*windows.LARGE_INTEGER,
            ) windows.NTSTATUS;
            extern "NtDll" stdcallcc fn NtReleaseKeyedEvent(
                EventHandle: windows.HANDLE,
                Key: *const c_void,
                Alertable: windows.BOOLEAN,
                Timeout: ?*windows.LARGE_INTEGER,
            ) windows.NTSTATUS;

            fn init() ?Backend {
                var self: KeyedEvent = undefined;
                if (NtCreateKeyedEvent(&self.handle, windows.GENERIC_READ | windows.GENERIC_WRITE, null, 0) != 0)
                    return null;
                return Backend{ .KeyedEvent = self };
            }

            fn wake(self: KeyedEvent, ptr: *const u32, waiters: *u32) void {
                const key = @ptrCast(*const c_void, ptr);
                var waiting = @atomicLoad(u32, waiters, .Monotonic);
                while (waiting != 0) {
                    waiting = @cmpxchgWeak(u32, waiters, waiting, waiting - 1, .Acquire, .Monotonic) orelse {
                        const rc = NtReleaseKeyedEvent(self.handle, key, windows.FALSE, null);
                        assert(rc == 0);
                        return;
                    };
                }
            }

            fn wait(self: KeyedEvent, ptr: *const u32, expected: u32, waiters: *u32) void {
                const key = @ptrCast(*const c_void, ptr);
                while (@atomicLoad(u32, ptr, .Monotonic) == expected) {
                    _ = @atomicRmw(u32, waiters, .Add, 1, .Release);
                    const rc = NtWaitForKeyedEvent(self.handle, key, windows.FALSE, null);
                    assert(rc == 0);
                }
            }
        };
    };
};

const PosixFutex = struct {
    cond: pthread_cond_t,
    mutex: pthread_mutex_t,

    pub fn init() PosixFutex {
        return PosixFutex{
            .cond = PTHREAD_COND_INITIALIZER,
            .mutex = PTHREAD_MUTEX_INITIALIZER,
        };
    }

    pub fn deinit(self: *PosixFutex) void {
        // On dragonfly, the destroy functions return EINVAL if they were initialized statically.
        const retm = pthread_mutex_destroy(&self.mutex);
        assert(retm == 0 or retm == (if (builtin.os == .dragonfly) os.EINVAL else 0));
        const retc = pthread_cond_destroy(&self.cond);
        assert(retc == 0 or retc == (if (builtin.os == .dragonfly) os.EINVAL else 0));
    }

    pub fn wake(self: *PosixFutex, ptr: *const u32) void {
        assert(pthread_mutex_lock(&self.mutex) == 0);
        defer assert(pthread_mutex_unlock(&self.mutex) == 0);
        assert(pthread_cond_signal(&self.cond) == 0);
    }

    pub fn wait(self: *PosixFutex, ptr: *const u32, expected: u32) void {
        assert(pthread_mutex_lock(&self.mutex) == 0);
        defer assert(pthread_mutex_unlock(&self.mutex) == 0);
        while (@atomicLoad(u32, ptr, .Acquire) == expected)
            assert(pthread_cond_wait(&self.cond, &self.mutex) == 0);
    }

    const PTHREAD_MUTEX_INITIALIZER = pthread_mutex_t{};
    extern "c" fn pthread_mutex_lock(mutex: *pthread_mutex_t) c_int;
    extern "c" fn pthread_mutex_unlock(mutex: *pthread_mutex_t) c_int;
    extern "c" fn pthread_mutex_destroy(mutex: *pthread_mutex_t) c_int;

    const PTHREAD_COND_INITIALIZER = pthread_cond_t{};
    extern "c" fn pthread_cond_wait(noalias cond: *pthread_cond_t, noalias mutex: *pthread_mutex_t) c_int;
    extern "c" fn pthread_cond_signal(cond: *pthread_cond_t) c_int;
    extern "c" fn pthread_cond_destroy(cond: *pthread_cond_t) c_int;

    // https://github.com/rust-lang/libc
    usingnamespace switch (builtin.os) {
        .macosx, .tvos, .ios, .watchos => struct {
            pub const pthread_mutex_t = extern struct {
                __sig: c_long = 0x32AAABA7,
                __opaque: [__PTHREAD_MUTEX_SIZE__]u8 = [_]u8{0} ** __PTHREAD_MUTEX_SIZE__,
            };
            pub const pthread_cond_t = extern struct {
                __sig: c_long = 0x3CB0B1BB,
                __opaque: [__PTHREAD_COND_SIZE__]u8 = [_]u8{0} ** __PTHREAD_COND_SIZE__,
            };
            const __PTHREAD_MUTEX_SIZE__ = if (@sizeOf(usize) == 8) 56 else 40;
            const __PTHREAD_COND_SIZE__ = if (@sizeOf(usize) == 8) 40 else 24;
        },
        .netbsd => struct {
            pub const pthread_mutex_t = extern struct {
                ptm_magic: c_uint = 0x33330003,
                ptm_errorcheck: padded_spin_t = 0,
                ptm_unused: padded_spin_t = 0,
                ptm_owner: usize = 0,
                ptm_waiters: ?*u8 = null,
                ptm_recursed: c_uint = 0,
                ptm_spare2: ?*c_void = null,
            };
            pub const pthread_cond_t = extern struct {
                ptc_magic: c_uint = 0x55550005,
                ptc_lock: pthread_spin_t = 0,
                ptc_waiters_first: ?*u8 = null,
                ptc_waiters_last: ?*u8 = null,
                ptc_mutex: ?*pthread_mutex_t = null,
                ptc_private: ?*c_void = null,
            };
            const pthread_spin_t = if (builtin.arch == .arm or .arch == .powerpc) c_int else u8;
            const padded_spin_t = switch (builtin.arch) {
                .sparc, .sparcel, .sparcv9, .i386, .x86_64, .le64 => u32,
                else => spin_t,
            };
        },
        .openbsd, .freebsd, .kfreebsd, .dragonfly => struct {
            pub const pthread_mutex_t = extern struct {
                inner: ?*c_void = null,
            };
            pub const pthread_cond_t = extern struct {
                inner: ?*c_void = null,
            };
        },
        .haiku => struct {
            pub const pthread_mutex_t = extern struct {
                flags: u32 = 0,
                lock: i32 = 0,
                unused: i32 = -42,
                owner: i32 = -1,
                owner_count: i32 = 0,
            };
            pub const pthread_cond_t = extern struct {
                flags: u32 = 0,
                unused: i32 = -42,
                mutex: ?*c_void = null,
                waiter_count: i32 = 0,
                lock: i32 = 0,
            };
        },
        .hermit => struct {
            pub const pthread_mutex_t = extern struct {
                inner: usize = ~usize(0),
            };
            pub const pthread_cond_t = extern struct {
                inner: usize = ~usize(0),
            };
        },
        .solaris => struct {
            pub const pthread_mutex_t = extern struct {
                __pthread_mutex_flag1: u16 = 0,
                __pthread_mutex_flag2: u8 = 0,
                __pthread_mutex_ceiling: u8 = 0,
                __pthread_mutex_type: u16 = 0,
                __pthread_mutex_magic: u16 = 0x4d58,
                __pthread_mutex_lock: u64 = 0,
                __pthread_mutex_data: u64 = 0,
            };
            pub const pthread_cond_t = extern struct {
                __pthread_cond_flag: u32 = 0,
                __pthread_cond_type: u16 = 0,
                __pthread_cond_magic: u16 = 0x4356,
                __pthread_cond_data: u64 = 0,
            };
        },
        .fuchsia, .minix, .linux => struct {
            pub const pthread_mutex_t = extern struct {
                size: [__SIZEOF_PTHREAD_MUTEX_T]u8 align(@alignOf(usize)) = [_]u8{0} ** __SIZEOF_PTHREAD_MUTEX_T,
            };
            pub const pthread_cond_t = extern struct {
                size: [__SIZEOF_PTHREAD_COND_T]u8 align(@alignOf(usize)) = [_]u8{0} ** __SIZEOF_PTHREAD_COND_T,
            };
            const __SIZEOF_PTHREAD_COND_T = 48;
            const __SIZEOF_PTHREAD_MUTEX_T = if (builtin.os == .fuchsia) 40 else switch (builtin.abi) {
                .musl, .musleabi, .musleabihf => if (@sizeOf(usize) == 8) 40 else 24,
                .gnu, .gnuabin32, .gnuabi64, .gnueabi, .gnueabihf, .gnux32 => switch (builtin.arch) {
                    .aarch64 => 48,
                    .x86_64 => if (builtin.abi == .gnux32) 40 else 32,
                    .mips64, .powerpc64, .powerpc64le, .sparcv9 => 40,
                    else => if (@sizeOf(usize) == 8) 40 else 24,
                },
                else => unreachable,
            };
        },
        .emscripten => struct {
            pub const pthread_mutex_t = extern struct {
                size: [__SIZEOF_PTHREAD_MUTEX_T]u8 align(4) = [_]u8{0} ** __SIZEOF_PTHREAD_MUTEX_T,
            };
            pub const pthread_cond_t = extern struct {
                size: [__SIZEOF_PTHREAD_COND_T]u8 align(@alignOf(usize)) = [_]u8{0} ** __SIZEOF_PTHREAD_COND_T,
            };
            const __SIZEOF_PTHREAD_COND_T = 48;
            const __SIZEOF_PTHREAD_MUTEX_T = 28;
        },
        else => unreachable,
    };
};