//! Per-process CPU, energy, wakeups and disk bytes from `proc_pid_rusage`.
//!
//! Field layout verified against MacOSX26.5.sdk/usr/include/sys/resource.h
//! (`sizeof(struct rusage_info_v6) == 464`, asserted at compile time).
//! `ri_user_time` and `ri_system_time` are Mach time-base ticks, not
//! nanoseconds: on Apple Silicon the time base is 125/3, so every delta is
//! scaled through `mach_timebase_info` before it becomes a percentage.
//! `ri_energy_nj` is the kernel's own energy accounting in nanojoules and is
//! non-zero for every readable process on Apple Silicon; it is preferred over
//! the computed impact score whenever it moves.

#![allow(deprecated)] // libc points at the mach2 crate for these; not on the dependency list
use libc::{c_int, c_void, pid_t};
use std::collections::{HashMap, HashSet};
use std::mem::size_of;
use std::time::Instant;

const RUSAGE_INFO_V4: c_int = 4;
const RUSAGE_INFO_V6: c_int = 6;
const PROC_ALL_PIDS: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RusageInfoV6 {
    pub ri_uuid: [u8; 16],
    pub ri_user_time: u64,
    pub ri_system_time: u64,
    pub ri_pkg_idle_wkups: u64,
    pub ri_interrupt_wkups: u64,
    pub ri_pageins: u64,
    pub ri_wired_size: u64,
    pub ri_resident_size: u64,
    pub ri_phys_footprint: u64,
    pub ri_proc_start_abstime: u64,
    pub ri_proc_exit_abstime: u64,
    pub ri_child_user_time: u64,
    pub ri_child_system_time: u64,
    pub ri_child_pkg_idle_wkups: u64,
    pub ri_child_interrupt_wkups: u64,
    pub ri_child_pageins: u64,
    pub ri_child_elapsed_abstime: u64,
    pub ri_diskio_bytesread: u64,
    pub ri_diskio_byteswritten: u64,
    pub ri_cpu_time_qos_default: u64,
    pub ri_cpu_time_qos_maintenance: u64,
    pub ri_cpu_time_qos_background: u64,
    pub ri_cpu_time_qos_utility: u64,
    pub ri_cpu_time_qos_legacy: u64,
    pub ri_cpu_time_qos_user_initiated: u64,
    pub ri_cpu_time_qos_user_interactive: u64,
    pub ri_billed_system_time: u64,
    pub ri_serviced_system_time: u64,
    pub ri_logical_writes: u64,
    pub ri_lifetime_max_phys_footprint: u64,
    pub ri_instructions: u64,
    pub ri_cycles: u64,
    pub ri_billed_energy: u64,
    pub ri_serviced_energy: u64,
    pub ri_interval_max_phys_footprint: u64,
    pub ri_runnable_time: u64,
    pub ri_flags: u64,
    pub ri_user_ptime: u64,
    pub ri_system_ptime: u64,
    pub ri_pinstructions: u64,
    pub ri_pcycles: u64,
    pub ri_energy_nj: u64,
    pub ri_penergy_nj: u64,
    pub ri_secure_time_in_system: u64,
    pub ri_secure_ptime_in_system: u64,
    pub ri_neural_footprint: u64,
    pub ri_lifetime_max_neural_footprint: u64,
    pub ri_interval_max_neural_footprint: u64,
    pub ri_reserved: [u64; 9],
}

const _: () = assert!(size_of::<RusageInfoV6>() == 464);

