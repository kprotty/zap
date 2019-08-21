const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");
const scheduler = @import("scheduler.zig");

pub const Buffer = Backend.Buffer;
pub const Socket = Backend.Socket;
pub const Selector = Backend.Selector;

const Backend = switch (builtin.os) {
    .linux => Linux,
    .windows => Windows,
    else => Posix,
};

const Windows = struct {
    const windows = std.os.windows;
    
    pub const Selector = struct {
        pub const Event = OVERLAPPED_ENTRY;
        iocp: windows.HANDLE,

        pub fn init(self: *@This()) !void {

        }

        pub fn close(self: *@This()) !void {

        }

        pub fn notify(self: *@This(), task: *scheduler.Task) void {

        }

        pub fn poll(self: *@This(), events: []Event, timeout_ms: ?u32) ?*scheduler.Task {

        }
    };

    pub const Buffer = struct {
        pub fn extract(data: *Buffer) *[]const u8 {

        }

        pub fn convert(data: *[]const u8) *Buffer {

        }
    };

    pub const Socket = struct {
        handle: windows.HANDLE,
    
        pub fn create(family: u32, protocol: u32, )

        pub async fn connect(self: @This(), addr: u32, port: u16) !void {

        }

        pub async fn recv(self: @This(), buffers: []Buffer) !usize {

        }

        pub async fn send(self: @This(), buffers: []const Buffer) !usize {

        }

        pub async fn recvfrom(self: @This(), buffers: []Buffer) !usize {

        }

        pub async fn send(self: @This(), buffers: []const Buffer) !usize {

        }
    };
};

const Linux = struct {

};

const Posix = struct {

};