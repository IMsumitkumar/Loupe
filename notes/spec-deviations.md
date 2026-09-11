Where the build departs from SPEC.md, why, and what the spec got wrong on this hardware.

- **5.2 time units.** `ri_user_time`/`ri_system_time` are Mach ticks, not nanoseconds (notes/rusage-time-units.md).
- **5.2 energy field.** `ri_energy_nj` is used, not `ri_billed_energy`; the column reads "Energy" in watts (notes/q1-energy-field.md).
- **5.2 EPERM.** Root and other users' processes cannot be sampled at all; their CPU comes from Mole's top-5 marked "≈" (notes/eperm-root-processes.md).
- **5.3 identity.** Grouping key is the outermost `.app` bundle path, not `CFBundleIdentifier`; Info.plist is never read. Same outcome, no plist parser.
- **3.3 FFI.** Five functions, not four: `sysmon_panels_json` parses `panels.toml` because Swift has no TOML parser and `toml` was on the Rust dependency list.
- **6.6 defaults.** Four `system` panels (cpu, memory, disk, network) instead of three, because UI.md's Overview is a 2×2 grid; app panels are energy, memory, cpu.
- **6.3 charts.** Path-based SwiftUI views instead of Swift Charts: smaller, deterministic sizing, and they render offscreen for snapshot tests.
- **8.2 cadence.** Mole streams only while the panel is open; the closed state runs no Mole at all and the verdict is marked approximate (notes/q5-cadence.md). Open interval is 2 s on AC and battery; the closed poll doubles on battery.
- **8.1 budget.** Closed holds. Open cannot: Mole's own tree costs ~5.5% at 2 s. Numbers in the final report.
- **7.3 terminal.** A `.command` file opened with `MO_LAUNCHER_APP` or Terminal instead of AppleScript, because Apple Events need an entitlement the hardened runtime denies by default.
- **9.1/9.2 build.** SwiftPM plus a Makefile-assembled bundle instead of an `.xcodeproj` and bridging header; `xcodebuild` is not used (notes/build-toolchain.md).
- **4.4 pressure.** Mole returns "" on macOS 26 (notes/mole-bug-memory-pressure.md); the kernel level fills the display field only.
- **5.6 version floor.** 1.53.0, the version verified; the Mole checkout is a single squashed commit so the true first `--watch` release is unknown.
- **10.3 snapshot tests.** Tiles and charts per state, scheme and Dynamic Type size via `ImageRenderer`, stored PNGs, first run records. Whole-tab renders come from `LOUPE_RENDER` on live data.
- **6.1 colour (user request, 2026-09-12).** Charts and bars use a five-hue categorical palette (blue, aqua, violet, magenta, green) validated for colour-vision separation on both panel surfaces; state dots, text and the menu bar stay greyscale, and amber/red stay reserved for alarms.
- **6.3 material (user request, 2026-09-12).** `.popover` material with an 82% window-background layer instead of `.hudWindow`; the HUD material was too transparent to read on a busy wallpaper. The panel can be dragged; a resize keeps the dragged position, reopening from the icon re-anchors it.
- **6.5 Settings.** A plain AppKit window hosting the SwiftUI settings view, because the SwiftUI `Settings` scene did not open from an accessory app's footer button.
