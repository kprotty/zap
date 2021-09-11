# Rust implementations

```
cargo run --release --bin qsort
```
Runs the quick sort benchmark using [`tokio`](https://tokio.rs/). The primiary rust representative in this case given it also supports async.

```
cargo run --release --bin rsort
```
Runs the quick sort benchmark using [`rayon`](https://docs.rs/rayon). This is just out of curiousity. Rayon doesn't support async AFAIK but it's still a good comparison.