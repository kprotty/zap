const std = @import("std");
const Worker = @import("../task.zig").Task.Scheduler.Worker;

pub const Thread = struct {
    pub const INVALID_PIN_CPU = std.math.maxInt(usize);

    pub fn spawn(
        worker_ptr: *Worker,
        is_main_thread: bool,
        max_stack_size: ?usize,
    ) !void {
        const Threading =
            if (std.builtin.os.tag == .windows) WinThread
            else if (std.builtin.link_libc) PThread
            else if (std.builtin.os.tag == .linux) LinuxClone
            else @compileError("Platform not supported");

        const param = Threading.toParameter(worker_ptr);
        if (is_main_thread) {
            _ = Threading.entry(param);
        } else {
            try Threading.spawn(param, max_stack_size);
        }
    }
};

const WinThread = struct {
    const windows = std.os.windows;

    const STACK_SIZE_PARAM_IS_A_RESERVATION = 0x10000;
    const GROUP_AFFINITY = extern struct {
        Mask: windows.SIZE_T,
        Group: windows.WORD,
        Reserved: [3]windows.WORD,
    };

    extern "kernel32" fn SetThreadAffinityMask(
        hThread: windows.HANDLE,
        dwThreadAffinityMask: usize,
    ) callconv(.Stdcall) usize;

    extern "kernel32" fn SetThreadGroupAffinity(
        hThread: windows.HANDLE,
        GroupAffinity: *const GROUP_AFFINITY,
        PreviousGroupAffinity: ?*GROUP_AFFINITY,
    ) callconv(.Stdcall) windows.BOOL;

    fn toParameter(worker: *Worker) windows.PVOID {
        return @ptrCast(windows.PVOID, worker);
    }

    fn entry(param: windows.PVOID) callconv(.C) windows.DWORD {
        const worker = @intToPtr(*Worker, @ptrToInt(param));
        bindThreadToCpu(worker.pin_cpu);
        worker.run();
        return 0;
    }

    fn spawn(param: windows.PVOID, max_stack_size: ?usize) !void {
        const handle = windows.kernel32.CreateThread(
            null,
            max_stack_size orelse 0,
            entry,
            param,
            if (max_stack_size != null) STACK_SIZE_PARAM_IS_A_RESERVATION else 0,
            null,
        ) orelse return error.SpawnError;

        windows.CloseHandle(handle);
    }

    fn bindThreadToCpu(cpu: usize) void {
        if (cpu == Thread.INVALID_PIN_CPU)
            return;

        if ((comptime isVersionOrHigher(.win7)) and @sizeOf(usize) == 8) {
            _ = SetThreadGroupAffinity(
                windows.kernel32.GetCurrentThread(),
                &GROUP_AFFINITY{
                    .Mask = @as(usize, 1) << @intCast(std.math.Log2Int(usize), cpu % 64),
                    .Group = @intCast(windows.WORD, cpu / 64),
                    .Reserved = [_]windows.WORD{0} ** 3,
                },
                null,
            );
            return;
        }

        if (cpu < @typeInfo(usize).Int.bits) {
            _ = SetThreadAffinityMask(
                windows.kernel32.GetCurrentThread(),
                @as(usize, 1) << @intCast(std.math.Log2Int(usize), cpu),
            );
        }
    }

    fn isVersionOrHigher(comptime target: std.Target.Os.WindowsVersion) bool {
        const current = std.builtin.os.version_range.windows.max;
        return @enumToInt(current) >= @enumToInt(target); 
    }
};

