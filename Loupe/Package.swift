// swift-tools-version:5.9
import PackageDescription
import Foundation

// Package.swift lives at <repo>/Loupe/Package.swift; the Rust staticlib is at <repo>/target/universal/release.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSysmon", path: "Sources/CSysmon"),
        .executableTarget(
            name: "Loupe",
            dependencies: ["CSysmon"],
            path: "Sources/Loupe",
            linkerSettings: [
                .unsafeFlags(["-L\(repoRoot)/target/universal/release"]),
                .linkedLibrary("sysmon_core"),
            ]
        ),
        .testTarget(name: "LoupeTests", dependencies: ["Loupe"], path: "Tests/LoupeTests"),
    ]
)
