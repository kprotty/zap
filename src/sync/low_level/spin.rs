use std::{hint::spin_loop, thread};

#[derive(Default)]
pub struct Spin {
    counter: u8,
}

impl Spin {
    pub fn yield_now(&mut self) -> bool {
        if self.counter >= 10 {
            return false;
        }

        self.counter += 1;
        match self.counter {
            0..=3 => (0..(1 << self.counter)).for_each(|_| spin_loop()),
            _ => thread::yield_now(),
        }

        true
    }
}
