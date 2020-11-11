package main

import "time"
import "sync/atomic"

const (
	num_yields = 100
	num_tasks = 100 * 1000
)

func main() {
	var counter uintptr = 0
	event := make(chan struct{})
	
	for i := 0; i < num_tasks; i++ {
		go func() {

			for j := 0; j < num_yields; j++ {
				time.Sleep(1)
			}

			if atomic.AddUintptr(&counter, 1) == num_tasks {
				event <- struct{}{}
			}
		}()
	}

	<- event
	if atomic.LoadUintptr(&counter) != num_tasks {
		panic("invalid count")
	}
}