# zap
A collection of zig libraries which provide interfaces over the system for writing high performance applications. Current plans are to support x86_64, i386, arm32 and aarch64 for Linux, Windows, and BSD systems. Only requires libc for BSD platforms at the moment. Link to [Documentation](https://kprotty.github.io/zap/#root)

## zio
Abstractions over the system's IO operations for both blocking and non-blocking IO. Uses a completion based polling scheme rather than a readyness based one found in other libraries to support a true zero-cost abstraction over non-blocking IO. Goals include minimal syscalls, no heap allocation and having a BSD-esque interface as close as possible. (Inspired by golang's netpoller and rust's mio)

- [x] Event Polling (Linux: epoll, Windows: IOCP, BSD: kqueue)
- [x] Sockets
- [ ] Files
- [ ] Pipes / TTY

## zuma 
Abstractions over the system's threading, memory, and topology operations. Zuma extends upon the zig stdlib to provide more control. Goals include first class NUMA node support along with more customizable memory + thread features such as smaller thread stacks, setting/getting/querying thread cpu topology, and unified virtual memory interface. (Inspired by pthread and libnuma).

- [ ] Threading (WIP)
- [ ] Virutal Memory

## zync
Abstractions over the systems thread blocking interfaces and provides both synchronization primitives as well as other useful functions. Goals include exposing customizable building blocks for creation high performance concurrent data structures while not assuming underlying platform as much as possible. (Inspired by rust's crossbeam)

- [x] Lazy (rust's lazy_static)
- [x] C11 Atomics (supports Unions, Enums, and arbitrary bit-width numbers)
- [x] Crossbeam utils (spin hint, backoff, cache padded)
- [ ] System sychnronization (mutex, condition_variable, rwlock, semaphore)
- [ ] Multi/Single-Producer Multi/Single-Consumer queues and stacks

## zell
(Zig Event Loop Layer). Library which **will** builds upon [zio](#zio), [zync](#zync), and [zuma](#zuma) to provide a runtime for NUMA-aware asynchronous computing and IO. Goals include pluggable system topology for scheduler & leveraging Zig's async functions to provide concurrency as well as not assuming memory allocation scheme. (Inspired by golang's NUMA-aware scheduler proposal, Ponylang's scheduler, and Rust's tokio executor)

*TODO*

## zimalloc
**Eventual** port of microsoft's mimalloc to zig. Will serve as the default allocator in [zell](#zell). Goals include to only provide the building blocks instead of assuming allocator access and platform.

**TODO**