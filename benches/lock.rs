const NUM_TASKS: usize = 100_000;
const NUM_ITERS: usize = 100;

use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};

#[tokio::main]
async fn main() {
    let event = tokio::sync::Notify::new();
    let counter = tokio::sync::Mutex::new(0u64);
    let ev_counter = AtomicUsize::new(NUM_TASKS);
    let context = Arc::new((event, ev_counter, counter));

    for _ in 0..NUM_TASKS {
        let context = context.clone();

        tokio::spawn(async move {
            let (event, ev_counter, counter) = &*context;

            for _ in 0..NUM_ITERS {
                *counter.lock().await += 1;
            }

            if ev_counter.fetch_sub(1, Ordering::Relaxed) - 1 == 0 {
                event.notify_one();
            }
        });
    }

    let (event, ev_counter, counter) = &*context;
    event.notified().await;
    assert_eq!(0, ev_counter.load(Ordering::Relaxed));
    assert_eq!((NUM_TASKS * NUM_ITERS) as u64, *counter.lock().await);
}