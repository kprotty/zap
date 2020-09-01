# Examples
A group of synthetic benchmarks used to stress test various task schedulers

## Running
* Zig: 
    - `zig build ${example} -Drelease-safe`
    - `./zig-cache/${example}`
* Rust:
    - `cargo build --bin ${example} --release`
    - `./target/release/${example}`
* Go:
    - `go build -o ./gobuild/${example} ${example}.go
    - `./gobuild/${example}`

where `${example}` is one of the listed example benchmarks below:

## Benchmarks

`yield`
-- 
Spawns 100k tasks which each yield 200 times.
This puts pressure on the entire scheduler as theres constant producers rescheduling tasks with more threads than cpus available.

`spawn`
-- 
Spawns 10 tasks which each spawn 500k tasks.
This puts pressure on the memory allocator and the producer + consumer ends of the scheduler separately.
The initial spawner tasks act as producers until completed.
The remainder of the program measures the consumers running the large amout of produced tasks. 

`sieve`
--
Spawns 5k tasks which conditionally pipe the result from one channel to another.
This puts pressure on the lang's channel implementation for multiple sending & resuming 
