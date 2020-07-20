const std = @import("std");
const backend = switch (std.builtin.os.tag) {
    .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => @import("./io/kqueue.zig"),
    .windows => @import("./io/iocp.zig"),
    .linux => @import("./io/epoll.zig"),
    else => @compileError(
        \\ Operating system not supported.
        \\ Please file an issue or submit a PR to upstream
    ),
};

pub const Driver = struct {
    driver: backend.Driver,

    pub const Error = error{

    };

    pub fn init() Error!void {
        return self.driver.init();
    }

    pub fn deinit(self: *Driver) void {
        self.driver.deinit();
        self.* = undefined;
    }

    pub fn shutdown(self: *Driver) void {
        return self.driver.shutdown();
    }

    pub fn run(self: *Driver) void {
        return self.driver.run();
    }

    pub fn exec(self: *Driver, commands: []Command) void {
        return self.driver.exec(commands);
    }

    pub const Command = union(enum) {
        SocketCreate: SocketCreate,
        SocketRegister: SocketRegister,
        SocketGet: SocketOption,
        SocketSet: SocketOption,
        SocketBind: SocketBind,
        SocketListen: SocketListen,
        SocketAccept: SocketAccept,
        SocketConnect: SocketConnect,
        SocketSend: SocketSend,
        SocketRecv: SocketRecv,
        SocketDestroy: SocketDestroy,

        pub const SocketCreate = struct {
            result: Socket.Error!void,
            address_family: u32,
            socket_type: u32,
            protocol: u32,
        };

        pub const SocketRegister = struct {
            result: Socket.RegisterError!void,
            socket: *Socket,
        };

        pub const SocketOption = struct {
            result: Socket.OptionError!void,
            socket: *Socket,
            level: u32,
            name: u32,
            value_ptr: usize,
            value_len: usize,
        };

        pub const SocketBind = struct {
            result: Socket.BindError!void,
            socket: *Socket,
            address: []const u8,
        };

        pub const SocketListen = struct {
            result: Socket.ListenError!void,
            socket: *Socket,
            backlog: u32,
        };

        pub const SocketAccept = struct {
            result: Socket.AcceptError!Handle,
            socket: *Socket,
            address: []u8,
        };

        pub const SocketConnect = struct {
            result: Socket.ConnectError!void,
            socket: *Socket,
            address: []const u8,
        };

        pub const SocketSend = struct {
            result: Socket.SendError!void,
            socket: *Socket,
            message: *Socket.Message,
            flags: u32,
        };

        pub const SocketRecv = struct {
            result: Socket.RecvError!void,
            socket: *Socket,
            message: *Socket.Message,
            flags: u32,
        };

        pub const SocketDestroy = struct {
            result: void,
            socket: *Socket,
        };
    };
};

pub const Buffer = extern struct {
    buffer: backend.Buffer,

    pub fn init(bytes: []u8) Buffer {

    }

    pub fn initConst(bytes: []const u8) Buffer {

    }

    pub fn asSlice(self: Buffer) []u8 {

    }

    pub fn asSliceConst(self: Buffer) []const u8 {

    }
};

pub const Buffer = BufferType(false);
pub const BufferConst = BufferType(true);

fn BufferType(comptime is_const: bool) type {
    const buffer_t = backend.Buffer;
    const bytes_t = if (is_const) [*]const u8 else [*]u8;
    const slice_t = @TypeOf(@as(bytes_t, undefined)[0..0]);

    return extern struct {
        const Self = @This();

        raw_buf: buffer_t,

        pub fn fromBytes(bytes: slice_t) Self {
            const raw_buf = buffer_t.init(@ptrToInt(bytes.ptr), bytes.len);
            return Self{.raw_buf = raw_buf };
        }

        pub fn toBytes(self: Self) slice_t {
            const ptr = @intToPtr(bytes_t, self.raw_buf.getPtr());
            const len = self.raw_buf.getLen();
            return ptr[0..len];
        }
    };
}

pub const Socket = struct {
    driver: *Driver,
    socket: backend.Socket,
    handle: backend.Socket.Handle,

    pub const Message = MessageType(false);
    pub const MessageConst = MessageType(true);

    fn MessageType(comptime is_const: bool) type {
        const message_t = backend.Socket.Message;
        const buffer_t = if (is_const) Buffer else BufferConst;
        const bytes_t = if (is_const) [*]const u8 else [*]u8;
        const slice_t = @TypeOf(@as(bytes_t, undefined)[0..0]);

        return extern struct {
            const Self = @This();

            message: message_t,

            pub fn from(
                msg_name: ?slice_t,
                msg_buffers: ?[]const buffer_t,
                msg_control: ?slice_t,
                msg_flags: u32,
            ) Self {
                const message = message_t.init(
                    if (msg_name) |name| @ptrToInt(name.ptr) else 0,
                    if (msg_name) |name| name.len else 0,
                    if (msg_buffers) |buffers| @ptrToInt(buffers.ptr) else 0,
                    if (msg_buffers) |buffers| buffers.len else 0,
                    if (msg_control) |control| @ptrToInt(control.ptr) else 0,
                    if (msg_control) |control| control.len else 0,
                    msg_flags,
                );
                return Self{.message = message};
            }

            pub fn getName(self: Self) slice_t {
                const ptr = @intToPtr(bytes_t, self.message.getNamePtr());
                const len = @intCast(usize, self.message.getNameLen());
                return ptr[0..len];
            }

            pub fn getBuffers(self: Self) []const buffer_t {
                const ptr = @intToPtr([*]const buffer_t, self.message.getBuffersPtr());
                const len = @intCast(usize, self.message.getBuffersLen());
                return ptr[0..len];
            }

            pub fn getControl(self: Self) slice_t {
                const ptr = @intToPtr(bytes_t, self.message.getControlPtr());
                const len = @intCast(usize, self.message.getControlLen());
                return ptr[0..len];
            }

            pub fn getFlags(self: Self) u32 {
                return self.message.getFlags();
            }
        };
    }
};