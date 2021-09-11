const SIZE: usize = 10_000_000;

#[tokio::main]
pub async fn main() {
    use std::convert::TryInto;

    println!("filling");
    let arr = (0..SIZE)
        .map(|i| i.try_into().unwrap())
        .collect::<Vec<i32>>()
        .into_boxed_slice();

    let mut arr = Box::leak(arr);
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

async fn quick_sort(arr: &'static mut [i32]) {    
    if arr.len() <= 32 {
        insertion_sort(arr);
    } else {
        let mut mid = partition(arr);
        if mid < arr.len() / 2 {
            mid += 1;
        }

        fn spawn_quick_sort(array: &'static mut [i32]) -> tokio::task::JoinHandle<()> {
            tokio::spawn(async move { 
                quick_sort(array).await
            })
        }

        let (low, high) = arr.split_at_mut(mid);
        let left = spawn_quick_sort(low);
        let right = spawn_quick_sort(high);

        left.await.unwrap();
        right.await.unwrap();
    }
}

fn partition(arr: &mut [i32]) -> usize {
    arr.swap(0, arr.len() / 2);
    let mut mid = 0;
    for i in 1..arr.len() {
        if arr[i] < arr[0] {
            mid += 1;
            arr.swap(mid, i);
        }
    }
    arr.swap(0, mid);
    mid
}

fn insertion_sort(arr: &mut [i32]) {
    for i in 1..arr.len() {
        let mut n = i;
        while n > 0 && arr[n] < arr[n - 1] {
            arr.swap(n, n - 1);
            n -= 1;
        }
    }
}
