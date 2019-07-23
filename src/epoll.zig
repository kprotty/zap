const zio = @import("zio.zig");

pub const Handle = c_int;

pub const Token = packed struct {
    // readiness based, not completion based so no need for token data

    pub var reader: Token = undefined;
    pub var writer: Token = undefined;
    pub var read_and_writer: Token = undefined;

    pub fn reset(self: *Token) void {
        // no-op since theres no data
    }

    pub fn asReader(self: *const Token) usize {
        return self.stayReadWriterOr(@ptrToInt(&reader));
    }

    pub fn asWriter(self: *const Token) usize {
        return self.stayReadWriterOr(@ptrToInt(&writer));
    }

    /// When getting token identity, read_and_writer produced by `Selector.Event`
    /// should stay read_and_writer in order to match `is()` checks for `asReader()` and `asWriter()`.
    inline fn stayReadWriterOr(self: *const Token, convert_to: usize) usize {
        if (self.isReadWriter())
            return @ptrToInt(self);
        return convert_to;
    }

    /// When performing equality checks:
    ///   - ensure that both tokens are either `reader`, `writer` or `read_and_writer`
    ///   - read_and_writer compared to any other is always true (to handle both read and write events)
    pub fn is(self: *const Token, other: *const Token) bool {
        if (!isValidToken(self) or !isValidToken(other))
            return false;
        if (self.isReadWriter())
            return true;
        return @ptrToInt(self) == @ptrToInt(other);
    }

    inline fn isReadWriter(self: *const Token) bool {
        return @ptrToInt(self) == @ptrToInt(&read_and_writer);
    }

    inline fn isValidToken(self: *const Token) bool {
        const ptr = @ptrToInt(self);
        return self.isReadWriter() or ptr == self.asReader() or ptr == self.asWriter(); 
    }
};

pub const Selector = struct {
    handle: Handle,

    pub const Event = packed struct {
        event: epoll_event,

        pub fn getToken(self: Event) *Token {
            if ((self.event.events & EPOLLIN) != 0 and (self.event.events & EPOLLOUT) != 0)
                return &Token.read_and_writer;
            if ((self.event.events & EPOLLIN) != 0)
                return &Token.reader;
            return &Token.writer;
        }
        
        pub fn getUserData(self: Event) usize {
            return @ptrToInt(self.event.data.ptr);
        }

        pub fn getResult(self: Event) zio.Token.Result {
            if ((self.event.events & (EPOLLERR | EPOLLHUP)) != 0)
                return zio.Token.Result { .Error = 0 };
            return zio.Token.Result { .Retry };
        }
    };
};