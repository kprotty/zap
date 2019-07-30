const std = @import("std");
const builtin = @import("builtin");

pub usingnamespace switch (builtin.os) {
    .linux => LinuxBackend,
    .windows => Kernel32Backend,
    .macoxs, .freebsd, .netbsd, .openbsd => PosixBackend,
    else => @compileError("Operating System not supported"),
};

const Kernel32Backend = struct {
    pub fn map() ![]u8 {

    }

    pub fn unmap(memory: []u8) void {

    }

    pub fn commit(memory: []u8) void {

    }

    pub fn decommit(memory: []u8) void {
        
    }
};

const LinuxBackend = struct {

};

const PosixBackend = struct {

};