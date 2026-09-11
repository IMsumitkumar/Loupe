No unprivileged path gives CPU or memory for root or other users' processes; those rows carry Mole's ps figure marked as an average.

`proc_pid_rusage` and `proc_pidinfo(PROC_PIDTASKINFO)` both fail for every process owned by another uid
(237 of 582 here, including WindowServer, mds, launchd and kernel_task pid 0). `sysctl kern.proc` returns
zeroed `p_pctcpu`. `/bin/ps` gets them through the private entitlement `com.apple.system-task-ports.read`.
`PROC_PIDTBSDINFO` and `proc_pidpath` do work for all pids, so the rows exist with name, path and parent.
For CPU and memory the rollup falls back to Mole's `top_processes` (ps, top 5 by CPU) and marks
`cpu_source = "mole"`, which the UI shows with an approximate sign and a tooltip. A root process that is not in
Mole's top 5 shows no CPU at all. Activity Monitor's completeness comes from the privileged sysmond daemon.
