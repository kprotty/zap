#include <zap.h>
#include <stdlib.h>
#include <assert.h>
#include <stdatomic.h>

#define NUM_SPAWNERS 10
#define NUM_TASKS_PER_SPAWNER (500 * 1000)
#define NUM_TASKS (NUM_TASKS_PER_SPAWNER * NUM_SPAWNERS)

#define fieldParentPtr(type, field, ptr) \
    ((type*)(((char*)(ptr)) - offsetof(type, field)))

typedef struct Task Task;
typedef struct Root Root;

typedef struct {
    ZAP_RUNNABLE runnable;
    Root* root;
    int begin;
    int end;
} Spawner;

struct Root {
    ZAP_RUNNABLE runnable;
    _Atomic(size_t) counter;
    Task* tasks;
    Spawner spawners[NUM_SPAWNERS];
};

struct Task {
    ZAP_RUNNABLE runnable;
    Root* root;
};

void task_run(ZAP_RUNNABLE* runnable) {
    Task* self = fieldParentPtr(Task, runnable, runnable);

    size_t counter = atomic_fetch_add(&self->root->counter, 1);
    if (counter + 1 == NUM_TASKS)
        ZapRunnableSchedule(&self->root->runnable, ZAP_SCHED_LIFO);
}

void spawner_run(ZAP_RUNNABLE* runnable) {
    Spawner* self = fieldParentPtr(Spawner, runnable, runnable);

    ZAP_RUNNABLE_BATCH batch = ZAP_RUNNABLE_BATCH_INIT;
    for (int i = self->begin; i < self->end; i++) {
        Task* task = &self->root->tasks[i];
        task->runnable = ZAP_RUNNABLE_INIT(task_run);
        task->root = self->root;
        ZapRunnableBatchPush(&batch, &task->runnable);
    }

    ZapRunnableBatchSchedule(&batch, ZAP_SCHED_LIFO);
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
    for (int i = 0; i < NUM_SPAWNERS; i++) {
        Spawner* spawner = &self->spawners[i];
        spawner->runnable = ZAP_RUNNABLE_INIT(spawner_run);
        spawner->root = self;
        spawner->begin = i * NUM_TASKS_PER_SPAWNER;
        spawner->end = spawner->begin + NUM_TASKS_PER_SPAWNER;
        if (spawner->end > NUM_TASKS)
            spawner->end = NUM_TASKS;
        ZapRunnableBatchPush(&batch, &spawner->runnable);
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