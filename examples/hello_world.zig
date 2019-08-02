const zio = @import("zio");

pub fn main() void {
    _ = zio.memory.map(null, 4096, 0);
}