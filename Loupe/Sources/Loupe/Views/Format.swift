import AppKit
import SwiftUI

enum Fmt {
    static func bytes(_ b: UInt64) -> String { bytes(Double(b)) }
    static func bytes(_ b: Double) -> String {
        let gb = b / 1_073_741_824
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = b / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", b / 1024)
    }
    static func pct(_ v: Double, decimals: Int = 0) -> String { String(format: "%.\(decimals)f%%", v) }
    static func watts(_ w: Float) -> String {
        if w >= 1 { return String(format: "%.2f W", w) }
        return String(format: "%.0f mW", w * 1000)
    }
    static func rate(_ mbs: Double) -> String {
        if mbs >= 1 { return String(format: "%.1f MB/s", mbs) }
        return String(format: "%.0f KB/s", mbs * 1024)
    }
    static func duration(_ secs: UInt64) -> String {
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d) day\(d == 1 ? "" : "s") \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }
    static func age(_ ms: UInt64) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s) second\(s == 1 ? "" : "s")" }
        if s < 3600 { return "\(s / 60) minute\(s / 60 == 1 ? "" : "s")" }
        return "\(s / 3600) hour\(s / 3600 == 1 ? "" : "s")"
    }
}

enum State3 { case ok, warn, crit
    var word: String { switch self { case .ok: return "fine"; case .warn: return "worth a look"; case .crit: return "needs action" } }
}

enum Palette {
    /// Chart colours, fixed order, never cycled: blue, aqua, violet, magenta, green. Validated for
    /// colour-vision separation on both panel surfaces; amber and red stay reserved for alarms.
    private static let light: [Color] = [Color(hex: 0x2a78d6), Color(hex: 0x1baf7a), Color(hex: 0x4a3aa7), Color(hex: 0xe87ba4), Color(hex: 0x008300)]
    private static let dark: [Color] = [Color(hex: 0x3987e5), Color(hex: 0x199e70), Color(hex: 0x9085e9), Color(hex: 0xd55181), Color(hex: 0x008300)]
    static let slots = 5
    static func series(_ slot: Int?, _ scheme: ColorScheme) -> Color {
        guard let slot, slot >= 0, slot < slots else { return Color.primary.opacity(0.35) }
        return scheme == .dark ? dark[slot] : light[slot]
    }
    /// Colour follows the metric, so the same reading has the same hue everywhere.
    static func slot(for metric: Metric) -> Int {
        switch metric {
        case .cpu: return 0
        case .disk, .disk_io: return 1
        case .memory: return 2
        case .energy, .power, .thermal: return 3
        case .network, .battery: return 4
        }
    }
    static var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var warn: Color { highContrast ? Color(red: 0.95, green: 0.50, blue: 0.0) : Color(red: 0.86, green: 0.58, blue: 0.10) }
    static var crit: Color { highContrast ? Color(red: 0.90, green: 0.05, blue: 0.05) : Color(red: 0.84, green: 0.22, blue: 0.20) }
    static func color(_ s: State3) -> Color { switch s { case .ok: return Color.primary.opacity(0.45); case .warn: return warn; case .crit: return crit } }
    static func state(for band: String) -> State3 { switch band { case "busy": return .warn; case "strained": return .crit; default: return .ok } }
    static func alarm(for band: String) -> NSColor? {
        switch band {
        case "busy": return NSColor(warn)
        case "strained": return NSColor(crit)
        default: return nil
        }
    }
    static func level(_ v: Double, warn: Double, crit: Double) -> State3 {
        if warn <= crit { return v > crit ? .crit : (v > warn ? .warn : .ok) }
        return v < crit ? .crit : (v < warn ? .warn : .ok)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

enum Trend { case up, down, flat
    var symbol: String { switch self { case .up: return "arrow.up.right"; case .down: return "arrow.down.right"; case .flat: return "arrow.right" } }
    var word: String { switch self { case .up: return "climbing"; case .down: return "falling"; case .flat: return "steady" } }
    /// Last value against the value about 30 samples back, with a 5% of range dead band.
    static func of(_ s: [Float?], back: Int = 15) -> Trend {
        let vals = s.compactMap { $0 }
        guard let last = s.last ?? nil, vals.count > 3 else { return .flat }
        let idx = max(0, s.count - 1 - back)
        guard let prev = s[idx...].first(where: { $0 != nil }) ?? nil else { return .flat }
        let range = max((vals.max() ?? 0) - (vals.min() ?? 0), 1)
        let d = last - prev
        if abs(d) < range * 0.08 { return .flat }
        return d > 0 ? .up : .down
    }
}

/// The dot that means "checked": grey when fine, amber or red with a shape cue when not.
struct StateDot: View {
    var state: State3
    var body: some View {
        Group {
            if state == .ok || !Palette.highContrast {
                Circle().fill(Palette.color(state)).frame(width: 8, height: 8)
            } else {
                Image(systemName: state == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 9)).foregroundStyle(Palette.color(state))
            }
        }
        .accessibilityLabel(state.word)
    }
}

struct TrendGlyph: View {
    var trend: Trend
    var body: some View {
        Image(systemName: trend.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            .accessibilityLabel(trend.word)
    }
}

enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for app: App) -> NSImage {
        if let i = cache[app.path] { return i }
        let img: NSImage
        if app.kind == "app", !app.path.isEmpty {
            img = NSWorkspace.shared.icon(forFile: app.path)
        } else {
            img = NSImage(systemSymbolName: app.kind == "system" ? "gearshape" : "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        img.size = NSSize(width: 16, height: 16)
        cache[app.path] = img
        return img
    }
}
