import AppKit
import SwiftUI

struct StorageTab: View {
    @EnvironmentObject var engine: Engine
    @State private var state: ScanState = .idle
    enum ScanState { case idle, running, done(MoleAdapter.Analysis), failed(String) }

    var body: some View {
        let snap = engine.snapshot
        VStack(alignment: .leading, spacing: 10) {
            if let d = snap?.bootDisk {
                Text("Your disk is \(Int(d.usedPercent))% full: \(Fmt.bytes(d.used)) of \(Fmt.bytes(d.total)) used, \(Fmt.bytes(d.total > d.used ? d.total - d.used : 0)) free.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if d.purgeable > 0 {
                    Text("\(Fmt.bytes(d.purgeable)) of that is purgeable: macOS frees it on its own when needed.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Disk size is not measured yet.").font(.callout).foregroundStyle(.secondary)
            }
            if engine.moPath == nil {
                MoleMissingView(feature: "disk scans").padding(.horizontal, -14)
            } else {
            switch state {
            case .idle:
                HStack {
                    Button("Scan with Mole") { scan() }
                    Text("Walks your home folder. Takes a while; never runs on its own.").font(.caption2).foregroundStyle(.tertiary)
                }
            case .running:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Mole is measuring your folders…").font(.caption).foregroundStyle(.secondary) }
            case .failed(let msg):
                Text("Scan failed: \(msg)").font(.caption).foregroundStyle(Palette.crit)
                Button("Try again") { scan() }
            case .done(let a):
                result(a)
            }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private func scan() {
        state = .running
        MoleAdapter.analyze(path: nil) { r in
            switch r {
            case .success(let a): state = .done(a)
            case .failure(let e): state = .failed(e.localizedDescription)
            }
        }
    }

    @ViewBuilder private func result(_ a: MoleAdapter.Analysis) -> some View {
        let entries = a.entries.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let top = entries.first
        Text(top.map { "\($0.name) is the biggest at \(Fmt.bytes(Double($0.size))) of \(Fmt.bytes(Double(a.totalSize))) measured." } ?? "Nothing measurable was found.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        Treemap(items: entries.prefix(14).map { ($0.name, Double($0.size), $0.cleanable ?? false) })
            .frame(width: 368, height: 150)
            .accessibilityLabel("Disk usage by folder")
            .accessibilityValue(entries.prefix(5).map { "\($0.name) \(Fmt.bytes(Double($0.size)))" }.joined(separator: ", "))
        VStack(spacing: 0) {
            ForEach(entries.prefix(10)) { e in
                HStack(spacing: 6) {
                    Image(systemName: e.isDir ? "folder" : "doc").font(.caption).foregroundStyle(.secondary)
                    Text(e.name).font(.callout).lineLimit(1)
                    if e.cleanable == true {
                        Text("Mole can clean").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .help("Mole judges this safe to remove. Nothing is deleted from here; use Clean up to let Mole ask you.")
                    }
                    Spacer()
                    Text(Fmt.bytes(Double(e.size))).font(.callout).monospacedDigit()
                }
                .padding(.vertical, 3)
                .contextMenu { Button("Reveal in Finder") { Actions.reveal(path: e.path) } }
                Divider().opacity(0.4)
            }
        }
        if let files = a.largeFiles, !files.isEmpty {
            Text("Largest files").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(files.prefix(8)) { f in
                HStack {
                    Text(f.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(Double(f.size))).font(.caption).monospacedDigit()
                }
                .contextMenu { Button("Reveal in Finder") { Actions.reveal(path: f.path) } }
            }
        }
        HStack {
            Button("Rescan") { scan() }
            Button("Open in Mole") { MoleAdapter.openInTerminal(["analyze"]) }
        }
        .controlSize(.small)
    }
}

/// Squarified treemap in a Canvas. Greyscale by rank; cleanable items get a dotted border.
struct Treemap: View {
    var items: [(String, Double, Bool)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let rects = Treemap.layout(items.map { $0.1 }, in: CGRect(origin: .zero, size: size))
            for (i, r) in rects.enumerated() where r.width > 1 && r.height > 1 {
                let inset = r.insetBy(dx: 1, dy: 1)
                let fill = Palette.series(i < Palette.slots ? i : nil, scheme).opacity(i < Palette.slots ? 0.8 : 0.5)
                ctx.fill(Path(roundedRect: inset, cornerRadius: 2), with: .color(fill))
                if items[i].2 {
                    ctx.stroke(Path(roundedRect: inset, cornerRadius: 2), with: .color(Color.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                if inset.width > 44, inset.height > 24 {
                    let label = Text(items[i].0).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.95))
                    ctx.draw(label, in: inset.insetBy(dx: 4, dy: 3))
                }
            }
        }
    }

    static func worstAspect(_ row: [Double], sum: Double, side: Double) -> Double {
        var worst = 0.0
        let s2 = side * side, sum2 = sum * sum
        for a in row {
            let r1 = s2 * a / sum2
            let r2 = sum2 / (s2 * a)
            worst = Swift.max(worst, Swift.max(r1, r2))
        }
        return worst
    }

    /// Bruls et al. squarified layout: fills the shorter side with a row whose aspect ratios are as square as possible.
    static func layout(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, !bounds.isEmpty else { return values.map { _ in .zero } }
        var out: [CGRect] = []
        var rect = bounds
        var remaining = values.map { $0 / total * Double(bounds.width * bounds.height) }
        while !remaining.isEmpty {
            let short = Double(min(rect.width, rect.height))
            var row: [Double] = []
            var best = Double.infinity
            var idx = 0
            while idx < remaining.count {
                let cand = row + [remaining[idx]]
                let sum = cand.reduce(0, +)
                let worst = Treemap.worstAspect(cand, sum: sum, side: short)
                if worst > best { break }
                best = worst
                row = cand
                idx += 1
            }
            if row.isEmpty { row = [remaining[0]]; idx = 1 }
            let sum = row.reduce(0, +)
            let horizontal = rect.width >= rect.height
            let thickness = sum / short
            var offset = 0.0
            for area in row {
                let length = area / thickness
                let r = horizontal
                    ? CGRect(x: rect.minX, y: rect.minY + offset, width: thickness, height: length)
                    : CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: thickness)
                out.append(r)
                offset += length
            }
            if horizontal {
                rect = CGRect(x: rect.minX + thickness, y: rect.minY, width: rect.width - thickness, height: rect.height)
            } else {
                rect = CGRect(x: rect.minX, y: rect.minY + thickness, width: rect.width, height: rect.height - thickness)
            }
            remaining.removeFirst(idx)
            if rect.width <= 0 || rect.height <= 0 { out += remaining.map { _ in .zero }; break }
        }
        return out
    }
}
