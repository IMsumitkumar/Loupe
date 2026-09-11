// Everything Swift knows about Mole: where the binary is, its version, the
// analyze call, and the terminal hand-off. The Rust supervisor owns the
// `status --watch` stream (sysmon-core/src/supervisor.rs).

import AppKit
import Foundation

enum MoleAdapter {
    /// The version this build was synced against; older versions get a non-blocking update banner.
    static let versionFloor = "1.53.0"
    static let installCommand = "brew install mole"
    static let repoURL = URL(string: "https://github.com/tw93/Mole")!

    /// Search order from spec 5.6. A Finder-launched app has a minimal PATH, hence the fixed fallbacks.
    static func locate() -> String? {
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/mo" }
        candidates += ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", NSHomeDirectory() + "/.local/bin/mo"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func version(at path: String) -> String? {
        guard let out = run(path, ["--version"], timeout: 5) else { return nil }
        // "Mole version 1.53.0\nmacOS: 26.5.1"
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if let i = parts.firstIndex(of: "version"), i + 1 < parts.count { return String(parts[i + 1]) }
        }
        return nil
    }

    static func isBelowFloor(_ version: String) -> Bool {
        let a = version.split(separator: ".").compactMap { Int($0) }
        let b = versionFloor.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    struct Analysis: Codable {
        struct Entry: Codable, Identifiable {
            var id: String { path }
            var name: String, path: String, size: Int64, isDir: Bool
            var insight: Bool?, cleanable: Bool?, lastAccess: String?
        }
        struct FileEntry: Codable, Identifiable {
            var id: String { path }
            var name: String, path: String, size: Int64
        }
        var path: String
        var overview: Bool
        var entries: [Entry]
        var largeFiles: [FileEntry]?
        var totalSize: Int64
        var totalFiles: Int64?
    }

    /// `mo analyze --json [path]`, on demand only. Walks the filesystem; never call it on a timer.
    static func analyze(path: String?, completion: @escaping (Result<Analysis, Error>) -> Void) {
        guard let mo = locate() else {
            completion(.failure(NSError(domain: "Loupe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mole is not installed"])))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var args = ["analyze", "--json"]
            if let p = path { args.append(p) }
            guard let out = run(mo, args, timeout: 600) else {
                DispatchQueue.main.async { completion(.failure(NSError(domain: "Loupe", code: 2, userInfo: [NSLocalizedDescriptionKey: "mo analyze produced no output"]))) }
                return
            }
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            let result = Result { try d.decode(Analysis.self, from: Data(out.utf8)) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Destructive commands run in the user's terminal so Mole shows its own confirmations.
    /// Writes a .command file and opens it with MO_LAUNCHER_APP or Terminal; no Apple Events, so
    /// no automation entitlement is needed under the hardened runtime.
    static func openInTerminal(_ subcommand: [String]) {
        guard let mo = locate() else { return }
        let quoted = ([mo] + subcommand).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Loupe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("mo-\(subcommand.first ?? "run").command")
        let script = "#!/bin/zsh\nclear\nexec \(quoted)\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let app = ProcessInfo.processInfo.environment["MO_LAUNCHER_APP"] ?? "Terminal"
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId(for: app)) ?? appURL(named: app) {
            NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: cfg) { _, _ in }
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    private static func bundleId(for app: String) -> String {
        switch app.lowercased() {
        case "iterm", "iterm2": return "com.googlecode.iterm2"
        case "terminal": return "com.apple.Terminal"
        default: return app
        }
    }

    private static func appURL(named name: String) -> URL? {
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate() }
        return String(data: data, encoding: .utf8)
    }
}
