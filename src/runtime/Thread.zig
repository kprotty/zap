const std = @import("std");

// pub const Thread = if (std.builtin.os.tag == .windows)
//     WindowsThread
// else if (std.builtin.link_libc)
//     PosixThread
// else if (std.builtin.os.tag == .linux)
//     LinuxThread
// else
//     @compileError("Platform not supported");

pub const Thread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        const t = std.Thread.spawn(.{}, entryFn, .{context}) catch return false;
        t.detach();
        return true;
    }
};

const WindowsThread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        const Wrapper = struct {
            fn entry(raw_arg: std.os.windows.LPVOID) callconv(.C) std.os.windows.DWORD {
                entryFn(@ptrToInt(raw_arg));
                return 0;
            }
        };
        
        const handle = std.os.windows.kernel32.CreateThread(
            null,
            0, // use default stack size
            Wrapper.entry,
            @intToPtr(std.os.windows.LPVOID, context),
            0,
            null,
        ) orelse return false;

        // closing the handle detaches the thread
        std.os.windows.CloseHandle(handle);
        return true;
    }
};

const PosixThread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        const Wrapper = struct {
            fn entry(ctx: ?*c_void) callconv(.C) ?*c_void {
                entryFn(@ptrToInt(ctx));
                return null;
            }
        };

        var handle: std.c.pthread_t = undefined;
        const rc = std.c.pthread_create(
            &handle,
            null,
            Wrapper.entry,
            @intToPtr(?*c_void, context),
        );

        return rc == 0;
    }
};

const LinuxThread = struct {
    pub fn spawn(comptime entryFn: fn(usize) void, context: usize) bool {
        const stack_size = 4 * 1024 * 1024;

        var mmap_size: usize = std.mem.page_size;
        const guard_end = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + stack_size, std.mem.page_size);
        const stack_end = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size, @alignOf(Info));
        const info_begin = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + @sizeOf(Info), std.os.linux.tls.tls_image.alloc_align);
        const tls_begin = mmap_size;
        mmap_size = std.mem.alignForward(mmap_size + std.os.linux.tls.tls_image.alloc_size, std.mem.page_size);

        const mmap_bytes = std.os.mmap(
            null,
            mmap_size,
            std.os.PROT_NONE,
            std.os.MAP_PRIVATE | std.os.MAP_ANONYMOUS,
            -1,
            0,
        ) catch return false;

        std.os.mprotect(
            mmap_bytes[guard_end..],
            std.os.PROT_READ | std.os.PROT_WRITE,
        ) catch {
            std.os.munmap(mmap_bytes);
            return false;
        };

        const info = @ptrCast(*Info, @alignCast(@alignOf(Info), &mmap_bytes[info_begin]));
        info.* = .{
            .mmap_ptr = @ptrToInt(mmap_bytes.ptr),
            .mmap_len = mmap_bytes.len,
            .context = context,
            .callback = entryFn,
        };

        var user_desc: switch (std.builtin.arch) {
            .i386 => std.os.linux.user_desc,
            else => void,
        } = undefined;

        var tls_ptr = std.os.linux.tls.prepareTLS(mmap_bytes[tls_begin..]);
        if (std.builtin.arch == .i386) {
            defer tls_ptr = @ptrToInt(&user_desc);
            user_desc = .{
                .entry_number = std.os.linux.tls.tls_image.gdt_entry_number,
                .base_addr = tls_ptr,
                .limit = 0xfffff,
                .seg_32bit = 1,
                .contents = 0,
                .read_exec_only = 0,
                .limit_in_pages = 1,
                .seg_not_present = 0,
                .useable = 1,
            };
        }

        const flags: u32 = 
            std.os.CLONE_SIGHAND | std.os.CLONE_SYSVSEM |
            std.os.CLONE_VM | std.os.CLONE_FS | std.os.CLONE_FILES |
            std.os.CLONE_THREAD | std.os.CLONE_DETACHED | std.os.CLONE_SETTLS;

        var handle: i32 = undefined;
        const rc = std.os.linux.clone(
            Info.entry,
            @ptrToInt(&mmap_bytes[stack_end]),
            flags,
            @ptrToInt(info),
            &handle,
            tls_ptr,
            &handle, 
        );

        if (std.os.errno(rc) != 0) {
            std.os.munmap(mmap_bytes);
            return false;
        }

        return true;
    }

    const Info = struct {
        mmap_ptr: usize,
        mmap_len: usize,
        context: usize,
        callback: fn(usize) void,

        fn entry(raw_arg: usize) callconv(.C) u8 {
            const self = @intToPtr(*Info, raw_arg);
            _ = (self.callback)(self.context);
            __unmap_and_exit(self.mmap_ptr, self.mmap_len);
        }
    };

    extern fn __unmap_and_exit(ptr: usize, len: usize) callconv(.C) noreturn;
    comptime {
        asm(switch (std.builtin.arch) {
            .i386 => (
                \\.text
                \\.global __unmap_and_exit
                \\.type __unmap_and_exit, @function
                \\__unmap_and_exit:
                \\  movl $91, %eax
                \\  movl 4(%esp), %ebx
                \\  movl 8(%esp), %ecx
                \\  int $128
                \\  xorl %ebx, %ebx
                \\  movl $1, %eax
                \\  int $128
            ),
            .x86_64 => (
                \\.text
                \\.global __unmap_and_exit
                \\.type __unmap_and_exit, @function
                \\__unmap_and_exit:
                \\  movl $11, %eax
                \\  syscall
                \\  xor %rdi, %rdi
                \\  movl $60, %eax
                \\  syscall
            ),
            .arm, .armeb, .aarch64, .aarch64_be, .aarch64_32 => (
                \\.text
                \\.global __unmap_and_exit
                \\.type __unmap_and_exit, @function
                \\__unmap_and_exit:
                \\  mov r7, #91
                \\  svc 0
                \\  mov r7, #1
                \\  svc 0
            ),
            .mips, .mipsel, .mips64, .mips64el => (
                \\.set noreorder
                \\.global __unmap_and_exit
                \\.type __unmap_and_exit, @function
                \\__unmap_and_exit:
                \\  li $2, 4091
                \\  syscall
                \\  li $4, 0
                \\  li $2, 4001
                \\  syscall
            ),
            .powerpc, .powerpc64, .powerpc64le => (
                \\.text
                \\.global __unmap_and_exit
                \\.type __unmap_and_exit, @function
                \\__unmap_and_exit:
                \\  li 0, 91
                \\  sc
                \\  li 0, 1
                \\  sc
                \\  blr
            ),
            else => @compileError("Platform not supported"),
        });
    }
};