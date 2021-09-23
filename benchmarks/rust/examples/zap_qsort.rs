const SIZE: usize = 10_000_000;

pub fn main() {
    zap::Builder::new().block_on(async move {
        println!("filling");
        let arr = (0..SIZE)
            .map(|i| i.try_into().unwrap())
            .collect::<Vec<i32>>()
            .into_boxed_slice();

        let mut arr = Box::leak(arr);
        let arr_ptr = arr.as_ptr() as usize;

        println!("shuffling");
        shuffle(&mut arr);

        println!("running");
        let start = std::time::Instant::now();
        quick_sort(arr).await;

        println!("took {:?}", start.elapsed());
        assert!(verify(unsafe {
            std::slice::from_raw_parts(arr_ptr as *const i32, SIZE)
        }));
    });
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
        let mid = partition(arr);
        let (low, high) = arr.split_at_mut(mid);

        fn spawn_quick_sort(array: &'static mut [i32]) -> zap::JoinHandle<()> {
            zap::spawn(async move { quick_sort(array).await })
        }

        let left = spawn_quick_sort(low);
        let right = spawn_quick_sort(high);

        left.await;
        right.await;
    }
}

fn partition(arr: &mut [i32]) -> usize {
    let pivot = arr.len() - 1;
    let mut i = 0;
    for j in 0..pivot {
        if arr[j] <= arr[pivot] {
            arr.swap(i, j);
            i += 1;
        }
    }
    arr.swap(i, pivot);
    i
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
