Section 12 Q2: a full `proc_pid_rusage` pass over every PID costs about 1.4 ms on this M1, so the sampler reads all of them.

Measured with a C probe over 582 PIDs (344 readable, 237 EPERM): 2.2 ms cold, 1.35 to 1.5 ms steady. Adding
`proc_pidinfo(PROC_PIDTBSDINFO)` for every PID adds about 0.8 ms and `proc_pidpath` about 2 ms, and paths are
cached per (pid, start time), so a tick is well under the 15 ms ceiling that would have forced top-60 sampling.
