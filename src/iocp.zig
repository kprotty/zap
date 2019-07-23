const zio = @import("zio.zig");

pub const Handle = HANDLE;

pub const Token = packed struct {
    overlapped: OVERLAPPED,

    pub fn reset(self: *Token) void {
        _ = std.mem.secureZero(Token, @ptrCast([1]Token, self)[0..]);
    }

    pub fn asReader(self: *const Token) usize {
        return @ptrToInt(self); // overlapped pointers are unique, use identity for comparison 
    }

    pub fn asWriter(self: *const Token) usize {
        return @ptrToInt(self); // overlapped pointers are unique, use identity for comparison
    }

    pub fn is(self: *const Token, other: *const Token) bool {
        return @ptrToInt(self) == @ptrToInt(other);
    }
};

pub const Selector = struct {
    handle: Handle,

    pub const Event = packed struct {
        overlapped_entry: OVERLAPPED_ENTRY,

        pub fn getToken(self: Event) *Token {
            return @fieldParentPtr(Token, "overlapped", self.overlapped_entry.lpOverlapped);
        }
        
        pub fn getUserData(self: Event) usize {
            return self.overlapped_entry.lpCompletionKey;
        }

        pub fn getResult(self: Event) zio.Token.Result {
            const status = self.overlapped_entry.lpOverlapped.Internal;
            const transferred = self.overlapped_entry.dwNumberOfBytesTransferred;
            
            return switch (status) {
                STATUS_PENDING => zio.Token.Result { .Retry }, 
                ERROR_SUCCESS => zio.Token.Result { .Transferred = transferred },
                else => zio.Token.Result { .Error = transferred },
            };
        }
    };
};