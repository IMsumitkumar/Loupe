# Loupe — Product and Engineering Specification

A native macOS status monitor. Swift shell, Rust core, Mole as the data and action backend.

Version 1.0 of this document. Written 11 September 2026.

> **Name.** "Loupe" is a placeholder. Mole is GPL-3.0 and its author asks forks to use a different name. Pick a final name before release. Do not use "Mole", "mo", or a near variant.

---

## 1. Intent

### 1.1 The problem

You open a system monitor for one reason. The Mac feels slow and you want to know why.

Activity Monitor answers that badly. It shows forty numbers with equal weight. It splits Chrome into forty rows. Its CPU column mixes P-core and E-core work into one meaningless percentage. It makes you do the analysis.

Mole answers it well in the terminal. But it lives in the terminal. You cannot glance at it.

### 1.2 What Loupe is

A menu bar glyph that tells you when something is wrong, and a panel that tells you what.

Three claims define the product:

1. **It answers, it does not report.** One pressure score on top. The three metrics that drove it below. Not a metric dump.
2. **It groups by app, not by process.** Chrome is one row, not forty.
3. **It costs nothing to run.** Under 0.5% CPU and under 60 MB RSS for the whole app tree, measured by itself.

### 1.3 What Loupe is not

- Not a cleaner. Cleaning is Mole's job. Loupe launches Mole for it.
- Not a process killer beyond a plain Quit and Force Quit.
- Not cross-platform. macOS 14 and later, Apple Silicon first.
- Not a Mac App Store app. The sandbox blocks the syscalls this needs.

---

## 2. Findings from the Mole source

I read `Mole-main` before writing this. Five findings shape the architecture. Trust these over any assumption.

### 2.1 `mo status --watch` exists and solves the cost problem

`cmd/status/watch.go` implements a streaming mode:

```
mo status --watch --interval 2s
```

It emits one complete `MetricsSnapshot` as JSON per line, newline delimited, on stdout. It runs forever from a single process.

The implementation comment states the design intent directly: it uses a single warm `Collector` so that rate metrics such as network and disk I/O stay accurate across ticks. It emits the first snapshot immediately so the consumer can paint without waiting an interval. It exits cleanly when stdout closes, which means the child dies when the parent dies.

This is exactly the contract a GUI needs. One long-lived child process. No fork per tick. Correct rate maths. Automatic cleanup.

**Consequence:** Loupe spawns `mo status --watch` once and reads its stdout. Loupe does not call `mo status --json` on a timer.

### 2.2 Mole has no per-process energy metric

I grepped the whole `cmd/status` tree. There is no `proc_pid_rusage` call and no per-process energy field. `ProcessInfo` carries `pid`, `ppid`, `name`, `command`, `cpu`, `memory`, `memory_bytes`. Nothing else.

`ThermalStatus.system_power` gives whole-machine Watts, which is useful but is not per-app.

**Consequence:** your top request, "top 5 apps consuming more energy", cannot come from Mole. The Rust core must produce it. Section 5.2 specifies how.

### 2.3 Mole's process CPU comes from `ps`, and `ps` lies

`cmd/status/metrics_process.go` runs `ps -Aceo pid=,ppid=,state=,pcpu=,pmem=,rss= ,comm= -r` and parses the text. On macOS, BSD `ps` reports `%CPU` as a decaying average over roughly the last minute of real time, not an instantaneous sample.

This is why a process that just finished a heavy burst still shows high CPU in `mo status`, and why a process that just started a burst shows low.

**Consequence:** Loupe must not present Mole's `cpu` field as live CPU. The Rust core computes instantaneous CPU from its own two-sample delta. Mole's value is used only as a cross-check during development.

### 2.4 GPU needs root and will usually be absent

`cmd/status/metrics_gpu.go` shells to `powermetrics --samplers gpu_power`. The file carries its own comment noting that powermetrics may require root.

**Consequence:** treat `gpu` as an optional array that is normally empty. Never build a panel that breaks when it is missing. Show "GPU unavailable, needs elevated access" and move on.

### 2.5 Only two commands have a JSON contract

`mo status --json`, `mo status --watch`, and `mo analyze --json` produce structured output. Everything else in `bin/` is an interactive TUI written in shell. `mo clean --dry-run` prints human text for humans.

**Consequence:** wrap `status` and `analyze`. Never parse the output of `clean`, `uninstall`, `purge`, `installer`, or `optimize`. Launch those in a terminal instead, as specified in section 7.3.

---

## 3. Architecture

