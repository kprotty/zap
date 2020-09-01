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

import "sync"

const num_tasks = 100 * 1000

func main() {
	var wait_group sync.WaitGroup

	wait_group.Add(num_tasks);
	for i := 0; i < num_tasks; i++ {
		go func(){
			c1 := make(chan byte)
			c2 := make(chan byte)

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

			wait_group.Done()
		}()
	}

	wait_group.Wait()
}