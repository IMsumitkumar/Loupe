//! Processes rolled up into apps.
//!
//! Identity is the outermost `.app` bundle on the process's own path or any
//! ancestor's path (depth 8), which folds Chrome helpers, nested helper apps
//! and XPC services into their owner without reading Info.plist. Processes
//! outside any bundle group under the executable of their top-level ancestor.
//! Known heuristic: WebKit XPC processes are children of launchd, so they are
//! attributed to Safari whenever Safari is running, which over-attributes when
//! Mail or another WebKit host is also open.

use crate::energy::{pidpath, ProcInfo};
use crate::mole;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const WEBKIT_PREFIX: &str = "/System/Library/Frameworks/WebKit.framework/";
const MAX_DEPTH: usize = 8;
pub const MAX_CHILDREN: usize = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    App,
    System,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Weights {
    pub cpu: f32,
    pub wakeups: f32,
    pub disk: f32,
}

impl Default for Weights {
    fn default() -> Self {
        Self { cpu: 1.0, wakeups: 0.40, disk: 0.05 }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Proc {
    pub pid: i32,
    pub ppid: i32,
    pub name: String,
    pub path: String,
    pub cpu: Option<f32>,
    pub memory: Option<u64>,
    pub energy_w: Option<f32>,
    pub wakeups: Option<f32>,
    pub disk_bps: Option<f32>,
    pub impact: f32,
    pub cpu_source: &'static str,
    pub force_quit_ok: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct App {
    pub key: String,
    pub name: String,
    pub kind: Kind,
    pub path: String,
    pub root_pid: i32,
    pub procs: u32,
    pub cpu: Option<f32>,
    pub memory: u64,
    pub energy_w: Option<f32>,
    pub impact: f32,
    pub wakeups: f32,
    pub disk_bps: f32,
    pub cpu_source: &'static str,
    pub quit_ok: bool,
    pub force_quit_ok: bool,
    pub is_self: bool,
    pub children: Vec<Proc>,
    #[serde(skip)]
    root_start: u64,
}

#[derive(Debug, Clone)]
struct Identity {
    key: String,
    name: String,
    kind: Kind,
    path: String,
}

#[derive(Default)]
pub struct Resolver {
    paths: HashMap<i32, (u64, String)>,
    ids: HashMap<i32, (u64, Identity)>,
}

pub fn bundle_root(path: &str) -> Option<&str> {
    path.find(".app/Contents/").map(|i| &path[..i + 4])
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

pub fn is_system_path(path: &str) -> bool {
    path.starts_with("/System/")
        || path.starts_with("/usr/libexec/")
        || path.starts_with("/usr/sbin/")
        || path.starts_with("/sbin/")
        || path.starts_with("/usr/bin/")
        || path.starts_with("/bin/")
        || path.starts_with("/Library/Apple/")
}

pub fn force_quit_ok(path: &str) -> bool {
    !(path.starts_with("/System/") || path.starts_with("/usr/libexec/"))
}

impl Resolver {
    fn path(&mut self, p: &ProcInfo) -> String {
        if let Some(path) = &p.path {
            return path.clone();
        }
        if let Some((start, path)) = self.paths.get(&p.pid) {
            if *start == p.start_sec {
                return path.clone();
            }
        }
        let path = pidpath(p.pid);
        self.paths.insert(p.pid, (p.start_sec, path.clone()));
        path
    }

    fn identify(&mut self, p: &ProcInfo, by_pid: &HashMap<i32, &ProcInfo>) -> Identity {
        if p.pid == 0 {
            return Identity {
                key: "kernel_task".into(),
                name: "kernel_task".into(),
                kind: Kind::System,
                path: String::new(),
            };
        }
        if let Some((start, id)) = self.ids.get(&p.pid) {
            if *start == p.start_sec {
                return id.clone();
            }
        }
        let mut cur = p;
        let mut top_path = String::new();
        let mut top_comm = p.comm.clone();
        for _ in 0..MAX_DEPTH {
            let path = self.path(cur);
            if let Some(root) = bundle_root(&path) {
                let id = Identity {
                    key: root.to_string(),
                    name: basename(root).trim_end_matches(".app").to_string(),
                    kind: Kind::App,
                    path: root.to_string(),
                };
                self.ids.insert(p.pid, (p.start_sec, id.clone()));
                return id;
            }
            if !path.is_empty() {
                top_path = path;
            }
            top_comm = cur.comm.clone();
            if cur.ppid <= 1 {
                break;
            }
            match by_pid.get(&cur.ppid) {
                Some(parent) => cur = parent,
                None => break,
            }
        }
        let name = if top_path.is_empty() { top_comm } else { basename(&top_path).to_string() };
        let kind = if is_system_path(&top_path) { Kind::System } else { Kind::Other };
        let id = Identity {
            key: format!("exe:{}", if top_path.is_empty() { name.clone() } else { top_path.clone() }),
            name,
            kind,
            path: top_path,
        };
        self.ids.insert(p.pid, (p.start_sec, id.clone()));
        id
    }

    pub fn rollup(
        &mut self,
        procs: &[ProcInfo],
        mole_top: &[mole::Process],
        self_pid: i32,
        w: Weights,
    ) -> Vec<App> {
        let by_pid: HashMap<i32, &ProcInfo> = procs.iter().map(|p| (p.pid, p)).collect();
        let mole_by_pid: HashMap<i32, &mole::Process> = mole_top.iter().map(|m| (m.pid, m)).collect();

        let mut idents: Vec<(Identity, String)> = Vec::with_capacity(procs.len());
        let mut webkit = Vec::new();
        let mut safari: Option<Identity> = None;
        for (i, p) in procs.iter().enumerate() {
            let id = self.identify(p, &by_pid);
            let path = if p.pid == 0 { String::new() } else { self.path(p) };
            if p.ppid <= 1 && path.starts_with(WEBKIT_PREFIX) {
                webkit.push(i);
            }
            if id.path.ends_with("/Safari.app") && safari.is_none() {
                safari = Some(id.clone());
            }
            idents.push((id, path));
        }
        for i in webkit {
            idents[i].0 = match &safari {
                Some(s) => s.clone(),
                None => Identity {
                    key: "webkit".into(),
                    name: "WebKit".into(),
                    kind: Kind::System,
                    path: WEBKIT_PREFIX.trim_end_matches('/').to_string(),
                },
            };
        }

        let mut order: Vec<String> = Vec::new();
        let mut apps: HashMap<String, App> = HashMap::new();
        for (p, (id, path)) in procs.iter().zip(idents) {
            let (cpu, memory, energy, source) = if p.readable {
                (p.cpu_pct, p.memory, p.energy_w, "sampled")
            } else if let Some(m) = mole_by_pid.get(&p.pid) {
                let mem = if m.memory_bytes > 0 { Some(m.memory_bytes) } else { None };
                (Some(m.cpu as f32), mem, None, "mole")
            } else {
                (None, None, None, "none")
            };
            let impact = w.cpu * cpu.unwrap_or(0.0)
                + w.wakeups * p.wakeups_per_s.unwrap_or(0.0)
                + w.disk * p.disk_bps.unwrap_or(0.0) / 1_048_576.0;
            let child = Proc {
                pid: p.pid,
                ppid: p.ppid,
                name: if path.is_empty() { p.comm.clone() } else { basename(&path).to_string() },
                path: path.clone(),
                cpu,
                memory,
                energy_w: energy,
                wakeups: p.wakeups_per_s,
                disk_bps: p.disk_bps,
                impact,
                cpu_source: source,
                force_quit_ok: !path.is_empty() && force_quit_ok(&path),
            };
            let app = apps.entry(id.key.clone()).or_insert_with(|| {
                order.push(id.key.clone());
                App {
                    key: id.key.clone(),
                    name: id.name.clone(),
                    kind: id.kind,
                    path: id.path.clone(),
                    root_pid: p.pid,
                    procs: 0,
                    cpu: None,
                    memory: 0,
                    energy_w: None,
                    impact: 0.0,
                    wakeups: 0.0,
                    disk_bps: 0.0,
                    cpu_source: "none",
                    quit_ok: id.kind == Kind::App,
                    force_quit_ok: id.kind == Kind::App && force_quit_ok(&id.path),
                    is_self: false,
                    children: Vec::new(),
                    root_start: p.start_sec,
                }
            });
            if p.start_sec < app.root_start || (p.start_sec == app.root_start && p.pid < app.root_pid) {
                app.root_start = p.start_sec;
                app.root_pid = p.pid;
            }
            app.procs += 1;
            if let Some(c) = cpu {
                app.cpu = Some(app.cpu.unwrap_or(0.0) + c);
            }
            app.memory += memory.unwrap_or(0);
            if let Some(e) = energy {
                app.energy_w = Some(app.energy_w.unwrap_or(0.0) + e);
            }
            app.impact += impact;
            app.wakeups += p.wakeups_per_s.unwrap_or(0.0);
            app.disk_bps += p.disk_bps.unwrap_or(0.0);
            app.cpu_source = match (app.cpu_source, source) {
                ("mole", _) | (_, "mole") => "mole",
                ("sampled", _) | (_, "sampled") => "sampled",
                _ => "none",
            };
            if p.pid == self_pid {
                app.is_self = true;
            }
            app.children.push(child);
        }

        let mut out: Vec<App> = order.into_iter().filter_map(|k| apps.remove(&k)).collect();
        for app in &mut out {
            app.children.sort_by(|a, b| b.cpu.unwrap_or(0.0).total_cmp(&a.cpu.unwrap_or(0.0)));
            app.children.truncate(MAX_CHILDREN);
        }
        out
    }
}
