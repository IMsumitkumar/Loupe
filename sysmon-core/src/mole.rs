//! Mirror of `MetricsSnapshot` in ../Mole/cmd/status/metrics.go.
//! Synced against Mole 1.53.0 (2026-09-11).
//!
//! Every field is optional in practice: a missing key takes its default and a
//! JSON `null` array decodes as empty, because Go emits nil slices as `null`.
//! Sections we never render (`network_history`, `proxy`, `sensors`,
//! `bluetooth`, `zombie_parents`, `process_watch`, `process_alerts`) are not
//! mirrored; serde ignores unknown keys.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

fn null_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MoleSnapshot {
    pub collected_at: String,
    pub host: String,
    pub platform: String,
    pub uptime: String,
    pub uptime_seconds: u64,
    pub procs: u64,
    pub hardware: Hardware,
    pub health_score: i64,
    pub health_score_msg: String,
    pub cpu: Cpu,
    #[serde(deserialize_with = "null_default")]
    pub gpu: Vec<Gpu>,
    pub memory: Memory,
    #[serde(deserialize_with = "null_default")]
    pub disks: Vec<Disk>,
    pub trash_size: u64,
    pub trash_approx: bool,
    pub disk_io: DiskIo,
    #[serde(deserialize_with = "null_default")]
    pub network: Vec<Network>,
    #[serde(deserialize_with = "null_default")]
    pub batteries: Vec<Battery>,
    pub thermal: Thermal,
    #[serde(deserialize_with = "null_default")]
    pub top_processes: Vec<Process>,
    pub process_collected_at: Option<String>,
    pub process_stale: Option<bool>,
    pub zombie_count: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Hardware {
    pub model: String,
    pub cpu_model: String,
    pub total_ram: String,
    pub disk_size: String,
    pub os_version: String,
    pub refresh_rate: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Cpu {
    pub usage: f64,
    #[serde(deserialize_with = "null_default")]
    pub per_core: Vec<f64>,
    pub per_core_estimated: bool,
    pub load1: f64,
    pub load5: f64,
    pub load15: f64,
    pub core_count: i64,
    pub logical_cpu: i64,
    pub p_core_count: i64,
    pub e_core_count: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Gpu {
    pub name: String,
    pub usage: f64,
    pub memory_used: f64,
    pub memory_total: f64,
    pub core_count: i64,
    pub note: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Memory {
    pub used: u64,
    pub total: u64,
    pub available: u64,
    pub used_percent: f64,
    pub swap_used: u64,
    pub swap_total: u64,
    pub cached: u64,
    pub pressure: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Disk {
    pub mount: String,
    pub device: String,
    pub used: u64,
    pub total: u64,
    pub used_percent: f64,
    pub fstype: String,
    pub external: bool,
    pub smart_status: String,
    pub purgeable: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct DiskIo {
    pub read_rate: f64,
    pub write_rate: f64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Network {
    pub name: String,
    pub rx_rate_mbs: f64,
    pub tx_rate_mbs: f64,
    pub ip: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Battery {
    pub percent: f64,
    pub status: String,
    pub time_left: String,
    pub health: String,
    pub cycle_count: i64,
    pub capacity: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Thermal {
    pub cpu_temp: f64,
    pub gpu_temp: f64,
    pub battery_temp: f64,
    pub fan_speed: i64,
    pub fan_count: i64,
    pub system_power: f64,
    pub adapter_power: f64,
    pub battery_power: f64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Process {
    pub pid: i32,
    pub ppid: i32,
    pub name: String,
    pub command: String,
    pub cpu: f64,
    pub memory: f64,
    pub memory_bytes: u64,
}

/// Decodes stream lines. When a top-level section stops matching its type,
/// that key is dropped for the rest of the session so one changed field costs
/// one panel, not the whole feed.
#[derive(Debug, Default)]
pub struct Decoder {
    bad_keys: Vec<String>,
}

impl Decoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn bad_keys(&self) -> &[String] {
        &self.bad_keys
    }

    pub fn decode(&mut self, line: &str) -> Result<MoleSnapshot, String> {
        let mut value: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
        let Some(obj) = value.as_object_mut() else {
            return Err("line is not a JSON object".to_string());
        };
        for k in &self.bad_keys {
            obj.remove(k);
        }
        let first = match serde_json::from_value::<MoleSnapshot>(value.clone()) {
            Ok(s) => return Ok(s),
            Err(e) => e.to_string(),
        };
        let mut newly_bad = Vec::new();
        if let Some(obj) = value.as_object() {
            for (k, v) in obj {
                let single = Value::Object(std::iter::once((k.clone(), v.clone())).collect());
                if serde_json::from_value::<MoleSnapshot>(single).is_err() {
                    newly_bad.push(k.clone());
                }
            }
        }
        if newly_bad.is_empty() {
            return Err(first);
        }
        if let Some(obj) = value.as_object_mut() {
            for k in &newly_bad {
                obj.remove(k);
            }
        }
        self.bad_keys.extend(newly_bad);
        serde_json::from_value::<MoleSnapshot>(value).map_err(|e| e.to_string())
    }
}
