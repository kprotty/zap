const std = @import("std");
const posix = @import("posix.zig");
const zio = @import("../../zio.zig");

const os = std.os;
const linux = os.linux;

pub const Handle = posix.Handle;
pub const Buffer = posix.Buffer;
pub const Socket = posix.Socket;
pub const ConstBuffer = posix.ConstBuffer;