Mole bug (not patched): on macOS 26.5 `memory_pressure` prints no "normal/warn/critical" word, so Mole's `getMemoryPressure` returns "" and the pressure penalty never applies.

`memory_pressure` here ends with "System-wide memory free percentage: 49%" and nothing else; Mole's parser in
`cmd/status/metrics_memory.go` looks for the level words and falls through to "". Every stream line therefore
carries `memory.pressure: ""`, Mole's health score never subtracts the 5 or 15 point pressure penalty, and its
TUI shows no pressure state. The kernel exposes the same level as `sysctl kern.memorystatus_vm_pressure_level`
(1 normal, 2 warn, 4 critical); Loupe reads that only to fill the display field when Mole's is empty, and keeps
the score as Mole computed it so the bands never disagree. Reported to the user; Mole was not modified.
