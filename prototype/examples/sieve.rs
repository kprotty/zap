
const NUM_CHANS: usize = 5000;

#[tokio::main]
async fn main() {
    let (mut tx, mut rx) = tokio::sync::mpsc::channel(1);
    tokio::spawn(async move {
        for i in 2u64.. {
            if tx.send(i).await.is_err() {
                break;
            }
        }
    });

    for _ in 0..NUM_CHANS {
        let prime = rx.recv().await.unwrap();
        let (mut t1, r1) = tokio::sync::mpsc::channel(1);
        
        tokio::spawn(async move {
            while let Some(i) = rx.recv().await {
                if i % prime != 0 {
                    if t1.send(i).await.is_err() {
                        break;
                    }
                }
            }
        });

        rx = r1;
    }

    for _ in 0..NUM_CHANS {
        let _ = rx.recv().await.unwrap();
    }
}