impl RusageInfoV6 {
    fn zeroed() -> Self {
        // SAFETY: all-zero bytes are a valid value for a struct of plain integers.
        unsafe { std::mem::zeroed() }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ProcInfo {
    pub pid: i32,
    pub ppid: i32,
    pub uid: u32,
    pub comm: String,
    pub start_sec: u64,
    /// Executable path when already known (tests inject it); the resolver
    /// looks it up otherwise.
    pub path: Option<String>,
    /// `proc_pid_rusage` succeeded. False for root and other users' processes.
    pub readable: bool,
    pub cpu_pct: Option<f32>,
    pub energy_w: Option<f32>,
    pub wakeups_per_s: Option<f32>,
    pub disk_bps: Option<f32>,
    pub memory: Option<u64>,
}

struct Prev {
    start_sec: u64,
    t: Instant,
    cpu: u64,
    energy: u64,
    wakeups: u64,
    disk: u64,
}

pub struct Sampler {
    flavor: c_int,
    numer: u64,
    denom: u64,
    prev: HashMap<i32, Prev>,
    pidbuf: Vec<pid_t>,
    pub energy_seen: bool,
    pub last_pass_ms: f32,
    pub readable: usize,
    pub total: usize,
}

fn cstr(bytes: &[libc::c_char]) -> String {
    let end = bytes.iter().position(|&c| c == 0).unwrap_or(bytes.len());
    let raw: Vec<u8> = bytes[..end].iter().map(|&c| c as u8).collect();
    String::from_utf8_lossy(&raw).into_owned()
}

fn rusage(pid: i32, flavor: c_int, out: &mut RusageInfoV6) -> bool {
    // SAFETY: `out` is a 464-byte buffer, larger than any flavor's struct.
    unsafe { libc::proc_pid_rusage(pid, flavor, out as *mut RusageInfoV6 as *mut libc::rusage_info_t) == 0 }
}

impl Default for Sampler {
    fn default() -> Self {
        Self::new()
    }
}

impl Sampler {
    pub fn new() -> Self {
        let mut tb = libc::mach_timebase_info { numer: 0, denom: 0 };
        // SAFETY: plain out-parameter call.
        unsafe { libc::mach_timebase_info(&mut tb) };
        let (numer, denom) = if tb.denom == 0 { (1, 1) } else { (tb.numer as u64, tb.denom as u64) };
        // SAFETY: getpid has no preconditions.
        let me = unsafe { libc::getpid() };
        let mut ri = RusageInfoV6::zeroed();
        let flavor = if rusage(me, RUSAGE_INFO_V6, &mut ri) { RUSAGE_INFO_V6 } else { RUSAGE_INFO_V4 };
        Self {
            flavor,
            numer,
            denom,
            prev: HashMap::new(),
            pidbuf: Vec::with_capacity(1024),
            energy_seen: false,
            last_pass_ms: 0.0,
            readable: 0,
            total: 0,
        }
    }

    pub fn is_v6(&self) -> bool {
        self.flavor == RUSAGE_INFO_V6
    }

    pub fn ticks_to_ns(&self, ticks: u64) -> f64 {
        ticks as f64 * self.numer as f64 / self.denom as f64
    }

    fn list_pids(&mut self) -> usize {
        // SAFETY: a null buffer asks for the byte count needed.
        let needed = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
        if needed <= 0 {
            return 0;
        }
        let cap = needed as usize / size_of::<pid_t>() + 64;
        self.pidbuf.clear();
        self.pidbuf.resize(cap, 0);
        let bytes = (cap * size_of::<pid_t>()) as c_int;
        // SAFETY: buffer holds `cap` pids and we pass its byte length.
        let got = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, self.pidbuf.as_mut_ptr() as *mut c_void, bytes) };
        if got <= 0 {
            return 0;
        }
        (got as usize / size_of::<pid_t>()).min(cap)
    }

    pub fn sample(&mut self) -> Vec<ProcInfo> {
        let t0 = Instant::now();
        let n = self.list_pids();
        let mut out = Vec::with_capacity(n);
        let mut alive = HashSet::with_capacity(n);
        let mut readable = 0usize;
        for i in 0..n {
            let pid = self.pidbuf[i];
            // SAFETY: zeroed proc_bsdinfo is a valid out-buffer of the size we pass.
            let mut bi: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
            let r = unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDTBSDINFO,
                    0,
                    &mut bi as *mut libc::proc_bsdinfo as *mut c_void,
                    size_of::<libc::proc_bsdinfo>() as c_int,
                )
            };
            if r <= 0 {
                continue;
            }
            let name = cstr(&bi.pbi_name);
            let comm = if name.is_empty() { cstr(&bi.pbi_comm) } else { name };
            let mut info = ProcInfo {
                pid,
                ppid: bi.pbi_ppid as i32,
                uid: bi.pbi_uid,
                comm,
                start_sec: bi.pbi_start_tvsec,
                ..Default::default()
            };
            let now = Instant::now();
            let mut ri = RusageInfoV6::zeroed();
            if rusage(pid, self.flavor, &mut ri) {
                readable += 1;
                info.readable = true;
                info.memory = Some(ri.ri_phys_footprint);
                let cpu = ri.ri_user_time.saturating_add(ri.ri_system_time);
                let energy = ri.ri_energy_nj;
                let wakeups = ri.ri_pkg_idle_wkups;
                let disk = ri.ri_diskio_bytesread.saturating_add(ri.ri_diskio_byteswritten);
                if let Some(p) = self.prev.get(&pid) {
                    let elapsed = now.duration_since(p.t).as_secs_f64();
                    if p.start_sec == info.start_sec && elapsed > 0.05 && cpu >= p.cpu {
                        let cpu_ns = self.ticks_to_ns(cpu - p.cpu);
                        info.cpu_pct = Some((cpu_ns / (elapsed * 1e9) * 100.0) as f32);
                        if energy >= p.energy {
                            let joules = (energy - p.energy) as f64 / 1e9;
                            info.energy_w = Some((joules / elapsed) as f32);
                            if energy > p.energy {
                                self.energy_seen = true;
                            }
                        }
                        if wakeups >= p.wakeups {
                            info.wakeups_per_s = Some(((wakeups - p.wakeups) as f64 / elapsed) as f32);
                        }
                        if disk >= p.disk {
                            info.disk_bps = Some(((disk - p.disk) as f64 / elapsed) as f32);
                        }
                    }
                }
                self.prev.insert(pid, Prev { start_sec: info.start_sec, t: now, cpu, energy, wakeups, disk });
            }
            alive.insert(pid);
            out.push(info);
        }
        self.prev.retain(|pid, _| alive.contains(pid));
        self.readable = readable;
        self.total = out.len();
        self.last_pass_ms = t0.elapsed().as_secs_f32() * 1000.0;
        out
    }
}

/// Executable path for a live pid, or an empty string when the kernel refuses.
pub fn pidpath(pid: i32) -> String {
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: buffer length is passed alongside the pointer.
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr() as *mut c_void, buf.len() as u32) };
    if n <= 0 {
        return String::new();
    }
    buf.truncate(n as usize);
    String::from_utf8_lossy(&buf).into_owned()
}
