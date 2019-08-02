const os = @import("os.zig");
const zio = @import("../memory.zig");

pub fn map(address: ?[*]align(zio.page_size) u8, bytes: usize, flags: u32) zio.Error![]align(zio.page_size) u8 {
    const alloc_type = (if ((flags & zio.MEM_COMMIT) != 0) os.MEM_COMMIT else 0);
    const memory = os.VirtualAlloc(
        @ptrCast(?os.LPVOID, @alignCast(@alignOf(?os.LPVOID), address)),
        os.SIZE_T(bytes),
        os.DWORD(alloc_type),
        getProtectFlags(flags),
    ) orelse return null;
    return @ptrCast([*]align(zio.page_size) u8, @alignCast(zio.page_size, memory))[0..bytes];
}

pub fn unmap(memory: []align(zio.page_size) u8) void {
    _ = os.VirtualFree(
        @ptrCast(?os.LPVOID, @alignCast(@alignOf(?os.LPVOID), memory.ptr)),
        os.SIZE_T(0),
        os.MEM_RELEASE,
    );
}

pub fn protect(memory: []align(zio.page_size) u8, flags: u32) void {
    var old_protect: DWORD = undefined;
    _ = os.VirtualProtect(
        @ptrCast(?os.LPVOID, @alignCast(@alignOf(?os.LPVOID), memory.ptr)),
        os.SIZE_T(memory.len),
        getProtectFlags(flags),
        &old_protect,
    );
}

pub fn advise(memory: []align(zio.page_size) u8, flags: u32) void {
    if ((flags & zio.MEM_COMMIT) != 0) {
        _ = os.VirtualAlloc(
            @ptrCast(?os.LPVOID, @alignCast(@alignOf(?os.LPVOID), memory.ptr)),
            os.SIZE_T(memory.len),
            os.MEM_COMMIT,
            getProtectFlags(flags),
        );
    } else {
        _ = os.VirtualFree(
            @ptrCast(?os.LPVOID, @alignCast(@alignOf(?os.LPVOID), memory.ptr)),
            os.SIZE_T(memory.len),
            os.MEM_DECOMMIT,
        );
    }
}

fn getProtectFlags(flags: u32) os.DWORD {
    return switch (flags & (zio.MEM_EXEC | zio.MEM_READ | zio.MEM_WRITE)) {
        zio.MEM_EXEC | zio.MEM_READ | zio.MEM_WRITE, 
        zio.MEM_EXEC | zio.MEM_WRITE => os.PAGE_EXECUTE_READWRITE,
        zio.MEM_EXEC | zio.MEM_READ  => os.PAGE_EXECUTE_READ,
        zio.MEM_READ | zio.MEM_WRITE,
        zio.MEM_WRITE => os.PAGE_READWRITE,
        zio.MEM_READ => os.PAGE_READONLY,
        zio.MEM_EXEC => os.PAGE_EXECUTE,
        else => os.PAGE_NOACCESS,
    };
}