```
Loupe.app
├── Loupe (Swift, AppKit + SwiftUI)     the shell: menu bar, panel, settings
│   └── links libsysmon_core.a
│
└── sysmon-core (Rust, staticlib)       the pipeline
     ├── spawns and reads ──────────────► mo status --watch --interval Ns
     ├── samples energy directly ───────► proc_pid_rusage / libproc
     ├── rolls processes up to apps
     ├── keeps history ring buffers
     └── computes derived scores
```

### 3.1 Why the Rust core is small

Mole already produces correct system metrics. The Rust core does not duplicate that work. It does four things Mole does not do:

1. Samples per-process energy and instantaneous CPU.
2. Rolls processes up into apps.
3. Keeps a rolling history for charts.
4. Computes the pressure score and per-app impact score.

That is the whole justification for the crate. If you find yourself writing a `vm_stat` parser in Rust, stop. Mole already gives you that.

### 3.2 Why not pure Swift

Swift can call `proc_pid_rusage`. It can also do the rollup. So why Rust?

Honest answer: Rust is not strictly necessary. It buys you three things. A sampler with no ARC traffic in the hot path. A core you can test with `cargo test` and run headless in CI. A core you can later reuse in a CLI or a daemon.

If you decide mid-build that the FFI boundary costs more than it earns, moving the sampler to Swift is a legitimate call. Do not add Rust for its own sake. This spec assumes Rust because you asked for it, and the design keeps the boundary small enough that the decision stays reversible.

### 3.3 The FFI boundary

One function. Nothing more.

```rust
/// Returns a JSON-encoded Snapshot. Caller owns the string.
#[no_mangle]
pub extern "C" fn sysmon_snapshot_json() -> *mut c_char;

#[no_mangle]
pub extern "C" fn sysmon_free(ptr: *mut c_char);

#[no_mangle]
pub extern "C" fn sysmon_start(config_json: *const c_char) -> i32;

#[no_mangle]
pub extern "C" fn sysmon_stop();
```

Swift decodes the JSON with `Codable`. A 6 KB parse at 0.5 Hz costs under 0.2 ms. That is free.

Do not use UniFFI. Do not use `#[repr(C)]` structs across the boundary. Four functions do not need a code generator, and struct layout bugs across FFI are the worst class of bug to debug.

### 3.4 Threading

- Rust owns one background thread. It reads the Mole stdout pipe and blocks on it.
- It samples energy on the same thread, on its own cadence.
- It writes the current snapshot into an `ArcSwap<Snapshot>` or a `Mutex<Snapshot>`.
- Swift polls `sysmon_snapshot_json()` from the main queue on a display timer.

No callbacks from Rust into Swift. Callbacks across FFI create lifetime problems and make the Swift side hard to reason about. Polling a lock-free cell is simpler and costs nothing.

---

## 4. Data contract from Mole

The Go source of truth is `cmd/status/metrics.go`. Mirror it in Rust with `serde`. Every field is optional in practice. Decode defensively: a missing or renamed field must degrade one panel, never crash the app.

### 4.1 Top level

| Field | Type | Notes |
|---|---|---|
| `collected_at` | RFC3339 timestamp | use for staleness detection |
| `host` | string | |
| `platform` | string | |
| `uptime` | string | human readable |
| `uptime_seconds` | uint64 | |
| `procs` | uint64 | total process count |
| `hardware` | object | see 4.2 |
| `health_score` | int 0–100 | Mole's own score |
| `health_score_msg` | string | short explanation |
| `cpu` | object | see 4.3 |
| `gpu` | array | usually empty, see 2.4 |
| `memory` | object | see 4.4 |
| `disks` | array | |
| `trash_size` | uint64 | bytes |
| `trash_approx` | bool | |
| `disk_io` | object | `read_rate`, `write_rate` in MB/s |
| `network` | array | per interface |
| `network_history` | object | `rx_history`, `tx_history` float arrays |
| `proxy` | object | `enabled`, `type`, `host` |
| `batteries` | array | see 4.5 |
| `thermal` | object | see 4.6 |
| `sensors` | array | `label`, `value`, `unit`, `note` |
| `bluetooth` | array | `name`, `connected`, `battery` |
| `top_processes` | array | see 4.7 |
| `process_collected_at` | timestamp, optional | |
| `process_stale` | bool, optional | **honour this** |
| `zombie_count` | int, optional | |
| `zombie_parents` | array | `pid`, `name`, `count` |
| `process_watch` | object | threshold config |
| `process_alerts` | array | Mole's own sustained-CPU alerts |

### 4.2 `hardware`

`model`, `cpu_model`, `total_ram`, `disk_size`, `os_version`, `refresh_rate`. All strings, all human formatted. Display only. Never parse them.

### 4.3 `cpu`

`usage` float, `per_core` float array, `per_core_estimated` bool, `load1`, `load5`, `load15`, `core_count`, `logical_cpu`, `p_core_count`, `e_core_count`.

