## Cpp Implementations

Runs the quick sort benchmark using [asio](https://github.com/chriskohlhoff/asio). The C++ library in this case given it also supports async.

### Have two examples

- C++14 with asio using strands
- C++14 with asio using make_parallel_group
- C++20 with asio + std::coroutines

```bash
# build run example (C++14) - strands (default)
$> zig build run
# build run example (C++14) - parallel_group
$> zig build run -DExample=parallel
# build run example (C++20)
$> zig build run -DExample=coro
```

