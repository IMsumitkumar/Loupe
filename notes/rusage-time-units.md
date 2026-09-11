`ri_user_time`/`ri_system_time` are Mach time-base ticks, not nanoseconds; scale by `mach_timebase_info` (125/3 on Apple Silicon).

Spec 5.2 calls them "nanoseconds of CPU". A probe burning one core for 720 ms of wall time showed a delta of
17.2 million units; treated as ns that is 17 ms, scaled by 125/3 it is 716 ms. On Intel the timebase is 1/1 so
the bug would be invisible there and every CPU percentage on Apple Silicon would read 42x too low.
`energy.rs` scales every delta through the timebase before dividing by elapsed time.