`p_core_count` and `e_core_count` are the important ones. They let you split `per_core` into two clusters. Section 6.3 explains why that matters.

Respect `per_core_estimated`. When true, mark the P/E chart as approximate rather than presenting a false number.

### 4.4 `memory`

`used`, `total`, `available`, `used_percent`, `swap_used`, `swap_total`, `cached`, `pressure`.

`pressure` is the string `normal`, `warn`, or `critical`, sourced from the macOS `memory_pressure` tool. This is the field that matters. `used_percent` on macOS is close to meaningless because the kernel deliberately uses free RAM as cache.

### 4.5 `batteries[]`

`percent`, `status`, `time_left`, `health`, `cycle_count`, `capacity`.

`capacity` is maximum capacity as a percentage of original. `cycle_count` over 800 is Mole's warn threshold, over 900 its danger threshold.

### 4.6 `thermal`

`cpu_temp`, `gpu_temp`, `battery_temp`, `fan_speed`, `fan_count`, `system_power`, `adapter_power`, `battery_power`.

All temperatures in Celsius. All power in Watts. `battery_power` positive means discharging.

On Apple Silicon several of these are commonly zero. Treat zero as "unavailable" and hide the row, do not render "0°C".

`system_power` is the whole-machine draw. It is the denominator for the energy panel in section 6.6.

### 4.7 `top_processes[]`

`pid`, `ppid`, `name`, `command`, `cpu`, `memory`, `memory_bytes`.

Use `pid`, `ppid`, `name`, `command`, and `memory_bytes`. Ignore `cpu` for display per finding 2.3. Ignore `memory` in favour of `memory_bytes`.

---

## 5. The Rust core

### 5.1 Responsibilities

| Job | Source |
|---|---|
| Spawn and supervise `mo status --watch` | `std::process::Command` |
| Decode NDJSON lines | `serde_json` from a `BufReader` |
| Sample per-process CPU and energy | `libproc` / `proc_pid_rusage` |
| Roll processes up to apps | bundle resolution, see 5.3 |
| Keep history | ring buffers, see 5.4 |
| Compute scores | see 5.5 |
| Expose one merged snapshot | FFI, see 3.3 |

### 5.2 Per-process energy

This is the feature Mole does not have and the one you asked for most clearly.

Use `proc_pid_rusage(pid, RUSAGE_INFO_V6, &mut info)`. It needs no elevated privileges and no private frameworks. It returns a `rusage_info_v6` struct containing, among other fields:

- `ri_user_time`, `ri_system_time` — nanoseconds of CPU
- `ri_pkg_idle_wkups` — package idle wakeups, the expensive kind
- `ri_interrupt_wkups` — interrupt wakeups
- `ri_diskio_bytesread`, `ri_diskio_byteswritten`
- `ri_instructions`, `ri_cycles` — on supported hardware
- `ri_billed_energy`, `ri_serviced_energy` — on supported hardware

**Verify the exact field names and the V6 availability against `/usr/include/sys/resource.h` on the target machine before relying on them.** Apple moves fields between `rusage_info_v*` versions. If V6 is unavailable, fall back to V4 and drop the instruction and cycle terms. Do not guess.

Compute an impact score per process from two samples, `t0` and `t1`:

```
cpu_ns      = Δ(ri_user_time + ri_system_time)
wakeups     = Δ(ri_pkg_idle_wkups)
disk_bytes  = Δ(ri_diskio_bytesread + ri_diskio_byteswritten)

impact = (cpu_ns / elapsed_ns) * 100.0          // CPU-normalised core-percent
       + (wakeups / elapsed_s)  * 0.40          // wakeups are why a Mac gets hot doing nothing
       + (disk_bytes / elapsed_s / 1_048_576) * 0.05
```

The weights are a starting point, not physics. Activity Monitor's Energy Impact uses a private formula and there is no way to match it exactly. Put the three weights in the config file so the user can tune them, and label the column "Impact", not "Watts". Do not invent a Watts figure you cannot defend.

If `ri_billed_energy` is present and non-zero on the machine, prefer it and label the column "Energy". Fall back to the computed score otherwise.

Instantaneous CPU comes from the same delta: `cpu_ns / elapsed_ns * 100`, which gives core-percent where 100 means one core fully busy. This is the Activity Monitor convention and it is what users expect.

**Sampling cost.** `proc_pid_rusage` on a few hundred PIDs takes single-digit milliseconds. Do it at the same cadence as the Mole stream, not faster. Enumerate PIDs with `proc_listpids`, keep the previous sample in a `HashMap<pid_t, Sample>`, and prune dead PIDs each tick.

