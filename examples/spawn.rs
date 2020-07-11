use tokio::sync::mpsc;
use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};

const NUM_SPAWNERS: usize = 10;
const NUM_TASKS_PER_SPAWNER: usize = 500 * 1000;
const NUM_TASKS: usize = NUM_SPAWNERS * NUM_TASKS_PER_SPAWNER;

#[tokio::main]
async fn main() {
    let (tx, mut rx) = mpsc::channel(1);
    let spawned = Arc::new(AtomicUsize::new(0));

    for _ in 0..NUM_SPAWNERS {
        let tx = tx.clone();
        let spawned = spawned.clone();

        tokio::spawn(async move {
            for _ in 0..NUM_TASKS_PER_SPAWNER {
                let mut tx = tx.clone();
                let spawned = spawned.clone();

                tokio::spawn(async move {
                    if spawned.fetch_add(1, Ordering::SeqCst) == NUM_TASKS - 1 {
                        tx.send(()).await.unwrap();
                    }
                });
            }
        });
    }

    let _ = rx.recv().await.unwrap();
    assert_eq!(
        spawned.load(Ordering::SeqCst),
        NUM_TASKS,
    );
}