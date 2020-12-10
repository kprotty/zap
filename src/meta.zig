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
    return @typeInto(T).Int.bits;
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

pub fn eql(left: anytype, right: anytype) bool {
    const Left = @TypeOf(left);
    const Right = @TypeOf(right);
    if (Left != Right)
        @compileError("Comparing " ++ @typeName(Left) ++ " with " ++ @typeName(Right));

    switch (@typeInfo(Left)) {
        .Pointer => |info| if (info.size == .Slice) {
            if (left.len != right.len)
                return false;
            for (left) |item, index| {
                if (item != right[index])
                    return false;
            }
            return true;
        },
        else => {},
    }

    return left == right;
}

pub fn indexOf(haystack: anytype, needle: anytype) ?usize {
    const Needle = @TypeOf(needle);
    if (@typeInfo(Needle) != .Pointer)
        return indexOf(haystack, @as([]const Needle, &[_]Needle{needle}));

    for (haystack) |item, index| {
        if (haystack.len - index < needle.len)
            break;
        if (item != needle[0])
            continue;
        if (eql(haystack[index..], needle))
            return index;
    }

    return null;
}