**Permissions.** `proc_pid_rusage` succeeds for your own processes and for most others without special entitlement. It fails with `EPERM` for some system processes. Skip failures silently, never surface an error for this.

### 5.3 App rollup

This is what makes the product better than Activity Monitor. Chrome must be one row.

Resolution order for a PID:

1. Walk the parent chain via `ppid` up to a depth of 8, or until `ppid` is 1 or 0.
2. For each ancestor, get the executable path with `proc_pidpath`.
3. If the path contains `.app/Contents/`, take the bundle root and read `CFBundleIdentifier` from `Info.plist`. That is the app identity.
4. If no ancestor is inside a bundle, group under the top-level ancestor's executable name.
5. Cache the PID-to-identity mapping. Resolution is expensive; identity never changes for a live PID.

Special cases that must work on day one, because they are the ones users notice:

- **Chrome and Electron helpers.** `Google Chrome Helper (Renderer)` has Chrome as an ancestor. The chain walk handles this.
- **Safari.** `com.apple.WebKit.WebContent` processes are children of `launchd`, not of Safari. The parent walk fails. Special-case them: attribute WebKit content processes to Safari when Safari is running. Document this as a known heuristic.
- **XPC services.** A service inside `Foo.app/Contents/XPCServices/` rolls up to Foo by path, not by parent.
- **`kernel_task`.** Always its own row. Never merged, never hidden. High `kernel_task` CPU means thermal throttling and the user needs to see it.

Aggregate per app: sum CPU, sum resident memory, sum impact, sum disk bytes, count processes. Keep the child list so the row can expand.

Show the child count in the row. "Google Chrome · 41 processes" is information, not clutter.

### 5.4 History

A fixed ring buffer per series. 300 samples. At a 2 s cadence that is 10 minutes of history.

Series to keep:
- CPU total, CPU P-cluster, CPU E-cluster
- Memory used, swap used, memory pressure level
- Network rx, network tx
- Disk read, disk write
- System power in Watts
- Impact of the current top app

300 `f32` per series across 12 series is 14 KB. Memory is a non-issue. Do not persist history to disk. A monitor that writes to disk every 2 s is a monitor that wears your SSD and shows up in its own disk panel.

Mole already ships `network_history` in the snapshot. Use your own ring buffer anyway, so every chart shares one time axis. Mixing two history sources with different cadences produces charts that lie.

### 5.5 Scores

**Pressure score, 0 to 100, higher is worse.** This is Loupe's headline number and it inverts Mole's `health_score`, which runs the other way.

Mole computes health in `cmd/status/metrics_health.go` with published weights: CPU 30, memory 25, disk 20, thermal 15, I/O 10, with penalties for memory pressure, battery cycles, and long uptime. That model is sound and well tested. Reuse it.

Do not reimplement it in Rust. Read `health_score` from the stream and present `100 - health_score` as pressure. Then add one thing Mole cannot know: attribution.

```
pressure = 100 - snapshot.health_score
driver   = the single metric with the largest penalty contribution
culprit  = the top app by that metric
```

The panel headline becomes a sentence, not a number:

> **Pressure 62** — memory. Google Chrome is holding 9.4 GB.

That sentence is the product. Everything else is supporting detail.

Compute `driver` by evaluating Mole's own penalty formula locally on the incoming values. The thresholds are constants in the Go source and are listed in section 4 of this spec by implication; copy them into one Rust module with a comment pointing at `metrics_health.go` so they can be resynced when Mole changes.

**Bands.** Match Mole's display bands so the two tools never disagree in front of the user: health 85+ excellent, 65+ good, 45+ fair, below that poor. Inverted, pressure 0–15 calm, 16–35 normal, 36–55 busy, 56+ strained.

### 5.6 Supervising the Mole child

- Resolve the `mo` binary. Search `$PATH`, then `/opt/homebrew/bin/mo`, then `/usr/local/bin/mo`, then `~/.local/bin/mo`. Never hardcode one path.
- On launch, run `mo --version`. Store it. If it is below a known-good floor, show a non-blocking banner asking the user to update.
- Spawn `mo status --watch --interval <N>s --proc-cpu-alerts=false`. Disable Mole's alerts; Loupe owns alerting and two alert systems would double-notify.
- Read stdout with a `BufReader` and `lines()`. One line, one snapshot.
- Read stderr on a separate thread into a bounded 200-line buffer. Surface it in Settings under "Diagnostics". Never let stderr fill the pipe and block the child.
- If the child exits, restart it with exponential backoff: 1 s, 2 s, 4 s, up to 30 s. After five consecutive failures, stop and show the degraded-mode banner from section 8.4.
- On app quit, close the stdin pipe and drop the handle. Mole's watch loop exits on stdout close, as documented in `watch.go`. Send `SIGTERM` after 2 s if it is still alive. Never leak a child.

