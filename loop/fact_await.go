package main

import "math/big"

func main() {
	const N = 10000
	fact(N)
}

func fact(n uint64) {
	var x big.Int
	done := make(chan struct{}, 1)
	bigIntMultRange(&x, 1, n, done)
	<-done
}

func bigIntMultRange(out *big.Int, a, b uint64, done chan struct{}) {
	if a == b {
		out.SetUint64(a)
		close(done)
		return
	}

	var l big.Int
	var r big.Int
	m := (a + b) / 2

	ldone := make(chan struct{}, 1)
	rdone := make(chan struct{}, 1)

	go bigIntMultRange(&l, a, m, ldone)
	go bigIntMultRange(&r, m + 1, b, rdone)
	
	<- ldone
	<- rdone
	out.Mul(&l, &r)
	close(done)
}