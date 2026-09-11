//! sysmon-core: the pipeline behind Loupe.
//!
//! Spawns `mo status --watch`, samples per-process energy with
//! `proc_pid_rusage`, rolls processes up to apps, keeps ring-buffer history,
//! computes the pressure verdict, and exposes one JSON snapshot over a C ABI.
//! Nothing here may panic across the FFI boundary: no `unwrap`, no `expect`,
//! and every extern function runs under `catch_unwind`.

pub mod energy;
pub mod engine;
pub mod fallback;
pub mod ffi;
pub mod history;
pub mod mole;
pub mod panels;
pub mod rollup;
pub mod score;
pub mod supervisor;
