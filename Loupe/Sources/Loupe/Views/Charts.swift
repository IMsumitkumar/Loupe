// Three chart types, all Path-based: sparkline, share bar, core grid. No
// pies, gauges or radial anything. Values never animate.

import SwiftUI

struct Sparkline: View {
    var values: [Float?]
    var max: Float? = nil
    var lineWidth: CGFloat = 1.2
    var fill = true
    var color: Color = .primary

    var body: some View {
        GeometryReader { geo in
            let paths = Sparkline.paths(values, max: max, size: geo.size)
            ZStack {
                if fill { paths.area.fill(color.opacity(0.14)) }
                paths.line.stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            }
        }
    }

    /// Line and filled area; a nil sample lifts the pen so gaps stay gaps.
    static func paths(_ values: [Float?], max: Float?, size: CGSize) -> (line: Path, area: Path) {
        let vals = values.compactMap { $0 }
        let top = Swift.max(max ?? (vals.max() ?? 1), 0.001)
        let w = size.width, h = size.height
        let n = Swift.max(values.count - 1, 1)
        var line = Path()
        var area = Path()
        var pen = false
        for (i, v) in values.enumerated() {
            guard let v else { pen = false; continue }
            let p = CGPoint(x: w * CGFloat(i) / CGFloat(n), y: h - h * CGFloat(min(v, top) / top))
            if pen {
                line.addLine(to: p)
                area.addLine(to: p)
            } else {
                line.move(to: p)
                area.move(to: CGPoint(x: p.x, y: h))
                area.addLine(to: p)
            }
            pen = true
            let nextNil = i + 1 >= values.count || values[i + 1] == nil
            if nextNil { area.addLine(to: CGPoint(x: p.x, y: h)); area.closeSubpath() }
        }
        return (line, area)
    }
}

struct MirroredSparkline: View {
    var up: [Float?]
    var down: [Float?]
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height / 2
            VStack(spacing: 0) {
                Sparkline(values: up, max: sharedMax).frame(height: h)
                Sparkline(values: down, max: sharedMax).frame(height: h).scaleEffect(y: -1)
            }
            .overlay(Rectangle().fill(Color.primary.opacity(0.25)).frame(height: 1), alignment: .center)
        }
    }
    private var sharedMax: Float { Swift.max((up + down).compactMap { $0 }.max() ?? 1, 0.001) }
}

struct MicroSparkline: View {
    var values: [Float?]
    var color: Color = .primary
    var body: some View {
        Sparkline(values: values, lineWidth: 1.2, fill: false, color: color).frame(width: 46, height: 15)
    }
}

struct ShareSegment: Identifiable {
    var id: String { label }
    var label: String
    var value: Double
    /// Palette slot; nil is the neutral "Everything else" or an overflow beyond five.
    var slot: Int? = nil
}

/// One horizontal bar split by app in fixed palette slots, "Everything else" neutral and last.
struct ShareBar: View {
    var segments: [ShareSegment]
    @Environment(\.colorScheme) private var scheme
    var total: Double { segments.reduce(0) { $0 + $1.value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                        Rectangle()
                            .fill(shade(i))
                            .frame(width: Swift.max(0, (geo.size.width - CGFloat(segments.count - 1)) * CGFloat(total > 0 ? s.value / total : 0)))
                    }
                }
            }
            .frame(width: 368, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(spacing: 10) {
                ForEach(Array(segments.prefix(4).enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(shade(i)).frame(width: 8, height: 8)
                        Text("\(s.label) \(Int((total > 0 ? s.value / total : 0) * 100))%").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share by app")
        .accessibilityValue(segments.map { "\($0.label) \(Int((total > 0 ? $0.value / total : 0) * 100)) percent" }.joined(separator: ", "))
    }

    private func shade(_ i: Int) -> Color {
        Palette.series(segments[i].slot, scheme)
    }
}

/// One block per core; fast and efficient clusters separated by a gap, each its own hue, shade by load.
struct CoreGrid: View {
    var cores: Cores
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if cores.split {
                HStack(alignment: .top, spacing: 16) {
                    cluster(cores.p, "\(cores.p.count) fast cores", "performance cluster, hw.perflevel0", Palette.series(0, scheme))
                    cluster(cores.e, "\(cores.e.count) efficient cores", "efficiency cluster, hw.perflevel1", Palette.series(1, scheme))
                }
            } else {
                cluster(cores.all, "\(cores.all.count) cores", "per-core usage; this Mac reports no fast/efficient split", Palette.series(0, scheme))
            }
            if cores.estimated {
                Text("Per-core figures are approximate on this Mac.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func cluster(_ v: [Float], _ label: String, _ tech: String, _ hue: Color) -> some View {
        let mean = v.isEmpty ? 0 : v.reduce(0, +) / Float(v.count)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(Array(v.enumerated()), id: \.offset) { i, u in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hue.opacity(0.18 + 0.82 * Double(min(u, 100) / 100)))
                        .frame(width: 18, height: 18)
                        .help("core \(i): \(Int(u))%")
                }
            }
            Text("\(label) · \(Int(mean))%").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(tech)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(mean)) percent busy on average")
    }
}