---

## 6. The interface

### 6.1 Design rules

These are constraints, not preferences. Hold them.

1. **Greyscale until alarm.** The whole interface is neutral. Colour appears only when a threshold is crossed. One accent for warn, one for critical. This is the single decision that separates professional from decorated.
2. **No pie charts, no donuts, no radial gauges.** They read badly at small sizes and encode one number in a shape that implies a whole. Sparklines and horizontal bars.
3. **One shared time axis.** Every chart in the panel covers the same window and the same instant. Hovering one chart shows a crosshair on all of them. This is what turns six charts into one diagnosis.
4. **Tabular figures everywhere.** `.monospacedDigit()` on every changing number. Without it the layout twitches on every update and the app feels cheap within a day.
5. **No animation on data.** Numbers change instantly. Animate layout changes, never values. An animated counter is a counter you cannot read.
6. **Dense, not sparse.** A 380 pt panel should carry real information. Minimal means no decoration, not no data.
7. **Every number has a unit and a scale.** "42" is noise. "42% of 8 P-cores" is information.

### 6.2 The menu bar item

`NSStatusItem` with `LSUIElement` set to true in `Info.plist`, so there is no Dock icon and no menu bar of your own.

**Width is fixed. This is non-negotiable.** A status item whose width changes with its content pushes every item to its left, several times a minute, forever. It is the fastest way to make a good app unbearable. Set `statusItem.length` to a constant and draw into an `NSImage` of that exact size.

Display modes, user selectable in Settings:

| Mode | Content | Width |
|---|---|---|
| Glyph | icon only, tinted by pressure band | 24 pt |
| Sparkline | 40-sample CPU or pressure sparkline drawn into an NSImage | 48 pt |
| Number | one metric, tabular figures, zero-padded | 44 pt |
| Compact | glyph plus one number | 60 pt |

Set `image.isTemplate = true` in the calm band so the glyph adapts to light and dark automatically. Drop template rendering only when tinting for warn or critical.

Left click opens the panel. Right click opens an `NSMenu` with: Open Panel, Settings, Run Mole Clean, Run Mole Analyze, Check for Mole Update, Quit.

### 6.3 The panel

An `NSPanel`, not an `NSPopover`. A popover cannot be pinned, cannot be moved, and dismisses when you switch apps, which is exactly when you most want to keep watching.

Configuration:
- `NSPanel` with `.nonactivatingPanel` and `.utilityWindow` style.
- `isFloatingPanel = true`, `level = .statusBar`.
- `hidesOnDeactivate = false`.
- `NSVisualEffectView` with `.hudWindow` material behind the SwiftUI content.
- Anchor below the status item, clamped to the screen that contains the item.
- Dismiss on outside click via a local and global `NSEvent` monitor, unless the user has pinned it.
- A pin button in the top-right keeps it open across app switches.

Content is SwiftUI in an `NSHostingView`. Charts are Swift Charts. Both are native, both are accessible for free, neither needs a dependency.

Width 380 pt. Height grows with the panel list, capped at 70% of screen height with a scroll view beyond that.

### 6.4 Panel layout, top to bottom

**Header.** The pressure sentence from 5.5. Large number, band colour, one line of plain-English attribution. Machine model and uptime in small secondary text.

**Panel list.** User-configured. Each panel is one section. Section 6.6 defines the panel types.

**Footer.** Four buttons: Clean, Analyze, Settings, Quit. The first two hand off to Mole per section 7.

### 6.5 Settings window

A standard `Settings` scene, tabbed.

- **General.** Launch at login via `SMAppService.mainApp.register()`. Poll interval when open. Poll interval when idle. Menu bar display mode and metric.
- **Panels.** A reorderable list. Add, remove, drag to reorder, edit each panel's fields. This writes `panels.toml`. An "Edit as text" button opens the file in the default editor and reloads on change.
- **Thresholds.** Warn and critical values for each metric. The three energy weights from 5.2.
- **Mole.** Detected binary path, detected version, a Test Connection button, and the stderr diagnostics buffer.
- **About.** Version, licence notices, a link to the Mole project with credit.

### 6.6 Panel types

One panel type, parameterised. This is the whole customization system. Do not build a plugin architecture.

```toml
[[panel]]
metric  = "memory"      # cpu | memory | energy | disk | network | power | battery | thermal | disk_io
group   = "app"         # app | process | system
sort    = "desc"        # desc | asc
count   = 5             # rows, 1..20, ignored when group = "system"
chart   = "sparkline"   # sparkline | bar | none
label   = "Memory hogs" # optional override
```

