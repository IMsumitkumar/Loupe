// User settings, all in UserDefaults. Written on user action only.

import Foundation
import Combine
import ServiceManagement

enum MenuMode: String, CaseIterable, Identifiable {
    case glyph, sparkline, number, compact
    var id: String { rawValue }
    var label: String {
        switch self {
        case .glyph: return "Loupe glyph"
        case .sparkline: return "Heartbeat line"
        case .number: return "Number"
        case .compact: return "Glyph and number"
        }
    }
    var width: CGFloat {
        switch self {
        case .glyph: return 24
        case .sparkline: return 48
        case .number: return 44
        case .compact: return 60
        }
    }
}

enum MenuMetric: String, CaseIterable, Identifiable {
    case pressure, cpu, memory
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pressure: return "Pressure"
        case .cpu: return "Processor"
        case .memory: return "Memory"
        }
    }
}

struct Thresholds: Equatable {
    var cpuWarn = 50.0, cpuCrit = 85.0
    var memWarn = 70.0, memCrit = 88.0
    var diskWarn = 80.0, diskCrit = 93.0
    var thermalWarn = 65.0, thermalCrit = 85.0
    var ioWarn = 50.0, ioCrit = 150.0
    var batteryCapWarn = 80.0, batteryCapCrit = 60.0
    var cyclesWarn = 800.0, cyclesCrit = 900.0
}

struct Weights: Equatable {
    var cpu = 1.0, wakeups = 0.4, disk = 0.05
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var menuMode: MenuMode { didSet { d.set(menuMode.rawValue, forKey: "menuMode") } }
    @Published var menuMetric: MenuMetric { didSet { d.set(menuMetric.rawValue, forKey: "menuMetric") } }
    @Published var intervalOpen: Int { didSet { d.set(intervalOpen, forKey: "intervalOpen") } }
    @Published var intervalClosed: Int { didSet { d.set(intervalClosed, forKey: "intervalClosed") } }
    @Published var thresholds: Thresholds { didSet { saveThresholds() } }
    @Published var weights: Weights { didSet { saveWeights() } }
    @Published var excluded: [String] { didSet { d.set(excluded, forKey: "excludedApps") } }
    @Published var firstRunDone: Bool { didSet { d.set(firstRunDone, forKey: "firstRunDone") } }
    @Published var selectedTab: Int { didSet { d.set(selectedTab, forKey: "selectedTab") } }
    @Published var pinned: Bool { didSet { d.set(pinned, forKey: "pinned") } }

    // Open: engine tick and Mole stream interval. Closed: Swift poll interval while Mole is off (notes/q5-cadence.md).
    static let defaultOpen = 2
    static let defaultClosed = 10

    private init() {
        let d = UserDefaults.standard
        menuMode = MenuMode(rawValue: d.string(forKey: "menuMode") ?? "") ?? .sparkline
        menuMetric = MenuMetric(rawValue: d.string(forKey: "menuMetric") ?? "") ?? .pressure
        intervalOpen = d.object(forKey: "intervalOpen") as? Int ?? Prefs.defaultOpen
        intervalClosed = d.object(forKey: "intervalClosed") as? Int ?? Prefs.defaultClosed
        excluded = d.stringArray(forKey: "excludedApps") ?? []
        firstRunDone = d.bool(forKey: "firstRunDone")
        selectedTab = d.integer(forKey: "selectedTab")
        pinned = d.bool(forKey: "pinned")
        var t = Thresholds()
        func g(_ k: String, _ v: inout Double) { if let x = d.object(forKey: "th.\(k)") as? Double { v = x } }
        g("cpuWarn", &t.cpuWarn); g("cpuCrit", &t.cpuCrit); g("memWarn", &t.memWarn); g("memCrit", &t.memCrit)
        g("diskWarn", &t.diskWarn); g("diskCrit", &t.diskCrit); g("thermalWarn", &t.thermalWarn); g("thermalCrit", &t.thermalCrit)
        g("ioWarn", &t.ioWarn); g("ioCrit", &t.ioCrit); g("batteryCapWarn", &t.batteryCapWarn); g("batteryCapCrit", &t.batteryCapCrit)
        g("cyclesWarn", &t.cyclesWarn); g("cyclesCrit", &t.cyclesCrit)
        thresholds = t
        var w = Weights()
        g("w.cpu", &w.cpu); g("w.wakeups", &w.wakeups); g("w.disk", &w.disk)
        weights = w
    }

    private func saveThresholds() {
        let t = thresholds
        let pairs: [(String, Double)] = [
            ("cpuWarn", t.cpuWarn), ("cpuCrit", t.cpuCrit), ("memWarn", t.memWarn), ("memCrit", t.memCrit),
            ("diskWarn", t.diskWarn), ("diskCrit", t.diskCrit), ("thermalWarn", t.thermalWarn), ("thermalCrit", t.thermalCrit),
            ("ioWarn", t.ioWarn), ("ioCrit", t.ioCrit), ("batteryCapWarn", t.batteryCapWarn), ("batteryCapCrit", t.batteryCapCrit),
            ("cyclesWarn", t.cyclesWarn), ("cyclesCrit", t.cyclesCrit),
        ]
        for (k, v) in pairs { d.set(v, forKey: "th.\(k)") }
    }

    private func saveWeights() {
        d.set(weights.cpu, forKey: "th.w.cpu"); d.set(weights.wakeups, forKey: "th.w.wakeups"); d.set(weights.disk, forKey: "th.w.disk")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSLog("launch at login: \(error)") }
            objectWillChange.send()
        }
    }
}
