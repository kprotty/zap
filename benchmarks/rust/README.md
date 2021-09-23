# Rust implementations

```
cargo run --example qsort --release
```
Runs the quick sort benchmark using [`tokio`](https://tokio.rs/). The primiary rust representative in this case given it also supports async.

```
cargo run --example rsort --release
```
Runs the quick sort benchmark using [`rayon`](https://docs.rs/rayon). This is just out of curiousity. Rayon doesn't support async AFAIK but it's still a good comparison.

```
cargo run --example zsort --release
```
Runs the quick sort benchmark using the Rust port of zap as an async executor. This is a proof of concept to see what the ideal async case for rust would be
