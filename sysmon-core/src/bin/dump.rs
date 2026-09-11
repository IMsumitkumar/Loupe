//! Prints the current app rollup once, for debugging names, paths and grouping:
//! `cargo run --release --bin dump`.

use std::time::Duration;
use sysmon_core::engine::{Config, Engine};

fn main() {
    let engine = Engine::start(Config { interval_secs: 1, stream: false, ..Default::default() });
    std::thread::sleep(Duration::from_millis(2600));
    let Some(json) = engine.latest_json() else { return };
    let Ok(snap) = serde_json::from_str::<serde_json::Value>(&json) else { return };
    for a in snap["apps"].as_array().cloned().unwrap_or_default() {
        println!("{:<28} {:<7} procs={:<3} cpu={:<6} energy={:<8} path={}",
            a["name"].as_str().unwrap_or(""), a["kind"].as_str().unwrap_or(""), a["procs"], a["cpu"], a["energy_w"], a["path"].as_str().unwrap_or(""));
        for c in a["children"].as_array().cloned().unwrap_or_default().iter().take(3) {
            println!("    pid {:<6} {:<24} {}", c["pid"], c["name"].as_str().unwrap_or(""), c["path"].as_str().unwrap_or(""));
        }
    }
}