The renderer switches on `group`:

- `group = "system"` renders one headline value plus a chart of that metric's ring buffer.
- `group = "app"` renders `count` rows of apps, sorted by `metric`, with per-row bars and a disclosure triangle that expands to the child processes.
- `group = "process"` renders `count` raw processes with no rollup. For users who want the truth of the process table.

Per-metric notes:

- `cpu` with `group = "system"` renders the P/E split. Two stacked bar groups, one per cluster, each core a segment. This is the chart that makes Apple Silicon legible, and no mainstream tool draws it. Make it good.
- `memory` with `group = "system"` renders pressure as the primary reading, with swap used below it, and `used_percent` in small secondary text with a tooltip explaining why it is not the number to watch.
- `energy` uses the impact score from 5.2 and shows `thermal.system_power` as the system headline when available.
- `network` shows rx and tx as a mirrored sparkline around a zero axis. Per-app network is not available without private frameworks; state that in the panel rather than omitting it silently.
- `thermal` hides any sensor reading zero.
- `battery` shows percent, time remaining, capacity, and cycles. Warn at Mole's thresholds: capacity below 80, cycles above 800.

**Ship these defaults.** A user who never opens Settings should get a good app.

```toml
[[panel]]
metric = "cpu"
group  = "system"
chart  = "bar"

[[panel]]
metric = "memory"
group  = "system"
chart  = "sparkline"

[[panel]]
metric = "energy"
group  = "app"
count  = 5
chart  = "bar"

[[panel]]
metric = "memory"
group  = "app"
count  = 5
chart  = "bar"

[[panel]]
metric = "network"
group  = "system"
chart  = "sparkline"
```

### 6.7 Row interactions

Each app row supports:
- Click to expand into child processes.
- Right click for: Reveal in Finder, Quit, Force Quit, Copy PID, Exclude from list.
- Quit sends `SIGTERM`. Force Quit sends `SIGKILL` and requires a confirmation sheet naming the app.
- Never offer Force Quit on a process whose executable lives under `/System` or `/usr/libexec`. Grey it out with a tooltip.

### 6.8 Accessibility

- Every chart gets `.accessibilityLabel` and `.accessibilityValue` with the current reading in words.
- The pressure sentence is already a screen-reader-friendly summary. Mark it as the panel's accessibility summary.
- Respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- Respect `accessibilityDisplayShouldIncreaseContrast` by raising the alarm-colour contrast and adding a shape cue, so colour is never the only signal.
- Full keyboard navigation in the panel. Tab moves between rows, arrow keys move within a list, Escape closes.

---

## 7. Mole integration

### 7.1 `MoleAdapter.swift`

All knowledge of Mole lives in exactly one Swift file plus one Rust module. When Mole changes, you fix two files.

The adapter owns: binary discovery, version check, argument construction, the `analyze` call, and the terminal hand-off. The Rust side owns only the `--watch` stream.

### 7.2 Disk analysis

```
mo analyze --json <path>
```

Schema from `cmd/analyze/json.go`:

| Field | Type |
|---|---|
| `path` | string |
| `overview` | bool |
| `entries[]` | `name`, `path`, `size`, `is_dir`, `insight`, `cleanable`, `last_access` |
| `large_files[]` | `name`, `path`, `size` |
| `total_size` | int64 |
| `total_files` | int64 |

Run it on demand only, never on a timer. It walks the filesystem and is expensive.

`cleanable` and `insight` are Mole's judgement about what is safe to remove. That judgement is the most valuable thing in the repository and you must not second-guess it. Surface `cleanable` as a badge. Never act on it automatically.

Render as a treemap or a sorted bar list. A treemap is the better answer here and is one of the few places where a non-linear chart earns its place. Swift Charts has no treemap; a squarified treemap in `Canvas` is about 120 lines.

### 7.3 Destructive commands

`clean`, `uninstall`, `purge`, `installer`, `optimize`.

**Do not parse these. Do not wrap these. Do not reimplement these.**

The Loupe button opens the user's terminal and runs the command:

```
open -a Terminal "$(command -v mo)"   # with the subcommand appended
```

Honour `MO_LAUNCHER_APP` if the user has set it, as Mole itself does.

You get every future Mole improvement for free, the user sees Mole's own confirmations and dry-run output, and you never hold responsibility for a deletion your UI described inaccurately.

Always run `--dry-run` first where the command supports it, and let the user re-run without it from Mole's own prompt.

### 7.4 Licence boundary

Mole is GPL-3.0. Loupe calls the `mo` binary as a separate process over a pipe. That is arm's-length use and does not make Loupe a derivative work.

