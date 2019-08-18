const scheduler = @import("src/runtime/scheduler.zig");

test "ziggo" {
    
}

pub const runtime = struct {
    pub const Config = scheduler.Config;

    pub fn run(config: Config, comptime main_function: var, main_args: ...) !void {
        return scheduler.run(config, main_function, main_args);
    }
};
