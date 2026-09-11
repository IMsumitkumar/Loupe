Section 12 Q5: neither restarting Mole per state nor a fixed 2 s stream meets the closed budget, so Mole streams only while the panel is open and the core ticks alone on Mach readings while it is closed.

Measured on this M1 (Mole 1.53.0), whole `mo status --watch` process tree via `/usr/bin/time -l`, 60 to 120 s runs:

| interval | CPU seconds / wall | steady state |
|---|---|---|
| 1 s  | 6.9 / 66  | ~9%   |
| 2 s  | 4.6 / 63  | ~5.5% |
| 5 s  | 2.6 / 58  | ~3.4% |
| 10 s | 4.5 / 125 | ~2.6% |
| 60 s | 2.7 / 123 | ~1.1% (one full refresh in window) |

Startup (bash router + first fast collect + immediate full collect) costs 1.3 s of CPU; a one-shot `mo status --json`
costs 1.1 s. The floor is the full refresh every 30 s (bluetooth `system_profiler`, `diskutil`, Trash scan,
`ioreg`, `pmset`, `scutil`), about 0.6 s of CPU each, which `--interval` does not change; `ps -Aceo` runs on every
tick because Mole's process refresh interval is fixed at 1 s. So the closed-panel budget of 0.3% for the whole
tree (spec 8.1) cannot be met with any streaming cadence, and restarting the child on each panel toggle would add
1.3 s per transition on top. The state machine collapses to one bit: `stream = panelOpen`. Closed, the Rust core
ticks every 2 s with rusage + Mach CPU/memory/statfs and computes an approximate pressure band for the glyph;
open, the stream runs at the open interval and the exact Mole score takes over within about 4 s. Open-state cost
is about 5.5% for Mole plus Loupe's own share and is transient by design.
