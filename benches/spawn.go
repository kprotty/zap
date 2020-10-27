package main

import "sync/atomic"

const (
	num_spawners = 10
	num_tasks = 100000
)

func main() {
	var counter uintptr = 0
	event := make(chan struct{})
	
	for i := 0; i < num_spawners; i++ {
		go func() {
			for j := 0; j < num_tasks; j++ {
				go func() {
					if atomic.AddUintptr(&counter, 1) == num_tasks * num_spawners {
						event <- struct{}{}
					}
				}()
			}
		}()
	}

	<- event
	if atomic.LoadUintptr(&counter) != num_tasks * num_spawners {
		panic("invalid count")
	}
}