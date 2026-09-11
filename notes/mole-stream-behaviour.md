The first `--watch` line is a fast collect with null arrays and no static fields; the full collect follows about 2.7 s later and repeats every 30 s.

From the captured fixture (`sysmon-core/fixtures/stream.ndjson`): line 0 arrives ~1.6 s after spawn with
`hardware` empty, `p_core_count`/`e_core_count` 0, `memory.pressure` "", and `gpu`, `batteries`,
`top_processes` as JSON `null` (Go nil slices). Line 1 is the immediate full collect; line 2 lands 2.7 s later
because the full collect blocks the loop. After that ticks are interval + ~70 ms. The same shape recurs after
every child restart, so `engine.rs` carries hardware, core counts and pressure forward across lines and the
decoder maps `null` arrays to empty. `gpu` on this M1 is one entry with `usage: -1` and a note, not an empty
array, so "GPU unavailable" must also trigger on a negative usage. Thermal is all zero on this machine.
