//! The background loop: wait for a Mole line or the interval, sample energy,
//! roll up, score, push history, and publish one JSON string that the FFI
//! hands to Swift.

use crate::energy::Sampler;
use crate::fallback;
use crate::history::{push, round1, round2, round4, History};
use crate::mole::{Decoder, MoleSnapshot};
use crate::rollup::{App, Proc, Resolver, Weights};
use crate::score::{self, Verdict};
use crate::supervisor::{Event, Supervisor};
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const MAX_APPS: usize = 20;
pub const MAX_PROCS: usize = 40;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub interval_secs: u64,
    /// Run the Mole stream. Off while the panel is closed: the core keeps
    /// ticking on Mach readings and the verdict is marked approximate.
    pub stream: bool,
    pub mo_path: Option<String>,
    pub mo_version: Option<String>,
    pub weights: Weights,
}

impl Default for Config {
    fn default() -> Self {
        Self { interval_secs: 2, stream: true, mo_path: None, mo_version: None, weights: Weights::default() }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct MoleStatus {
    pub state: &'static str,
    /// A line arrived within the last three intervals.
    pub live: bool,
    pub path: Option<String>,
    pub version: Option<String>,
    pub failures: u32,
    pub lines: u64,
    pub decode_errors: u64,
    pub bad_keys: Vec<String>,
    pub last_line_age_ms: Option<u64>,
    pub interval_secs: u64,
    pub child_pid: Option<i32>,
    pub stderr: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Cores {
    pub p: Vec<f32>,
    pub e: Vec<f32>,
    pub all: Vec<f32>,
    pub estimated: bool,
    pub split: bool,
    pub source: &'static str,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SystemFallback {
    pub cpu_usage: Option<f32>,
    pub mem_used: Option<u64>,
    pub mem_total: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SelfStats {
    pub pid: i32,
    pub cpu: Option<f32>,
    pub memory: Option<u64>,
    pub wakeups_per_s: Option<f32>,
    pub energy_w: Option<f32>,
    pub child_cpu: Option<f32>,
    pub child_memory: Option<u64>,
    pub tree_cpu: Option<f32>,
    pub tree_memory: Option<u64>,
    pub sample_ms: f32,
    pub tick_ms: f32,
    pub snapshot_bytes: usize,
    pub pids_total: usize,
    pub pids_readable: usize,
    /// Loupe's own CPU seconds since launch over wall seconds, as a percent of one core.
    pub avg_cpu_since_launch: f32,
    pub uptime_s: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    pub seq: u64,
    pub generated_at_ms: u64,
    pub mole: Option<MoleSnapshot>,
    pub mole_status: MoleStatus,
    pub verdict: Verdict,
    pub energy_mode: &'static str,
    pub apps: Vec<App>,
    pub processes: Vec<Proc>,
    pub history: History,
    pub cores: Cores,
    pub system: SystemFallback,
    pub self_stats: SelfStats,
}

struct Shared {
    latest: Mutex<Option<String>>,
    weights: Mutex<Weights>,
    version: Mutex<Option<String>>,
    stop: AtomicBool,
}

pub struct Engine {
    shared: Arc<Shared>,
    sup: Arc<Supervisor>,
    tx: Sender<Event>,
    thread: Option<JoinHandle<()>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

/// Own user+system CPU seconds from getrusage; the long-run honesty number.
fn own_cpu_seconds() -> f64 {
    // SAFETY: zeroed rusage is a valid out-buffer.
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) } != 0 {
        return 0.0;
    }
    let secs = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    secs(ru.ru_utime) + secs(ru.ru_stime)
}

fn unix_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl Engine {
    pub fn start(cfg: Config) -> Engine {
        let shared = Arc::new(Shared {
            latest: Mutex::new(None),
            weights: Mutex::new(cfg.weights),
            version: Mutex::new(cfg.mo_version.clone()),
            stop: AtomicBool::new(false),
        });
        let sup = Supervisor::new(cfg.mo_path.clone(), cfg.interval_secs);
        sup.reconfigure(cfg.mo_path.clone(), cfg.interval_secs, cfg.stream);
        let (tx, rx) = mpsc::channel::<Event>();
        let sup_thread = {
            let sup = Arc::clone(&sup);
            let tx = tx.clone();
            std::thread::Builder::new().name("mole-supervisor".into()).spawn(move || sup.run(tx)).ok()
        };
        let thread = {
            let shared = Arc::clone(&shared);
            let sup = Arc::clone(&sup);
            std::thread::Builder::new()
                .name("sysmon-engine".into())
                .spawn(move || {
                    run_loop(shared, Arc::clone(&sup), rx);
                    sup.stop();
                    if let Some(t) = sup_thread {
                        let _ = t.join();
                    }
                })
                .ok()
        };
        Engine { shared, sup, tx, thread }
    }

    pub fn apply(&self, cfg: Config) {
        *lock(&self.shared.weights) = cfg.weights;
        *lock(&self.shared.version) = cfg.mo_version;
        self.sup.reconfigure(cfg.mo_path, cfg.interval_secs, cfg.stream);
    }

    pub fn latest_json(&self) -> Option<String> {
        lock(&self.shared.latest).clone()
    }

    pub fn stop(mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        let _ = self.tx.send(Event::Stop);
        self.sup.stop();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        let _ = self.tx.send(Event::Stop);
        self.sup.stop();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Static fields arrive only on Mole's full collect (every 30 s) and are
/// empty on the fast line that follows each restart; keep the last good ones.
fn carry_forward(m: &mut MoleSnapshot, prev: Option<&MoleSnapshot>) {
    let Some(p) = prev else { return };
    if m.hardware.model.is_empty() {
        m.hardware = p.hardware.clone();
    }
    if m.cpu.p_core_count == 0 && m.cpu.e_core_count == 0 {
        m.cpu.p_core_count = p.cpu.p_core_count;
        m.cpu.e_core_count = p.cpu.e_core_count;
    }
    if m.memory.pressure.is_empty() {
        m.memory.pressure = p.memory.pressure.clone();
    }
}

fn mean(v: &[f32]) -> Option<f32> {
    if v.is_empty() { None } else { Some(v.iter().sum::<f32>() / v.len() as f32) }
}

fn cores(m: Option<&MoleSnapshot>) -> Cores {
    if let Some(m) = m {
        let all: Vec<f32> = m.cpu.per_core.iter().map(|v| round1(*v as f32)).collect();
        let (p, e) = (m.cpu.p_core_count as usize, m.cpu.e_core_count as usize);
        if p > 0 && e > 0 && all.len() == p + e {
            return Cores { p: all[e..].to_vec(), e: all[..e].to_vec(), all, estimated: m.cpu.per_core_estimated, split: true, source: "mole" };
        }
        return Cores { all, estimated: m.cpu.per_core_estimated, split: false, source: "mole", ..Default::default() };
    }
    Cores::default()
}

/// Top `n` by `key` without a full sort, then ordered for display.
fn top_n<T: Clone, F: Fn(&T) -> f32>(items: &[T], n: usize, key: F) -> Vec<T> {
    let mut v: Vec<T> = items.to_vec();
    if v.len() > n {
        v.select_nth_unstable_by(n, |a, b| key(b).total_cmp(&key(a)));
        v.truncate(n);
    }
    v.sort_by(|a, b| key(b).total_cmp(&key(a)));
    v
}

fn trim_apps(apps: &[App], energy_mode: &str) -> Vec<App> {
    let rank = |a: &App| if energy_mode == "energy" { a.energy_w.unwrap_or(0.0) } else { a.impact };
    let mut out = top_n(apps, MAX_APPS, rank);
    for extra in [top_n(apps, MAX_APPS, |a| a.memory as f32), top_n(apps, MAX_APPS, |a| a.cpu.unwrap_or(0.0))] {
        for a in extra {
            if !out.iter().any(|o| o.key == a.key) {
                out.push(a);
            }
        }
    }
    for a in &mut out {
        a.cpu = a.cpu.map(round1);
        a.energy_w = a.energy_w.map(round4);
        a.impact = round1(a.impact);
        a.wakeups = round1(a.wakeups);
        for c in &mut a.children {
            c.cpu = c.cpu.map(round1);
            c.energy_w = c.energy_w.map(round4);
            c.impact = round1(c.impact);
        }
    }
    out
}

fn trim_procs(apps: &[App]) -> Vec<Proc> {
    let all: Vec<Proc> = apps.iter().flat_map(|a| a.children.iter().cloned()).collect();
    let mut out = top_n(&all, MAX_PROCS, |p| p.cpu.unwrap_or(0.0));
    for p in top_n(&all, MAX_PROCS, |p| p.memory.unwrap_or(0) as f32) {
        if !out.iter().any(|o| o.pid == p.pid) {
            out.push(p);
        }
    }
    out
}

fn run_loop(shared: Arc<Shared>, sup: Arc<Supervisor>, rx: mpsc::Receiver<Event>) {
    // SAFETY: getpid has no preconditions.
    let self_pid = unsafe { libc::getpid() };
    let mut sampler = Sampler::new();
    let mut resolver = Resolver::default();
    let mut decoder = Decoder::new();
    let mut history = History::default();
    let mut cpu_fb = fallback::CpuFallback::new();
    let e_count = fallback::e_core_count();
    let mut mole: Option<MoleSnapshot> = None;
    let mut last_line: Option<Instant> = None;
    let mut lines = 0u64;
    let mut decode_errors = 0u64;
    let mut seq = 0u64;
    let mut last_sample = Instant::now() - Duration::from_secs(3600);
    let launched = Instant::now();
    let cpu_at_launch = own_cpu_seconds();
    let mut apps_all: Vec<App> = Vec::new();
    let mut snapshot_bytes = 0usize;

    loop {
        if shared.stop.load(Ordering::Relaxed) {
            break;
        }
        let interval = Duration::from_secs(sup.interval_secs.load(Ordering::Relaxed).max(1));
        let mut got_line = false;
        match rx.recv_timeout(interval) {
            Ok(Event::Line(l)) => match decoder.decode(&l) {
                Ok(mut m) => {
                    carry_forward(&mut m, mole.as_ref());
                    mole = Some(m);
                    last_line = Some(Instant::now());
                    lines += 1;
                    got_line = true;
                }
                Err(_) => decode_errors += 1,
            },
            Ok(Event::Stop) => break,
            Ok(_) => continue,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        // Drain queued lines so a paused consumer paints the newest state.
        while let Ok(Event::Line(l)) = rx.try_recv() {
            if let Ok(mut m) = decoder.decode(&l) {
                carry_forward(&mut m, mole.as_ref());
                mole = Some(m);
                last_line = Some(Instant::now());
                lines += 1;
                got_line = true;
            } else {
                decode_errors += 1;
            }
        }

        let tick_start = Instant::now();
        let sampled = last_sample.elapsed() >= interval / 2;
        if sampled {
            last_sample = Instant::now();
            let procs = sampler.sample();
            let weights = *lock(&shared.weights);
            let top = mole.as_ref().map(|m| m.top_processes.as_slice()).unwrap_or(&[]);
            apps_all = resolver.rollup(&procs, top, self_pid, weights);
        } else if !got_line {
            continue;
        }

        let mole_alive = sup.state() == "running" && last_line.map(|t| t.elapsed() < interval * 3).unwrap_or(false);
        let energy_mode = if !sampler.is_v6() {
            "impact_estimated"
        } else if sampler.energy_seen {
            "energy"
        } else {
            "impact"
        };

        // While the stream is off, stalled or absent, the live-able readings come
        // from Mach and are patched over the last Mole snapshot so the tiles never
        // go quietly stale; everything Mole alone can measure keeps its age.
        let mut system = SystemFallback::default();
        let mut view: Option<MoleSnapshot> = mole.clone();
        let mut approximate = false;
        if !mole_alive && sampled {
            let live = cpu_fb.live();
            system = SystemFallback {
                cpu_usage: live.per_core.as_deref().and_then(mean).map(round1),
                mem_used: live.memory.map(|m| m.0),
                mem_total: live.memory.map(|m| m.1),
            };
            let mut v = view.take().unwrap_or_default();
            if let Some(cores) = &live.per_core {
                v.cpu.usage = mean(cores).unwrap_or(0.0) as f64;
                v.cpu.per_core = cores.iter().map(|c| *c as f64).collect();
                v.cpu.per_core_estimated = false;
                if v.cpu.e_core_count == 0 && e_count > 0 && cores.len() > e_count as usize {
                    v.cpu.e_core_count = e_count;
                    v.cpu.p_core_count = cores.len() as i64 - e_count;
                }
            }
            if let Some((used, total)) = live.memory {
                v.memory.used = used;
                v.memory.total = total;
                v.memory.available = total.saturating_sub(used);
                v.memory.used_percent = if total > 0 { used as f64 / total as f64 * 100.0 } else { 0.0 };
            }
            if let Some((used, total)) = live.disk {
                if v.disks.is_empty() {
                    v.disks.push(crate::mole::Disk { mount: "/".into(), ..Default::default() });
                }
                if let Some(d) = v.disks.first_mut() {
                    d.used = used;
                    d.total = total;
                    d.used_percent = if total > 0 { used as f64 / total as f64 * 100.0 } else { 0.0 };
                }
            }
            let pen = score::penalties(&v);
            v.health_score = (100.0 - pen.total()).clamp(0.0, 100.0) as i64;
            approximate = true;
            view = Some(v);
        }
        // Mole's pressure string is empty when `memory_pressure` prints no level
        // word (macOS 26 does not); the kernel's own level fills the gap. It is
        // display-only: the score stays Mole's so the two never disagree.
        if let Some(v) = view.as_mut() {
            if v.memory.pressure.is_empty() {
                if let Some(level) = fallback::memory_pressure() {
                    v.memory.pressure = level.to_string();
                }
            }
        }
        let m_ref = view.as_ref();
        let mut verdict = score::verdict(m_ref, &apps_all);
        verdict.approximate = approximate || m_ref.is_none();
        let apps = trim_apps(&apps_all, energy_mode);
        let processes = trim_procs(&apps);
        let cores = cores(m_ref);

        let fresh = got_line || (approximate && sampled);
        let mole_f = |f: &dyn Fn(&MoleSnapshot) -> f32| if got_line { m_ref.map(f) } else { None };
        let top_rank = apps.first().map(|a| if energy_mode == "energy" { a.energy_w.unwrap_or(0.0) } else { a.impact });
        let [h_cpu, h_p, h_e, h_mem, h_swap, h_press, h_rx, h_tx, h_dr, h_dw, h_pw, h_top] = history.all_mut();
        push(h_cpu, if fresh { m_ref.map(|m| m.cpu.usage as f32) } else { None });
        push(h_p, if fresh { mean(&cores.p) } else { None });
        push(h_e, if fresh { mean(&cores.e) } else { None });
        push(h_mem, if fresh { m_ref.map(|m| m.memory.used_percent as f32) } else { None });
        push(h_swap, mole_f(&|m| m.memory.swap_used as f32 / 1_073_741_824.0));
        push(h_press, mole_f(&|m| match m.memory.pressure.as_str() { "warn" => 1.0, "critical" => 2.0, _ => 0.0 }));
        push(h_rx, mole_f(&|m| m.network.iter().map(|n| n.rx_rate_mbs as f32).sum()));
        push(h_tx, mole_f(&|m| m.network.iter().map(|n| n.tx_rate_mbs as f32).sum()));
        push(h_dr, mole_f(&|m| m.disk_io.read_rate as f32));
        push(h_dw, mole_f(&|m| m.disk_io.write_rate as f32));
        push(h_pw, mole_f(&|m| m.thermal.system_power as f32));
        push(h_top, if sampled { top_rank } else { None });

        let child_pid = sup.child_pid();
        let me = apps_all.iter().flat_map(|a| a.children.iter()).find(|p| p.pid == self_pid);
        let child = child_pid.and_then(|c| apps_all.iter().flat_map(|a| a.children.iter()).find(|p| p.pid == c));
        let add = |a: Option<f32>, b: Option<f32>| match (a, b) { (None, None) => None, _ => Some(a.unwrap_or(0.0) + b.unwrap_or(0.0)) };
        let addm = |a: Option<u64>, b: Option<u64>| match (a, b) { (None, None) => None, _ => Some(a.unwrap_or(0) + b.unwrap_or(0)) };
        let self_stats = SelfStats {
            pid: self_pid,
            cpu: me.and_then(|p| p.cpu).map(round2),
            memory: me.and_then(|p| p.memory),
            wakeups_per_s: me.and_then(|p| p.wakeups).map(round1),
            energy_w: me.and_then(|p| p.energy_w).map(round2),
            child_cpu: child.and_then(|p| p.cpu).map(round2),
            child_memory: child.and_then(|p| p.memory),
            tree_cpu: add(me.and_then(|p| p.cpu), child.and_then(|p| p.cpu)).map(round2),
            tree_memory: addm(me.and_then(|p| p.memory), child.and_then(|p| p.memory)),
            sample_ms: round2(sampler.last_pass_ms),
            tick_ms: 0.0,
            snapshot_bytes,
            pids_total: sampler.total,
            pids_readable: sampler.readable,
            avg_cpu_since_launch: {
                let wall = launched.elapsed().as_secs_f64().max(1.0);
                round2(((own_cpu_seconds() - cpu_at_launch) / wall * 100.0) as f32)
            },
            uptime_s: launched.elapsed().as_secs(),
        };

        let sup_state = sup.state();
        let mole_status = MoleStatus {
            state: if sup_state == "running" && !mole_alive && lines > 0 { "stalled" } else { sup_state },
            live: mole_alive,
            path: sup.mo_path(),
            version: lock(&shared.version).clone(),
            failures: sup.failures.load(Ordering::Relaxed),
            lines,
            decode_errors,
            bad_keys: decoder.bad_keys().to_vec(),
            last_line_age_ms: last_line.map(|t| t.elapsed().as_millis() as u64),
            interval_secs: interval.as_secs(),
            child_pid,
            stderr: sup.stderr_lines(),
        };

        seq += 1;
        let mut snap = Snapshot {
            seq,
            generated_at_ms: unix_ms(),
            mole: view,
            mole_status,
            verdict,
            energy_mode,
            apps,
            processes,
            history: history.clone(),
            cores,
            system,
            self_stats,
        };
        snap.self_stats.tick_ms = round2(tick_start.elapsed().as_secs_f32() * 1000.0);
        if let Ok(json) = serde_json::to_string(&snap) {
            snapshot_bytes = json.len();
            *lock(&shared.latest) = Some(json);
        }
    }
}
