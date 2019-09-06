const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const system = os.system;
const Backend = switch (builtin.os) {
    .linux => if (builtin.link_libc) Posix else Linux,
    .windows => Windows,
    else => Posix,
};

pub const yield = Backend.yield;
pub const spawn = Backend.spawn;
pub const stackSize = Backend.stackSize;
pub const nodeCount = Backend.nodeCount;
pub const nodeFree = Backend.nodeFree;
pub const nodeAlloc = Backend.nodeAlloc;
pub const nodeCommit = Backend.nodeCommit;
pub const nodeSetAffinity = Backend.nodeSetAffinity;

const Windows = struct {
    pub fn yield() void {
        _ = SwitchToThread();
    }

    pub fn stackSize(comptime function: var) usize {
        return 0; // windows doesnt allow custom thread stacks
    }

    pub fn spawn(stack: ?[]align(std.mem.page_size)u8, comptime function: var, parameter: var) !void {
        if (stack != null)
            return error.UnnecessaryStack;

        const Wrapper = struct {
            extern fn entry(arg: system.PVOID) system.DWORD {
                _ = function(@ptrCast(@typeOf(parameter), arg));
                return 0;
            }
        };

        const param = @ptrCast(system.PVOID, parameter);
        const stack_size = std.math.max(64 * 1024, @frameSize(function));
        const handle = system.kernel32.CreateThread(null, stack_size, Wrapper.entry, param, 0, null)
            orelse return system.unexpectedError(system.kernel32.GetLastError());
        system.CloseHandle(handle);
    }

    pub fn nodeCount() usize {
        var count: system.ULONG = undefined;
        if (GetNumaHighestNodeNumber(&count) != system.TRUE)
            return 1;
        return @intCast(usize, count);
    }

    pub fn nodeSetAffinity(node: usize) !void {
        var affinity: GROUP_AFFINITY = undefined;
        if (GetNumaNodeProcessorMaskEx(@truncate(system.USHORT, node), &affinity) != system.TRUE)
            return system.unexpectedError(system.kernel32.GetLastError());
        if (SetProcessAffinityMask(GetCurrentProcess(), @ptrCast(system.DWORD_PTR, affinity.Mask)) != system.TRUE)
            return system.unexpectedError(system.kernel32.GetLastError());
    }

    pub fn nodeAlloc(node: usize, bytes: usize) ![]align(std.mem.page_size) u8 {
        const memory = VirtualAllocExNuma(
            GetCurrentProcess(),
            null,
            bytes,
            system.MEM_RESERVE,
            system.PAGE_NOACCESS,
            @truncate(system.DWORD, node),
        ) orelse return error.OutOfMemory;
        return memory[0..bytes];
    }

    pub fn nodeFree(node: usize, memory: []align(std.mem.page_size) u8) void {
        _ = VirtualFreeEx(
            GetCurrentProcess(),
            @ptrCast(?system.PVOID, memory.ptr),
            0,
            system.MEM_RELEASE,
        );
    }

    pub fn nodeCommit(node: usize, memory: []align(std.mem.page_size) u8, validate: bool) !void {
        if (validate) {
            _ = VirtualAllocExNuma(
                GetCurrentProcess(),
                @ptrCast(?system.PVOID, memory.ptr),
                memory.len,
                system.MEM_COMMIT,
                system.PAGE_READWRITE,
                @truncate(system.DWORD, node),
            ) orelse return error.OutOfMemory;
        } else {
            if (VirtualFreeEx(
                GetCurrentProcess(),
                @ptrCast(?system.PVOID, memory.ptr),
                memory.len,
                system.MEM_DECOMMIT,
            ) != system.TRUE)
                return error.InvalidMemory;
        }
    }

    const KAFFINITY = system.ULONG_PTR;
    const GROUP_AFFINITY = extern struct {
        Mask: KAFFINITY,
        Group: system.USHORT,
        Reserved: [3]system.USHORT,
    };

    extern "kernel32" stdcallcc fn SwitchToThread() system.BOOL;
    extern "kernel32" stdcallcc fn GetCurrentProcess() system.HANDLE;

    extern "kernel32" stdcallcc fn SetProcessAffinityMask(
        hProcess: system.HANDLE,
        dwProcessAffinity: system.DWORD_PTR,
    ) system.BOOL;
    extern "kernel32" stdcallcc fn GetNumaNodeProcessorMaskEx(
        Node: system.USHORT,
        ProcessAffinity: *GROUP_AFFINITY,
    ) system.BOOL;

    extern "kernel32" stdcallcc fn VirtualFreeEx(
        hProcess: system.HANDLE,
        lpAddress: ?system.PVOID,
        dwSize: system.SIZE_T,
        dwFreeType: system.DWORD,
    ) system.BOOL;
    extern "kernel32" stdcallcc fn VirtualAllocExNuma(
        hProcess: system.HANDLE,
        lpAddress: ?system.PVOID,
        dwSize: system.SIZE_T,
        flAllocationType: system.DWORD,
        flProtect: system.DWORD,
        numaNodePreferred: system.DWORD,
    ) ?[*]align(std.mem.page_size) u8;
};

