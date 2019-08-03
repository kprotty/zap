const builtin = @import("builtin");
const Backend = switch (builtin.os) {
    .windows => @import("windows/memory.zig"),
    else => @compileError("Platform not supported"),
};

pub inline fn ptrCast(comptime To: type, from: var) To {
    return @ptrCast(To, @alignCast(@alignOf(To), from));
}

pub const page_size = 4 * 1024;

pub const MEM_EXEC = 1 << 0;
pub const MEM_READ = 1 << 1;
pub const MEM_WRITE = 1 << 2;
pub const MEM_COMMIT = 1 << 3;

pub const Error = error {
    OutOfMemory,
};

pub inline fn map(address: ?[*]align(page_size) u8, bytes: usize, flags: u32) Error![]align(page_size) u8 {
    return Backend.map(address, bytes, flags);
}

pub inline fn unmap(memory: []align(page_size) u8) void {
    return Backend.unmap(memory);
}

pub inline fn protect(memory: []align(page_size) u8, flags: u32) void {
    return Backend.protect(memory, flags);
}

pub inline fn advise(memory: []align(page_size) u8, flags: u32) void {
    return Backend.advise(memory, flags);
}

test "virtual memory" {
    var memory = try map(null, page_size * 64, 0);
    defer unmap(memory);

    protect(memory[0..page_size], MEM_READ | MEM_WRITE);
    advise(memory[0..page_size], MEM_READ | MEM_WRITE | MEM_COMMIT);
    memory[0] = 64;
}