const LinuxClone = struct {
    const linux = std.os.linux;

    fn toParameter(worker: *Worker) usize {
        return @ptrToInt(worker);
    }

    fn entry(param: usize) callconv(.C) u8 {
        const worker = @intToPtr(*Worker, param);
        bindThreadToCpu(worker.pin_cpu);
        worker.run();
        return 0;
    }

    fn spawn(param: usize, max_stack_size: ?usize) !void {
        var mmap_size: usize = std.mem.page_size;
        const guard_end_offset = mmap_size;

        const stack_size = std.math.max(std.mem.page_size, max_stack_size orelse getStackSize());
        mmap_size = std.mem.alignForward(mmap_size + stack_size, std.mem.page_size);
        const stack_offset = mmap_size;
        
        mmap_size = std.mem.alignForward(mmap_size, linux.tls.tls_image.alloc_align);
        const tls_offset = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + linux.tls.tls_image.alloc_size, std.mem.page_size);

        const memory = try std.os.mmap(
            null,
            mmap_size,
            linux.PROT_NONE,
            linux.MAP_PRIVATE | linux.MAP_ANONYMOUS,
            -1,
            0,
        );
        errdefer std.os.munmap(memory);
        try std.os.mprotect(
            memory[guard_end_offset..],
            linux.PROT_READ | linux.PROT_WRITE,
        );

        var user_desc: if (std.builtin.arch == .i386) linux.user_desc else void = undefined;
        const tls_value = linux.tls.prepareTLS(memory[tls_offset..]);
        const tls_ptr = blk: {
            if (std.builtin.arch == .i386) {
                user_desc = linux.user_desc{
                    .entry_number = linux.tls.tls_image.gdt_entry_number,
                    .base_addr = tls_value,
                    .limit = 0xfffff,
                    .seg_32bit = 1,
                    .contents = 0, // Data
                    .read_exec_only = 0,
                    .limit_in_pages = 1,
                    .seg_not_present = 0,
                    .useable = 1,
                };
                break :blk @ptrToInt(&user_desc);
            } else {
                break :blk tls_value;
            }
        };

        const flags: u32 =
            linux.CLONE_DETACHED | linux.CLONE_SETTLS |
            linux.CLONE_VM | linux.CLONE_FS | linux.CLONE_FILES |
            linux.CLONE_SIGHAND | linux.CLONE_THREAD | linux.CLONE_SYSVSEM;
            
        var tid: c_int = undefined;
        const rc = linux.clone(
            entry,
            @ptrToInt(memory.ptr) + stack_offset,
            flags,
            param,
            &tid,
            tls_ptr,
            &tid,
        );
        if (linux.getErrno(rc) != 0)
            return error.SpawnError;
    }

    /// http://man7.org/linux/man-pages/man3/pthread_create.3.html
    fn getStackSize() usize {
        return switch (std.builtin.arch) {
            .i386, .x86_64, .s390x, .sparc, .sparcel => 2 * 1024 * 1024,
            .powerpc, .powerpc64, .powerpc64le, .sparcv9, => 4 * 1024 * 1024,
            else => @compileError("Architecture not supported"),
        };
    }

    fn bindThreadToCpu(cpu: usize) void {
        if (cpu == Thread.INVALID_PIN_CPU)
            return;

        var cpu_set: [4096]u8 align(@alignOf(c_ulonglong)) = undefined;
        if (cpu >= cpu_set.len)
            return;

        cpu_set = std.mem.zeroes(@TypeOf(cpu_set));
        cpu_set[cpu / 8] |= @as(u8, 1) << (@intCast(u3, cpu % 8));
        _ = linux.syscall3(
            linux.SYS.sched_setaffinity,
            0,
            @sizeOf(@TypeOf(cpu_set)),
            @ptrToInt(&cpu_set),
        );
    }
};

const PThread = struct {
    const c = std.c;

    const PTHREAD_CREATE_DETACHED = 1;
    extern "c" fn pthread_attr_setdetachstate(attr: *c.pthread_attr_t, state: c_int) callconv(.C) c_int;
    extern "c" fn pthread_attr_setstacksize(attr: *c.pthread_attr_t, stack_size: usize) callconv(.C) c_int;

    fn toParameter(worker: *Worker) *c_void {
        return @ptrCast(*c_void, worker);
    }

    fn entry(param: ?*c_void) callconv(.C) ?*c_void {
        const worker = @ptrCast(*Worker, @alignCast(@alignOf(*Worker), param.?));
        bindThreadToCpu(worker.pin_cpu);
        worker.run();
        return null;
    }
    
    fn spawn(param: ?*c_void, max_stack_size: ?usize) !void {
        var attr: c.pthread_attr_t = undefined;
        if (c.pthread_attr_init(&attr) != 0)
            return error.SystemResources;
        defer std.debug.assert(c.pthread_attr_destroy(&attr) == 0);

        std.debug.assert(pthread_attr_setstacksize(&attr, stack_size) == 0);
        std.debug.assert(pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED) == 0);

        var tid: c.pthread_t = undefined;
        if (c.pthread_create(&tid, &attr, entry, param) == 0)
            return error.SpawnError;
    }

    fn bindThreadToCpu(cpu: usize) void {
        if (cpu == Thread.INVALID_PIN_CPU)
            return;

        switch (std.builtin.os.tag) {
            .linux => LinuxClone.bindThreadToCpu(cpu),
            else => {},
        }
    }
};