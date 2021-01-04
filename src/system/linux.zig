const zap = @import("../../zap.zig");
const builtin = zap.builtin;

pub inline fn syscall(op: usize, args: anytype) usize {
    return systemCall(
        op,
        if (args.len > 0) @as(usize, args[0]) else 0,
        if (args.len > 1) @as(usize, args[1]) else 0,
        if (args.len > 2) @as(usize, args[2]) else 0,
        if (args.len > 3) @as(usize, args[3]) else 0,
        if (args.len > 4) @as(usize, args[4]) else 0,
        if (args.len > 5) @as(usize, args[5]) else 0,
    );
}

pub usingnamespace switch (builtin.arch) {
    .i386 => struct {
        pub fn systemCall(op: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) usize {
            // The 6th argument is passed via memory as we're out of registers if ebp is
            // used as frame pointer. We push arg6 value on the stack before changing
            // ebp or esp as the compiler may reference it as an offset relative to one
            // of those two registers.
            return asm volatile (
                \\ push %[arg6]
                \\ push %%ebp
                \\ mov  4(%%esp), %%ebp
                \\ int  $0x80
                \\ pop  %%ebp
                \\ add  $4, %%esp
                : [ret] "={eax}" (-> usize)
                : [number] "{eax}" (@enumToInt(number)),
                [arg1] "{ebx}" (arg1),
                [arg2] "{ecx}" (arg2),
                [arg3] "{edx}" (arg3),
                [arg4] "{esi}" (arg4),
                [arg5] "{edi}" (arg5),
                [arg6] "rm" (arg6)
                : "memory"
            );
        }
    },
    .x86_64 => struct {
        pub fn systemCall(op: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) usize {
            return asm volatile ("syscall"
                : [ret] "={rax}" (-> usize)
                : [number] "{rax}" (@enumToInt(number)),
                [arg1] "{rdi}" (arg1),
                [arg2] "{rsi}" (arg2),
                [arg3] "{rdx}" (arg3),
                [arg4] "{r10}" (arg4),
                [arg5] "{r8}" (arg5),
                [arg6] "{r9}" (arg6)
                : "rcx", "r11", "memory"
            );
        }
    },
    else => @compileError("TODO"),
};