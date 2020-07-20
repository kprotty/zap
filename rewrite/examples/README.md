#### spawn
Spawns one million tasks which increment a counter.
Once the counter reaches one million, notify the main thread to quit.

* Zap: 1.1s
* Go: 1.4s
* Tokio: 2s

#### yield
Spawns 100k tasks which each yield 200 times.
After yielding, the tasks send to a channel and the main thread waits for all tasks to have sent.

* Zap: 0.45s
* Tokio: 0.8s
* Go: 7.4s