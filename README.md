zap [![License](https://img.shields.io/badge/license-MIT-8FBD08.svg)](https://shields.io/) [![Zig](https://img.shields.io/badge/Made_with-Zig-F7A41D.svg)](https://shields.io/)
====
A collection of resource efficient tools for writing scalable software.

## Design Goals
This project explicitly makes an effort to optimize for resource efficiency and customizability when possible as opposed to the more standard goal of performance and ease of use. This has two simultaneous, but sometimes conflicting, meanings:

* In order to achieve resource efficiency, maximum performance or ease of use may be sacrificed when reasonable.
* Optimizing for resource efficiency should not completely neglect performance and ease of use as these are practically important.

The term "resource efficiency" here refers to using the least amount of system resources (i.e. Compute, Memory, IO, etc.) to achieve similar functionality. This often includes tricks such as caching computed values, using special CPU instructions, favoring intrusively provided memory and amortizing synchronization or syscalls.

Aligning with the [Zen of Ziglang](https://ziglang.org/documentation/master/#Zen), this should aid in easing the ability to program software which utilizes the hardware better on average than before.

## License

<sup>
Licensed under either of <a href="LICENSE-APACHE">Apache License, Version
2.0</a> or <a href="LICENSE-MIT">MIT license</a> at your option.
</sup>

<br/>

<sub>
Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this crate by you, as defined in the Apache-2.0 license, shall
be dual licensed as above, without any additional terms or conditions.
</sub>
