// Polls sysmon-core on a coalesced timer, owns the one-bit cadence state
// (Mole streams only while the panel is open) and the sleep/wake hooks.
// No callbacks cross the FFI: Swift pulls.

import AppKit
import Combine
import CSysmon
import IOKit.ps

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var moPath: String?
    @Published private(set) var moVersion: String?
    @Published private(set) var running = false

    var panelOpen = false { didSet { if panelOpen != oldValue { panelChanged() } } }

    private var timer: DispatchSourceTimer?
    private var streamDebounce: DispatchWorkItem?
    private var streaming = false
    private var observers: [NSObjectProtocol] = []
    private var prefsSink: AnyCancellable?

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let engine = self
                Task { @MainActor in engine?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let engine = self
                Task { @MainActor in engine?.resume() }
            })
        }
        prefsSink = Prefs.shared.objectWillChange.receive(on: DispatchQueue.main).sink(receiveValue: { [weak self] (_: Void) in
            DispatchQueue.main.async { self?.applyConfig() }
        })
    }

    // MARK: lifecycle

    func start() {
        recheckMole()
        streaming = panelOpen
        _ = sysmon_start(configJSON())
        running = true
        startTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        streamDebounce?.cancel()
        sysmon_stop()
        running = false
    }

    private func suspend() {
        guard running else { return }
        stop()
    }

    private func resume() {
        guard !running else { return }
        // A fresh engine has empty ring buffers, so the sleep gap never draws as a line.
        start()
    }

    func recheckMole() {
        moPath = MoleAdapter.locate()
        moVersion = moPath.flatMap { MoleAdapter.version(at: $0) }
        if running { applyConfig() }
    }

    var moleBelowFloor: Bool { moVersion.map(MoleAdapter.isBelowFloor) ?? false }

    /// Re-sends the config; the core restarts the child only when the interval, path or stream bit changed.
    func applyConfig() {
        guard running else { return }
        _ = sysmon_start(configJSON())
        startTimer()
    }

    /// The engine tick and, while open, the Mole stream interval.
    private func tickInterval() -> Int { max(1, Prefs.shared.intervalOpen) }

    /// Swift's poll rate: every tick while open; the closed interval, doubled on battery, while closed.
    private func pollInterval() -> Int {
        if panelOpen { return tickInterval() }
        let closed = Prefs.shared.intervalClosed * (Engine.onBattery() ? 2 : 1)
        return max(tickInterval(), closed)
    }

    private func configJSON() -> String {
        let w = Prefs.shared.weights
        var dict: [String: Any] = [
            "interval_secs": tickInterval(),
            "stream": streaming,
            "weights": ["cpu": w.cpu, "wakeups": w.wakeups, "disk": w.disk],
        ]
        if let p = moPath { dict["mo_path"] = p }
        if let v = moVersion { dict["mo_version"] = v }
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: cadence

    static func onBattery() -> Bool {
        IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited
    }

    /// Opening starts the stream at once; closing stops it after a 3 s debounce so a quick
    /// peek does not pay Mole's 1.3 s startup twice.
    private func panelChanged() {
        streamDebounce?.cancel()
        guard running else { return }
        if panelOpen {
            streaming = true
            applyConfig()
            poll()
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.running, !self.panelOpen else { return }
                self.streaming = false
                self.applyConfig()
            }
            streamDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            startTimer()
        }
    }

    private func startTimer() {
        timer?.cancel()
        let interval = pollInterval()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(400), repeating: .seconds(interval), leeway: .milliseconds(interval * 200))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // MARK: polling

    func poll() {
        guard let raw = sysmon_snapshot_json() else { return }
        defer { sysmon_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        guard let snap = try? Snapshot.decoder.decode(Snapshot.self, from: data) else { return }
        lastUpdate = Date()
        if ProcessInfo.processInfo.environment["LOUPE_DEBUG"] == "1" {
            let m = snap.moleStatus
            let st = snap.selfStats
            NSLog("seq=%llu state=%@ live=%d path=%@ child=%d lines=%llu errs=%llu stream=%d apps=%d bytes=%d selfcpu=%@ rss=%@ tick=%.1fms avg=%.2f%%",
                  snap.seq, m.state, m.live ? 1 : 0, m.path ?? "nil", m.childPid ?? 0, m.lines, m.decodeErrors, streaming ? 1 : 0,
                  snap.apps.count, st.snapshotBytes, st.cpu.map { String($0) } ?? "-", st.memory.map { String($0 / 1_048_576) } ?? "-", st.tickMs, st.avgCpuSinceLaunch)
        }
        if snap != snapshot { snapshot = snap }
        if panelOpen { AppHistory.shared.record(snap) }
    }
}

/// Per-app 60-sample micro-history for the Apps rows, kept on the Swift side
/// because the core only ships history for the top app.
@MainActor
final class AppHistory: ObservableObject {
    static let shared = AppHistory()
    @Published private(set) var series: [String: [Float?]] = [:]
    private let capacity = 60
    private var slots: [String: Int] = [:]

    /// A palette slot that sticks to the app while it stays on screen; nil beyond five apps.
    func slot(for key: String, shown: [String]) -> Int? {
        if let s = slots[key] { return s }
        for (k, _) in slots where !shown.contains(k) { slots.removeValue(forKey: k) }
        let used = Set(slots.values)
        guard let free = (0..<Palette.slots).first(where: { !used.contains($0) }) else { return nil }
        slots[key] = free
        return free
    }

    func record(_ s: Snapshot) {
        var next: [String: [Float?]] = [:]
        for a in s.apps {
            var v = series[a.key] ?? []
            v.append(s.energyMode == "energy" ? a.energyW : a.impact)
            if v.count > capacity { v.removeFirst(v.count - capacity) }
            next[a.key] = v
        }
        series = next
    }
}