const Posix = struct {
    pub fn stackSize(comptime function: var) usize {
        return std.mem.alignForward(@frameSize(function), std.mem.page_size);
    }

    pub fn spawn(stack: ?[]align(std.mem.page_size)u8, comptime function: var, parameter: var) !void {
        var attr: system.pthread_attr_t = undefined;
        if (system.pthread_attr_init(&attr) != 0)
            return error.OutOfMemory;
        defer std.debug.assert(system.pthread_attr_destroy(&attr) == 0);
        const memory = stack orelse return error.InvalidStackMemory;
        std.debug.assert(system.pthread_attr_setstack(&attr, memory.ptr, stackSize(function)) == 0);
        
        const Wrapper = struct {
            extern fn entry(arg: ?*c_void) ?*c_void {
                _ = function(@ptrCast(@typeOf(parameter), arg));
                return null;
            }
        };

        var tid: system.pthread_t = undefined;
        return switch (system.pthread_create(&tid, &attr, Wrapper.entry, @ptrCast(*c_void, parameter))) {
            0 => {},
            os.EAGAIN => error.OutOfMemory,
            os.EPERM, os.EINVAL => unreachable,
            else => |err| os.unexpectedError(err),
        };
    }
};

const Linux = struct {
    pub fn stackSize(comptime function: var) usize {
        var size = std.mem.alignForward(@frameSize(function), std.mem.page_size);
        if (system.tls.tls_image) |tls_image|
            size = std.mem.alignForward(size, @alignOf(usize)) + tls_image.alloc_size;
        return size;
    }

    pub fn spawn(stack: ?[]align(std.mem.page_size)u8, comptime function: var, parameter: var) !void {
        const memory = stack orelse return error.InvalidStackMemory;
        var clone_flags = 
            os.CLONE_VM | os.CLONE_FS | os.CLONE_FILES |
            os.CLONE_THREAD | os.CLONE_SIGHAND | os.CLONE_SYSVSEM;

        var tls_offset: usize = undefined;
        if (system.tls.tls_image) |tls_image| {
            clone_flags |= os.CLONE_SETTLS;
            const tls_start = @ptrToInt(memory.ptr) + stackSize(function) - tls_image.alloc_size;
            tls_offset = system.tls.copyTLS(tls_start);
        }

        const Wrapper = struct {
            extern fn entry(arg: usize) u8 {
                _ = function(@intToPtr(@typeOf(parameter), arg));
                return 0;
            }
        };

        const stack_size = std.mem.alignForward(@frameSize(function), std.mem.page_size);
        return switch (system.clone(
            Wrapper.entry,
            @ptrToInt(&memory[stack_size]),
            clone_flags,
            @ptrToInt(parameter),
            @ptrCast(*i32, &memory[0]),
            tls_offset,
            @ptrCast(*i32, &memory[0]),
        )) {
            0 => {},
            os.EPERM, os.EINVAL, os.ENOSPC, os.EUSERS => unreachable,
            os.ENOMEM => error.OutOfMemory,
            os.EAGAIN => error.TooManyThreads,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn nodeCount() usize {
        var dir_iter: DirIterator = undefined;
        dir_iter.init("/sys/devices/system/node\x00") catch return 1;
        defer dir_iter.close();
        
        var nodes = usize(0);
        while (dir_iter.next()) |dir| {
            if (std.mem.startsWith(u8, dir, "node"))
                nodes += 1;
        }
        return nodes;
    }

    pub fn nodeSetAffinity(node: usize) !void {
        var dir_bytes: [64]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(dir_bytes[0..], "/sys/devices/system/node/node{}\x00", node);

        var dir_iter: DirIterator = undefined;
        try dir_iter.init(dir_name);
        defer dir_iter.close();

        var cpu_set: [512]u8 = undefined; // 512 * 8bits = 4096 max logical cpu cores
        while (dir_iter.next()) |dir| {
            if (std.mem.startsWith(u8, dir, "cpu")) {
                const cpu = try std.fmt.parseInt(usize, dir[3..], 10);
                cpu_set[cpu / 8] |= u8(1) << @truncate(u3, cpu % 8);
            }
        }

        return switch (os.errno(system.syscall3(
            system.SYS_sched_setaffinity,
            0, // current pid
            @sizeOf(@typeOf(cpu_set)),
            @ptrToInt(cpu_set[0..].ptr),
        ))) {
            0 => {},
            os.EINVAL => error.TooManyCpuCores,
            os.EFAULT, os.EPERM, os.ESRCH => unreachable,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn nodeAlloc(node: usize, bytes: usize) ![]align(std.mem.page_size) u8 {
        var node_mask: [64]c_ulong = undefined;
        std.mem.secureZero(c_ulong, node_mask[0..]);
        node_mask[node / @sizeOf(c_ulong)] = c_ulong(1) << @truncate(u5, node % @sizeOf(c_ulong));

        const memory = try os.mmap(null, bytes, os.PROT_NONE, os.MAP_PRIVATE | os.MAP_ANONYMOUS, -1, 0);
        return switch (os.errno(system.syscall6(
            system.SYS_mbind,
            @ptrToInt(memory.ptr),
            memory.len,
            MPOL_DEFAULT,
            @ptrToInt(node_mask[0..].ptr),
            node_mask.len + 1,
            0,
        ))) {
            0 => memory,
            os.ENOMEM => error.OutOfMemory,
            os.EIO, os.EPERM, os.EFAULT, os.EINVAL => unreachable,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn nodeFree(node: usize, memory: []align(std.mem.page_size) u8) void {
        os.munmap(memory);
    }

    pub fn nodeCommit(node: usize, memory: []align(std.mem.page_size) u8, validate: bool) !void {
        if (validate) {
            try os.mprotect(memory, os.PROT_READ | os.PROT_WRITE);
        } else {
            return switch (os.errno(system.syscall3(
                system.SYS_madvise,
                @ptrToInt(memory.ptr),
                memory.len,
                MADV_FREE,
            ))) {
                0 => {},
                os.EAGAIN, os.ENOMEM => error.OutOfMemory,
                os.EACCES, os.EBADF, os.EINVAL, os.EPERM => unreachable,
                else => |err| os.unexpectedErrno(err),
            };
        }
    }

    const MADV_FREE = 8;
    const MPOL_BIND = 2;
    const MPOL_DEFAULT = 0;
    const MPOL_PREFERRED = 1;
    
    const DirIterator = struct {
        const linux_dirent = extern struct {
            d_ino: c_ulong,
            d_off: c_ulong,
            d_reclen: c_ushort,
            d_name: [0]u8,
        };

        fd: usize,
        pos: usize,
        read: usize,
        buffer: [64 * 1024]u8,
        
        pub fn init(self: *@This(), dirname: []const u8) !void {
            self.fd = system.syscall2(system.SYS_open, @ptrToInt(dirname.ptr), system.O_RDONLY | system.O_DIRECTORY);
            var errno = system.getErrno(self.fd);
            if (errno != 0)
                return os.unexpectedErrno(errno);

            self.pos = 0;
            errno = self.readDir();
            if (errno != 0)
                return os.unexpectedErrno(errno);
        }

        pub fn close(self: *@This()) void {
            _ = system.syscall1(system.SYS_close, self.fd);
        }

        pub fn next(self: *@This()) ?[]const u8 {
            while (true) {
                if (self.pos >= self.read and self.readDir() != 0)
                    return null;
                const dirent = @ptrCast(*linux_dirent, @alignCast(@alignOf(linux_dirent), &self.buffer[self.pos]));
                self.pos += @sizeOf(linux_dirent) + dirent.d_reclen;
                if (dirent.d_ino != 0)
                    return std.mem.toSliceConst(u8, dirent.d_name[0..].ptr);
            }
        }

        fn readDir(self: *@This()) u12 {
            self.read = system.syscall3(
                system.SYS_getdents,
                self.fd,
                @ptrToInt(self.buffer[0..].ptr),
                self.buffer.len - 1,
            );
            self.buffer[self.buffer.len - 1] = 0;
            if (self.read == 0)
                return os.EAGAIN;
            return system.getErrno(self.read);
        }
    };
};