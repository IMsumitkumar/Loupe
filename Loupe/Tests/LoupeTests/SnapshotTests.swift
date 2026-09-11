// Renders every tile type at every state, light and dark, at the default and the
// largest Dynamic Type size, and compares against stored PNGs. First run records.
// Delete Tests/__Snapshots__ to re-record after an intentional visual change.

import SwiftUI
import XCTest
@testable import Loupe

@MainActor
final class SnapshotTests: XCTestCase {
    private var dir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__", isDirectory: true)
    }

    private func check<V: View>(_ name: String, _ view: V, file: StaticString = #filePath, line: UInt = #line) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return XCTFail("no image for \(name)", file: file, line: line) }
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        let url = dir.appendingPathComponent("\(name).png")
        if let existing = try? Data(contentsOf: url) {
            XCTAssertEqual(existing, png, "\(name) changed; delete the stored PNG to re-record", file: file, line: line)
        } else {
            try png.write(to: url)
        }
    }

    private func reading(_ state: State3) -> TileReading {
        let series: [Float?] = (0..<60).map { Float(30 + 20 * sin(Double($0) / 6)) }
        return TileReading(label: "Memory", value: "21.0 GB", unit: "of 24 GB", context: state == .ok ? "Pressure normal, no swap" : "Pressure rising · swap 1.2 GB",
                           state: state, series: series, trend: .up, reason: nil, technical: "memory.pressure")
    }

    func testTilesAtEveryStateSchemeAndSize() throws {
        for state in [State3.ok, .warn, .crit] {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility5] {
                    let name = "tile-\(state)-\(scheme == .dark ? "dark" : "light")-\(size == .large ? "default" : "largest")"
                    let view = StatTile(reading: reading(state)).padding(8)
                        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size)
                    try check(name, view)
                }
            }
        }
    }

    func testChartsBothSchemes() throws {
        let cores = Cores(p: [80, 60, 20, 5], e: [50, 45, 40, 38], all: [50, 45, 40, 38, 80, 60, 20, 5], estimated: false, split: true, source: "mole")
        let flat = Cores(p: [], e: [], all: [10, 20, 30, 40], estimated: true, split: false, source: "mole")
        let shares = [ShareSegment(label: "Google Chrome", value: 9.4), ShareSegment(label: "Xcode", value: 3.1), ShareSegment(label: "Everything else", value: 6.2)]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let bg = scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)
            try check("coregrid-split-\(suffix)", CoreGrid(cores: cores).padding(8).background(bg).environment(\.colorScheme, scheme))
            try check("coregrid-flat-\(suffix)", CoreGrid(cores: flat).padding(8).background(bg).environment(\.colorScheme, scheme))
            try check("sharebar-\(suffix)", ShareBar(segments: shares).padding(8).background(bg).environment(\.colorScheme, scheme))
            try check("sparkline-gap-\(suffix)", Sparkline(values: [1, 2, 3, nil, nil, 4, 5, 2]).frame(width: 120, height: 30).padding(8).background(bg).environment(\.colorScheme, scheme))
        }
    }
}
