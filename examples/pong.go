// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import "sync/atomic"

const num_tasks = 100 * 1000

func main() {
	var counter uintptr = num_tasks
	event := make(chan struct {})

	for i := 0; i < num_tasks; i++ {
		go func(){
			c1 := make(chan byte, 1)
			c2 := make(chan byte, 1)

			go func(){
				x := <- c1
				if x != 0 {
					panic("invalid receive from c1")
				}
				c2 <- 1
			}()

			c1 <- 0
			x := <- c2
			if x != 1 {
				panic("invalid receive from c2")
			}

			if atomic.AddUintptr(&counter, ^uintptr(0)) == 0 {
				event <- struct{}{}
			}
		}()
	}

	<- event
	if atomic.LoadUintptr(&counter) != 0 {
		panic("all tasks did not complete")
	}
}