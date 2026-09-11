//! `make verify`: run the engine beside `mo status --json` for a minute and
//! report per-metric drift. Memory, disk and network must agree within 2%.
//! Process CPU is expected to diverge and the output says why.

use std::process::Command;
use std::time::{Duration, Instant};
use sysmon_core::engine::{Config, Engine};
use sysmon_core::mole::{Decoder, MoleSnapshot};

fn find_mo() -> Option<String> {
    let mut candidates: Vec<String> = std::env::var("PATH")
        .unwrap_or_default()
        .split(':')
        .map(|d| format!("{d}/mo"))
        .collect();
    candidates.push("/opt/homebrew/bin/mo".into());
    candidates.push("/usr/local/bin/mo".into());
    if let Ok(home) = std::env::var("HOME") {
        candidates.push(format!("{home}/.local/bin/mo"));
    }
    candidates.into_iter().find(|p| std::path::Path::new(p).is_file())
}

fn drift(ours: f64, theirs: f64) -> f64 {
    if ours.abs() < 0.01 && theirs.abs() < 0.01 {
        return 0.0;
    }
    (ours - theirs).abs() / theirs.abs().max(0.01) * 100.0
}

fn net_total(m: &MoleSnapshot) -> f64 {
    m.network.iter().map(|n| n.rx_rate_mbs + n.tx_rate_mbs).sum()
}

fn main() {
    let Some(mo) = std::env::args().nth(1).or_else(find_mo) else {
        eprintln!("verify: mo not found; pass its path as the first argument");
        std::process::exit(2);
    };
    let secs: u64 = std::env::var("VERIFY_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(60);
    println!("verify: engine vs `{mo} status --json` for {secs}s");
    let engine = Engine::start(Config { interval_secs: 1, mo_path: Some(mo.clone()), ..Default::default() });
    let start = Instant::now();
    let mut decoder = Decoder::new();
    let mut rows: Vec<(f64, f64, f64)> = Vec::new();
    let mut net_ours: Vec<f64> = Vec::new();
    let mut net_theirs: Vec<f64> = Vec::new();
    let mut proc_rows: Vec<(String, f64, Option<f64>)> = Vec::new();
    std::thread::sleep(Duration::from_secs(5));
    println!("{:>4} {:>12} {:>12} {:>12} {:>12}", "n", "mem drift%", "disk drift%", "net ours", "net mole");
    while start.elapsed() < Duration::from_secs(secs) {
        let Ok(out) = Command::new(&mo).args(["status", "--json"]).output() else { break };
        let text = String::from_utf8_lossy(&out.stdout);
        let Ok(theirs) = decoder.decode(text.trim()) else {
            println!("oneshot decode failed");
            continue;
        };
        let Some(json) = engine.latest_json() else { continue };
        let Ok(snap) = serde_json::from_str::<serde_json::Value>(&json) else { continue };
        let Some(ours) = snap.get("mole").cloned().and_then(|v| serde_json::from_value::<MoleSnapshot>(v).ok()) else {
            println!("engine has no Mole snapshot yet");
            std::thread::sleep(Duration::from_secs(2));
            continue;
        };
        let disk = |m: &MoleSnapshot| m.disks.first().map(|d| d.used_percent).unwrap_or(0.0);
        let r = (
            drift(ours.memory.used as f64, theirs.memory.used as f64),
            drift(disk(&ours), disk(&theirs)),
            0.0,
        );
        net_ours.push(net_total(&ours));
        net_theirs.push(net_total(&theirs));
        println!("{:>4} {:>12.2} {:>12.2} {:>12.3} {:>12.3}", rows.len() + 1, r.0, r.1, net_total(&ours), net_total(&theirs));
        rows.push(r);
        if let Some(procs) = snap.get("processes").and_then(|p| p.as_array()) {
            for t in &theirs.top_processes {
                let sampled = procs
                    .iter()
                    .find(|p| p.get("pid").and_then(|v| v.as_i64()) == Some(t.pid as i64))
                    .and_then(|p| p.get("cpu").and_then(|v| v.as_f64()));
                proc_rows.push((t.name.clone(), t.cpu, sampled));
            }
        }
        std::thread::sleep(Duration::from_secs(4));
    }
    drop(engine);
    if rows.is_empty() {
        println!("verify: no samples collected");
        std::process::exit(1);
    }
    let n = rows.len() as f64;
    let mean = |f: &dyn Fn(&(f64, f64, f64)) -> f64| rows.iter().map(f).sum::<f64>() / n;
    let (mem, disk) = (mean(&|r| r.0), mean(&|r| r.1));
    let avg = |v: &[f64]| v.iter().sum::<f64>() / v.len().max(1) as f64;
    let net = drift(avg(&net_ours), avg(&net_theirs));
    println!(
        "\nmean drift over {} samples: memory {mem:.2}%  disk {disk:.2}%  network {net:.2}% (run means {:.3} vs {:.3} MB/s)",
        rows.len(),
        avg(&net_ours),
        avg(&net_theirs)
    );
    println!("Network is compared as run means: both tools report an instantaneous rate over their own\nsampling window, so single samples taken at different instants legitimately differ.");
    println!("\nprocess CPU, Mole (ps, ~1 min decaying average) vs sampled (rusage delta over the last tick):");
    println!("{:<32} {:>10} {:>10}", "process", "mole %", "sampled %");
    for (name, theirs, ours) in proc_rows.iter().take(25) {
        let o = ours.map(|v| format!("{v:.1}")).unwrap_or_else(|| "n/a".into());
        println!("{:<32} {:>10.1} {:>10}", name, theirs, o);
    }
    println!(
        "\nProcess CPU is expected to diverge: BSD ps reports %CPU as a decaying average over roughly\n\
         the last minute, while the sampler measures the delta between two rusage reads. A process\n\
         that just finished a burst still reads high in Mole; one that just started reads low.\n\
         Root and other users' processes show n/a because proc_pid_rusage returns EPERM for them.\n\
         This is not a bug in either tool."
    );
    // A relative bound is meaningless on an idle link (16 vs 31 KB/s is "47%"), so the network
    // check also passes when the run means differ by under 0.05 MB/s.
    let net_abs = (avg(&net_ours) - avg(&net_theirs)).abs();
    let net_ok = net <= 2.0 || net_abs < 0.05;
    let pass = mem <= 2.0 && disk <= 2.0 && net_ok;
    println!(
        "\nverify: {}",
        if pass {
            format!("PASS (memory {mem:.2}%, disk {disk:.2}%, network {net:.2}% relative / {net_abs:.3} MB/s absolute)")
        } else {
            "FAIL (a metric drifted more than 2%)".to_string()
        }
    );
    std::process::exit(if pass { 0 } else { 1 });
}
