package main

const num_chans = 5000

func main() {
    ch := make(chan uint64)
    go Generate(ch)

    for i := 0; i < num_chans; i++ {
		prime := <- ch
		ch1 := make(chan uint64)
		go Filter(ch, ch1, prime)
		ch = ch1
    }
    
    for i := 0; i < num_chans; i++ {
        <- ch
    }
}

func Generate(ch chan<- uint64) {
	for i := uint64(2); ; i++ {
		ch <- i
	}
}


func Filter(in <-chan uint64, out chan<- uint64, prime uint64) {
	for {
		i := <- in
		if i % prime != 0 {
			out <- i
		}
	}
}