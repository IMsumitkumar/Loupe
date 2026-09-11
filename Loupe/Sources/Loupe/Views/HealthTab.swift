import SwiftUI

struct HealthTab: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        let snap = engine.snapshot
        let t = prefs.thresholds
        VStack(alignment: .leading, spacing: 10) {
            Text(sentence(snap)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let s = snap {
                VStack(spacing: 0) {
                    row("Pressure", value: s.verdict.score.map { "\($0) of 100" } ?? "—", detail: pressureDetail(s), state: Palette.state(for: s.verdict.band),
                        tech: "100 minus Mole's health_score; bands 0-15 calm, 16-35 normal, 36-55 busy, 56+ strained")
                    if let b = s.mole?.batteries.first {
                        let cap = Palette.level(Double(b.capacity), warn: t.batteryCapWarn, crit: t.batteryCapCrit)
                        let cyc = Palette.level(Double(b.cycleCount), warn: t.cyclesWarn, crit: t.cyclesCrit)
                        row("Battery", value: "\(Int(b.percent))%", detail: [b.status, b.timeLeft.isEmpty ? nil : "\(b.timeLeft) left"].compactMap { $0 }.joined(separator: " · "), state: .ok, tech: "batteries[0].percent, pmset")
                        if b.capacity > 0 {
                            row("Battery health", value: "\(b.capacity)% of original", detail: cap == .ok ? "Healthy" : "Apple recommends service below 80%", state: cap, tech: "batteries[0].capacity, warn under 80, danger under 60")
                        }
                        row("Charge cycles", value: "\(b.cycleCount)", detail: cyc == .ok ? "Fine" : "High; batteries are rated for about 1000", state: cyc, tech: "batteries[0].cycle_count, warn over 800, danger over 900")
                    }
                    if let th = s.mole?.thermal {
                        if th.cpuTemp > 0 {
                            row("Processor temperature", value: String(format: "%.0f°C", th.cpuTemp), detail: th.cpuTemp > t.thermalWarn ? "Hot; macOS slows down to cool" : "Normal", state: Palette.level(th.cpuTemp, warn: t.thermalWarn, crit: t.thermalCrit), tech: "thermal.cpu_temp")
                        }
                        if th.fanSpeed > 0 { row("Fans", value: "\(th.fanSpeed) rpm", detail: "\(th.fanCount) fan\(th.fanCount == 1 ? "" : "s")", state: .ok, tech: "thermal.fan_speed") }
                        if th.systemPower > 0 { row("Power draw", value: String(format: "%.1f W", th.systemPower), detail: th.batteryPower > 0 ? "from battery" : "from the adapter", state: .ok, tech: "thermal.system_power") }
                    }
                    if let m = s.mole {
                        let days = m.uptimeSeconds / 86400
                        row("Uptime", value: Fmt.duration(m.uptimeSeconds), detail: days >= 14 ? "A restart is overdue" : (days >= 7 ? "A restart soon would not hurt" : "Fine"), state: days >= 14 ? .crit : (days >= 7 ? .warn : .ok), tech: "uptime_seconds; Mole penalises 7 and 14 days")
                        row("Memory pressure", value: m.memory.pressure.isEmpty ? "not measured yet" : m.memory.pressure, detail: m.memory.swapUsed > 0 ? "swap \(Fmt.bytes(m.memory.swapUsed)) in use" : "no swap in use", state: m.memory.pressure == "critical" ? .crit : (m.memory.pressure == "warn" ? .warn : .ok), tech: "memory.pressure from memory_pressure; the number to watch on macOS")
                        let gpuOk = m.gpu.first.map { $0.usage >= 0 } ?? false
                        row("Graphics", value: gpuOk ? "\(Int(m.gpu[0].usage))%" : "unavailable", detail: gpuOk ? m.gpu[0].name : "needs elevated access (powermetrics)", state: .ok, tech: "gpu[] via powermetrics, usually requires root")
                        row("Processes", value: "\(m.procs)", detail: (m.zombieCount ?? 0) > 0 ? "\(m.zombieCount ?? 0) zombies waiting to be reaped" : "no zombies", state: .ok, tech: "procs, zombie_count")
                        if !m.healthScoreMsg.isEmpty {
                            row("Mole says", value: m.healthScoreMsg, detail: "health score \(m.healthScore)", state: .ok, tech: "health_score_msg")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private func sentence(_ s: Snapshot?) -> String {
        guard let s else { return "Taking the first reading." }
        let word: String = switch s.verdict.band {
        case "calm": "in good shape"
        case "normal": "in fair shape"
        case "busy": "under some pressure"
        case "strained": "under real pressure"
        default: "still being checked"
        }
        return "Your Mac is \(word)." + (s.verdict.approximate ? " This is an estimate until the full check runs." : "")
    }

    private func pressureDetail(_ s: Snapshot) -> String {
        let band = s.verdict.band
        let d = s.verdict.driver
        if d == "none" { return "Nothing is pushing it up" }
        return "\(band); mostly from \(d == "io" ? "disk activity" : d)"
    }

    private func row(_ label: String, value: String, detail: String, state: State3, tech: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateDot(state: state)
            Text(label).font(.callout)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.callout).monospacedDigit().lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .help(tech)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value). \(detail). \(state.word).")
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }
}
