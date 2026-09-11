//! System CPU and memory straight from Mach, used only while Mole is absent
//! so the Overview keeps working in the degraded state. Mole stays the source
//! of truth whenever it is running.

#![allow(deprecated)] // libc points at the mach2 crate for these; not on the dependency list
use libc::{c_int, c_void};
use std::mem::size_of;

pub struct CpuFallback {
    prev: Vec<[u32; 4]>,
}

impl Default for CpuFallback {
    fn default() -> Self {
        Self::new()
    }
}

impl CpuFallback {
    pub fn new() -> Self {
        Self { prev: Vec::new() }
    }

    /// Percent busy per core since the previous call; `None` until two samples exist.
    pub fn sample(&mut self) -> Option<Vec<f32>> {
        let mut count: libc::natural_t = 0;
        let mut info: libc::processor_info_array_t = std::ptr::null_mut();
        let mut info_count: libc::mach_msg_type_number_t = 0;
        // SAFETY: standard out-parameter call; the array is released below.
        let kr = unsafe {
            libc::host_processor_info(
                libc::mach_host_self(),
                libc::PROCESSOR_CPU_LOAD_INFO,
                &mut count,
                &mut info,
                &mut info_count,
            )
        };
        if kr != 0 || info.is_null() {
            return None;
        }
        let n = count as usize;
        let mut cur = Vec::with_capacity(n);
        for i in 0..n {
            let mut ticks = [0u32; 4];
            for (s, t) in ticks.iter_mut().enumerate() {
                // SAFETY: the kernel returned `count * CPU_STATE_MAX` integers.
                *t = unsafe { *info.add(i * libc::CPU_STATE_MAX as usize + s) } as u32;
            }
            cur.push(ticks);
        }
        // SAFETY: releasing the array the kernel handed us.
        unsafe {
            libc::vm_deallocate(
                libc::mach_task_self(),
                info as libc::vm_address_t,
                info_count as usize * size_of::<libc::integer_t>(),
            );
        }
        let out = if self.prev.len() == n {
            Some(
                cur.iter()
                    .zip(&self.prev)
                    .map(|(c, p)| {
                        let d = |i: usize| c[i].wrapping_sub(p[i]) as f32;
                        let busy = d(0) + d(1) + d(3);
                        let total = busy + d(2);
                        if total > 0.0 { busy / total * 100.0 } else { 0.0 }
                    })
                    .collect(),
            )
        } else {
            None
        };
        self.prev = cur;
        out
    }
}

/// Reads an integer sysctl of either width (the kernel reports 4 or 8 bytes).
fn sysctl_u64(name: &str) -> Option<u64> {
    let cname = std::ffi::CString::new(name).ok()?;
    let mut val: u64 = 0;
    let mut len = size_of::<u64>();
    // SAFETY: out-buffer and its length are passed together.
    let r = unsafe {
        libc::sysctlbyname(cname.as_ptr(), &mut val as *mut u64 as *mut c_void, &mut len, std::ptr::null_mut(), 0)
    };
    if r != 0 {
        return None;
    }
    Some(if len == 4 { val & 0xffff_ffff } else { val })
}

pub fn e_core_count() -> i64 {
    sysctl_u64("hw.perflevel1.logicalcpu").unwrap_or(0) as i64
}

/// (used, total) bytes; used counts active, wired and compressed pages, the
/// same definition Mole uses.
pub fn memory() -> Option<(u64, u64)> {
    let total = sysctl_u64("hw.memsize")?;
    // SAFETY: zeroed vm_statistics64 is a valid out-buffer.
    let mut vm: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
    let mut count = libc::HOST_VM_INFO64_COUNT;
    let kr = unsafe {
        libc::host_statistics64(
            libc::mach_host_self(),
            libc::HOST_VM_INFO64,
            &mut vm as *mut libc::vm_statistics64 as *mut c_int,
            &mut count,
        )
    };
    if kr != 0 {
        return None;
    }
    let page = sysctl_u64("hw.pagesize").unwrap_or(16384);
    let used = (vm.active_count as u64 + vm.wire_count as u64 + vm.compressor_page_count as u64) * page;
    Some((used, total))
}

/// (used, total) bytes of the boot volume from statfs. Mole corrects APFS
/// purgeable space on its full collect; this raw figure is the approximate one.
pub fn disk() -> Option<(u64, u64)> {
    let path = std::ffi::CString::new("/").ok()?;
    // SAFETY: zeroed statfs is a valid out-buffer.
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(path.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let bsize = st.f_bsize as u64;
    let total = st.f_blocks * bsize;
    let used = st.f_blocks.saturating_sub(st.f_bfree) * bsize;
    Some((used, total))
}

/// One tick of live system readings taken while the Mole stream is off.
#[derive(Debug, Clone, Default)]
pub struct Live {
    pub per_core: Option<Vec<f32>>,
    pub memory: Option<(u64, u64)>,
    pub disk: Option<(u64, u64)>,
}

impl CpuFallback {
    pub fn live(&mut self) -> Live {
        Live { per_core: self.sample(), memory: memory(), disk: disk() }
    }
}

/// The kernel's memory pressure level, the same source the `memory_pressure`
/// tool reads: 1 normal, 2 warn, 4 critical. Used when Mole's string is empty.
pub fn memory_pressure() -> Option<&'static str> {
    match sysctl_u64("kern.memorystatus_vm_pressure_level")? {
        1 => Some("normal"),
        2 => Some("warn"),
        4 => Some("critical"),
        _ => None,
    }
}
