// ~/.config/loupe/panels.toml: read, watched, parsed by sysmon-core, written on user action only.

import Foundation
import Combine
import CSysmon
import AppKit

struct Panel: Codable, Equatable, Identifiable {
    var id = UUID()
    var metric: String
    var group: String
    var sort: String = "desc"
    var count: Int = 5
    var chart: String = "sparkline"
    var label: String?

    enum CodingKeys: String, CodingKey { case metric, group, sort, count, chart, label }

    var title: String {
        if let l = label, !l.isEmpty { return l }
        return Metric(rawValue: metric)?.title ?? metric
    }
}

enum Metric: String, CaseIterable {
    case cpu, memory, energy, disk, network, power, battery, thermal, disk_io
    var title: String {
        switch self {
        case .cpu: return "Processor"
        case .memory: return "Memory"
        case .energy: return "Energy"
        case .disk: return "Disk space"
        case .network: return "Network"
        case .power: return "Power"
        case .battery: return "Battery"
        case .thermal: return "Temperature"
        case .disk_io: return "Disk activity"
        }
    }
    var technical: String {
        switch self {
        case .cpu: return "cpu.usage, all cores"
        case .memory: return "memory.pressure via memory_pressure; used_percent is secondary"
        case .energy: return "ri_energy_nj delta per second, or weighted impact score"
        case .disk: return "disks[0].used_percent (statfs)"
        case .network: return "sum of rx_rate_mbs + tx_rate_mbs over interfaces"
        case .power: return "thermal.system_power (W)"
        case .battery: return "batteries[0]"
        case .thermal: return "thermal.cpu_temp (°C)"
        case .disk_io: return "disk_io.read_rate + write_rate (MB/s)"
        }
    }
}

@MainActor
final class Config: ObservableObject {
    static let shared = Config()
    static let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/loupe", isDirectory: true)
    static let fileURL = dir.appendingPathComponent("panels.toml")

    @Published private(set) var panels: [Panel] = []
    @Published private(set) var error: String?
    @Published private(set) var errorLine: Int?
    @Published private(set) var usingDefaults = true
    private(set) var defaultToml = ""
    private var watcher: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    private struct Parsed: Codable {
        var panels: [Panel]
        var error: String?
        var line: Int?
        var defaultToml: String
    }

    private init() {
        load()
        watch()
    }

    var systemPanels: [Panel] { panels.filter { $0.group == "system" } }
    var appPanels: [Panel] { panels.filter { $0.group != "system" } }

    private func parse(_ text: String?) -> Parsed? {
        let raw: UnsafeMutablePointer<CChar>? = text == nil ? sysmon_panels_json(nil) : text!.withCString { sysmon_panels_json($0) }
        guard let raw else { return nil }
        defer { sysmon_free(raw) }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(Parsed.self, from: Data(bytes: raw, count: strlen(raw)))
    }

    func load() {
        let text = try? String(contentsOf: Config.fileURL, encoding: .utf8)
        guard let parsed = parse(text) else { return }
        defaultToml = parsed.defaultToml
        if let err = parsed.error {
            error = err
            errorLine = parsed.line
            usingDefaults = true
            if let fallback = parse(nil) { panels = fallback.panels }
        } else {
            error = nil
            errorLine = nil
            usingDefaults = text == nil
            panels = parsed.panels
        }
    }

    /// Writes the user's panel list. The only path that writes the file besides "Edit as text".
    func save(_ list: [Panel]) {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        try? toml(for: list).write(to: Config.fileURL, atomically: true, encoding: .utf8)
        load()
        watch()
    }

    func openInEditor() {
        if !FileManager.default.fileExists(atPath: Config.fileURL.path) {
            try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
            try? defaultToml.write(to: Config.fileURL, atomically: true, encoding: .utf8)
            watch()
        }
        NSWorkspace.shared.open(Config.fileURL)
    }

    func toml(for list: [Panel]) -> String {
        var out = "# Loupe panels. See the defaults for the field reference.\n"
        for p in list {
            out += "\n[[panel]]\nmetric = \"\(p.metric)\"\ngroup  = \"\(p.group)\"\nsort   = \"\(p.sort)\"\ncount  = \(p.count)\nchart  = \"\(p.chart)\"\n"
            if let l = p.label, !l.isEmpty { out += "label  = \"\(l.replacingOccurrences(of: "\"", with: "\\\""))\"\n" }
        }
        return out
    }

    // Editors replace the file (rename), so the watch re-arms whenever the descriptor goes away.
    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = open(Config.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.load()
                if ev.contains(.delete) || ev.contains(.rename) { self?.watch() }
            }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
}
