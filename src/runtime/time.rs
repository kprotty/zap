use super::{
    task::{Task, Batch},
};
use std::{
    collections::{Vec, BTreeMap},
    sync::Mutex,
    time::{Instant, Duration},
};

struct Delay {
    index: Cell<usize>,
    waker: Mutex<Waker>,
}

enum DelayPoll {
    Expired(Batch),
    Wait(Duration),
}

pub struct DelayQueue {
    entries: Mutex<BTreeMap<Instant, Vec<Arc<Delay>>>>.
}

impl DelayQueue {
    pub fn schedule(&self, deadline: Instant, delay: Arc<Delay>) {

    }
}