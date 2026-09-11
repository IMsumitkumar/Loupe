// The menu bar item. Its width is fixed per display mode and never follows
// content; every mode draws into an NSImage of exactly that size.

import AppKit
import Combine

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let panel: PanelController
    private let menu = NSMenu()
    private var sinks: [AnyCancellable] = []

    init(panel: PanelController) {
        self.panel = panel
        item = NSStatusBar.system.statusItem(withLength: Prefs.shared.menuMode.width)
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel("Loupe")
        }
        buildMenu()
        sinks.append(Engine.shared.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.redraw() })
        sinks.append(Prefs.shared.objectWillChange.receive(on: DispatchQueue.main).sink(receiveValue: { [weak self] (_: Void) in
            DispatchQueue.main.async { self?.redraw() }
        }))
        redraw()
    }

    /// Rebuilt on every right-click so Mole entries appear only while Mole is installed.
    private func buildMenu() {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }
        add("Open Panel", #selector(openPanel))
        add("Settings…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        if Engine.shared.moPath != nil {
            add("Run Mole Clean", #selector(runClean))
            add("Run Mole Analyze", #selector(runAnalyze))
            add("Check for Mole Update", #selector(checkUpdate))
        } else {
            add("Install Mole (copies brew command)", #selector(copyInstall))
            add("Recheck for Mole", #selector(recheck))
        }
        menu.addItem(.separator())
        add("Quit Loupe", #selector(quit), key: "q")
    }

    /// Screen rect of the status item, for anchoring the panel when opened without a click.
    var anchorRect: NSRect? {
        guard let b = item.button, let w = b.window else { return nil }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            buildMenu()
            item.menu = menu
            item.button?.performClick(nil)
            DispatchQueue.main.async { self.item.menu = nil }
        } else {
            panel.toggle(relativeTo: item.button)
        }
    }

    @objc private func openPanel() { panel.show(relativeTo: item.button) }
    @objc private func openSettings() { Actions.openSettings() }
    @objc private func runClean() { MoleAdapter.openInTerminal(["clean", "--dry-run"]) }
    @objc private func runAnalyze() { MoleAdapter.openInTerminal(["analyze"]) }
    @objc private func checkUpdate() { MoleAdapter.openInTerminal(["--version"]); Engine.shared.recheckMole() }
    @objc private func copyInstall() { Actions.copy(MoleAdapter.installCommand) }
    @objc private func recheck() { Engine.shared.recheckMole() }
    @objc private func quit() { NSApp.terminate(nil) }

    func redraw() {
        let mode = Prefs.shared.menuMode
        item.length = mode.width
        let snap = Engine.shared.snapshot
        item.button?.image = MenuImage.render(mode: mode, metric: Prefs.shared.menuMetric, snapshot: snap)
        let head = snap?.verdict.headline ?? "Starting"
        item.button?.setAccessibilityValue(head)
        item.button?.toolTip = head
    }
}

enum MenuImage {
    static let height: CGFloat = 22

    static func render(mode: MenuMode, metric: MenuMetric, snapshot: Snapshot?) -> NSImage {
        let band = snapshot?.verdict.band ?? "calm"
        let score = snapshot?.verdict.score ?? 0
        let alarm = Palette.alarm(for: band)
        let size = NSSize(width: mode.width, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let color: NSColor = alarm ?? .black
            color.set()
            switch mode {
            case .glyph:
                drawGlyph(in: NSRect(x: (rect.width - 16) / 2, y: 3, width: 16, height: 16), score: score)
            case .sparkline:
                drawHeartbeat(in: rect.insetBy(dx: 3, dy: 4), values: series(metric, snapshot), band: band)
            case .number:
                drawNumber(in: rect, text: numberText(metric, snapshot), color: color)
            case .compact:
                drawGlyph(in: NSRect(x: 3, y: 3, width: 16, height: 16), score: score)
                drawNumber(in: NSRect(x: 20, y: 0, width: rect.width - 22, height: rect.height), text: numberText(metric, snapshot), color: color)
            }
            return true
        }
        // The heartbeat is always coloured; the other modes stay template until an alarm.
        image.isTemplate = alarm == nil && mode != .sparkline
        image.accessibilityDescription = snapshot?.verdict.headline
        return image
    }

    static let pulse = NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.16, alpha: 1)

    /// An orange pulse of the last minute; red once the Mac is strained. A flat trace means no data yet.
    static func drawHeartbeat(in r: NSRect, values: [Float?], band: String) {
        let color = band == "strained" ? (Palette.alarm(for: band) ?? pulse) : pulse
        color.withAlphaComponent(0.35).set()
        let base = NSBezierPath()
        base.lineWidth = 1
        base.move(to: NSPoint(x: r.minX, y: r.minY + 0.5))
        base.line(to: NSPoint(x: r.maxX, y: r.minY + 0.5))
        base.stroke()
        color.set()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        let vals = values.isEmpty ? [Float?](repeating: 0, count: 2) : values
        // Scale to at least 35% so idle wiggles still read as a pulse, and bursts spike.
        let top = max(vals.compactMap { $0 }.max() ?? 1, 35)
        var pen = false
        for (i, v) in vals.enumerated() {
            let x = r.minX + r.width * CGFloat(i) / CGFloat(max(vals.count - 1, 1))
            let y = r.minY + 1 + (r.height - 2) * CGFloat(min(v ?? 0, top) / top)
            if pen && v != nil { path.line(to: NSPoint(x: x, y: y)) } else { path.move(to: NSPoint(x: x, y: y)) }
            pen = v != nil
        }
        path.stroke()
    }

    /// Heartbeat preview for onboarding.
    static func heartbeat(values: [Float?], band: String, width: CGFloat = 96, height: CGFloat = 28) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            drawHeartbeat(in: rect.insetBy(dx: 2, dy: 3), values: values, band: band)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func series(_ metric: MenuMetric, _ s: Snapshot?) -> [Float?] {
        guard let s else { return [] }
        let h = metric == .memory ? s.history.memUsedPct : s.history.cpu
        return Array(h.suffix(60))
    }

    private static func numberText(_ metric: MenuMetric, _ s: Snapshot?) -> String {
        guard let s else { return "---" }
        let v: Double? = switch metric {
        case .pressure: s.verdict.score.map(Double.init)
        case .cpu: s.cpuUsage
        case .memory: s.memUsedPct
        }
        guard let v else { return "---" }
        return String(format: "%03d", Int(v.rounded()))
    }

    /// A loupe: the lens fills from the bottom as pressure rises, the handle points down-right.
    static func drawGlyph(in r: NSRect, score: Int) {
        let lens = NSRect(x: r.minX + 0.75, y: r.minY + r.height * 0.28, width: r.width * 0.68, height: r.width * 0.68)
        let ring = NSBezierPath(ovalIn: lens)
        ring.lineWidth = 1.6
        ring.stroke()
        let level = CGFloat(min(max(score, 0), 100)) / 100
        if level > 0.02 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: lens.insetBy(dx: 1.4, dy: 1.4)).addClip()
            NSBezierPath(rect: NSRect(x: lens.minX, y: lens.minY, width: lens.width, height: lens.height * level)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let handle = NSBezierPath()
        handle.lineWidth = 2.2
        handle.lineCapStyle = .round
        let start = NSPoint(x: lens.maxX - lens.width * 0.16, y: lens.minY + lens.height * 0.16)
        handle.move(to: start)
        handle.line(to: NSPoint(x: r.maxX - 1.2, y: r.minY + 1.2))
        handle.stroke()
    }

    /// The glyph alone, for previews.
    static func glyph(score: Int, band: String, size: CGFloat = 16) -> NSImage {
        let alarm = Palette.alarm(for: band)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            (alarm ?? .labelColor).set()
            drawGlyph(in: rect, score: score)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawNumber(in r: NSRect, text: String, color: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = NSAttributedString(string: text + "%", attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }
}