**Do not bundle `mo` inside `Loupe.app`.** Bundling makes you a distributor of GPL software with full source obligations, and it is unnecessary.

Instead: detect `mo` on launch. If it is missing, show a one-screen onboarding pane with a copy button for `brew install mole`, a link to the repository, and a Recheck button.

Credit Mole by name in About and in the README. Use a different product name, as the Mole licence section asks.

### 7.5 Staying current

The user's goal is "git pull and get new features". Concretely:

1. Loupe reads `mo --version` at every launch and caches it.
2. Loupe decodes the Mole snapshot with unknown fields ignored and all fields optional. A new Mole field never breaks Loupe.
3. New Mole fields become available to Loupe only when someone adds a panel for them. That is the honest boundary. There is no way for a UI to render a field it has never heard of, and any design that claims otherwise is lying.
4. Keep the Rust `MoleSnapshot` struct in one file with a header comment naming the Go file it mirrors and the Mole version it was synced against. Resyncing is then a ten-minute job.

---

## 8. Performance

### 8.1 Budget

Measured with Loupe's own panel open, on an Apple Silicon Mac, as a whole process tree including the `mo` child.

| State | CPU | RSS |
|---|---|---|
| Panel closed | under 0.3% | under 45 MB |
| Panel open | under 1.2% | under 70 MB |
| Idle 24 h, no growth | — | no upward drift |

If the app cannot meet this, it has failed its own premise and the budget is not negotiable down.

### 8.2 How to hit it

**Coalesce the timer.** `DispatchSourceTimer` with `leeway` set to 20% of the interval. The kernel batches your wakeup with other timers instead of waking the CPU alone. This is the largest single battery win available and it costs one line.

**Scale cadence with state.**

| State | Interval |
|---|---|
| Panel open, on AC | 1 s |
| Panel open, on battery | 2 s |
| Panel closed | 5 s |
| On battery and panel closed | 10 s |
| Display asleep or system idle | suspend entirely |

Changing the Mole interval requires restarting the child. Restart it on state transitions, debounced by 3 s so a user toggling the panel does not thrash processes.

**Suspend properly.** Observe `NSWorkspace.shared.notificationCenter` for `willSleepNotification` and `didWakeNotification`, and `NSWorkspace.screensDidSleepNotification`. On sleep, terminate the Mole child and stop the timer. On wake, restart and clear the history ring buffers, because the gap would otherwise draw a straight line across a chart and imply data that does not exist.

**Cap the work.** Keep the top 20 apps and top 40 processes. Sort with `select_nth_unstable_by`, not a full sort. Discard the rest before it crosses FFI.

**Do not redraw what did not change.** SwiftUI will redraw the whole panel on every snapshot unless your model conforms to `Equatable` with a meaningful implementation. Make `Snapshot` and every sub-struct `Equatable`, and round floats to display precision before comparing, so a change from 41.2001% to 41.2002% does not trigger a repaint.

**Never write to disk on a timer.** Config writes happen on user action only.

### 8.3 Self-measurement

Ship a Diagnostics pane that shows Loupe's own CPU, RSS, and wakeups, sampled by the same code path as everything else.

This is not a gimmick. It is the honesty check. If Loupe appears in its own energy panel, you have a bug and the user deserves to see it.

### 8.4 Degraded modes

The app must stay useful when a source fails. Never show an error dialog for any of these.

| Failure | Behaviour |
|---|---|
| `mo` not installed | Onboarding pane with the Homebrew command. Rust-sourced panels (CPU, energy, memory via syscall) still work. |
| `mo` child crashed | Backoff restart. Banner after five failures. Last-known values greyed out with a timestamp. |
| `process_stale` is true | Grey the process panels and show "processes N s old". Do not hide them. |
| `gpu` empty | Panel shows "GPU unavailable, needs elevated access". |
| Thermal sensors zero | Hide those rows. |
| `proc_pid_rusage` returns `EPERM` for a PID | Skip the PID silently. |
| `RUSAGE_INFO_V6` unavailable | Fall back to V4 and relabel the column "Impact (estimated)". |

---

## 9. Build and distribution

### 9.1 Layout

```
loupe/
├── Cargo.toml                    workspace
├── sysmon-core/
│   ├── src/lib.rs
│   ├── src/ffi.rs
│   ├── src/mole.rs               MoleSnapshot, mirrors cmd/status/metrics.go
│   ├── src/supervisor.rs         spawn, read, restart
│   ├── src/energy.rs             proc_pid_rusage
│   ├── src/rollup.rs             bundle identity
│   ├── src/history.rs            ring buffers
│   ├── src/score.rs              pressure, impact
│   └── include/sysmon.h          generated by cbindgen
├── Loupe/
│   ├── LoupeApp.swift
│   ├── StatusItemController.swift
│   ├── PanelController.swift
│   ├── Views/                    SwiftUI
│   ├── Model/Snapshot.swift      Codable, mirrors the Rust Snapshot
│   ├── MoleAdapter.swift
│   └── Config.swift              panels.toml
├── Loupe.xcodeproj
├── Makefile
└── README.md
```

