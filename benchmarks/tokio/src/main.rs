use std::{future::Future, time::Instant};

const NUM_TASKS: usize = 200_000;
const NUM_PRODUCERS: usize = 10;
const NUM_SLOTS: usize = 100;

#[tokio::main]
pub async fn main() {
    benchmark("spawn-spmc", run_spawn(1)).await;
    benchmark("spawn-mpsc", run_spawn(NUM_PRODUCERS)).await;
    benchmark("chan-spsc", run_chan(1)).await;
    benchmark("chan-mpsc", run_chan(NUM_PRODUCERS)).await;
}

async fn benchmark(name: &str, func: impl Future<Output = ()>) {
    let start = Instant::now();
    let _ = func.await;
    let elapsed = start.elapsed();
    println!("{:?}\t... {:?}", name, elapsed);
}

fn black_box<T>(value: T) -> T {
    use std::{mem::MaybeUninit, ptr::{read_volatile, write_volatile}};
    unsafe {
        let mut stub = MaybeUninit::uninit();
        write_volatile(stub.as_mut_ptr(), value);
        read_volatile(stub.as_ptr())
    }
}

async fn run_spawn(num_producers: usize) {
    let producers = (0..num_producers)
        .map(|_| tokio::spawn(async move {
            let workers = (0..(NUM_TASKS / num_producers))
                .map(|_| tokio::spawn(async move {
                    let divisor: usize = black_box(1000);
                    let iter = (2..=(divisor / 2)).filter(move |d| divisor % d == 0);
                    let _: usize = black_box(iter.sum());
                }))
                .collect::<Vec<_>>();

            for worker in workers {
                worker.await.unwrap();
            }
        }))
        .collect::<Vec<_>>();

    for producer in producers {
        producer.await.unwrap();
    }
}

async fn run_chan(num_producers: usize) {
    let (tx, mut rx) = tokio::sync::mpsc::channel(NUM_SLOTS);
    
    let consumer = tokio::spawn(async move {
        while let Some(_) = rx.recv().await {}
    });
    
    let producers = (0..num_producers)
        .map(|_| {
            let tx = tx.clone();
            tokio::spawn(async move {
                for _ in 0..(NUM_TASKS / num_producers) {
                    tx.send(()).await.unwrap();
                }
            })
        })
        .collect::<Vec<_>>();

    for producer in producers.into_iter() {
        producer.await.unwrap();
    }

    std::mem::drop(tx);
    consumer.await.unwrap()
}