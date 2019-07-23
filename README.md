# Zio
Zig library which abstracts out synchronous and asynchronous IO operations. The project is **currently a WIP** so expect updates. The motive being that there do not seem to be any IO multiplexing abstractions over the machine that:

* Does not rely on language features such as closures or coroutines
* Support Windows IOCP or completion based IO (eliminates libev & libevent)
* Does not require libc or memory allocation (eliminates libuv & rust mio & boost asio)

This is a library meant to solve these problems and enable easy use from different applications including C as well as not dictate any memory requirements. Goal is essentially reuseability and customizability all in the spirit of Zig. Some planned features include:

- [ ] Windows/Unix Pipes
- [ ] File IO
- [ ] External C API bindings
- [ ] Zig Coroutine Implementation
- [ ] Add other system abstractions (Threading, Sync, VirtualMemory, ...) ?
