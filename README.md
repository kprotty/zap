zap [![License](https://img.shields.io/badge/license-MIT/Apache-8FBD08.svg)](https://shields.io/) [![Zig](https://img.shields.io/badge/Made_with-Zig-F7A41D.svg)](https://shields.io/)
====

An asynchronous runtime written in Zig with a focus on performance and resource efficiency.

### Features
The goal of `zap` is to provide a cross-platform library implementing an efficient
general purpose task scheduler as well as IO and timer facilities.
This includes a few notable features:

- [x] Multi-threaded, work-stealing scheduler
- [x] Lock-free scheduler
- [x] Intrusive memory model
- [ ] Usable as a C library
- [x] Does not require libc on linux and windows
- [x] Supports Zig `async/await`
- [ ] Supports Rust `future::Future`
- [ ] NUMA aware scheduler
- [ ] OS-agnostic scheduler
- [ ] Userspace async timers
- [ ] Standard async IO:
  - [ ] Sockets
  - [ ] Files
  - [ ] Pipes / UDS

### Documentation

Work In Progress - See the `examples/` folder for the time being.

### License

Licensed under either of

 * Apache License, Version 2.0
   ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license
   ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.
