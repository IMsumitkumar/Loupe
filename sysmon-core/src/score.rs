//! Pressure verdict: Mole's health score inverted, plus attribution.
//!
//! Weights and thresholds mirror ../Mole/cmd/status/metrics_health.go
//! (Mole 1.53.0). The score itself is read from the stream; the penalties are
//! re-evaluated locally only to find which metric contributed most. Resync
//! the constants when Mole changes them.

use crate::mole::MoleSnapshot;
use crate::rollup::{App, Kind};
use serde::Serialize;

const CPU_WEIGHT: f64 = 30.0;
const MEM_WEIGHT: f64 = 25.0;
const DISK_WEIGHT: f64 = 20.0;
const THERMAL_WEIGHT: f64 = 15.0;
const IO_WEIGHT: f64 = 10.0;

pub const CPU_NORMAL: f64 = 50.0;
pub const CPU_HIGH: f64 = 85.0;
pub const MEM_NORMAL: f64 = 70.0;
pub const MEM_HIGH: f64 = 88.0;
const MEM_PRESSURE_WARN: f64 = 5.0;
const MEM_PRESSURE_CRIT: f64 = 15.0;
pub const DISK_WARN: f64 = 80.0;
pub const DISK_CRIT: f64 = 93.0;
pub const THERMAL_NORMAL: f64 = 65.0;
pub const THERMAL_HIGH: f64 = 85.0;
pub const IO_NORMAL: f64 = 50.0;
pub const IO_HIGH: f64 = 150.0;
pub const BATTERY_CYCLE_WARN: i64 = 800;
pub const BATTERY_CYCLE_DANGER: i64 = 900;
pub const BATTERY_CAP_WARN: i64 = 80;
pub const BATTERY_CAP_DANGER: i64 = 60;
const UPTIME_WARN_SECS: u64 = 7 * 86400;
const UPTIME_DANGER_SECS: u64 = 14 * 86400;
const SMART_FAILING: &str = "failing";

pub const HEALTH_EXCELLENT: i64 = 85;
pub const HEALTH_GOOD: i64 = 65;
pub const HEALTH_FAIR: i64 = 45;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Driver {
    None,
    Cpu,
    Memory,
    Disk,
    Thermal,
    Io,
    Battery,
    Uptime,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Penalties {
    pub cpu: f64,
    pub memory: f64,
    pub disk: f64,
    pub thermal: f64,
    pub io: f64,
    pub battery: f64,
    pub uptime: f64,
    pub issues: Vec<&'static str>,
}

impl Penalties {
    pub fn total(&self) -> f64 {
        self.cpu + self.memory + self.disk + self.thermal + self.io + self.battery + self.uptime
    }
}

fn ramp(v: f64, normal: f64, high: f64, weight: f64) -> f64 {
    if v > high {
        weight * (v - normal) / (100.0 - normal)
    } else if v > normal {
        (weight / 2.0) * (v - normal) / (high - normal)
    } else {
        0.0
    }
}

pub fn penalties(m: &MoleSnapshot) -> Penalties {
    let mut p = Penalties::default();

    p.cpu = ramp(m.cpu.usage, CPU_NORMAL, CPU_HIGH, CPU_WEIGHT);
    if m.cpu.usage > CPU_HIGH {
        p.issues.push("High CPU");
    }

    p.memory = ramp(m.memory.used_percent, MEM_NORMAL, MEM_HIGH, MEM_WEIGHT);
    if m.memory.used_percent > MEM_HIGH {
        p.issues.push("High Memory");
    }
    match m.memory.pressure.as_str() {
        "warn" => {
            p.memory += MEM_PRESSURE_WARN;
            p.issues.push("Memory Pressure");
        }
        "critical" => {
            p.memory += MEM_PRESSURE_CRIT;
            p.issues.push("Critical Memory");
        }
        _ => {}
    }

    if let Some(d) = m.disks.first() {
        let u = d.used_percent;
        if u > DISK_CRIT {
            p.disk = DISK_WEIGHT * (u - DISK_WARN) / (100.0 - DISK_WARN);
            p.issues.push("Disk Almost Full");
        } else if u > DISK_WARN {
            p.disk = (DISK_WEIGHT / 2.0) * (u - DISK_WARN) / (DISK_CRIT - DISK_WARN);
        }
    }
    if m.disks.iter().any(|d| d.smart_status == SMART_FAILING) {
        // Mole caps the score at 44 here; expressed as a penalty so the
        // driver ranking sees it.
        let so_far = 100.0 - (p.cpu + p.memory + p.disk);
        if so_far > 44.0 {
            p.disk += so_far - 44.0;
        }
        p.issues.push("Disk SMART Failing");
    }

    let t = m.thermal.cpu_temp;
    if t > 0.0 {
        if t > THERMAL_HIGH {
            p.thermal = THERMAL_WEIGHT;
            p.issues.push("Overheating");
        } else if t > THERMAL_NORMAL {
            p.thermal = THERMAL_WEIGHT * (t - THERMAL_NORMAL) / (THERMAL_HIGH - THERMAL_NORMAL);
        }
    }

    let io = m.disk_io.read_rate + m.disk_io.write_rate;
    if io > IO_HIGH {
        p.io = IO_WEIGHT;
        p.issues.push("Heavy Disk IO");
    } else if io > IO_NORMAL {
        p.io = IO_WEIGHT * (io - IO_NORMAL) / (IO_HIGH - IO_NORMAL);
    }

    if let Some(b) = m.batteries.first() {
        match battery_severity(b.cycle_count, b.capacity) {
            "danger" => {
                p.battery = 5.0;
                p.issues.push("Battery Service Soon");
            }
            "warn" => p.battery = 2.0,
            _ => {}
        }
    }

    if m.uptime_seconds > UPTIME_DANGER_SECS {
        p.uptime = 3.0;
        p.issues.push("Restart Recommended");
    } else if m.uptime_seconds > UPTIME_WARN_SECS {
        p.uptime = 1.0;
    }
    p
}

pub fn battery_severity(cycles: i64, capacity: i64) -> &'static str {
    if cycles > BATTERY_CYCLE_DANGER || (capacity > 0 && capacity < BATTERY_CAP_DANGER) {
        "danger"
    } else if cycles > BATTERY_CYCLE_WARN || (capacity > 0 && capacity < BATTERY_CAP_WARN) {
        "warn"
    } else {
        "ok"
    }
}

