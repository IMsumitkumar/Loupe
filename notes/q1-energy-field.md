Section 12 Q1: V6 is available and `ri_energy_nj` (not `ri_billed_energy`) is the per-process energy field; the column says "Energy".

`RUSAGE_INFO_V6` exists in MacOSX26.5.sdk (`sizeof == 464`, asserted at compile time in `energy.rs`) and works on
this M1. Of 344 readable processes, `ri_energy_nj` was non-zero for all 344 and `ri_billed_energy` for 335.
`ri_billed_energy` is energy billed to a task by other tasks doing work on its behalf (voucher accounting), which
is why it reads ~16 000 for a process whose `ri_energy_nj` reads 3 000 000. `ri_energy_nj` is the task's own
accounting in nanojoules: a 720 ms one-core burn cost 866 mJ, about 1.2 W, which is a plausible M1 P-core figure.
The sampler divides the delta by elapsed seconds and reports watts. `ri_penergy_nj` is the P-cluster share.
V4 also carries `ri_billed_energy`/`ri_instructions`/`ri_cycles` (296 bytes); only the `_nj` fields are V6-only,
so the V4 fallback loses energy and uses the computed impact score, labelled "Impact (estimated)".
