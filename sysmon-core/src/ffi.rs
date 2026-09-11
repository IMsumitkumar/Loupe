//! The C ABI. Five functions, JSON strings both ways, and every call runs
//! under `catch_unwind` because a panic here would abort the host app.

use crate::engine::{Config, Engine};
use crate::panels;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, MutexGuard};

static ENGINE: Mutex<Option<Engine>> = Mutex::new(None);

fn engine() -> MutexGuard<'static, Option<Engine>> {
    ENGINE.lock().unwrap_or_else(|p| p.into_inner())
}

fn read_cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    // SAFETY: the caller passes a NUL-terminated string that outlives the call.
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(str::to_owned)
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// Starts the engine with a JSON config (`{"interval_secs":2,"mo_path":"/opt/homebrew/bin/mo",
/// "mo_version":"1.53.0","weights":{"cpu":1.0,"wakeups":0.4,"disk":0.05}}`; null means defaults).
/// Calling it again while running applies the new config in place.
/// Returns 0 started, 1 reconfigured, -1 bad config, -2 internal error.
#[no_mangle]
pub extern "C" fn sysmon_start(config_json: *const c_char) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let cfg = match read_cstr(config_json) {
            None => Config::default(),
            Some(text) => match serde_json::from_str::<Config>(&text) {
                Ok(c) => c,
                Err(_) => return -1,
            },
        };
        let mut g = engine();
        match g.as_ref() {
            Some(e) => {
                e.apply(cfg);
                1
            }
            None => {
                *g = Some(Engine::start(cfg));
                0
            }
        }
    }))
    .unwrap_or(-2)
}

/// Stops the engine and terminates the Mole child. Safe to call when stopped.
#[no_mangle]
pub extern "C" fn sysmon_stop() {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let taken = engine().take();
        if let Some(e) = taken {
            e.stop();
        }
    }));
}

/// Returns the latest snapshot as a JSON string, or null before the first
/// tick. Caller owns the string and must release it with `sysmon_free`.
#[no_mangle]
pub extern "C" fn sysmon_snapshot_json() -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        engine().as_ref().and_then(|e| e.latest_json()).map(to_c).unwrap_or(std::ptr::null_mut())
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Releases a string returned by this library.
#[no_mangle]
pub extern "C" fn sysmon_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: only pointers produced by `CString::into_raw` in this crate reach here.
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe { drop(CString::from_raw(ptr)) }));
    }
}

/// Parses `panels.toml` text (null means the built-in defaults) into
/// `{"panels":[...],"error":null,"line":null,"default_toml":"..."}`.
#[no_mangle]
pub extern "C" fn sysmon_panels_json(toml_text: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let text = read_cstr(toml_text).unwrap_or_else(|| panels::DEFAULT_TOML.to_string());
        to_c(panels::parse_json(&text))
    }))
    .unwrap_or(std::ptr::null_mut())
}
