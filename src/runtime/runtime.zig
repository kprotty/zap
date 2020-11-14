const std = @import("std");
const Heap = @import("./heap.zig");
const Scheduler = @import("./scheduler.zig").Scheduler;

fn ReturnTypeOf(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).Fn.return_type.?;
}

pub fn run(comptime asyncFn: anytype, args: anytype) ReturnTypeOf(asyncFn) {
    const Args = @TypeOf(args);
    const Decorator = struct {
        fn entry(frame_ptr: *anyframe, result_ptr: *?ReturnTypeOf(asyncFn), fn_args: Args) void {
            suspend frame_ptr.* = @frame();
            const result = @call(.{}, asyncFn, fn_args);
            suspend {
                result_ptr.* = result;
                Scheduler.instance.?.shutdown();
            }
        }
    };

    var frame_ptr: anyframe = undefined;
    var result: ?ReturnTypeOf(asyncFn) = null;
    var frame = async Decorator.entry(&frame_ptr, &result, args);

    var scheduler: Scheduler = undefined;
    scheduler.init(Heap.getAllocator());
    scheduler.start(frame_ptr);
    scheduler.deinit();
    
    return result orelse unreachable;
}

pub fn schedule(frame: anyframe) void {
    Scheduler.instance.?.schedule(frame);
}

pub fn yield() void {
    suspend schedule(@frame());
}

pub fn spawn(comptime asyncFn: anytype, args: anytype) void {
    const Args = @TypeOf(args);
    const Decorator = struct {
        fn entry(allocator: *std.mem.Allocator, fn_args: Args) void {
            yield();
            _ = @call(.{}, asyncFn, fn_args);
            suspend allocator.destroy(@frame());
        }
    };

    const allocator = Scheduler.instance.?.allocator;
    var frame = allocator.create(@Frame(Decorator.entry)) catch unreachable;
    frame.* = async Decorator.entry(allocator, args);
}
