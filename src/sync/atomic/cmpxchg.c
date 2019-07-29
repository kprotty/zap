#ifndef CMPXCHG_H
#define CMPXCHG_H

#include <stddef.h>
#include <stdbool.h>
#include <stdatomic.h>

typedef struct {
    size_t raw[2];
} DoubleWord;

static inline bool cmpxchg(size_t ptr, size_t cmp, size_t xchg1, size_t xchg2) {
    DoubleWord xchg = { .raw = { xchg1, xchg2 } };
    return atomic_compare_exchange_weak_explicit(
        (_Atomic(DoubleWord*)) ptr,
        (DoubleWord*) cmp,
        &xchg,
        memory_order_relaxed,
        memory_order_relaxed,
    );
}

#endif // CMPXCHG_H