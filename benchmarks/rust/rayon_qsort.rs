const SIZE: usize = 10_000_000;

fn main() {
    println!("filling");
    let mut arr = (0..SIZE)
        .map(|i| i.try_into().unwrap())
        .collect::<Vec<i32>>()
        .into_boxed_slice();

    println!("shuffling");
    shuffle(&mut arr);

    println!("running");
    let start = std::time::Instant::now();
    quick_sort(&mut arr);

    println!("took {:?}", start.elapsed());
    assert!(verify(&arr));
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

fn quick_sort(arr: &mut [i32]) {
    if arr.len() <= 32 {
        insertion_sort(arr);
    } else {
        let mid = partition(arr);
        let (low, high) = arr.split_at_mut(mid);

        rayon::scope(|s| {
            s.spawn(|_| quick_sort(low));
            s.spawn(|_| quick_sort(high));
        });
        
        // Optimized version (hooks directly into the scheduler)
        // rayon::join(
        //     || quick_sort(low),
        //     || quick_sort(high)
        // );
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
