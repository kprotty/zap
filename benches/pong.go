package main

import "sync/atomic"

const (
	num_tasks = 100 * 1000
)

func main() {
	var counter uintptr = 0
	event := make(chan struct{})
	
	for i := 0; i < num_tasks; i++ {
		go func() {

			c1 := make(chan struct{})
			c2 := make(chan struct{})

			go func(){
				c1 <- struct{}{}
				<- c2
			}()
			
			<- c1
			c2 <- struct{}{}

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