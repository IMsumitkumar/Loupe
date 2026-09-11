import AppKit
import CSysmon
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gear") }
            PanelsPane().tabItem { Label("Panels", systemImage: "rectangle.grid.2x2") }
            ThresholdsPane().tabItem { Label("Thresholds", systemImage: "slider.horizontal.3") }
            MolePane().tabItem { Label("Mole", systemImage: "terminal") }
            DiagnosticsPane().tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            AboutPane().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }
}

struct GeneralPane: View {
    @EnvironmentObject var prefs: Prefs
    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
            Section("Refresh") {
                Stepper("Every \(prefs.intervalOpen) s while the panel is open", value: $prefs.intervalOpen, in: 1...10)
                Stepper("Every \(prefs.intervalClosed) s while it is closed", value: $prefs.intervalClosed, in: 2...60)
                Text("Closed, Mole is not running and the glyph follows processor, memory and disk only; on battery the closed interval doubles.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Picker("Show", selection: $prefs.menuMode) { ForEach(MenuMode.allCases) { Text($0.label).tag($0) } }
                Picker("Metric", selection: $prefs.menuMetric) { ForEach(MenuMetric.allCases) { Text($0.label).tag($0) } }
                Text("The item keeps a fixed width in every mode so the menu bar never shifts.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Excluded from lists") {
                if prefs.excluded.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(prefs.excluded, id: \.self) { key in
                    HStack { Text(key).lineLimit(1); Spacer(); Button("Show again") { prefs.excluded.removeAll { $0 == key } } }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PanelsPane: View {
    @EnvironmentObject var config: Config
    @State private var draft: [Panel] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach($draft) { $p in
                    HStack(spacing: 6) {
                        Picker("", selection: $p.metric) { ForEach(Metric.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }.frame(width: 120)
                        Picker("", selection: $p.group) { Text("App").tag("app"); Text("Process").tag("process"); Text("System").tag("system") }.frame(width: 90)
                        Picker("", selection: $p.chart) { Text("Sparkline").tag("sparkline"); Text("Bar").tag("bar"); Text("None").tag("none") }.frame(width: 90)
                        if p.group != "system" { Stepper("\(p.count)", value: $p.count, in: 1...20).frame(width: 60) }
                        TextField("Label", text: Binding(get: { p.label ?? "" }, set: { p.label = $0.isEmpty ? nil : $0 })).frame(width: 90)
                    }
                    .labelsHidden()
                }
                .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { draft.remove(atOffsets: $0) }
            }
            HStack {
                Button("Add panel") { draft.append(Panel(metric: "cpu", group: "app")) }
                Button("Reset to defaults") { draft = defaults() }
                Spacer()
                Button("Edit as text") { config.openInEditor() }
                Button("Save") { config.save(draft) }.keyboardShortcut(.defaultAction).disabled(draft == config.panels)
            }
            Text("System panels become Overview tiles (first four). App and process panels become Apps choices. Saved to ~/.config/loupe/panels.toml; drag to reorder, delete key removes.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = config.error { Text("Current file has an error: \(e)").font(.caption).foregroundStyle(Palette.crit) }
        }
        .padding()
        .onAppear { if !loaded { draft = config.panels; loaded = true } }
        .onReceive(config.$panels) { draft = $0 }
    }

    private func defaults() -> [Panel] {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        struct P: Codable { var panels: [Panel] }
        let raw = config.defaultToml.withCString { sysmon_panels_json($0) }
        defer { if let raw { sysmon_free(raw) } }
        guard let raw, let parsed = try? d.decode(P.self, from: Data(bytes: raw, count: strlen(raw))) else { return draft }
        return parsed.panels
    }
}

struct ThresholdsPane: View {
    @EnvironmentObject var prefs: Prefs
    var body: some View {
        Form {
            Section("Warn and critical (defaults are Mole's)") {
                pair("Processor %", $prefs.thresholds.cpuWarn, $prefs.thresholds.cpuCrit)
                pair("Memory used %", $prefs.thresholds.memWarn, $prefs.thresholds.memCrit)
                pair("Disk used %", $prefs.thresholds.diskWarn, $prefs.thresholds.diskCrit)
                pair("Temperature °C", $prefs.thresholds.thermalWarn, $prefs.thresholds.thermalCrit)
                pair("Disk activity MB/s", $prefs.thresholds.ioWarn, $prefs.thresholds.ioCrit)
                pair("Battery health % (below)", $prefs.thresholds.batteryCapWarn, $prefs.thresholds.batteryCapCrit)
                pair("Battery cycles", $prefs.thresholds.cyclesWarn, $prefs.thresholds.cyclesCrit)
            }
            Section("Impact weights (used when kernel energy is unavailable)") {
                weight("Core-percent", $prefs.weights.cpu)
                weight("Idle wakeups per second", $prefs.weights.wakeups)
                weight("Disk MB per second", $prefs.weights.disk)
                Text("impact = cpu·w1 + wakeups·w2 + MB/s·w3. On this Mac the Energy column uses the kernel's nanojoule counter instead.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    private func pair(_ label: String, _ warn: Binding<Double>, _ crit: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 190, alignment: .leading)
            TextField("warn", value: warn, format: .number).frame(width: 70)
            TextField("critical", value: crit, format: .number).frame(width: 70)
        }
    }
    private func weight(_ label: String, _ v: Binding<Double>) -> some View {
        HStack { Text(label).frame(width: 190, alignment: .leading); TextField("", value: v, format: .number).frame(width: 70) }
    }
}

struct MolePane: View {
    @EnvironmentObject var engine: Engine
    @State private var testResult = ""
    var body: some View {
        Form {
            LabeledContent("Binary", value: engine.moPath ?? "not found")
            LabeledContent("Version", value: engine.moVersion ?? "—")
            LabeledContent("Stream", value: engine.snapshot?.moleStatus.state ?? "—")
            LabeledContent("Lines received", value: "\(engine.snapshot?.moleStatus.lines ?? 0), \(engine.snapshot?.moleStatus.decodeErrors ?? 0) rejected")
            if let bad = engine.snapshot?.moleStatus.badKeys, !bad.isEmpty {
                LabeledContent("Ignored fields", value: bad.joined(separator: ", "))
            }
            HStack {
                Button("Recheck") { engine.recheckMole() }
                Button("Test connection") {
                    guard let p = engine.moPath else { testResult = "mo not found"; return }
                    let out = MoleAdapter.run(p, ["status", "--json"], timeout: 15) ?? ""
                    testResult = out.contains("\"health_score\"") ? "OK: \(out.count) bytes of JSON in one shot" : "Failed: no JSON from mo status --json"
                }
                Text(testResult).font(.caption).foregroundStyle(.secondary)
            }
            Section("Mole stderr (last 200 lines)") {
                ScrollView {
                    Text((engine.snapshot?.moleStatus.stderr ?? []).joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 120)
            }
        }
        .formStyle(.grouped)
    }
}

/// The honesty check: Loupe measured by the same sampler as everything else.
struct DiagnosticsPane: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        let s = engine.snapshot?.selfStats
        let open = engine.panelOpen
        Form {
            Section("Loupe, measured by its own sampler") {
                LabeledContent("Loupe CPU, last tick", value: s?.cpu.map { String(format: "%.2f%% of one core", $0) } ?? "—")
                LabeledContent("Loupe CPU, average since launch", value: s.map { String(format: "%.2f%% over %@", $0.avgCpuSinceLaunch, Fmt.duration($0.uptimeS)) } ?? "—")
                LabeledContent("Loupe memory", value: s?.memory.map(Fmt.bytes) ?? "—")
                LabeledContent("Idle wakeups", value: s?.wakeupsPerS.map { String(format: "%.1f per second", $0) } ?? "—")
                LabeledContent("Loupe energy", value: s?.energyW.map(Fmt.watts) ?? "—")
                LabeledContent("Mole child CPU", value: s?.childCpu.map { String(format: "%.2f%%", $0) } ?? "not running")
                LabeledContent("Mole child memory", value: s?.childMemory.map(Fmt.bytes) ?? "—")
                LabeledContent("Whole tree CPU", value: s?.treeCpu.map { String(format: "%.2f%%", $0) } ?? "—")
                LabeledContent("Whole tree memory", value: s?.treeMemory.map(Fmt.bytes) ?? "—")
            }
            Section("Budget (spec 8.1: closed < 0.3% / 45 MB, open < 1.2% / 70 MB, whole tree)") {
                let cpuCap: Float = open ? 1.2 : 0.3
                let memCap: UInt64 = (open ? 70 : 45) * 1_048_576
                LabeledContent("State", value: open ? "panel open (Mole streaming)" : "panel closed (Mole off)")
                LabeledContent("CPU", value: verdict(s?.treeCpu, cap: cpuCap) { String(format: "%.2f%%", $0) })
                LabeledContent("Memory", value: verdict(s?.treeMemory, cap: memCap) { Fmt.bytes($0) })
                LabeledContent("In its own top 5 by energy?", value: (engine.snapshot?.apps.prefix(5).contains { $0.isSelf } ?? false) ? "yes, that is a bug" : "no")
            }
            Section("Sampler") {
                LabeledContent("PIDs", value: s.map { "\($0.pidsReadable) readable of \($0.pidsTotal)" } ?? "—")
                LabeledContent("Sampling pass", value: s.map { String(format: "%.2f ms", $0.sampleMs) } ?? "—")
                LabeledContent("Whole tick", value: s.map { String(format: "%.2f ms", $0.tickMs) } ?? "—")
                LabeledContent("Snapshot size", value: s.map { "\($0.snapshotBytes / 1024) KB JSON" } ?? "—")
                LabeledContent("Energy source", value: engine.snapshot?.energyMode ?? "—")
            }
        }
        .formStyle(.grouped)
    }

    private func verdict<T: Comparable>(_ v: T?, cap: T, fmt: (T) -> String) -> String {
        guard let v else { return "—" }
        return "\(fmt(v)) · \(v <= cap ? "within budget" : "OVER budget (\(fmt(cap)))")"
    }
}

struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loupe").font(.title2.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").foregroundStyle(.secondary)
            Text("A menu bar glyph that tells you when something is wrong, and a panel that tells you what.")
            Divider()
            Text("System metrics, the health score and disk analysis come from **Mole** by tw93, licensed GPL-3.0. Loupe runs the `mo` command as a separate process and does not bundle it.")
            Link("Mole on GitHub", destination: MoleAdapter.repoURL)
            Text("Per-app energy uses the kernel's own accounting (`proc_pid_rusage`). No helper tool, no root, no private frameworks.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}
