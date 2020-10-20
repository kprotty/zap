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

const NUM_TASKS: usize = 100_000;
const NUM_SPAWNERS: usize = 10;

use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};

#[tokio::main]
async fn main() {
    let event = tokio::sync::Notify::new();
    let counter = AtomicUsize::new(NUM_TASKS * NUM_SPAWNERS);
    let context = Arc::new((event, counter));

    for _ in 0..NUM_SPAWNERS {
        let context = context.clone();
        tokio::spawn(async move {

            for _ in 0..NUM_TASKS {
                let context = context.clone(); 
                tokio::spawn(async move {

                    let (event, counter) = &*context;   
                    if counter.fetch_sub(1, Ordering::Relaxed) - 1 == 0 {
                        event.notify_one();
                    }
                });
            }
        });
    }

    let (event, counter) = &*context;
    event.notified().await;
    assert_eq!(0, counter.load(Ordering::Relaxed));
}