//! Section 12 Q4: compare Loupe's energy ordering with Apple's `top -o power`
//! (its POWER column is the energy-impact metric) for a few minutes and report
//! how often the top three user-owned apps agree. Root processes are excluded
//! because `proc_pid_rusage` cannot see them without `top`'s entitlement.

use std::collections::HashMap;
use std::process::Command;
use std::time::Duration;
use sysmon_core::engine::{Config, Engine};

fn main() {
    let secs: u64 = std::env::var("RANK_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(120);
    let engine = Engine::start(Config { interval_secs: 2, stream: false, ..Default::default() });
    std::thread::sleep(Duration::from_secs(6));
    let mut samples = 0;
    let mut top1 = 0;
    let mut top3_set = 0;
    let mut top3_order = 0;
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(secs) {
        let Ok(out) = Command::new("top").args(["-l", "2", "-n", "40", "-o", "power", "-stats", "pid,power"]).output() else { break };
        let text = String::from_utf8_lossy(&out.stdout);
        // second sample only: the first has no deltas
        let block = text.rsplit("PID").next().unwrap_or("");
        let mut top_pids: Vec<(i32, f64)> = block
            .lines()
            .filter_map(|l| {
                let mut it = l.split_whitespace();
                let pid = it.next()?.parse::<i32>().ok()?;
                let p = it.next()?.parse::<f64>().ok()?;
                Some((pid, p))
            })
            .collect();
        let Some(json) = engine.latest_json() else { continue };
        let Ok(snap) = serde_json::from_str::<serde_json::Value>(&json) else { continue };
        let apps = snap["apps"].as_array().cloned().unwrap_or_default();
        let mut pid_to_app: HashMap<i32, (String, f64)> = HashMap::new();
        for a in &apps {
            let name = a["name"].as_str().unwrap_or("").to_string();
            let e = a["energy_w"].as_f64().unwrap_or(0.0);
            for c in a["children"].as_array().cloned().unwrap_or_default() {
                if let Some(p) = c["pid"].as_i64() {
                    pid_to_app.insert(p as i32, (name.clone(), e));
                }
            }
        }
        let me = std::process::id() as i32;
        top_pids.retain(|(p, _)| *p != me && pid_to_app.contains_key(p));
        // fold top's per-process power into apps, keep order of first appearance
        let mut apple: Vec<(String, f64)> = Vec::new();
        for (p, pw) in &top_pids {
            let name = &pid_to_app[p].0;
            if let Some(e) = apple.iter_mut().find(|(n, _)| n == name) { e.1 += pw } else { apple.push((name.clone(), *pw)) }
        }
        apple.sort_by(|a, b| b.1.total_cmp(&a.1));
        let mut ours: Vec<(String, f64)> = apps
            .iter()
            .map(|a| (a["name"].as_str().unwrap_or("").to_string(), a["energy_w"].as_f64().unwrap_or(0.0)))
            .filter(|(n, _)| apple.iter().any(|(m, _)| m == n))
            .collect();
        ours.sort_by(|a, b| b.1.total_cmp(&a.1));
        if apple.len() < 3 || ours.len() < 3 {
            continue;
        }
        samples += 1;
        let a3: Vec<&str> = apple.iter().take(3).map(|x| x.0.as_str()).collect();
        let o3: Vec<&str> = ours.iter().take(3).map(|x| x.0.as_str()).collect();
        if a3[0] == o3[0] { top1 += 1 }
        if a3.iter().all(|n| o3.contains(n)) { top3_set += 1 }
        if a3 == o3 { top3_order += 1 }
        println!("top:   {}", apple.iter().take(5).map(|(n, p)| format!("{n} {p:.1}")).collect::<Vec<_>>().join(" | "));
        println!("loupe: {}", ours.iter().take(5).map(|(n, w)| format!("{n} {:.2}W", w)).collect::<Vec<_>>().join(" | "));
        println!();
        std::thread::sleep(Duration::from_secs(3));
    }
    drop(engine);
    println!("samples {samples}: same #1 {top1}, same top-3 set {top3_set}, same top-3 order {top3_order}");
}
