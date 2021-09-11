zap [![License](https://img.shields.io/badge/license-MIT-8FBD08.svg)](https://shields.io/)
====
Designing efficient task scheduling for Ziglang.

## Goals
So I originally started this project around 2019 in order to develop memory, threads, io, and synchronization primitives for Zig given they were lacking at the time. Over the months, it shifted more on developing a runtime (or thread pool rather) that was both resource efficient (one of Zig's, and my personal, implicit Zen's) and competitive in performance with existing implementations.

Here lies the result of that effort for now. There's still more experimenting to do like how to dispatch I/O efficiently and the like, but I'm happy with what has come and wanted to share. You can find a copy of the blogpost [in this repo](blog.md), the reference implementation in [src](src/thread_pool.zig), and some of my [previous attempts](zap/tree/old_branches) in their own branch.

## Benchmarks
To benchmark the implementation, I wrote some quicksort implementations for similar APIs in other languages. The reasoning behind quicksort is that it's fairly practical and can also be heavy with concurrency. Try running them locally!
