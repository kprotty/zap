package main

import (
	"fmt"
	"time"
	"sync"
)

func main() {
	arr := make([]int, 10 * 1000 * 1000)

	fmt.Println("filling")
	for i := 0; i < len(arr); i++ {
		arr[i] = i
	}

	fmt.Println("shuffling")
	shuffle(arr)

	fmt.Println("running")
	start := time.Now()
	quickSort(arr)

	fmt.Println("took", time.Since(start))
	if !verify(arr) {
		panic("array not sorted")
	}
}

func verify(arr []int) bool {
	for i := 0;; i++ {
		if i == len(arr) - 1 {
			return true
		} else if arr[i] > arr[i + 1] {
			return false
		}
	}
}

func shuffle(arr []int) {
	var xs uint = 0xdeadbeef
	for i := uint(len(arr)) - 1; i > 0; i-- {
		xs ^= xs << 13
		xs ^= xs >> 17
		xs ^= xs << 5
		j := xs % (i + 1)
		arr[i], arr[j] = arr[j], arr[i]
	}
}

func quickSort(arr []int) {
	if len(arr) <= 32 {
		insertionSort(arr)
	} else {
		var wg sync.WaitGroup
		mid := partition(arr)
		
		wg.Add(2)
		go func() {
			quickSort(arr[:mid])
			wg.Done()
		}()
		go func() {
			quickSort(arr[mid:])
			wg.Done()
		}()

		wg.Wait()
	}
}

func partition(arr []int) int {
	pivot := len(arr) - 1
	i := 0;
	for j := 0; j < pivot; j++ {
		if arr[j] <= arr[pivot] {
			arr[i], arr[j] = arr[j], arr[i]
			i++
		}
	}
	arr[i], arr[pivot] = arr[pivot], arr[i]
	return i
}

func insertionSort(arr [] int) {
	for i := 1; i < len(arr); i++ {
		for n := i; n > 0 && arr[n] < arr[n - 1]; n-- {
			arr[n], arr[n - 1] = arr[n - 1], arr[n]
		}
	}
}