const std = @import("std");
const io = @import("../io.zig");
const windows = std.os.windows;

pub const Buffer = struct {
    wsabuf: WSABUF,

    const WSABUF = extern struct {
        len: windows.ULONG,
        buf: ?[*]u8,
    };

    pub fn init(ptr: usize, len: usize) Buffer {
        var wsabuf: WSABUF = undefined;
        wsabuf.buf = @intToPtr(@TypeOf(wsabuf.buf), ptr);
        wsabuf.len = @intCast(@TypeOf(wsabuf.len), len);
        return Buffer{.wsabuf = wsabuf};
    }

    pub fn getPtr(self: Buffer) usize {
        return @ptrToInt(self.wsabuf.buf);
    }

    pub fn getLen(self: Buffer) usize {
        return self.wsabuf.len;
    }
};

pub const Socket = struct {
    pub const Handle = windows.SOCKET;

    pub const Message = struct {
        wsamsg: WSAMSG,

        const WSAMSG = extern struct {
            name: ?*sockaddr,
            namelen: windows.INT,
            lpBuffers: [*]Buffer.WSABUF,
            dwBufferCount: windows.DWORD,
            Control: Buffer.WSABUF,
            dwFlags: windows.DWORD,
        };

        pub fn init(
            name_ptr: usize,
            name_len: usize,
            buffers_ptr: usize,
            buffers_len: usize,
            control_ptr: usize,
            control_len: usize,
            flags: u32,
        ) Message {
            var wsamsg: WSAMSG = undefined;
            wsamsg.name = @intToPtr(@TypeOf(wsamsg.name), name_ptr);
            wsamsg.namelen = @intCast(@TypeOf(wsamsg.namelen), name_len);
            wsamsg.lpBuffers = @intToPtr(@TypeOf(wsamsg.lpBuffers), buffers_ptr);
            wsamsg.dwBufferCount = @intCast(@TypeOf(wsamsg.dwBufferCount), buffers_len);
            wsamsg.Control.buf = @intToPtr(@TypeOf(wsamsg.Control.buf), control_ptr);
            wsamsg.Control.len = @intCast(@TypeOf(wsamsg.Control.len), control_len);
            wsamsg.dwFlags = flags;
            return Message{.wsamsg = wsamsg};
        }

        pub fn getNamePtr(self: Message) usize {
            return @ptrToInt(self.wsamsg.name);
        }

        pub fn getNameLen(self: Message) usize {
            return @intCast(usize, self.wsamsg.namelen);
        }

        pub fn getBuffersPtr(self: Message) usize {
            return @ptrToInt(self.wsamsg.lpBuffers);
        }

        pub fn getBuffersLen(self: Message) usize {
            return @intCast(usize, self.wsamsg.dwBufferCount);
        }

        pub fn getControlPtr(self: Message) usize {
            return @ptrToInt(self.wsamsg.Control.buf);
        }

        pub fn getControlLen(self: Message) usize {
            return @intCast(usize, self.wsamsg.Control.len);
        }

        pub fn getFlags(self: Message) u32 {
            return self.wsamsg.dwFlags;
        }
    };
};

pub const Driver = struct {
    iocp_handle: windows.HANDLE,

    pub fn init() io.Driver.Error!void {

    }

    pub fn deinit(self: *Driver) void {
        windows.CloseHandle(self.iocp_handle);
        self.* = undefined;
    }

    pub fn shutdown(self: *Driver) void {

    }

    pub fn run(self: *Driver) void {

    }

    pub fn exec(self: *Driver, commands: []io.Driver.Command) void {

    }
};