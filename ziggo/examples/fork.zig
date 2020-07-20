const std = @import("std");
const zap = @import("zap");

const Link = zap.Link;
const Builder = zap.Builder;
const Runnable = zap.Runnable;

pub fn main() !void {
    const allocator = 
        if (std.builtin.os.tag == .windows) std.heap.page_allocator
        else if (std.builtin.link_libc) std.heap.c_allocator
        else std.heap.page_allocator;

    const root = try allocator.create(Root);
    defer allocator.destroy(root);
    root.init();

    const builder = Builder{};
    try builder.run(&root.runnable);

    const completed = @atomicLoad(usize, &root.completed, .Monotonic);
    std.debug.assert(completed == Root.num_children);
}

fn print(comptime fmt: []const u8, args: var) void {
    // std.debug.warn(fmt, args);
    // disabled for perf
}

const Root = struct {
    const num_children = 10 * 1000 * 1000;
    runnable: Runnable,
    children: [num_children]Child,
    completed: usize,

    fn init(self: *Root) void {
        self.completed = 0;
        self.runnable = Runnable.init(.Normal, @"resume");
        for (self.children) |*child, id|
            child.init(self, id);
    }

    fn @"resume"(
        noalias runnable: *Runnable,
        noalias context: Runnable.Context,
    ) callconv(.C) ?*Runnable {
        const self = @fieldParentPtr(Root, "runnable", runnable);

        switch (@atomicLoad(usize, &self.completed, .Monotonic)) {
            num_children => {
                print("[Root]: All children completed\n", .{});
                return null;
            },
            0 => {},
            else => unreachable,
        }

        for (self.children) |*child| {
            const batch = Link.Queue.fromLink(child.runnable.getLink());
            context.schedule(.Local, batch);
        }

        return null;
    }
};

const Child = struct {
    id: usize,
    root: *Root,
    runnable: Runnable,

    fn init(self: *Child, root: *Root, id: usize) void {
        self.id = id;
        self.root = root;
        self.runnable = Runnable.init(.Normal, @"resume");
    }

    fn @"resume"(
        noalias runnable: *Runnable,
        noalias context: Runnable.Context,
    ) callconv(.C) ?*Runnable {
        const self = @fieldParentPtr(Child, "runnable", runnable);
        
        // print("[Child {}] resumed on thread {}\n", .{self.id + 1, std.Thread.getCurrentId()});

        _ = @atomicRmw(usize, &self.root.completed, .Add, 1, .Monotonic);
        // if (@atomicRmw(usize, &self.root.completed, .Add, 1, .Monotonic) == Root.num_children - 1)
        //    return &self.root.runnable;
        
        return null;
    }
};