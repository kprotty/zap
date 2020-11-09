package main

import "sync"

const (
	num_spawners = 10
	num_tasks = 100000
)

func main() {
	var wg sync.WaitGroup
	wg.Add(num_spawners * num_tasks)
	
	for i := 0; i < num_spawners; i++ {
		go func() {
			for j := 0; j < num_tasks; j++ {
				go func() {
					wg.Done()
				}()
			}
		}()
	}

	wg.Wait()
}