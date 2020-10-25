const NUM_TASKS: usize = 100_000;
const NUM_SPAWNERS: usize = 10;

use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};

#[tokio::main]
async fn main() {
    let event = tokio::sync::Notify::new();
    let counter = AtomicUsize::new(NUM_TASKS * NUM_SPAWNERS);
    let context = Arc::new((event, counter));

    for _ in 0..NUM_SPAWNERS {
        let context = context.clone();
        tokio::spawn(async move {

            for _ in 0..NUM_TASKS {
                let context = context.clone(); 
                tokio::spawn(async move {

                    let (event, counter) = &*context;   
                    if counter.fetch_sub(1, Ordering::Relaxed) - 1 == 0 {
                        event.notify_one();
                    }
                });
            }
        });
    }

    let (event, counter) = &*context;
    event.notified().await;
    assert_eq!(0, counter.load(Ordering::Relaxed));
}