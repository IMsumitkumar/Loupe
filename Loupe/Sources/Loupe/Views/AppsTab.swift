import AppKit
import SwiftUI

struct AppsTab: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var config: Config
    @EnvironmentObject var history: AppHistory
    @EnvironmentObject var ctx: PanelContext
    @State private var selected: String = ""
    @State private var expanded: Set<String> = []

    private var panels: [Panel] { config.appPanels }
    private var panel: Panel? { panels.first { $0.id.uuidString == selected } ?? panels.first }

    var body: some View {
        let snap = engine.snapshot
        VStack(alignment: .leading, spacing: 10) {
            if let p = panel, let snap {
                let rows = ranked(snap, p)
                Text(sentence(rows, p, snap)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if panels.count > 1 {
                    Segments(items: panels.map { ($0.id.uuidString, $0.title) }, selection: Binding(get: { p.id.uuidString }, set: { selected = $0 }))
                }
                if p.metric == "network" {
                    Text("Per-app network use is not available without private frameworks. The Overview shows the total.").font(.caption).foregroundStyle(.secondary)
                } else if rows.isEmpty {
                    Text("Nothing to rank yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    let shown = rows.map(\.key)
                    ShareBar(segments: shares(rows, snap, p, shown))
                    VStack(spacing: 0) {
                        ForEach(rows) { a in
                            AppRow(app: a, metric: p.metric, mode: snap.energyMode, expanded: expanded.contains(a.key), series: history.series[a.key] ?? [], raw: p.group == "process", slot: history.slot(for: a.key, shown: shown)) {
                                if expanded.contains(a.key) { expanded.remove(a.key) } else { expanded.insert(a.key) }
                            }
                            .environmentObject(ctx)
                        }
                    }
                    if snap.mole?.processStale == true, let age = snap.moleStatus.lastLineAgeMs {
                        Text("Process list from Mole is \(Fmt.age(age)) old.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.vertical, 2)
                CoreGrid(cores: snap.cores)
            } else {
                Text(snap == nil ? "Taking the first reading." : "No app panels are configured. Add one in Settings › Panels.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func value(_ a: App, _ metric: String, _ mode: String) -> Double {
        switch metric {
        case "cpu": return Double(a.cpu ?? 0)
        case "memory": return Double(a.memory)
        case "energy", "power": return mode == "energy" ? Double(a.energyW ?? 0) : Double(a.impact)
        case "disk_io", "disk": return Double(a.diskBps)
        default: return Double(a.impact)
        }
    }

    private func ranked(_ s: Snapshot, _ p: Panel) -> [App] {
        var apps = s.apps.filter { !prefs.excluded.contains($0.key) }
        if p.group == "process" {
            apps = s.processes.map { proc in
                App(key: "pid:\(proc.pid)", name: proc.name, kind: "process", path: proc.path, rootPid: proc.pid, procs: 1, cpu: proc.cpu, memory: proc.memory ?? 0,
                    energyW: proc.energyW, impact: proc.impact, wakeups: proc.wakeups ?? 0, diskBps: proc.diskBps ?? 0, cpuSource: proc.cpuSource,
                    quitOk: true, forceQuitOk: proc.forceQuitOk, isSelf: proc.pid == s.selfStats.pid, children: [])
            }
        }
        let sorted = apps.sorted { value($0, p.metric, s.energyMode) > value($1, p.metric, s.energyMode) }
        let ordered = p.sort == "asc" ? Array(sorted.reversed()) : sorted
        return Array(ordered.prefix(p.count))
    }

    private func shares(_ rows: [App], _ s: Snapshot, _ p: Panel, _ shown: [String]) -> [ShareSegment] {
        let all = (p.group == "process" ? [] : s.apps).reduce(0.0) { $0 + value($1, p.metric, s.energyMode) }
        var segs = rows.map { ShareSegment(label: $0.name, value: value($0, p.metric, s.energyMode), slot: history.slot(for: $0.key, shown: shown)) }
        let shown = segs.reduce(0) { $0 + $1.value }
        if all > shown { segs.append(ShareSegment(label: "Everything else", value: all - shown)) }
        return segs
    }

    private func sentence(_ rows: [App], _ p: Panel, _ s: Snapshot) -> String {
        guard let top = rows.first else { return "No app stands out." }
        let word: String = switch p.metric {
        case "cpu": "processor time"
        case "memory": "memory"
        case "energy", "power": s.energyMode == "energy" ? "energy" : "impact"
        case "disk_io": "disk activity"
        default: p.title.lowercased()
        }
        let total = s.apps.reduce(0.0) { $0 + value($1, p.metric, s.energyMode) }
        let share = total > 0 ? Int(value(top, p.metric, s.energyMode) / total * 100) : 0
        if share >= 50 { return "\(top.name) is using \(share)% of the \(word). One app is the story." }
        if share >= 25 { return "\(top.name) is using the most \(word), at \(share)%." }
        return "No single app dominates \(word). \(top.name) leads with \(share)%."
    }
}

struct AppRow: View {
    var app: App
    var metric: String
    var mode: String
    var expanded: Bool
    var series: [Float?]
    var raw: Bool
    var slot: Int?
    var onTap: () -> Void
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var ctx: PanelContext
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: Icons.icon(for: app)).resizable().frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(app.name).font(.callout).lineLimit(1)
                        if app.isSelf { Text("this app").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(verbatim: raw ? "pid \(app.rootPid)" : "\(app.procs) process\(app.procs == 1 ? "" : "es")").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !raw { MicroSparkline(values: series, color: Palette.series(slot, scheme)).accessibilityHidden(true) }
                TrendGlyph(trend: Trend.of(series, back: 10))
                Text(valueText).font(.callout).monospacedDigit().frame(width: 72, alignment: .trailing)
                    .help(app.cpuSource == "mole" ? "Average from Mole's process list; live sampling needs elevated access for this process." : technical)
                if !raw {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { if !raw { onTap() } }
            .contextMenu { menu }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(app.name), \(app.procs) processes")
            .accessibilityValue("\(valueText), \(Trend.of(series, back: 10).word)")
            .accessibilityAddTraits(.isButton)
            if expanded {
                ForEach(app.children.prefix(25)) { c in
                    HStack(spacing: 8) {
                        Text(c.name).font(.caption).lineLimit(1)
                        Text(verbatim: "pid \(c.pid)").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text(childValue(c)).font(.caption).monospacedDigit()
                    }
                    .padding(.leading, 24).padding(.vertical, 2)
                    .contextMenu {
                        Button("Quit") { Actions.quit(pid: c.pid) }
                        Button("Force Quit…") { Actions.forceQuit(name: c.name, pids: [c.pid], in: ctx.window) }.disabled(!c.forceQuitOk)
                        Button("Copy PID") { Actions.copy("\(c.pid)") }
                    }
                }
                if app.children.count > 25 { Text("and \(app.children.count - 25) more").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 24) }
            }
            Divider().opacity(0.4)
        }
    }

    private var technical: String {
        switch metric {
        case "cpu": return "core-percent: 100 means one core fully busy (rusage delta)"
        case "memory": return "physical footprint, summed over the app's processes"
        case "energy", "power": return mode == "energy" ? "ri_energy_nj delta per second" : "impact = cpu + 0.4·wakeups + 0.05·MB/s (Settings › Thresholds)"
        default: return metric
        }
    }

    private var valueText: String {
        let approx = app.cpuSource == "mole" ? "≈" : ""
        switch metric {
        case "cpu": return app.cpu.map { approx + Fmt.pct(Double($0)) } ?? "—"
        case "memory": return Fmt.bytes(app.memory)
        case "energy", "power":
            if mode == "energy" { return app.energyW.map(Fmt.watts) ?? "—" }
            return String(format: "%.1f", app.impact)
        case "disk_io", "disk": return Fmt.rate(Double(app.diskBps) / 1_048_576)
        default: return String(format: "%.1f", app.impact)
        }
    }

    private func childValue(_ c: Proc) -> String {
        let approx = c.cpuSource == "mole" ? "≈" : ""
        switch metric {
        case "cpu": return c.cpu.map { approx + Fmt.pct(Double($0)) } ?? "—"
        case "memory": return c.memory.map(Fmt.bytes) ?? "—"
        case "energy", "power": return mode == "energy" ? (c.energyW.map(Fmt.watts) ?? "—") : String(format: "%.1f", c.impact)
        default: return c.diskBps.map { Fmt.rate(Double($0) / 1_048_576) } ?? "—"
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Reveal in Finder") { Actions.reveal(path: app.path) }.disabled(app.path.isEmpty)
        Button("Quit") { Actions.quit(app) }.disabled(!app.quitOk)
        Button("Force Quit…") { Actions.forceQuit(name: app.name, pids: app.children.map(\.pid), in: ctx.window) }
            .disabled(!app.forceQuitOk)
            .help(app.forceQuitOk ? "" : "Not offered for anything under /System or /usr/libexec")
        Button("Copy PID") { Actions.copy("\(app.rootPid)") }
        Divider()
        Button("Exclude from list") { prefs.excluded.append(app.key) }
    }
}
