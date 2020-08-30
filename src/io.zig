// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const zap = @import("./zap.zig");

const io = switch (std.builtin.os.tag) {
    .windows => @import("./io/iocp.zig"),
    else => @compileError("OS not supported"),
};

pub const Buffer = extern struct {
    inner: io.Buffer,

    pub fn from(bytes: []u8) Buffer {
        return _from(bytes);
    }

    pub fn fromConst(bytes: []const u8) Buffer {
        return _from(bytes);
    }

    fn _from(bytes: anytype) Buffer {
        return Buffer{
            .inner = io.Buffer.from(
                @ptrToInt(bytes.ptr),
                bytes.len,
            ),
        };
    }
};

pub const Address = extern struct {
    inner: io.Address,

    
};

pub const Message = extern struct {
    inner: io.Message,
    
    pub fn from(
        address: ?[]u8,
        buffers: ?[]const Buffer,
        control: ?const Buffer,
        flags: u32,
    ) Message {
        return _from(address, buffers, control, flags);
    }

    pub fn fromConst(
        address: ?[]const u8,
        buffers: ?[]const Buffer,
        control: ?const Buffer,
        flags: u32,
    ) Message {
        return _from(address, buffers, control, flags);
    }

    fn _from(address: anytype, buffers: anytype, control: anytype, flags: u32) Message {
        return Message{
            .inner = io.Message.from(
                @ptrToInt(address.ptr),
                @intCast(u32, address.len),
                @ptrToInt(buffers.ptr),
                @intCast(u32, buffers.len),
                @ptrToInt(control.ptr),
                @intCast(u32, control.len),
                flags,
            ),
        };
    }
};

pub const Socket = extern struct {
    inner: io.Socket,

    pub const Handle = io.Socket.Handle;

    pub fn init(self: *Socket, family: u32, socket_type: u32, protocol: u32) !void {
        const driver = try Driver.get();
        const handle = try io.Socket.open(driver, family, socket_type, protocol);
        return self.inner.init(driver, handle);
    }

    pub fn fromHandle(self: *Socket, handle: Handle) !void {
        const driver = try Driver.get();
        return self.inner.init(driver, handle);
    }

    pub fn deinit(self: *Socket) void {
        self.inner.deinit();
    }

    pub fn getHandle(self: *Socket) Handle {
        return self.inner.getHandle();
    }

    pub fn bind(self: *Socket, address: []const u8) !void {
        return self.inner.bind(address);
    }

    pub fn listen(self: *Socket, backlog: u32) !void {
        return self.inner.listen(backlog);
    }

    pub fn connect(self: *Socket, address: []const u8) !void {
        return self.inner.connect(address);
    }

    pub fn accept(self: *Socket, address: []u8) !void {
        return self.inner.accept(address, flags);
    }

    pub fn readv(self: *Socket, buffers: []const Buffer) !usize {
        return self.recvmsg(&Message.from(null, buffers, null, 0));
    }

    pub fn read(self: *Socket, buffer: []u8) !usize {
        return self.recv(buffer, 0);
    }

    pub fn recv(self: *Socket, buffer: []u8, flags: u32) !usize {
        return self.recvfrom(null, buffer, flags);
    }

    pub fn recvfrom(self: *Socket, address: ?[]u8, buffer: []u8, flags: u32) !usize {
        return self.recvmsg(&Message.from(address, &[_]Buffer{ Buffer.from(buffer) }, null, flags));
    }

    pub fn recvmsg(self: *Socket, message: *Message) !usize {
        return self.inner.recvmsg(message);
    }

    pub fn writev(self: *Socket, buffers: []const Buffer) !usize {
        return self.sendmsg(&Message.from(null, buffers, null, 0));
    }

    pub fn write(self: *Socket, buffer: []const u8) !usize {
        return self.send(buffer, 0);
    }

    pub fn send(self: *Socket, buffer: []const u8, flags: u32) !usize {
        return self.sendto(null, buffer, flags);
    }

    pub fn sendto(self: *Socket, address: ?[]const u8, buffer: []const u8, flags: u32) !usize {
        return self.sendmsg(&Message.from(address, &[_]Buffer{ Buffer.fromConst(buffer) }, null, flags));
    }

    pub fn sendmsg(self: *Socket, message: *const Message) !usize {
        return self.inner.sendmsg(message);
    }
};

pub const Driver = extern struct {
    inner: io.Driver,

    pub const Error = error{NotInitialized}; 

    fn get() !*Driver {
        return zap.Task.getIoDriver() orelse Error.NotInitialized;
    }

    pub fn alloc() !*Driver {
        const inner = try io.Driver.alloc();
        return @fieldParentPtr(Driver, "inner", inner);
    }

    pub fn free(self: *Driver) void {
        self.inner.free();
    }

    pub fn run(self: *Driver) 
};
