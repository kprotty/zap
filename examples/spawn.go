package main

import "sync/atomic"

const num_spawners = 10
const num_tasks_per_spawner = 500 * 1000
const num_tasks = num_tasks_per_spawner * num_spawners

func main() {
    var spawned uintptr = 0
    done := make(chan struct{})

    for j := 0; j < num_spawners; j++ {
        for i := 0; i < num_tasks_per_spawner; i++ {
            go func(){
                spawned_count := atomic.AddUintptr(&spawned, 1)
                if spawned_count == num_tasks {
                    done <- struct{}{}
                }
            }()
        }
    }

    <- done
    if spawned != num_tasks {
        panic("Bad spawned count")
    }
}