pub fn driver(p: &Penalties) -> Driver {
    let candidates = [
        (p.cpu, Driver::Cpu),
        (p.memory, Driver::Memory),
        (p.disk, Driver::Disk),
        (p.thermal, Driver::Thermal),
        (p.io, Driver::Io),
        (p.battery, Driver::Battery),
        (p.uptime, Driver::Uptime),
    ];
    let mut best = (0.0, Driver::None);
    for (v, d) in candidates {
        if v > best.0 {
            best = (v, d);
        }
    }
    best.1
}

pub fn pressure(health_score: i64) -> i64 {
    (100 - health_score).clamp(0, 100)
}

/// Bands follow Mole's health bands exactly (85/65/45) so the two tools never
/// disagree in front of the user.
pub fn band(pressure: i64) -> &'static str {
    let health = 100 - pressure;
    if health >= HEALTH_EXCELLENT {
        "calm"
    } else if health >= HEALTH_GOOD {
        "normal"
    } else if health >= HEALTH_FAIR {
        "busy"
    } else {
        "strained"
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Culprit {
    pub key: String,
    pub name: String,
    pub root_pid: i32,
    pub detail: String,
    pub quit_ok: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Verdict {
    pub score: Option<i64>,
    /// True when the score was computed locally from Mach readings because
    /// the Mole stream is off or absent; exact once the stream is live.
    pub approximate: bool,
    pub band: &'static str,
    pub driver: Driver,
    pub flagged: bool,
    pub headline: String,
    pub explanation: String,
    pub culprit: Option<Culprit>,
    pub issues: Vec<&'static str>,
    pub penalties: Penalties,
}

pub fn fmt_bytes(b: u64) -> String {
    let gb = b as f64 / 1_073_741_824.0;
    if gb >= 10.0 {
        format!("{gb:.0} GB")
    } else if gb >= 1.0 {
        format!("{gb:.1} GB")
    } else {
        format!("{:.0} MB", b as f64 / 1_048_576.0)
    }
}

fn top_by<F: Fn(&App) -> Option<f32>>(apps: &[App], f: F) -> Option<&App> {
    apps.iter()
        .filter(|a| !a.is_self)
        .filter_map(|a| f(a).map(|v| (v, a)))
        .filter(|(v, _)| *v > 0.0)
        .max_by(|a, b| a.0.total_cmp(&b.0))
        .map(|(_, a)| a)
}

fn culprit(app: &App, detail: String) -> Culprit {
    Culprit {
        key: app.key.clone(),
        name: app.name.clone(),
        root_pid: app.root_pid,
        detail,
        quit_ok: app.kind == Kind::App && app.quit_ok,
    }
}

pub fn verdict(m: Option<&MoleSnapshot>, apps: &[App]) -> Verdict {
    let Some(m) = m else {
        return Verdict {
            score: None,
            approximate: true,
            band: "unknown",
            driver: Driver::None,
            flagged: false,
            headline: "Waiting for Mole".to_string(),
            explanation: "System checks need the Mole command line tool. Apps are still measured."
                .to_string(),
            culprit: None,
            issues: Vec::new(),
            penalties: Penalties::default(),
        };
    };
    let p = penalties(m);
    let score = pressure(m.health_score);
    let band = band(score);
    let drv = driver(&p);
    let flagged = !p.issues.is_empty() || band == "busy" || band == "strained";

    let (headline, mut explanation, culprit) = if !flagged {
        (
            "Nothing needs your attention".to_string(),
            "Every check passed. Nothing to explain.".to_string(),
            None,
        )
    } else {
        match drv {
            Driver::Cpu => {
                let c = top_by(apps, |a| a.cpu).map(|a| {
                    culprit(a, format!("using {:.0}% of one core", a.cpu.unwrap_or(0.0)))
                });
                let mut e = format!("The processor is {:.0}% busy.", m.cpu.usage);
                if let Some(c) = &c {
                    e.push_str(&format!(" {} is using the most, at {}.", c.name, c.detail.trim_start_matches("using ")));
                }
                ("Your Mac is working hard".to_string(), e, c)
            }
            Driver::Memory => {
                let c = top_by(apps, |a| Some(a.memory as f32))
                    .map(|a| culprit(a, format!("holding {}", fmt_bytes(a.memory))));
                let swapping = m.memory.swap_used > 0
                    || m.memory.pressure == "warn"
                    || m.memory.pressure == "critical";
                let mut e = if swapping {
                    "Your Mac has started moving data to disk, which is slower than memory."
                        .to_string()
                } else {
                    format!(
                        "{:.0}% of your {} of memory is in use.",
                        m.memory.used_percent,
                        fmt_bytes(m.memory.total)
                    )
                };
                if let Some(c) = &c {
                    e.push_str(&format!(" {} is {}.", c.name, c.detail));
                }
                ("Memory is running low".to_string(), e, c)
            }
            Driver::Disk => {
                let d = m.disks.first();
                let used = d.map(|d| d.used_percent).unwrap_or(0.0);
                let free = d.map(|d| d.total.saturating_sub(d.used)).unwrap_or(0);
                let e = if m.disks.iter().any(|d| d.smart_status == SMART_FAILING) {
                    "Your disk reports a hardware fault. Back up now.".to_string()
                } else {
                    format!(
                        "{used:.0}% of your disk is used, {} left. Free up space to keep macOS fast.",
                        fmt_bytes(free)
                    )
                };
                ("Your disk is almost full".to_string(), e, None)
            }
            Driver::Thermal => {
                let c = top_by(apps, |a| a.cpu)
                    .map(|a| culprit(a, format!("using {:.0}% of one core", a.cpu.unwrap_or(0.0))));
                let mut e = format!("The processor is at {:.0}°C.", m.thermal.cpu_temp);
                if let Some(c) = &c {
                    e.push_str(&format!(" {} is working it hardest.", c.name));
                }
                ("Your Mac is running hot".to_string(), e, c)
            }
            Driver::Io => {
                let c = top_by(apps, |a| Some(a.disk_bps)).map(|a| {
                    culprit(a, format!("moving {:.1} MB/s", a.disk_bps / 1_048_576.0))
                });
                let mut e = format!(
                    "Reading and writing {:.0} MB/s.",
                    m.disk_io.read_rate + m.disk_io.write_rate
                );
                if let Some(c) = &c {
                    e.push_str(&format!(" {} is doing most of it.", c.name));
                }
                ("Your disk is working hard".to_string(), e, c)
            }
            Driver::Battery => {
                let b = m.batteries.first();
                let e = format!(
                    "It holds {}% of its original charge after {} cycles.",
                    b.map(|b| b.capacity).unwrap_or(0),
                    b.map(|b| b.cycle_count).unwrap_or(0)
                );
                ("Your battery needs service".to_string(), e, None)
            }
            Driver::Uptime => (
                "A restart is overdue".to_string(),
                format!("Your Mac has been on for {} days.", m.uptime_seconds / 86400),
                None,
            ),
            Driver::None => (
                "Your Mac is under pressure".to_string(),
                m.health_score_msg.clone(),
                None,
            ),
        }
    };
    if explanation.is_empty() {
        explanation = m.health_score_msg.clone();
    }
    Verdict {
        score: Some(score),
        approximate: false,
        band,
        driver: drv,
        flagged,
        headline,
        explanation,
        culprit,
        issues: p.issues.clone(),
        penalties: p,
    }
}
