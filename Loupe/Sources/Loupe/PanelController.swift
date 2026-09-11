// The NSPanel that hosts the SwiftUI content: floating, non-activating,
// pinnable, anchored under the status item, dismissed on outside click.

import AppKit
import Combine
import SwiftUI

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class PanelContext: ObservableObject {
    weak var controller: PanelController?
    var window: NSWindow? { controller?.panel }
    func close() { controller?.hide() }
    func select(tab: Int) { Prefs.shared.selectedTab = tab }
}

@MainActor
final class PanelController {
    let panel: KeyPanel
    private var hosting: NSHostingView<AnyView>!
    private let context = PanelContext()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var anchor: NSRect?
    private var sinks: [AnyCancellable] = []
    /// Where the status item is; used when show() is called without a button (reopen, menu).
    var anchorProvider: (() -> NSRect?)?
    /// Set once the user drags the panel; resizes then keep the dragged position until it closes.
    private var userMoved = false
    private var settingFrame = false
    static let width: CGFloat = 400

    init() {
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelController.width, height: 320),
            styleMask: [.nonactivatingPanel, .utilityWindow, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.setAccessibilityLabel("Loupe panel")

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        panel.contentView = effect

        context.controller = self
        // A near-solid backing over the blur: readable on any wallpaper, still a hint of depth.
        let root = RootView().background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
            .environmentObject(Engine.shared)
            .environmentObject(Prefs.shared)
            .environmentObject(Config.shared)
            .environmentObject(AppHistory.shared)
            .environmentObject(context)
        hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.onCancel = { [weak self] in self?.hide() }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            let controller = self
            Task { @MainActor in
                guard let controller, !controller.settingFrame, controller.panel.isVisible else { return }
                controller.userMoved = true
            }
        }
        // Content height follows the data: refit after every snapshot and any preference change.
        sinks.append(Engine.shared.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.fit() })
        sinks.append(Prefs.shared.objectWillChange.receive(on: DispatchQueue.main).sink(receiveValue: { [weak self] (_: Void) in
            DispatchQueue.main.async { self?.fit() }
        }))
        sinks.append(Config.shared.objectWillChange.receive(on: DispatchQueue.main).sink(receiveValue: { [weak self] (_: Void) in
            DispatchQueue.main.async { self?.fit() }
        }))
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(relativeTo button: NSStatusBarButton? = nil) {
        if isVisible { hide() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton? = nil) {
        if let b = button, let w = b.window {
            anchor = w.convertToScreen(b.convert(b.bounds, to: nil))
        } else if let a = anchorProvider?() {
            anchor = a
        }
        userMoved = false
        place(height: panel.frame.height)
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
        Engine.shared.panelOpen = true
        fit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fit() }
    }

    func hide() {
        panel.orderOut(nil)
        removeMonitors()
        Engine.shared.panelOpen = false
    }

    /// Height follows the SwiftUI ideal size up to 70% of the screen; the top edge stays put.
    private func fit() {
        guard panel.isVisible else { return }
        let ideal = hosting.fittingSize.height
        guard ideal > 0 else { return }
        let screen = panel.screen ?? NSScreen.main
        let cap = (screen?.visibleFrame.height ?? 900) * 0.7
        let height = min(ideal, cap)
        if ProcessInfo.processInfo.environment["LOUPE_DEBUG"] == "1" { NSLog("fit: ideal %.0f pt -> height %.0f pt", ideal, height) }
        if abs(panel.frame.height - height) > 0.5 { place(height: height) }
    }

    private func place(height: CGFloat) {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.contains(NSPoint(x: a.midX, y: a.midY)) } } ?? panel.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var origin: NSPoint
        if let a = anchor, !userMoved {
            origin = NSPoint(x: a.midX - PanelController.width / 2, y: a.minY - height - 6)
        } else {
            // Keep the top-left corner where the user put it; only the height changes.
            origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - height)
        }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - PanelController.width - 8)
        origin.y = max(origin.y, vf.minY + 8)
        settingFrame = true
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: PanelController.width, height: height)), display: true)
        settingFrame = false
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !Prefs.shared.pinned else { return }
                self.hide()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.window == self.panel {
                if event.modifierFlags.contains(.command), let n = Int(event.charactersIgnoringModifiers ?? ""), (1...4).contains(n) {
                    Prefs.shared.selectedTab = n - 1
                    return nil
                }
                if event.keyCode == 53 { self.hide(); return nil }
                return event
            }
            if event.type != .keyDown, event.window != self.panel, !Prefs.shared.pinned {
                self.hide()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }
}
