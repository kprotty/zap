# zap
An experimental alternative to `std.event.Loop`

To run code in the examples folder:
* Zig: 
    - `zig build ${example} -Drelease-fast`
    - `./zig-cache/${example}`
* Rust: 
    - `cargo build --bin ${example} --release`
    - `./target/release/${example}`
* Go:
    - `go build -o ./zig-cache/${example}_go ${example}.go`
    - `./zig-cache/${example}_go`
