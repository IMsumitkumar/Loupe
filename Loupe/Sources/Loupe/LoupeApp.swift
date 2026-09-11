import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var delegate: AppDelegate?
    private var statusItem: StatusItemController?
    private var panel: PanelController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One glyph per Mac: a second launch hands over to the running copy.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.loupe.app")
            .filter { $0.processIdentifier != me }
        if !others.isEmpty && ProcessInfo.processInfo.environment["LOUPE_RENDER"] == nil {
            NSApp.terminate(nil)
            return
        }
        let panel = PanelController()
        self.panel = panel
        let status = StatusItemController(panel: panel)
        statusItem = status
        panel.anchorProvider = { [weak status] in status?.anchorRect }
        Engine.shared.start()
        if ProcessInfo.processInfo.environment["LOUPE_OPEN_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { panel.show() }
        }
        // Offscreen renders of every tab for inspection and snapshot tests: LOUPE_RENDER=<dir>.
        if let dir = ProcessInfo.processInfo.environment["LOUPE_RENDER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { Render.allTabs(to: dir); NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Engine.shared.stop()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return false
    }
}

/// The Settings window, plain AppKit so it opens from the footer, the status menu and ⌘, alike.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(Engine.shared)
                .environmentObject(Prefs.shared)
                .environmentObject(Config.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Loupe Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum Actions {
    static func openSettings() {
        SettingsWindow.shared.show()
    }

    /// SIGTERM to the app's main process; a bundle app gets AppKit's polite terminate first.
    static func quit(_ app: App) {
        if app.kind == "app", let running = NSRunningApplication(processIdentifier: app.rootPid), running.terminate() {
            return
        }
        for c in app.children { kill(c.pid, SIGTERM) }
    }

    static func quit(pid: Int32) {
        kill(pid, SIGTERM)
    }

    /// SIGKILL after a confirmation sheet naming the app.
    static func forceQuit(name: String, pids: [Int32], in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Force Quit \(name)?"
        alert.informativeText = "Unsaved work in \(name) will be lost. This sends a kill signal that the app cannot refuse."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        let act = {
            for p in pids { kill(p, SIGKILL) }
        }
        if let window {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { act() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            act()
        }
    }

    static func reveal(path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


@MainActor
enum Render {
    /// Renders the panel content at 400 pt for each tab, light and dark, to PNG files.
    static func allTabs(to dir: String, snapshot: Snapshot? = nil) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Prefs.shared.firstRunDone = true
        let names = ["overview", "apps", "storage", "health"]
        for (i, name) in names.enumerated() {
            Prefs.shared.selectedTab = i
            for scheme in [ColorScheme.light, .dark] {
                let view = VStack(spacing: 0) { VerdictView(); Divider(); TabBodyView(tab: i).padding(.top, 8); Divider(); FooterView() }
                    .frame(width: PanelController.width)
                    .environmentObject(Engine.shared)
                    .environmentObject(Prefs.shared)
                    .environmentObject(Config.shared)
                    .environmentObject(AppHistory.shared)
                    .environmentObject(PanelContext())
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let cg = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
