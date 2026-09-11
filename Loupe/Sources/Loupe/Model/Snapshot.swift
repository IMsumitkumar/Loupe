// Codable mirror of the JSON produced by sysmon-core (engine.rs `Snapshot`).
// Every struct is Equatable so SwiftUI skips redraws when nothing changed; the
// Rust side rounds floats to display precision before serialising.

import Foundation

struct Snapshot: Codable, Equatable {
    var seq: UInt64
    var generatedAtMs: UInt64
    var mole: Mole?
    var moleStatus: MoleStatus
    var verdict: Verdict
    var energyMode: String
    var apps: [App]
    var processes: [Proc]
    var history: History
    var cores: Cores
    var system: SystemFallback
    var selfStats: SelfStats

    // Volatile per-tick counters are excluded so unchanged data compares equal.
    static func == (a: Snapshot, b: Snapshot) -> Bool {
        a.mole == b.mole && a.verdict == b.verdict && a.energyMode == b.energyMode && a.apps == b.apps
            && a.processes == b.processes && a.history == b.history && a.cores == b.cores && a.system == b.system
            && a.moleStatus.state == b.moleStatus.state && a.moleStatus.live == b.moleStatus.live && a.moleStatus.failures == b.moleStatus.failures
            && a.moleStatus.path == b.moleStatus.path
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

struct Mole: Codable, Equatable {
    var collectedAt: String
    var host: String
    var platform: String
    var uptime: String
    var uptimeSeconds: UInt64
    var procs: UInt64
    var hardware: Hardware
    var healthScore: Int
    var healthScoreMsg: String
    var cpu: Cpu
    var gpu: [Gpu]
    var memory: Memory
    var disks: [Disk]
    var trashSize: UInt64
    var trashApprox: Bool
    var diskIo: DiskIo
    var network: [Network]
    var batteries: [Battery]
    var thermal: Thermal
    var topProcesses: [MoleProcess]
    var processCollectedAt: String?
    var processStale: Bool?
    var zombieCount: Int?
}

struct Hardware: Codable, Equatable {
    var model: String, cpuModel: String, totalRam: String, diskSize: String, osVersion: String, refreshRate: String
}
struct Cpu: Codable, Equatable {
    var usage: Double, perCore: [Double], perCoreEstimated: Bool, load1: Double, load5: Double, load15: Double
    var coreCount: Int, logicalCpu: Int, pCoreCount: Int, eCoreCount: Int
}
struct Gpu: Codable, Equatable { var name: String, usage: Double, memoryUsed: Double, memoryTotal: Double, coreCount: Int, note: String }
struct Memory: Codable, Equatable {
    var used: UInt64, total: UInt64, available: UInt64, usedPercent: Double, swapUsed: UInt64, swapTotal: UInt64, cached: UInt64, pressure: String
}
struct Disk: Codable, Equatable {
    var mount: String, device: String, used: UInt64, total: UInt64, usedPercent: Double, fstype: String, external: Bool, smartStatus: String, purgeable: UInt64
}
struct DiskIo: Codable, Equatable { var readRate: Double, writeRate: Double }
struct Network: Codable, Equatable { var name: String, rxRateMbs: Double, txRateMbs: Double, ip: String }
struct Battery: Codable, Equatable { var percent: Double, status: String, timeLeft: String, health: String, cycleCount: Int, capacity: Int }
struct Thermal: Codable, Equatable {
    var cpuTemp: Double, gpuTemp: Double, batteryTemp: Double, fanSpeed: Int, fanCount: Int, systemPower: Double, adapterPower: Double, batteryPower: Double
}
struct MoleProcess: Codable, Equatable { var pid: Int32, ppid: Int32, name: String, command: String, cpu: Double, memory: Double, memoryBytes: UInt64 }

struct MoleStatus: Codable, Equatable {
    var state: String
    var live: Bool
    var path: String?
    var version: String?
    var failures: UInt32
    var lines: UInt64
    var decodeErrors: UInt64
    var badKeys: [String]
    var lastLineAgeMs: UInt64?
    var intervalSecs: UInt64
    var childPid: Int32?
    var stderr: [String]
}

struct Penalties: Codable, Equatable {
    var cpu: Double, memory: Double, disk: Double, thermal: Double, io: Double, battery: Double, uptime: Double
    var issues: [String]
}
struct Culprit: Codable, Equatable { var key: String, name: String, rootPid: Int32, detail: String, quitOk: Bool }
struct Verdict: Codable, Equatable {
    var score: Int?
    var approximate: Bool
    var band: String
    var driver: String
    var flagged: Bool
    var headline: String
    var explanation: String
    var culprit: Culprit?
    var issues: [String]
    var penalties: Penalties
}

struct Proc: Codable, Equatable, Identifiable {
    var id: Int32 { pid }
    var pid: Int32, ppid: Int32, name: String, path: String
    var cpu: Float?, memory: UInt64?, energyW: Float?, wakeups: Float?, diskBps: Float?
    var impact: Float, cpuSource: String, forceQuitOk: Bool
}
struct App: Codable, Equatable, Identifiable {
    var id: String { key }
    var key: String, name: String, kind: String, path: String, rootPid: Int32, procs: UInt32
    var cpu: Float?, memory: UInt64, energyW: Float?, impact: Float, wakeups: Float, diskBps: Float
    var cpuSource: String, quitOk: Bool, forceQuitOk: Bool, isSelf: Bool
    var children: [Proc]
}

struct History: Codable, Equatable {
    var cpu: [Float?], cpuP: [Float?], cpuE: [Float?], memUsedPct: [Float?], swapUsedGb: [Float?], pressureLevel: [Float?]
    var netRx: [Float?], netTx: [Float?], diskR: [Float?], diskW: [Float?], powerW: [Float?], topImpact: [Float?]
}
struct Cores: Codable, Equatable { var p: [Float], e: [Float], all: [Float], estimated: Bool, split: Bool, source: String }
struct SystemFallback: Codable, Equatable { var cpuUsage: Float?, memUsed: UInt64?, memTotal: UInt64? }
struct SelfStats: Codable, Equatable {
    var pid: Int32
    var cpu: Float?, memory: UInt64?, wakeupsPerS: Float?, energyW: Float?
    var childCpu: Float?, childMemory: UInt64?, treeCpu: Float?, treeMemory: UInt64?
    var sampleMs: Float, tickMs: Float, snapshotBytes: Int, pidsTotal: Int, pidsReadable: Int
    var avgCpuSinceLaunch: Float, uptimeS: UInt64
}

// Convenience readings used by several views.
extension Snapshot {
    var cpuUsage: Double? { mole?.cpu.usage ?? system.cpuUsage.map(Double.init) }
    var memUsedPct: Double? {
        if let m = mole { return m.memory.usedPercent }
        if let u = system.memUsed, let t = system.memTotal, t > 0 { return Double(u) / Double(t) * 100 }
        return nil
    }
    var memUsed: UInt64? { mole?.memory.used ?? system.memUsed }
    var memTotal: UInt64? { mole?.memory.total ?? system.memTotal }
    var bootDisk: Disk? { mole?.disks.first }
    var netRx: Double { mole?.network.reduce(0) { $0 + $1.rxRateMbs } ?? 0 }
    var netTx: Double { mole?.network.reduce(0) { $0 + $1.txRateMbs } ?? 0 }
    var moleAlive: Bool { moleStatus.state == "running" && mole != nil }
    var topApp: App? { apps.first }
}
