# Examples
A group of synthetic benchmarks used to stress-test various task schedulers

## Running
* Zig: 
    - `zig build ${example} -Drelease-safe`
    - `./zig-cache/${example}`
* Rust:
    - `cargo build --bin ${example} --release`
    - `./target/release/${example}`
* Go:
    - `go build -o ./gobuild/${example} ${example}.go` (add .exe for windows)
    - `./gobuild/${example}`

where `${example}` is one of the listed example benchmarks below:

## Benchmarks

`yield`
-- 
Spawns 100k tasks which each yield 200 times.
This puts pressure on the entire scheduler as theres constant producers rescheduling tasks with more threads than cpus available.

`pong`
--
Spawns 100k tasks which each do a send and receive on their own channel shared with another spawned tasks. This measures the overhead of the language's Channel construct when communicating with two tasks.
