package main

import "runtime"
import "sync/atomic"

const num_tasks = 100 * 1000
const num_yields = 200

func main() {
    var counter uintptr = 0
    done := make(chan struct{}, 1)

    for i := 0; i < num_tasks; i++ {
        go func(){
            for j := 0; j < num_yields; j++ {
                runtime.Gosched()
            }
            
            if atomic.AddUintptr(&counter, 1) == num_tasks {
                done <- struct{}{}
            }
        }()
    }

    <- done
    if counter != num_tasks {
        panic("Bad counter")
    }
}