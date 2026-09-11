Loupe's closed-state CPU is ~0% on a quiet machine but rises to 1-3% while the machine spawns hundreds of short-lived processes or swaps hard; the cost is in the per-pid sampling, not in a timer.

Three independent readings on the release build with the panel closed: a 10 s `sample` profile, a 45 s
`sample` profile and a 70 s per-thread `ps -M` diff all showed every Loupe thread parked in a wait primitive
with only a few dozen `__proc_info` samples. Two `ps cputime` runs taken right after parallel `swift build`
and `cargo build` jobs, on an 8 GB machine with 4 GB of swap in use, showed 1.3% and 3%. Every new pid costs
a `proc_pidinfo`, a `proc_pid_rusage` and a `proc_pidpath`, and memory pressure adds decompression time to
every poll that touches Loupe's pages. The Diagnostics pane shows "CPU average since launch" from
`getrusage` so the number can be read on the user's own machine instead of trusted from here.
