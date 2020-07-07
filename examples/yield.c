#include <zap.h>
#include <stdlib.h>
#include <assert.h>
#include <stdatomic.h>

#define NUM_TASKS (100 * 1000)
#define NUM_YIELDS 200

#define fieldParentPtr(type, field, ptr) \
    ((type*)(((char*)(ptr)) - offsetof(type, field)))

typedef struct Task Task;

typedef struct {
    ZAP_RUNNABLE runnable;
    _Atomic(size_t) counter;
    struct Task* tasks;
} Root;

struct Task {
    ZAP_RUNNABLE runnable;
    Root* root;
    int yielded;
};

void task_yield(ZAP_RUNNABLE* runnable) {
    Task* self = fieldParentPtr(Task, runnable, runnable);

    if (self->yielded < NUM_YIELDS) {
        self->yielded++;
        self->runnable = ZAP_RUNNABLE_INIT(task_yield);
        ZapRunnableSchedule(&self->runnable, ZAP_SCHED_FIFO);
        return;
    }

    size_t counter = atomic_fetch_add(&self->root->counter, 1);
    if (counter + 1 == NUM_TASKS)
        ZapRunnableSchedule(&self->root->runnable, ZAP_SCHED_LIFO);
}

void root_end(ZAP_RUNNABLE* runnable) {
    Root* self = fieldParentPtr(Root, runnable, runnable);

    size_t counter = atomic_load(&self->counter);
    assert(counter == NUM_TASKS);

    free(self->tasks);
    self->tasks = NULL;
}

void root_begin(ZAP_RUNNABLE* runnable) {
    Root* self = fieldParentPtr(Root, runnable, runnable);
    self->tasks = malloc(sizeof(Task) * NUM_TASKS);
    assert(self->tasks != NULL);

    ZAP_RUNNABLE_BATCH batch = ZAP_RUNNABLE_BATCH_INIT;
    for (int i = 0; i < NUM_TASKS; i++) {
        Task* task = &self->tasks[i];
        task->runnable = ZAP_RUNNABLE_INIT(task_yield);
        task->root = self;
        task->yielded = 0;
        ZapRunnableBatchPush(&batch, &task->runnable);
    }

    self->counter = 0;
    self->runnable = ZAP_RUNNABLE_INIT(root_end);
    ZapRunnableBatchSchedule(&batch, ZAP_SCHED_LIFO);
}

int main() {
    ZAP_RUN_CONFIG config;
    ZapRunConfigInit(&config, ~((size_t)0));

    Root root;
    root.runnable = ZAP_RUNNABLE_INIT(root_begin);

    ZAP_RUN_STATUS status = ZapRun(&config, &root.runnable);
    assert(status == ZAP_RUN_SUCCESS);

    assert(root.tasks == NULL);
    assert(atomic_load(&root.counter) == NUM_TASKS);
}