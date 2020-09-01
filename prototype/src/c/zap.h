#ifndef _ZAP_H
#define _ZAP_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct ZAP_RUNNABLE ZAP_RUNNABLE;

typedef void (*ZAP_CALLBACK)(struct ZAP_RUNNABLE*);

struct ZAP_RUNNABLE {
    ZAP_RUNNABLE* next;
    ZAP_CALLBACK callback;
};

#define ZAP_RUNNABLE_INIT(callback_fn)  \
    ((ZAP_RUNNABLE) {                   \
        .next = NULL,                   \
        .callback = callback_fn         \
    })

static inline void ZapRunnableInit(
    ZAP_RUNNABLE* self,
    ZAP_CALLBACK callback
) {
    self->callback = callback;
}

typedef struct ZAP_RUNNABLE_BATCH {
    ZAP_RUNNABLE* head;
    ZAP_RUNNABLE* tail;
    size_t len;
} ZAP_RUNNABLE_BATCH;

#define ZAP_RUNNABLE_BATCH_INIT \
    ((ZAP_RUNNABLE_BATCH){0})

static inline void ZapRunnableBatchInit(
    ZAP_RUNNABLE_BATCH* self
) {
    *self = ZAP_RUNNABLE_BATCH_INIT;
}

static inline size_t ZapRunnableBatchLength(
    const ZAP_RUNNABLE_BATCH* self
) {
    return self->len;
}

static inline void ZapRunnableBatchPush(
    ZAP_RUNNABLE_BATCH* self,
    ZAP_RUNNABLE* runnable
) {
    if (self->head == NULL)
        self->head = runnable;
    if (self->tail != NULL)
        self->tail->next = runnable;
    self->tail = runnable;
    runnable->next = NULL;
    self->len++;
}

static inline ZAP_RUNNABLE* ZapRunnableBatchPop(
  ZAP_RUNNABLE_BATCH* self
) {
    ZAP_RUNNABLE* runnable = self->head;
    if (runnable == NULL)
        return NULL;
    self->head = runnable->next;
    if (self->head == NULL)
        self->tail = NULL;
    self->len--;
    return runnable;
}

typedef enum ZAP_SCHED_HINT {
    ZAP_SCHED_FIFO = 0,
    ZAP_SCHED_LIFO = 1,
} ZAP_SCHED_HINT;

void ZapRunnableBatchSchedule(
    ZAP_RUNNABLE_BATCH* batch,
    ZAP_SCHED_HINT scheduler_hint
);

static inline void ZapRunnableSchedule(
    ZAP_RUNNABLE* runnable,
    ZAP_SCHED_HINT scheduler_hint
) {
    ZAP_RUNNABLE_BATCH batch = ZAP_RUNNABLE_BATCH_INIT;
    ZapRunnableBatchPush(&batch, runnable);
    ZapRunnableBatchSchedule(&batch, scheduler_hint);
}

//////////////////////////////////////////////////////

typedef struct ZAP_RUN_CONFIG {
    size_t max_threads;
} ZAP_RUN_CONFIG;

#define ZAP_RUN_CONFIG_INIT \
    ((ZAP_RUN_CONFIG){0})

static inline void ZapRunConfigInit(
    ZAP_RUN_CONFIG* self,
    size_t max_threads
) {
    self->max_threads = max_threads;
}

typedef enum ZAP_RUN_STATUS {
    ZAP_RUN_SUCCESS = 0,
    ZAP_RUN_OOM = 1,
} ZAP_RUN_STATUS;

ZAP_RUN_STATUS ZapRun(
    const ZAP_RUN_CONFIG* config,
    ZAP_RUNNABLE* runnable
);

#endif // _ZAP_H