package main

import (
	"fmt"
	"time"
	"sync"
)

func main() {
	arr := make([]int, 128 * 1000)
	fmt.Println("shuffling")
	shuffle(arr)

	fmt.Println("running")
	start := time.Now()
	quickSort(arr)
	elapsed := time.Since(start)

	fmt.Println("took", elapsed)
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

func partition(arr []int) int {
	i := 0
	p := len(arr) - 1
	pivot := arr[p]
	for j := 0; j < len(arr); j++ {
		if arr[j] < pivot {
			arr[i], arr[j] = arr[j], arr[i]
			i++
		}
	}
	arr[i], arr[p]= arr[p], arr[i]
	return i
}

func quickSort(arr []int) {
	if len(arr) <= 32 {
		selectionSort(arr);
	} else {
		p := partition(arr)
		
		var wg sync.WaitGroup
		if p != 0 {
			wg.Add(1)
			go func() {
				quickSort(arr[:p])
				wg.Done()
			}()
		}

		if p < len(arr) - 1 {
			wg.Add(1)
			go func() {
				quickSort(arr[p + 1:])
				wg.Done()
			}()
		}

		wg.Wait()
	}
}

func selectionSort(arr [] int) {
	n := len(arr)
	for i := 0; i < n; i++ {
		min := i;
		for j := i + 1; j < n; j++ {
			if arr[j] < arr[min] {
				min = j;
			}
		}
		if min != i {
			arr[min], arr[i] = arr[i], arr[min]
		}
	}
}