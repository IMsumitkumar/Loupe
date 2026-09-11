// Turns a snapshot plus the user's thresholds into what a stat tile shows:
// a label, a number with its denominator, one line of context, a state, a
// series and a trend. Plain words on screen, the technical name in the tooltip.

import Foundation

struct TileReading {
    var label: String
    var value: String
    var unit: String
    var context: String
    var state: State3
    var series: [Float?]
    var trend: Trend
    var reason: String?
    var technical: String
    var available = true
    var slot: Int = 0

    var accessibilityValue: String { "\(value) \(unit). \(context). \(state.word), \(trend.word)." }
}

enum Readings {
    static func tile(_ metric: Metric, _ s: Snapshot?, _ t: Thresholds) -> TileReading {
        var r = reading(metric, s, t)
        r.slot = Palette.slot(for: metric)
        return r
    }

    private static func reading(_ metric: Metric, _ s: Snapshot?, _ t: Thresholds) -> TileReading {
        let tech = metric.technical
        guard let s else {
            return TileReading(label: metric.title, value: "—", unit: "", context: "Waiting for the first reading", state: .ok, series: [], trend: .flat, technical: tech)
        }
        let h = s.history
        switch metric {
        case .cpu:
            let u = s.cpuUsage ?? 0
            let cores = s.mole?.cpu.logicalCpu ?? s.cores.all.count
            let state = Palette.level(u, warn: t.cpuWarn, crit: t.cpuCrit)
            let load = s.mole.map { String(format: " · load %.1f", $0.cpu.load1) } ?? ""
            return TileReading(label: "Processor", value: Fmt.pct(u), unit: "of \(cores) cores", context: busyContext(u, s) + load, state: state, series: h.cpu, trend: Trend.of(h.cpu),
                               reason: state == .ok ? nil : "The processor is \(Int(u))% busy across all cores. Anything above \(Int(t.cpuWarn))% for long makes everything feel slow.", technical: tech)
        case .memory:
            let used = s.memUsed ?? 0, total = s.memTotal ?? 0
            let pressure = s.mole?.memory.pressure ?? ""
            let swap = s.mole?.memory.swapUsed ?? 0
            let state: State3 = switch pressure {
            case "warn": .warn
            case "critical": .crit
            case "normal": .ok
            default: Palette.level(s.memUsedPct ?? 0, warn: t.memWarn, crit: t.memCrit)
            }
            let ctx: String = if pressure == "critical" { "Pressure critical · swap \(Fmt.bytes(swap))" }
                else if pressure == "warn" { "Pressure rising · swap \(Fmt.bytes(swap))" }
                else if pressure.isEmpty { "Pressure not measured · swap \(Fmt.bytes(swap))" }
                else if swap > 0 { "Pressure normal · swap \(Fmt.bytes(swap))" }
                else { "Pressure normal, no swap in use" }
            return TileReading(label: "Memory", value: Fmt.bytes(used), unit: "of \(Fmt.bytes(total))", context: ctx, state: state, series: h.memUsedPct, trend: Trend.of(h.memUsedPct),
                               reason: state == .ok ? nil : "Your Mac has started moving data to disk, which is slower than memory. Closing something big frees it fastest.", technical: tech)
        case .disk:
            guard let d = s.bootDisk else {
                return TileReading(label: "Disk space", value: "—", unit: "", context: "Not measured yet", state: .ok, series: [], trend: .flat, technical: tech)
            }
            let state = Palette.level(d.usedPercent, warn: t.diskWarn, crit: t.diskCrit)
            let free = d.total > d.used ? d.total - d.used : 0
            return TileReading(label: "Disk space", value: Fmt.pct(d.usedPercent), unit: "of \(Fmt.bytes(d.total))", context: "\(Fmt.bytes(free)) free", state: state, series: [], trend: .flat,
                               reason: state == .ok ? nil : "\(Int(d.usedPercent))% of your disk is used. macOS needs free space to swap and update; the Storage tab shows what is taking it.", technical: tech)
        case .network:
            let rx = s.netRx, tx = s.netTx
            let ifaces = s.mole?.network.count ?? 0
            let ctx = s.moleAlive ? "\(ifaces) interface\(ifaces == 1 ? "" : "s") · ↓ \(Fmt.rate(rx)) ↑ \(Fmt.rate(tx))" : "Measured by the full check only"
            let sum = sumSeries(h.netRx, h.netTx)
            return TileReading(label: "Network", value: Fmt.rate(rx + tx), unit: "total", context: ctx, state: .ok, series: sum, trend: Trend.of(sum), technical: tech, available: s.moleAlive)
        case .power, .energy:
            let w = s.mole?.thermal.systemPower ?? 0
            if w > 0 {
                return TileReading(label: "Power", value: String(format: "%.1f W", w), unit: "whole Mac", context: topAppContext(s), state: .ok, series: h.powerW, trend: Trend.of(h.powerW), technical: tech)
            }
            let top = s.topApp
            return TileReading(label: "Energy", value: top.flatMap { a in a.energyW.map(Fmt.watts) } ?? "—", unit: top.map { "for \($0.name)" } ?? "", context: "Whole-Mac power is not reported on this Mac", state: .ok, series: h.topImpact, trend: Trend.of(h.topImpact), technical: tech)
        case .battery:
            guard let b = s.mole?.batteries.first else {
                return TileReading(label: "Battery", value: "—", unit: "", context: "No battery found", state: .ok, series: [], trend: .flat, technical: tech, available: false)
            }
            let cap = Palette.level(Double(b.capacity), warn: t.batteryCapWarn, crit: t.batteryCapCrit)
            let cyc = Palette.level(Double(b.cycleCount), warn: t.cyclesWarn, crit: t.cyclesCrit)
            let state: State3 = (cap == .crit || cyc == .crit) ? .crit : ((cap == .warn || cyc == .warn) ? .warn : .ok)
            let ctx = b.timeLeft.isEmpty ? "\(b.status) · \(b.cycleCount) cycles" : "\(b.timeLeft) left · \(b.cycleCount) cycles"
            return TileReading(label: "Battery", value: Fmt.pct(b.percent), unit: b.capacity > 0 ? "health \(b.capacity)%" : "", context: ctx, state: state, series: [], trend: .flat,
                               reason: state == .ok ? nil : "The battery holds \(b.capacity)% of its original charge after \(b.cycleCount) cycles. Apple recommends service below 80%.", technical: tech)
        case .thermal:
            let temp = s.mole?.thermal.cpuTemp ?? 0
            guard temp > 0 else {
                return TileReading(label: "Temperature", value: "—", unit: "", context: "Not reported on this Mac", state: .ok, series: [], trend: .flat, technical: tech, available: false)
            }
            let state = Palette.level(temp, warn: t.thermalWarn, crit: t.thermalCrit)
            let fans = s.mole?.thermal.fanSpeed ?? 0
            return TileReading(label: "Temperature", value: String(format: "%.0f°C", temp), unit: "processor", context: fans > 0 ? "fans \(fans) rpm" : "fanless or fans idle", state: state, series: [], trend: .flat,
                               reason: state == .ok ? nil : "The processor is at \(Int(temp))°C. Above \(Int(t.thermalWarn))°C macOS slows it down to cool off.", technical: tech)
        case .disk_io:
            let r = s.mole?.diskIo.readRate ?? 0, w = s.mole?.diskIo.writeRate ?? 0
            let state = Palette.level(r + w, warn: t.ioWarn, crit: t.ioCrit)
            let sum = sumSeries(h.diskR, h.diskW)
            return TileReading(label: "Disk activity", value: Fmt.rate(r + w), unit: "read + write", context: "read \(Fmt.rate(r)) · write \(Fmt.rate(w))", state: state, series: sum, trend: Trend.of(sum),
                               reason: state == .ok ? nil : "The disk is moving \(Int(r + w)) MB/s. Heavy reading and writing makes apps wait.", technical: tech, available: s.moleAlive)
        }
    }

    /// Element-wise sum of two series; a gap in both stays a gap.
    private static func sumSeries(_ a: [Float?], _ b: [Float?]) -> [Float?] {
        var out: [Float?] = []
        out.reserveCapacity(min(a.count, b.count))
        for (x, y) in zip(a, b) {
            if x == nil && y == nil {
                out.append(nil)
            } else {
                out.append((x ?? 0) + (y ?? 0))
            }
        }
        return out
    }

    private static func busyContext(_ u: Double, _ s: Snapshot) -> String {
        if s.cores.split, !s.cores.p.isEmpty, !s.cores.e.isEmpty {
            let p = s.cores.p.reduce(0, +) / Float(s.cores.p.count)
            let e = s.cores.e.reduce(0, +) / Float(s.cores.e.count)
            return "fast \(Int(p))% · efficient \(Int(e))%"
        }
        return u < 20 ? "mostly idle" : (u < 60 ? "moderately busy" : "very busy")
    }

    private static func topAppContext(_ s: Snapshot) -> String {
        guard let a = s.topApp else { return "no app stands out" }
        if let w = a.energyW { return "\(a.name) \(Fmt.watts(w))" }
        return "\(a.name) leads"
    }
}
