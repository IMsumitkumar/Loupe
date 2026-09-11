//! Fixed-length ring buffers, one per chart series, all pushed on the same
//! tick so every chart shares one time axis. A tick with no fresh Mole line
//! pushes `None`, which the UI draws as a gap instead of a flat line.

use serde::Serialize;
use std::collections::VecDeque;

pub const CAPACITY: usize = 300;

pub type Series = VecDeque<Option<f32>>;

#[derive(Debug, Clone, Default, Serialize)]
pub struct History {
    pub cpu: Series,
    pub cpu_p: Series,
    pub cpu_e: Series,
    pub mem_used_pct: Series,
    pub swap_used_gb: Series,
    pub pressure_level: Series,
    pub net_rx: Series,
    pub net_tx: Series,
    pub disk_r: Series,
    pub disk_w: Series,
    pub power_w: Series,
    pub top_impact: Series,
}

pub fn push(s: &mut Series, v: Option<f32>) {
    if s.len() >= CAPACITY {
        s.pop_front();
    }
    s.push_back(v.filter(|x| x.is_finite()).map(round1));
}

pub fn round1(v: f32) -> f32 {
    (v * 10.0).round() / 10.0
}

pub fn round2(v: f32) -> f32 {
    (v * 100.0).round() / 100.0
}

/// Energy keeps 0.1 mW so idle apps still order instead of tying at zero.
pub fn round4(v: f32) -> f32 {
    (v * 10000.0).round() / 10000.0
}

impl History {
    pub fn clear(&mut self) {
        *self = Self::default();
    }

    pub fn all_mut(&mut self) -> [&mut Series; 12] {
        [
            &mut self.cpu,
            &mut self.cpu_p,
            &mut self.cpu_e,
            &mut self.mem_used_pct,
            &mut self.swap_used_gb,
            &mut self.pressure_level,
            &mut self.net_rx,
            &mut self.net_tx,
            &mut self.disk_r,
            &mut self.disk_w,
            &mut self.power_w,
            &mut self.top_impact,
        ]
    }
}
