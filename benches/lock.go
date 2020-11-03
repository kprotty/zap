package main

import "sync"

const (
	num_iters = 100
	num_tasks = 100 * 1000
)

func main() {
	var wg sync.WaitGroup
	wg.Add(num_tasks)

	var lock sync.Mutex
	var counter uint64 = 0

	for i := 0; i < num_tasks; i++ {
		go func() {
			for j := 0; j < num_iters; j++ {
				lock.Lock()
				counter += 1
				lock.Unlock()
			}
			wg.Done()
		}()
	}

	wg.Wait()
	if counter != (num_tasks * num_iters) {
		panic("bad counter")
	}
}