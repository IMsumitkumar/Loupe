import SwiftUI

struct OverviewTab: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var config: Config

    var body: some View {
        let snap = engine.snapshot
        let readings = config.systemPanels.prefix(4).compactMap { p in Metric(rawValue: p.metric).map { (p, Readings.tile($0, snap, prefs.thresholds)) } }
        let flagged = readings.filter { $0.1.state != .ok }
        VStack(alignment: .leading, spacing: 10) {
            Text(sentence(flagged.count, snap)).font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.fixed(180), spacing: 8), GridItem(.fixed(180), spacing: 8)], spacing: 8) {
                ForEach(readings, id: \.0.id) { p, r in StatTile(reading: r, title: p.label) }
            }
            VStack(alignment: .leading, spacing: 6) {
                if flagged.isEmpty {
                    Text("Every check passed. Nothing to explain.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(flagged, id: \.0.id) { _, r in
                        HStack(alignment: .top, spacing: 6) {
                            StateDot(state: r.state).padding(.top, 4)
                            Text(r.reason ?? "").font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func sentence(_ n: Int, _ s: Snapshot?) -> String {
        guard s != nil else { return "Taking the first reading." }
        if n == 0 { return "Nothing is out of the ordinary right now." }
        return n == 1 ? "One reading needs a look." : "\(n) readings need a look."
    }
}

struct StatTile: View {
    var reading: TileReading
    var title: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                StateDot(state: reading.state)
                Text(title ?? reading.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !reading.series.isEmpty { TrendGlyph(trend: reading.trend) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading.value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(reading.unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(reading.context).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(width: 180, height: 92, alignment: .topLeading)
        .background(alignment: .bottom) {
            if !reading.series.isEmpty {
                Sparkline(values: Array(reading.series.suffix(120)), color: Palette.series(reading.slot, scheme)).frame(height: 22).padding(.horizontal, 1)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(reading.available ? 1 : 0.6)
        .help(reading.technical)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? reading.label)
        .accessibilityValue(reading.accessibilityValue)
    }
}