### 9.2 Build

- Rust builds a universal `staticlib`: `cargo build --release --target aarch64-apple-darwin --target x86_64-apple-darwin`, then `lipo`.
- `cbindgen` generates the header. Xcode uses a bridging header.
- A single `make` target does Rust, then `xcodebuild`, then produces a signed and notarized DMG.
- Minimum deployment target macOS 14.

### 9.3 Signing

Developer ID signing, hardened runtime, notarized DMG. Not Mac App Store; the sandbox denies `proc_pid_rusage` for other processes and denies spawning `mo`.

No entitlements beyond hardened runtime defaults are required. If a feature seems to need one, that feature is out of scope.

### 9.4 Config

`~/.config/loupe/panels.toml`. Watch it with `DispatchSource.makeFileSystemObjectSource` and reload on change, debounced 300 ms. A malformed file falls back to defaults and shows a banner naming the parse error and line. It never crashes and it never overwrites the user's file.

---

## 10. Testing

### 10.1 Rust

- `cargo test` with recorded Mole NDJSON fixtures. Capture real output with `mo status --watch --interval 1s | head -20 > fixtures/stream.ndjson`.
- Fixtures must include: a normal snapshot, one with `process_stale = true`, one with empty `gpu`, one with zeroed thermal, one with a missing field, and one line of malformed JSON. Every one must decode or skip without panic.
- Rollup tests with a synthetic process tree covering Chrome helpers, an XPC service, a WebKit content process, and `kernel_task`.
- Score tests that pin the band boundaries.
- No `unwrap()` or `expect()` anywhere in `sysmon-core`. This is a library called across FFI; a panic there aborts the host app.

### 10.2 Cross-check against Mole

A `make verify` target that runs Loupe's sampler and `mo status --json` side by side for 60 seconds and reports drift per metric.

Expect memory, disk, and network to agree within 2%. Expect process CPU to diverge, for the reason in finding 2.3. Assert the first and document the second in the output, so a future reader does not treat the divergence as a bug.

### 10.3 Swift

- Snapshot tests for each panel type at each band, in light and dark, at default and largest Dynamic Type.
- A leak test: run for one hour with the panel open and assert RSS growth under 5 MB.
- A child-process test: quit the app and assert no orphaned `mo` process survives.

### 10.4 Acceptance

The app is done when all of these hold:

1. Chrome with 40 helpers shows as one row with a child count.
2. The P/E core chart renders correctly on Apple Silicon and degrades to a flat core list on Intel.
3. The energy panel ranks apps plausibly and matches Activity Monitor's ordering for the top 3 most of the time. Ordering, not values.
4. The menu bar item never changes width.
5. Pressure and Mole's own health score never disagree about the band.
6. Uninstalling `mo` leaves a working, honest, degraded app.
7. Loupe does not appear in its own top-5 energy panel.
8. The performance budget in 8.1 holds.

---

## 11. Scope boundaries

**In scope:** everything above.

**Explicitly out of scope for 1.0.** Do not build these, and do not leave hooks for them.

- Per-app network usage. Needs the private `NetworkStatistics` framework.
- Fan control, temperature control, any SMC write.
- Anything requiring root, a helper tool, or `SMJobBless`.
- Historical data written to disk, trends over days, reports.
- Notifications, alerts to Slack, webhooks.
- iCloud sync of settings.
- A plugin system. The panel config in 6.6 is the extension point.
- Reimplementing any Mole cleaning logic.
- Windows or Linux.

---

## 12. Open questions to settle during the build

These need a decision but do not block starting. Decide them with evidence, not by guessing.

1. **Does `RUSAGE_INFO_V6` expose `ri_billed_energy` on the target hardware?** Check the header and write a five-line probe. This decides whether the column says "Energy" or "Impact".
2. **What is the real cost of `proc_pid_rusage` across 400 PIDs?** Measure it. If it exceeds 15 ms, sample only the top 60 by CPU and extrapolate.
3. **Does the Safari WebKit heuristic hold on macOS 15 and 26?** Verify on the target OS versions before shipping it.
4. **Is the energy weight set in 5.2 defensible?** Compare orderings against Activity Monitor for a week of real use. Adjust the weights, not the method.
5. **Does restarting the Mole child on cadence change cost more than running at a fixed 2 s?** Measure both. If a fixed interval wins, simplify and drop the state machine.
