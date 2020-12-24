

const builtin = @import("builtin");

pub fn Min(comptime A: type, comptime B: type) type {
    switch (@typeInfo(A)) {
        .Int => |a| switch (@typeInfo(B)) {
            .Int => |b| if (a.signedness == .unsigned and b.signedness == .unsigned) {
                return if (a.bits < b.bits) A else B;
            },
            else => {},
        },
        else => {},
    }
    return @TypeOf(@as(A, 0) + @as(B, 0));
}

pub fn min(x: anytype, y: anytype) Min(@TypeOf(x), @TypeOf(y)) {
    const Result = Min(@TypeOf(x), @TypeOf(y));
    if (x < y) {
        return if (@typeInfo(Result) == .Int) @intCast(Result, x) else x;
    } else {
        return if (@typeInfo(Result) == .Int) @intCast(Result, y) else y;
    }
}

pub fn max(x: anytype, y: anytype) @TypeOf(x, y) {
    return if (x > y) x else y;
}

pub fn bitCount(comptime T: type) comptime_int {
    return @typeInfo(T).Int.bits;
}

pub fn Int(comptime signedness: builtin.Signedness, comptime bits: u16) type {
    return @Type(builtin.TypeInfo{
        .Int = .{
            .signedness = signedness,
            .bits = bits,
        },
    });
}

pub fn Log2Int(comptime T: type) type {
    return Int(.unsigned, @popCount(usize, bitCount(T)));
}