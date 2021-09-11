const SIZE: usize = 128_000;

#[tokio::main]
pub async fn main() {
    let mut arr = Box::leak(vec![0; SIZE].into_boxed_slice());
    let arr_ptr = arr.as_ptr();

    println!("shuffling");
    shuffle(&mut arr);

    println!("running");
    let start = std::time::Instant::now();
    quick_sort(arr).await;

    println!("took {:?}", start.elapsed());
    assert!(verify(unsafe { std::slice::from_raw_parts(arr_ptr, SIZE) }));
}

fn verify(arr: &[i32]) -> bool {
    arr.windows(2).all(|i| i[0] <= i[1])
}

fn shuffle(arr: &mut [i32]) {
    let mut xs: u32 = 0xdeadbeef;
    for i in 0..arr.len() {
        xs ^= xs << 13;
		xs ^= xs >> 17;
		xs ^= xs << 5;
        let j = (xs as usize) % (i + 1);
        arr.swap(i, j);
    }
}

fn partition(arr: &mut [i32]) -> usize {
    let mut i = 0;
    let p = arr.len() - 1;
    let pivot = arr[p];
    for j in 0..arr.len() {
        if arr[j] < pivot {
            arr.swap(i, j);
            i += 1;
        }
    }
    arr.swap(i, p);
    i
}

fn spawn_quick_sort(arr: &'static mut [i32]) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move { 
        quick_sort(arr).await
    })
}

async fn quick_sort(arr: &'static mut [i32]) {    
    if arr.len() <= 32 {
        selection_sort(arr);
    } else {
        let p = partition(arr);
        let (mut low, high) = arr.split_at_mut(p + 1);

        let mut left = None;
        if low.len() > 0 {
            low = low.split_at_mut(low.len() - 1).0;
            left = Some(spawn_quick_sort(low));
        }

        let mut right = None;
        if high.len() > 0 {
            right = Some(spawn_quick_sort(high));
        }

        if let Some(handle) = left {
            handle.await.unwrap();
        }
        if let Some(handle) = right {
            handle.await.unwrap();
        }
    }
}

fn selection_sort(arr: &mut [i32]) {
    for i in 0..arr.len() {
        let min = (i..arr.len()).fold(i, |min, j| {
            if arr[j] < arr[min] {
                j
            } else {
                min
            }
        });
        if min != i {
            arr.swap(i, min);
        }
    }
}
