
pub inline fn ptrCast(comptime To: type, from: var) To {
    return @ptrCast(To, @alignCast(@alignOf(To), from));
}