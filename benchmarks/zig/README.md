# Zig implementations

```
zig build run -Drelease-fast // add -Dc flag if on posix systems
```
Runs the quick sort benchmark using the thread pool in this repo which is written in [Ziglang](https://ziglang.org/). `async.zig` wraps the thread pool api which similar `async/await` syntax as the other languages in the benchmark. Also, I wrote two thread pools for curiousity. You can switch which one is used by changing the path to the zig file in `build.zig`.