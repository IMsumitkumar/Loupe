Section 12 Q4: on this Mac the Energy column is the kernel's `ri_energy_nj`, so the 5.2 weights only govern the fallback impact score; against Apple's `top -o power` the leader matched in 17 of 27 quiet samples and the third place is a near-tie.

`cargo run --release --bin rank` runs the core beside `top -l 2 -o power` (its POWER column is Activity
Monitor's energy-impact figure) and reports, per sample, whether the top user-owned app and the top three
agree. Two-minute run on a quiet machine: same #1 in 17 of 27 samples, same top-3 set in 9, same order in 5;
in the steady stretch both tools put zsh (this Claude Code session) first and Google Chrome second, with
tmux, cmux and VS Code trading third place at 1.5 to 3 POWER units apart. A rerun during parallel compiles
dropped to 10 of 27 because compiler processes churn through both rankings. Two corrections came out of it:
energy is now kept to 0.1 mW instead of 10 mW so idle apps order instead of tying at zero, and root daemons
(proactived, cloudd) that `top` sees are invisible to the sampler by design. The 5.2 weights (1.0, 0.40,
0.05) are unchanged; they only matter on hardware without `ri_energy_nj`. The spec's week of comparison is
the user's to run with the same tool.
