use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};

const NUM_TASKS: usize = 100 * 1000;
const NUM_YIELDS: usize = 200;

#[tokio::main]
async fn main() {
    let counter = Arc::new(AtomicUsize::new(0));
    let (tx, mut rx) = tokio::sync::mpsc::channel(1);

    for _ in 0..NUM_TASKS {
        let mut tx = tx.clone();
        let counter = counter.clone();

        tokio::spawn(async move {
            for _ in 0..NUM_YIELDS {
                tokio::task::yield_now().await;
            }
            
            if counter.fetch_add(1, Ordering::Relaxed) + 1 == NUM_TASKS {
                tx.send(()).await.unwrap();
            }
        });
    }

    rx.recv().await.unwrap();
    assert_eq!(counter.load(Ordering::Relaxed), NUM_TASKS);
}