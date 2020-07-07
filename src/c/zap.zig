const zap = @import("zap");

pub const Runnable = zap.Runnable;
pub const Batch = Runnable.Batch;

pub const SchedulerHint = extern enum {
    fifo = 0,
    lifo = 1,
};

pub export fn ZapRunnableBatchSchedule(
    batch: *Batch,
    hint: SchedulerHint,
) void {
    return switch (hint) {
        .fifo => batch.schedule(),
        .lifo => batch.scheduleNext(),
    };
}

pub const RunConfig = zap.Scheduler.Config;

pub const RunStatus = extern enum {
    success = 0,
    out_of_memory = 1,
};

pub export fn ZapRun(
    config: *RunConfig,
    runnable: *Runnable,
) RunStatus {
    zap.Scheduler.run(config.*, runnable) catch |err| switch (err) {
        error.OutOfMemory => return RunStatus.out_of_memory,
    };
    return RunStatus.success;
}
