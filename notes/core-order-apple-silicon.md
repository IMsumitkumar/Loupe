`per_core[]` lists efficiency cores first on Apple Silicon: indices 0..e_core_count are E-cores, the rest are P-cores.

Verified by running two QOS_CLASS_BACKGROUND busy loops and reading `host_processor_info`: cpu0 to cpu3 went to
95% while cpu4 to cpu7 stayed idle on this M1 (4P+4E). Mole's `per_core` comes from the same Mach call in the
same order. `engine.rs` splits `all[..e]` as the efficient cluster and `all[e..]` as the fast cluster.
