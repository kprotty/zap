use super::Thread;

pub type RunFn = extern "C" fn(&mut Task, &Thread) -> Batch;

#[repr(C)]
pub struct Task {}

pub struct Batch {}
